# winvm-runtime

The QEMU, swtpm, zstd and virtiofsd that
[winvm](https://github.com/stuffbucket/winvm) runs, built from source, packaged so they run from any directory, and pinned by
checksum in winvm. Modelled on Rancher Desktop's
[rancher-desktop-qemu](https://github.com/rancher-sandbox/rancher-desktop-qemu).

Apple Silicon, macOS 15 or later. No Intel build.

## Why

winvm used to take QEMU from Homebrew. On 2026-10-27 Homebrew's QEMU 11.0.3
made Windows guests stop in the firmware after about one reboot in ten (QEMU
`b5f8f77271`, fixed by `a86024eb2d` in 11.1.0). A runtime that winvm pins
changes only when winvm changes the pin.

## What a release contains

| Asset | |
|---|---|
| `winvm-runtime-<v>-darwin-arm64.tar.gz` | `bin/` (`qemu-system-aarch64`, `qemu-img`, `swtpm`, `zstd`, `virtiofsd`), `lib/` (every library they load, as regular files), `share/qemu/efi-virtio.rom`, `share/licenses/virtiofsd/` (its licences and its crates' notices), `manifest.json` |
| `…-darwin-arm64.manifest.json` | component versions, QEMU patch digest, licence entries, SHA-256 of every file |
| `winvm-runtime-<v>-sources.tar.gz` | every component's source tarball and formula, plus this recipe |
| `*.sha256` | checksums |

Versions are `<qemu>-<revision>`, e.g. `11.1.2-1`. Libraries load through
`@executable_path/../lib` and `@loader_path`, and QEMU finds its data files
relative to itself. Everything is signed ad hoc; `qemu-system-aarch64` carries
`com.apple.security.hypervisor`. The winvm app re-signs it all with its
Developer ID.

## How it is built

`.github/workflows/build.yml`, on a GitHub-hosted macOS 15 arm64 runner:

1. Uninstall every Homebrew package.
2. Install the formulae here (`Formula/winvm-qemu.rb`, derived from
   homebrew-core's `qemu` and cut down to what winvm uses, and
   `Formula/winvm-virtiofsd.rb`) together with core's `swtpm` and `zstd`. Every component that ships is rebuilt from source;
   build-only tools come from bottles. `scripts/package.py` refuses a shipped
   component poured from a bottle.
3. `scripts/package.py` copies the binaries and their library closure,
   rewrites load commands, removes Homebrew rpaths, signs, and fails if any
   Homebrew path remains.
4. `scripts/sources.sh` collects the sources.
5. `scripts/check.sh` unpacks the tarball elsewhere and checks that every
   binary runs with only its own libraries, the entitlement, the devices winvm
   uses, that `vhost-user-fs-pci` starts against `virtiofsd` and the daemon
   exits with QEMU, the `qemu-vdagent` chardev, the manifest, and the
   licence entries.

To build on a Mac without the empty-Homebrew step, install QEMU and virtiofsd
into prefixes of your own (the formulae's configure arguments and cargo
commands) and point `package.py` at them: `WINVM_PREFIX_WINVM_QEMU=<prefix>
WINVM_PREFIX_WINVM_VIRTIOFSD=<prefix> python3 scripts/package.py <v> dist`.
Those components are recorded as version `local`.

A tag `v<version>` publishes a draft release.

## Accepting a release

Hosted runners cannot run HVF guests, so a release is accepted on a real Mac
before winvm pins it:

- 40 guest-initiated reboots of a Windows 11 ARM64 guest with no firmware stall;
- the cage ARM64 check passes;
- a save and load round-trip.

Record the result, the Mac (chip, macOS version) and the release in the winvm
pull request that changes `packages/core/runtime.json`.

| Runtime | Accepted on |
|---|---|
| (none yet) | |

## The shared folder and the clipboard

winvm shares a Mac folder with the guest over virtio-fs and carries the
clipboard over the SPICE agent protocol. Both need things QEMU's default
macOS build leaves out:

- `--enable-vhost-user`, for `vhost-user-fs-pci`. `--disable-vhost-net`,
  because `vhost_net.c` includes Linux headers and does not build on Darwin.
- `patches/0002-…`: QEMU 11.1 injects a kick after `SET_VRING_KICK` by
  writing to the notifier's read side, which on macOS (a pipe, no eventfd)
  fails with `EBADF`, so no vhost-user device can start. The patch kicks
  through the notifier's write side.
- `--enable-spice-protocol` with `--disable-spice`: `qemu-vdagent` needs only
  spice-protocol's headers (BSD, build-time only). QEMU does not link
  spice-server; `check.sh` fails if it does.
- `virtiofsd`: Chris Thomas's macOS port of virtiofsd
  ([christhomas/virtiofsd](https://github.com/christhomas/virtiofsd), v1.14.0,
  pinned by commit). It patches `vhost`, `vhost-user-backend` and
  `vmm-sys-util` from forks; its `Cargo.lock` pins each fork by commit, the
  build is `--locked` and offline from `cargo vendor`, and the sources tarball
  carries the vendored crates. winvm runs one daemon per QEMU process; it
  exits when QEMU disconnects.

## Changing QEMU

Change `url` and `sha256` in `Formula/winvm-qemu.rb`, carry any patch in
`patches/` with a note saying why and when it can go, tag
`v<qemu>-1`, accept it, then change winvm's pin. A new QEMU version or patch
set changes the `qemuPatches`/`qemu` values in the manifest, which winvm's
saves are keyed on, so saves made with the old runtime will not load.

## Licences

This repository's scripts are MIT (`LICENSE`). `Formula/winvm-qemu.rb` is
derived from homebrew-core (BSD 2-Clause). The runtime contains QEMU
(GPL-2.0), virtiofsd (Apache-2.0 AND BSD-3-Clause, with its crates' notices in
`share/licenses/virtiofsd/`), glib, json-glib, libslirp and gettext's libintl (LGPL-2.1 or
later), swtpm and libtpms (BSD-3-Clause), zstd, lz4 and xz (BSD), pixman and
dtc's libfdt (MIT/BSD), pcre2 (BSD) and OpenSSL (Apache-2.0). Their sources
are in each release's sources tarball.
