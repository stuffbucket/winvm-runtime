#!/usr/bin/env python3
"""usage: paths.py RUNTIME_DIR SCRATCH_DIR

Runs, on TCG and without a guest OS, the QEMU paths winvm uses beyond a plain
start (winvm-design/packages/core/src: qemu.ts, saves.ts, snapshot.ts,
agentfwd.ts, display.ts, instance.ts), so a build that drops or breaks one
fails here rather than on someone's Mac. Prints one ok/FAIL line each; exits 1
on any FAIL.
"""
from __future__ import annotations

import atexit
import json
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

rt = Path(sys.argv[1])
tmp = Path(sys.argv[2])
qemu = str(rt / "bin" / "qemu-system-aarch64")
img = str(rt / "bin" / "qemu-img")
zstd = str(rt / "bin" / "zstd")
failed = False
started: list[subprocess.Popen] = []


@atexit.register
def stop_all() -> None:
    # A check that raises leaves its QEMU running; none may outlive the script.
    for p in started:
        if p.poll() is None:
            p.kill()
            p.wait()


def report(name: str, ok: bool, why: str = "") -> None:
    global failed
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'' if ok else f': {why}'}")
    failed |= not ok


class Qmp:
    def __init__(self, path: Path) -> None:
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(str(path))
                break
            except OSError:
                time.sleep(0.1)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name: str, **args: object) -> dict:
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "event" not in r:
                if "error" in r:
                    raise RuntimeError(f"{name}: {r['error']['desc']}")
                return r["return"]

    def hmp(self, line: str) -> str:
        return str(self.cmd("human-monitor-command", **{"command-line": line}))


def vm(tag: str, *extra: str) -> tuple[subprocess.Popen, Qmp]:
    sock = tmp / f"{tag}.qmp"
    p = subprocess.Popen(
        [qemu, "-M", "virt", "-cpu", "max", "-accel", "tcg", "-m", "256", "-nodefaults", "-display", "none",
         "-device", "ramfb", "-device", "qemu-xhci,id=usb-bus",
         "-drive", f"if=none,media=disk,id=hd0,file={tmp / 'disk.qcow2'}", "-device", "virtio-blk-pci,drive=hd0",
         "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
         "-qmp", f"unix:{sock},server=on,wait=off", *extra],
        stdout=subprocess.DEVNULL, stderr=open(tmp / f"{tag}.log", "w"))
    started.append(p)
    return p, Qmp(sock)


def finish(p: subprocess.Popen, q: Qmp) -> None:
    try:
        q.cmd("quit")
    except Exception:
        pass
    p.wait(timeout=30)


def wait_migration(q: Qmp) -> str:
    for _ in range(600):
        st = q.cmd("query-migrate").get("status", "")
        if st in ("completed", "failed", "cancelled"):
            return st
        time.sleep(0.1)
    return "timeout"


def wait_incoming(q: Qmp) -> str:
    for _ in range(600):
        st = q.cmd("query-status")["status"]
        if st not in ("inmigrate",):
            return st
        time.sleep(0.1)
    return "timeout"


