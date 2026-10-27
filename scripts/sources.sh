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
    [ "$formula" = winvm-qemu ] && ref=$WINVM_TAP/winvm-qemu
    brew fetch --quiet --build-from-source "$ref" > /dev/null
    cp "$(brew --cache --build-from-source "$ref")" "$stage/sources/"
    brew cat "$ref" > "$stage/formulae/$formula.rb"
  done

cp -R "$root/Formula" "$root/patches" "$root/scripts" "$root/README.md" "$stage/recipe/"
mkdir -p "$stage/recipe/.github/workflows"
cp "$root/.github/workflows/build.yml" "$stage/recipe/.github/workflows/"
cp "$manifest" "$stage/manifest.json"

tar -czf "$out/$name-sources.tar.gz" -C "$out" "$name-sources"
shasum -a 256 "$out/$name-sources.tar.gz" | sed "s|$out/||" > "$out/$name-sources.tar.gz.sha256"
echo "$out/$name-sources.tar.gz"
