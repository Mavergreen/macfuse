#!/bin/sh
# platform: macOS-only -- hdiutil attaches the APFS dmg; nothing on 10.9 or Linux reads APFS yet
# spec: _pkg-meta/core.bom.txt is listed from the Core payload archive (path, mode, uid/gid), because stevedore 20261027.1 has no BOM reader
# usage: extract-dmg.sh DMG OUTDIR (OUTDIR must be absent or empty)
# Writes the Core component's payload under OUTDIR at its install paths, plus OUTDIR/_pkg-meta/core.bom.txt.
# Nothing from the image is ever executed.
set -eu
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"

[ $# -eq 2 ] || { echo "usage: $0 DMG OUTDIR" >&2; exit 2; }
dmg=$1
out=$2
[ -f "$dmg" ] || { echo "extract-dmg: no such file: $dmg" >&2; exit 1; }
v="$(upstream_version)"
stevedore="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")"

if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo "extract-dmg: $out is not empty" >&2; exit 1
fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/extract-dmg.XXXXXX")"
mnt="$tmp/mnt"
attached=
cleanup() {
  if [ -n "$attached" ]; then hdiutil detach -quiet "$mnt" >/dev/null 2>&1 || hdiutil detach -force -quiet "$mnt" >/dev/null 2>&1 || :; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
attached=1

pkg="$mnt/Extras/macFUSE $v.pkg"
[ -f "$pkg" ] || { echo "extract-dmg: $pkg not found in the image" >&2; exit 1; }
"$stevedore" expand "$pkg" "$tmp/pkg"

# platform: pkgbuild writes a gzip'd cpio archive; decompressed to a file, not piped, so a failed
#           decompress fails here rather than yielding an empty payload (shipyard's artifact-facts.sh does the same).
gzip -dc "$tmp/pkg/Core.pkg/Payload" > "$tmp/core.cpio"
( cd "$out" && cpio -id < "$tmp/core.cpio" 2>/dev/null )

mkdir -p "$out/_pkg-meta"
sh "$REPO_ROOT/build/list-payload.sh" "$tmp/core.cpio" "$out/_pkg-meta/core.bom.txt"
