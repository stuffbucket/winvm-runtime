#!/usr/bin/env python3
"""Package the winvm runtime from Homebrew kegs into a relocatable tarball.

usage: package.py VERSION OUTDIR

Copies qemu-system-aarch64, qemu-img, swtpm and zstd with every non-system
dylib they load (as regular files), rewrites load commands to the runtime's
own lib/, signs ad hoc (qemu-system-aarch64 with the hypervisor entitlement),
writes manifest.json and winvm-runtime-VERSION-darwin-arm64.tar.gz.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SYSTEM = ("/usr/lib/", "/System/")
DATA = ["efi-virtio.rom"]


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def brew_prefix(formula: str) -> Path:
    return Path(run("brew", "--prefix", formula).strip())


def is_macho(path: Path) -> bool:
    return "Mach-O" in run("file", "-b", str(path))


def load_commands(path: Path) -> tuple[list[str], list[str]]:
    deps, rpaths = [], []
    text = run("otool", "-l", str(path))
    for block in text.split("Load command")[1:]:
        cmd = re.search(r"cmd (\S+)", block)
        if cmd is None:
            continue
        if cmd.group(1) in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"):
            deps.append(re.search(r"name (\S+) \(offset", block).group(1))
        elif cmd.group(1) == "LC_RPATH":
            rpaths.append(re.search(r"path (\S+) \(offset", block).group(1))
    return deps, rpaths


def resolve(ref: str, loader: Path, rpaths: list[str]) -> Path:
    if ref.startswith("@loader_path/"):
        return (loader.parent / ref[len("@loader_path/") :]).resolve()
    if ref.startswith("@rpath/"):
        for rp in rpaths:
            base = Path(rp.replace("@loader_path", str(loader.parent)))
            candidate = base / ref[len("@rpath/") :]
            if candidate.exists():
                return candidate.resolve()
        raise SystemExit(f"{loader}: cannot resolve {ref} through {rpaths}")
    if ref.startswith("@"):
        raise SystemExit(f"{loader}: unsupported reference {ref}")
    return Path(ref).resolve()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def keg_of(path: Path) -> tuple[str, str] | None:
    m = re.search(r"/Cellar/([^/]+)/([^/]+)/", str(path))
    return (m.group(1), m.group(2)) if m else None


def main() -> None:
    version, outdir = sys.argv[1], Path(sys.argv[2]).resolve()
    name = f"winvm-runtime-{version}-darwin-arm64"
    stage = outdir / name
    shutil.rmtree(stage, ignore_errors=True)
    (stage / "bin").mkdir(parents=True)
    (stage / "lib").mkdir()
    (stage / "share" / "qemu").mkdir(parents=True)

    qemu = brew_prefix("winvm-qemu")
    executables = {
        "qemu-system-aarch64": qemu / "bin" / "qemu-system-aarch64",
        "qemu-img": qemu / "bin" / "qemu-img",
        "swtpm": brew_prefix("swtpm") / "bin" / "swtpm",
        "zstd": brew_prefix("zstd") / "bin" / "zstd",
    }

    libs: dict[str, Path] = {}
    edges: dict[Path, list[tuple[str, str]]] = {}
    queue = [p.resolve() for p in executables.values()]
    seen: set[Path] = set()
    while queue:
        src = queue.pop()
        if src in seen:
            continue
        seen.add(src)
        deps, rpaths = load_commands(src)
        edges[src] = []
        for ref in deps:
            if ref.startswith(SYSTEM):
                continue
            target = resolve(ref, src, rpaths)
            libname = Path(ref).name
            if libname in libs and libs[libname] != target:
                raise SystemExit(f"two libraries named {libname}: {libs[libname]} and {target}")
            libs[libname] = target
            edges[src].append((ref, libname))
            queue.append(target)

    copies: dict[Path, Path] = {}
    for exe, src in executables.items():
        copies[src.resolve()] = stage / "bin" / exe
    for libname, src in libs.items():
        copies[src] = stage / "lib" / libname
    for src, dst in copies.items():
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o755)

    for src, dst in copies.items():
        in_bin = dst.parent.name == "bin"
        args = []
        for ref, libname in edges[src]:
            new = f"@executable_path/../lib/{libname}" if in_bin else f"@loader_path/{libname}"
            args += ["-change", ref, new]
        if not in_bin:
            args += ["-id", f"@rpath/{dst.name}"]
        _, rpaths = load_commands(dst)
        for rp in rpaths:
            args += ["-delete_rpath", rp]
        if args:
            subprocess.run(["install_name_tool", *args, str(dst)], check=True, capture_output=True)

    for f in DATA:
        shutil.copyfile(qemu / "share" / "qemu" / f, stage / "share" / "qemu" / f)

    entitlements = HERE / "hvf.entitlements"
    for dst in copies.values():
        cmd = ["codesign", "--force", "--sign", "-"]
        if dst.name == "qemu-system-aarch64":
            cmd += ["--entitlements", str(entitlements)]
        subprocess.run([*cmd, str(dst)], check=True, capture_output=True)

    for dst in copies.values():
        text = run("otool", "-l", str(dst))
        if "/opt/homebrew" in text or "/usr/local/" in text or "/Cellar/" in text:
            raise SystemExit(f"{dst} still refers to a Homebrew path")

    components = {}
    for src in copies:
        keg = keg_of(src)
        if keg is not None:
            components[keg[0]] = keg[1]
    if os.environ.get("REQUIRE_SOURCE") == "1":
        poured = [
            f"{n} {v}"
            for n, v in components.items()
            if json.loads((Path(run("brew", "--cellar").strip()) / n / v / "INSTALL_RECEIPT.json").read_text()).get(
                "poured_from_bottle"
            )
        ]
        if poured:
            raise SystemExit(f"installed from bottles, not built from source: {', '.join(poured)}")
    patches = sorted(p for p in (ROOT / "patches").glob("*.patch"))
    patch_digest = hashlib.sha256(b"".join(p.read_bytes() for p in patches)).hexdigest()[:16] if patches else "none"
    files = {
        str(p.relative_to(stage)): sha256(p)
        for p in sorted(stage.rglob("*"))
        if p.is_file() and p.name != "manifest.json"
    }
    manifest = {
        "name": "winvm-runtime",
        "version": version,
        "qemu": components.get("winvm-qemu", "unknown"),
        "qemuPatches": patch_digest,
        "components": dict(sorted(components.items())),
        "macho": sorted(str(p.relative_to(stage)) for p in copies.values()),
        "files": files,
        "build": {
            "macos": run("sw_vers", "-productVersion").strip(),
            "machine": platform.machine(),
            "xcode": run("xcrun", "--show-sdk-version").strip(),
        },
    }
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    tarball = outdir / f"{name}.tar.gz"
    with tarfile.open(tarball, "w:gz") as tar:
        tar.add(stage, arcname=name)
    (outdir / f"{name}.tar.gz.sha256").write_text(f"{sha256(tarball)}  {tarball.name}\n")
    shutil.copyfile(stage / "manifest.json", outdir / f"{name}.manifest.json")
    print(tarball)


if __name__ == "__main__":
    main()
