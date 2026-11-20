#!/bin/sh
# platform: host-agnostic
# spec: tests/compare-kexts-test.sh -- the kext is taken from the debug tbz, so it must be the one the signed dmg
#       ships: the same sections with the same bytes, and the same x86_64 UUID; only the signature and the symbol table may differ.
#       Reads with clang22's llvm-lipo and llvm-otool, never executes either kext.
#   usage: compare-kexts.sh DEBUG_KEXT DMG_KEXT
#          Each is a kext bundle (its Contents/MacOS/<CFBundleExecutable> is compared) or a Mach-O file. Both must hold the same
#          architectures. For each, the section lists (llvm-otool -l) and every section's contents (llvm-otool -X -s) must be
#          identical, and the x86_64 slices must carry the same LC_UUID. Exit 0 when they match, 1 naming each difference, 2 on
#          a usage error.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
[ $# -eq 2 ] || { echo "usage: $0 DEBUG_KEXT DMG_KEXT" >&2; exit 2; }
macho() {
  if [ -d "$1" ]; then
    _e="$(plist_string "$1/Contents/Info.plist" CFBundleExecutable)" || { echo "compare-kexts: $1/Contents/Info.plist has no CFBundleExecutable" >&2; return 2; }
    printf '%s\n' "$1/Contents/MacOS/$_e"
  else
    printf '%s\n' "$1"
  fi
}
A="$(macho "$1")" || exit 2
B="$(macho "$2")" || exit 2
for f in "$A" "$B"; do [ -f "$f" ] || { echo "compare-kexts: no $f" >&2; exit 2; }; done
. "$REPO_ROOT/build/msc.sh"
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "compare-kexts: no clang22" >&2; exit 2; }
OT="$CL/bin/llvm-otool"
T="$(mktemp -d "${TMPDIR:-/tmp}/compare-kexts.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
diffs=0
differ() { echo "compare-kexts: $*"; diffs=$((diffs + 1)); }

archs() { "$CL/bin/llvm-lipo" -info "$1" | sed -n 's/.*: //p' | xargs; }
archs_a="$(archs "$A")" && archs_b="$(archs "$B")" && [ -n "$archs_a" ] && [ -n "$archs_b" ] || { echo "compare-kexts: not Mach-O" >&2; exit 2; }
[ "$archs_a" = "$archs_b" ] || { differ "architectures differ: $archs_a vs $archs_b"; exit 1; }
case " $archs_a " in *" x86_64 "*) ;; *) differ "no x86_64 slice"; exit 1 ;; esac
# platform: llvm-otool's -arch does not select a slice of a fat file, so each slice is thinned first
for arch in $archs_a; do
  for s in a b; do
    if [ "$s" = a ]; then f="$A"; else f="$B"; fi
    if [ "$archs_a" = "$arch" ]; then cp "$f" "$T/$s.$arch"; else "$CL/bin/llvm-lipo" -thin "$arch" "$f" -output "$T/$s.$arch"; fi
    "$OT" -l "$T/$s.$arch" > "$T/$s.$arch.l"
    awk '$1 == "sectname" { s = $2; next } s != "" && $1 == "segname" { print $2 " " s; s = "" }' "$T/$s.$arch.l" > "$T/$s.$arch.sects"
    awk '$1 == "cmd" { c = $2 } c == "LC_UUID" && $1 == "uuid" { print $2 }' "$T/$s.$arch.l" > "$T/$s.$arch.uuid"
  done
  if ! cmp -s "$T/a.$arch.sects" "$T/b.$arch.sects"; then
    differ "$arch: the section lists differ"
    diff "$T/a.$arch.sects" "$T/b.$arch.sects" || :
    continue
  fi
  while read -r seg sect; do
    "$OT" -X -s "$seg" "$sect" "$T/a.$arch" > "$T/a.dump"
    "$OT" -X -s "$seg" "$sect" "$T/b.$arch" > "$T/b.dump"
    cmp -s "$T/a.dump" "$T/b.dump" || differ "$arch: section $seg,$sect differs"
  done < "$T/a.$arch.sects"
  echo "$arch: $(wc -l < "$T/a.$arch.sects" | tr -d ' ') sections compared"
done
ua="$(cat "$T/a.x86_64.uuid")"
ub="$(cat "$T/b.x86_64.uuid")"
if [ -z "$ua" ] || [ "$ua" != "$ub" ]; then
  differ "x86_64: the UUIDs differ: '$ua' vs '$ub'"
else
  echo "x86_64: UUID $ua"
fi
[ "$diffs" -eq 0 ] || exit 1
echo "compare-kexts: identical"