def run(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


# qemu-img, as instance.ts, commands.ts and snapshot.ts run it.
base, overlay, vars_raw, vars_q = (tmp / n for n in ("base.qcow2", "disk.qcow2", "vars.fd", "vars.qcow2"))
vars_raw.write_bytes(b"\0" * 64 * 1024 * 1024)
steps = [
    (img, "create", "-f", "qcow2", str(base), "64G"),
    (img, "create", "-f", "qcow2", "-b", str(base), "-F", "qcow2", str(overlay)),
    (img, "convert", "-f", "raw", "-O", "qcow2", str(vars_raw), str(vars_q)),
    (img, "snapshot", "-l", str(overlay)),
]
bad = [r for r in (run(*s) for s in steps) if r.returncode != 0]
report("qemu-img create, backing file, convert, snapshot -l", not bad, bad[0].stderr.strip() if bad else "")

# Saves in each RAM format (saves.ts migrationPlan): zstd through exec:, raw file:, mapped-ram + multifd.
plans = {
    "zstd": (f"exec:'{zstd}' -T0 -3 -q -f - -o '{tmp / 'ram.zst'}'", f"exec:'{zstd}' -dc '{tmp / 'ram.zst'}'", False),
    "raw": (f"file:{tmp / 'ram.raw'}", f"file:{tmp / 'ram.raw'}", False),
    "mapped": (f"file:{tmp / 'ram.mapped'}", f"file:{tmp / 'ram.mapped'}", True),
}
for fmt, (out_uri, in_uri, mapped) in plans.items():
    try:
        caps = [{"capability": c, "state": mapped} for c in ("mapped-ram", "multifd")]
        params = {"max-bandwidth": 64 * 1024**3, **({"multifd-channels": 8} if mapped else {})}
        p, q = vm(f"src-{fmt}")
        q.cmd("stop")
        q.cmd("migrate-set-capabilities", capabilities=caps)
        q.cmd("migrate-set-parameters", **params)
        q.cmd("migrate", uri=out_uri)
        out = wait_migration(q)
        finish(p, q)
        if mapped:
            p, q = vm(f"dst-{fmt}", "-incoming", "defer")
            q.cmd("migrate-set-capabilities", capabilities=caps)
            q.cmd("migrate-set-parameters", **params)
            q.cmd("migrate-incoming", uri=in_uri)
        else:
            p, q = vm(f"dst-{fmt}", "-incoming", in_uri)
        got = wait_incoming(q)
        finish(p, q)
        report(f"save and load ({fmt})", out == "completed" and got in ("paused", "postmigrate"), f"save {out}, load {got}")
    except Exception as e:
        report(f"save and load ({fmt})", False, str(e))

# Snapshots (snapshot.ts): savevm, info snapshots, loadvm, delvm, on a qcow2 disk.
try:
    p, q = vm("snap", "-S")
    errs = [r for r in (q.hmp("savevm accept"), q.hmp("loadvm accept")) if "rror" in r]
    listed = "accept" in q.hmp("info snapshots")
    errs += [r for r in (q.hmp("delvm accept"),) if "rror" in r]
    finish(p, q)
    report("savevm, info snapshots, loadvm, delvm", not errs and listed, "; ".join(errs) or "not listed")
except Exception as e:
    report("savevm, info snapshots, loadvm, delvm", False, str(e))

# Port forwards (agentfwd.ts): hostfwd_add, info usernet read with agentfwd's regex, hostfwd_remove.
try:
    p, q = vm("fwd", "-S")
    q.hmp("hostfwd_add net0 tcp:127.0.0.1:47801-:7801")
    listed = re.search(r"TCP\[HOST_FORWARD\]\s+\d+\s+127\.0\.0\.1\s+47801\s+\S+\s+7801", q.hmp("info usernet")) is not None
    removed = "rror" not in q.hmp("hostfwd_remove net0 tcp:127.0.0.1:47801")
    finish(p, q)
    report("slirp hostfwd_add, info usernet, hostfwd_remove", listed and removed, "forward not listed" if not listed else "remove failed")
except Exception as e:
    report("slirp hostfwd_add, info usernet, hostfwd_remove", False, str(e))

# The opt-in display (display.ts): virtio-gpu-pci at a set size, PNG screendump.
try:
    p, q = vm("gpu", "-S", "-device", "virtio-gpu-pci,xres=1920,yres=1080")
    q.cmd("screendump", filename=str(tmp / "gpu.png"), format="png")
    finish(p, q)
    report("virtio-gpu-pci display, PNG screendump", (tmp / "gpu.png").read_bytes()[:8] == b"\x89PNG\r\n\x1a\n")
except Exception as e:
    report("virtio-gpu-pci display, PNG screendump", False, str(e))

sys.exit(1 if failed else 0)
