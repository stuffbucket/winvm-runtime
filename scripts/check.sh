#!/usr/bin/env bash
# usage: check.sh TARBALL
# Unpacks the runtime somewhere unrelated and checks it stands alone: every
# binary runs, every library loads from the runtime itself, QEMU carries the
# hypervisor entitlement and has the devices winvm uses, vhost-user-fs-pci
# starts against virtiofsd, the paths winvm takes through QEMU work
# (paths.py), every file matches manifest.json, and the licences are there.
set -euo pipefail
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$tarball" -C "$tmp"
rt=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d)
fail=0

for b in qemu-system-aarch64 qemu-img swtpm zstd virtiofsd; do
  log=$(DYLD_PRINT_LIBRARIES=1 "$rt/bin/$b" --version 2>&1) || { echo "FAIL $b --version"; fail=1; continue; }
  if printf '%s\n' "$log" | grep -E '^dyld\[[0-9]+\]: <[^>]*> /' | grep -vE "$rt/|/usr/lib/|/System/" | grep -q .; then
    echo "FAIL $b loads a library from outside the runtime:"
    printf '%s\n' "$log" | grep -E '^dyld\[' | grep -vE "$rt/|/usr/lib/|/System/" | head -3
    fail=1
  else
    echo "ok   $b"
  fi
done

if codesign -d --entitlements - "$rt/bin/qemu-system-aarch64" 2>&1 | grep -q com.apple.security.hypervisor; then
  echo "ok   hypervisor entitlement"
else
  echo "FAIL qemu-system-aarch64 lacks com.apple.security.hypervisor"
  fail=1
fi

devices=$("$rt/bin/qemu-system-aarch64" -M virt -device help 2>&1)
for d in qemu-xhci nvme virtio-blk-pci virtio-net-pci virtio-serial-pci tpm-tis-device ramfb usb-storage usb-kbd usb-tablet \
  vhost-user-fs-pci virtserialport; do
  printf '%s\n' "$devices" | grep -q "\"$d\"" || { echo "FAIL device $d missing"; fail=1; }
done
echo "ok   devices"

# The shared folder's guest RAM must be shareable with virtiofsd, and the
# clipboard rides the qemu-vdagent chardev (spice-protocol headers only).
"$rt/bin/qemu-system-aarch64" -object help 2>&1 | grep -qx '  memory-backend-shm' || { echo "FAIL memory-backend-shm missing"; fail=1; }
if "$rt/bin/qemu-system-aarch64" -M virt -chardev help 2>&1 | grep -qx '  qemu-vdagent'; then
  echo "ok   qemu-vdagent chardev"
else
  echo "FAIL qemu-vdagent chardev missing"
  fail=1
fi
if otool -L "$rt/bin/qemu-system-aarch64" | grep -qi spice; then
  echo "FAIL qemu-system-aarch64 links spice-server; only spice-protocol's headers belong in the build"
  fail=1
fi

# The shared folder: QEMU's vhost-user-fs-pci against the runtime's virtiofsd,
# as winvm starts them. Realizing the device is the vhost-user handshake
# (GET_FEATURES, SET_OWNER, GET_PROTOCOL_FEATURES...); a QEMU that answers QMP
# with the device on its PCI bus completed it. virtiofsd must exit once QEMU
# disconnects, since winvm starts one per QEMU.
mkdir -p "$tmp/vfs/share"
"$rt/bin/virtiofsd" --shared-dir "$tmp/vfs/share" --socket-path "$tmp/vfs/vfs.sock" --sandbox none --cache auto \
  --migration-on-error guest-error --readonly > "$tmp/vfs/virtiofsd.log" 2>&1 &
vpid=$!
for _ in $(seq 1 50); do [ -S "$tmp/vfs/vfs.sock" ] && break; sleep 0.1; done
printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"query-pci"}' '{"execute":"quit"}' |
  "$rt/bin/qemu-system-aarch64" -M virt,memory-backend=mem -cpu max -accel tcg -m 256 -display none -nodefaults \
    -object memory-backend-shm,id=mem,size=256M,share=on \
    -chardev socket,id=vfs0,path="$tmp/vfs/vfs.sock" -device vhost-user-fs-pci,chardev=vfs0,tag=winvm,queue-size=1024 \
    -chardev qemu-vdagent,id=vdagent,clipboard=on,mouse=off -device virtio-serial-pci \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 -S -qmp stdio > "$tmp/vfs/qmp.log" 2>&1 || true
for _ in $(seq 1 50); do kill -0 "$vpid" 2> /dev/null || break; sleep 0.1; done
if python3 -c 'import json, sys
for line in open(sys.argv[1]):
    try:
        r = json.loads(line).get("return")
    except ValueError:
        continue
    for bus in r if isinstance(r, list) else []:
        if any(d["id"]["vendor"] == 0x1AF4 and d["id"]["device"] == 0x105A for d in bus.get("devices", [])):
            sys.exit(0)
