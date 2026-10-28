#!/usr/bin/env bash
# usage: sources.sh VERSION OUTDIR
# Collects the source tarball and formula of every component in the runtime's
# manifest, plus this repository's recipe, into winvm-runtime-VERSION-sources.tar.gz.
set -euo pipefail
version=$1
out=$(cd "$2" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
name="winvm-runtime-$version"
manifest="$out/$name-darwin-arm64.manifest.json"
stage="$out/$name-sources"
rm -rf "$stage"
mkdir -p "$stage/sources" "$stage/formulae" "$stage/recipe"

python3 -c 'import json,sys; [print(k) for k in json.load(open(sys.argv[1]))["components"]]' "$manifest" |
  while read -r formula; do
    ref=$formula
    case $formula in winvm-*) ref=$WINVM_TAP/$formula ;; esac
    brew fetch --quiet --build-from-source "$ref" > /dev/null
    src=$(brew --cache --build-from-source "$ref")
    cp "$src" "$stage/sources/"
    brew cat "$ref" > "$stage/formulae/$formula.rb"
    # virtiofsd's crates, the patched rust-vmm forks among them, at the
    # commits its Cargo.lock names: the tarball alone does not rebuild it.
    if [ "$formula" = winvm-virtiofsd ]; then
      work=$(mktemp -d)
      tar -xzf "$src" -C "$work" --strip-components 1
      (cd "$work" && cargo vendor --quiet --locked --versioned-dirs vendor > /dev/null)
      tar -czf "$stage/sources/virtiofsd-vendor.tar.gz" -C "$work" vendor Cargo.lock
      rm -rf "$work"
    fi
  done

cp -R "$root/Formula" "$root/patches" "$root/scripts" "$root/README.md" "$stage/recipe/"
mkdir -p "$stage/recipe/.github/workflows"
cp "$root/.github/workflows/build.yml" "$stage/recipe/.github/workflows/"
cp "$manifest" "$stage/manifest.json"

tar -czf "$out/$name-sources.tar.gz" -C "$out" "$name-sources"
shasum -a 256 "$out/$name-sources.tar.gz" | sed "s|$out/||" > "$out/$name-sources.tar.gz.sha256"
echo "$out/$name-sources.tar.gz"
