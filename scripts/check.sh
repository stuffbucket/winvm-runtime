#!/usr/bin/env bash
# usage: check.sh TARBALL
# Unpacks the runtime somewhere unrelated and checks it stands alone: every
# binary runs, every library loads from the runtime itself, QEMU carries the
# hypervisor entitlement and has the devices winvm uses, the paths winvm
# takes through QEMU work (paths.py), and every file matches manifest.json.
set -euo pipefail
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$tarball" -C "$tmp"
rt=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d)
fail=0

for b in qemu-system-aarch64 qemu-img swtpm zstd; do
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
for d in qemu-xhci nvme virtio-blk-pci virtio-net-pci virtio-serial-pci tpm-tis-device ramfb usb-storage usb-kbd usb-tablet; do
  printf '%s\n' "$devices" | grep -q "\"$d\"" || { echo "FAIL device $d missing"; fail=1; }
done
echo "ok   devices"

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

exit $fail
