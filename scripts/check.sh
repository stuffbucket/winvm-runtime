#!/usr/bin/env bash
# usage: check.sh TARBALL
# Unpacks the runtime somewhere unrelated and checks it stands alone: every
# binary runs, every library loads from the runtime itself, QEMU carries the
# hypervisor entitlement and has the devices winvm uses, and every file
# matches manifest.json.
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
