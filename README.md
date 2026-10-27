# winvm-runtime

The QEMU, swtpm and zstd that [winvm](https://github.com/stuffbucket/winvm)
runs, built from source, packaged so they run from any directory, and pinned by
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
| `winvm-runtime-<v>-darwin-arm64.tar.gz` | `bin/` (`qemu-system-aarch64`, `qemu-img`, `swtpm`, `zstd`), `lib/` (every library they load, as regular files), `share/qemu/efi-virtio.rom`, `manifest.json` |
| `…-darwin-arm64.manifest.json` | component versions, QEMU patch digest, SHA-256 of every file |
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
   homebrew-core's `qemu` and cut down to what winvm uses) together with core's
   `swtpm` and `zstd`. Every component that ships is rebuilt from source;
   build-only tools come from bottles. `scripts/package.py` refuses a shipped
   component poured from a bottle.
3. `scripts/package.py` copies the binaries and their library closure,
   rewrites load commands, removes Homebrew rpaths, signs, and fails if any
   Homebrew path remains.
4. `scripts/sources.sh` collects the sources.
5. `scripts/check.sh` unpacks the tarball elsewhere and checks that every
   binary runs with only its own libraries, the entitlement, the devices winvm
   uses, and the manifest.

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

## Changing QEMU

Change `url` and `sha256` in `Formula/winvm-qemu.rb`, carry any patch in
`patches/` with a note saying why and when it can go, tag
`v<qemu>-1`, accept it, then change winvm's pin. A new QEMU version or patch
set changes the `qemuPatches`/`qemu` values in the manifest, which winvm's
saves are keyed on, so saves made with the old runtime will not load.

## Licences

This repository's scripts are MIT (`LICENSE`). `Formula/winvm-qemu.rb` is
derived from homebrew-core (BSD 2-Clause). The runtime contains QEMU
(GPL-2.0), glib, json-glib, libslirp and gettext's libintl (LGPL-2.1 or
later), swtpm and libtpms (BSD-3-Clause), zstd, lz4 and xz (BSD), pixman and
dtc's libfdt (MIT/BSD), pcre2 (BSD) and OpenSSL (Apache-2.0). Their sources
are in each release's sources tarball.