sys.exit(1)' "$tmp/vfs/qmp.log" && grep -q "Client connected" "$tmp/vfs/virtiofsd.log"; then
  echo "ok   vhost-user-fs-pci with virtiofsd (handshake, clipboard chardev)"
else
  echo "FAIL vhost-user-fs-pci with virtiofsd:"
  grep -v '^{"QMP"' "$tmp/vfs/qmp.log" | grep -v '"return": {}' | head -3
  tail -3 "$tmp/vfs/virtiofsd.log"
  fail=1
fi
if kill -0 "$vpid" 2> /dev/null; then
  echo "FAIL virtiofsd kept running after QEMU disconnected"
  kill "$vpid"
  fail=1
fi
wait "$vpid" 2> /dev/null || true

if printf 'quit\n' | "$rt/bin/qemu-system-aarch64" -M virt -cpu max -accel tcg -m 256 -display none -nodefaults \
  -vnc 127.0.0.1:99,password=on -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -device ramfb -S -monitor stdio > "$tmp/start.log" 2>&1; then
  echo "ok   starts with VNC, ramfb and virtio-net (keymaps and option ROM found)"
else
  echo "FAIL QEMU does not start with winvm's display and network:"
  tail -3 "$tmp/start.log"
  fail=1
fi

# The browser view and the app reach the screen through QEMU's websocket. Its
# handshake hashes with the crypto backend (QEMU 11.1 crashed here with nettle 4).
"$rt/bin/qemu-system-aarch64" -M virt -cpu max -accel tcg -m 256 -display none -nodefaults \
  -vnc 127.0.0.1:98,websocket=127.0.0.1:5798,password=on -S -monitor none > "$tmp/ws.log" 2>&1 &
qpid=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 5798 2> /dev/null && break; sleep 0.2; done
curl -s -i --max-time 3 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Protocol: binary" \
  http://127.0.0.1:5798/ > "$tmp/ws.out" 2>&1 || true
if grep -q "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" "$tmp/ws.out" && kill -0 "$qpid" 2> /dev/null; then
  echo "ok   websocket handshake"
else
  echo "FAIL websocket handshake:"
  head -5 "$tmp/ws.out"
  tail -3 "$tmp/ws.log"
  fail=1
fi
kill "$qpid" 2> /dev/null
wait "$qpid" 2> /dev/null

# winvm's screenshots, OCR and computer use take PNG screendumps.
if printf '%s\n' '{"execute":"qmp_capabilities"}' "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$tmp/shot.png\",\"format\":\"png\"}}" '{"execute":"quit"}' |
  "$rt/bin/qemu-system-aarch64" -M virt -cpu max -accel tcg -m 256 -display none -nodefaults -device ramfb -S -qmp stdio > "$tmp/shot.log" 2>&1 &&
  [ "$(head -c 8 "$tmp/shot.png" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
  echo "ok   PNG screendump"
else
  echo "FAIL PNG screendump:"
  grep -o '"desc": *"[^"]*"' "$tmp/shot.log" | head -2
  fail=1
fi

# The paths winvm uses beyond a plain start: qemu-img, saves in each format,
# snapshots, port forwards, the virtio-gpu display.
mkdir -p "$tmp/paths"
python3 "$(dirname "$0")/paths.py" "$rt" "$tmp/paths" || fail=1

python3 - "$rt" <<'EOF' || fail=1
import hashlib, json, pathlib, sys
rt = pathlib.Path(sys.argv[1])
m = json.loads((rt / "manifest.json").read_text())
bad = [f for f, h in m["files"].items() if hashlib.sha256((rt / f).read_bytes()).hexdigest() != h]
extra = [str(p.relative_to(rt)) for p in rt.rglob("*") if p.is_file() and p.name != "manifest.json" and str(p.relative_to(rt)) not in m["files"]]
if bad or extra:
    print("FAIL manifest:", bad, extra)
    sys.exit(1)
print(f"ok   manifest ({len(m['files'])} files)")
EOF

# Every component that needs its notices shipped has a licence entry, and the
# files it names are in the runtime: virtiofsd's own licences and its crates'.
python3 - "$rt" <<'EOF' || fail=1
import json, pathlib, sys
rt = pathlib.Path(sys.argv[1])
m = json.loads((rt / "manifest.json").read_text())
lic = m.get("licenses", {}).get("virtiofsd")
if lic is None or lic.get("license") != "Apache-2.0 AND BSD-3-Clause":
    print("FAIL manifest has no licence entry for virtiofsd:", lic)
    sys.exit(1)
d = rt / lic["path"]
missing = [f for f in ("LICENSE-APACHE", "LICENSE-BSD-3-Clause", "crates.txt") if not (d / f).is_file()]
crates = (d / "crates.txt").read_text().splitlines() if (d / "crates.txt").is_file() else []
if missing or not crates or not any((d / "crates").iterdir()):
    print("FAIL virtiofsd licence files:", missing or "no crate notices")
    sys.exit(1)
print(f"ok   licences (virtiofsd and {len(crates)} crates)")
EOF

exit $fail
