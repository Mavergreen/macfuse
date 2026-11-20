#!/bin/sh
# platform: host-agnostic
# spec: maintainer, 2026-11-19 (an osrelease shim, not a byte patch; the closed helpers' SDK 27.0 a declared sdk-pin deviation,
#       INGREDIENTS.md) -- adapts upstream's closed mount_macfuse and load_macfuse for 10.9 with Drydock
#       (components/drydock/version, fetched by shipyard's fetch_drydock.sh): the x86_64 slice only, then the recipe
#       helpers/<helper>.drydock.in with @SHIM@ -> $MACFUSE_OSRELEASE_SHIM and @RECAULK_SYSTEM@ -> $RECAULK_SYSTEM_DYLIB
#       (build/lib.sh), so each loads only real tree paths. Rewrites the binaries and never executes them.
#   usage: adapt-helpers.sh DMG_ROOT STAGE
#          DMG_ROOT is the extracted dmg payload (build/extract-dmg.sh). Writes
#          STAGE/$MACFUSE_PREFIX/fs/Contents/Resources/{mount_macfuse,load_macfuse} (mode 755; the pkg makes them
#          root:wheel 4755), replacing only those two files. Fails, leaving any earlier ones, on any error.
#   usage: adapt-helpers.sh --recipe HELPER
#          Prints the rendered recipe for HELPER (mount_macfuse or load_macfuse) and fetches nothing.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
HELPERS="mount_macfuse load_macfuse"

render() {
  case $1 in mount_macfuse|load_macfuse) ;; *) echo "adapt-helpers: no recipe for '$1'" >&2; return 2 ;; esac
  sed -e "s|@SHIM@|$MACFUSE_OSRELEASE_SHIM|g" -e "s|@RECAULK_SYSTEM@|$RECAULK_SYSTEM_DYLIB|g" \
    "$REPO_ROOT/helpers/$1.drydock.in" > "$2"
  if grep -q '@[A-Z_]*@' "$2"; then echo "adapt-helpers: $1's recipe keeps a placeholder" >&2; return 1; fi
}

if [ "${1:-}" = --recipe ]; then
  [ $# -eq 2 ] || { echo "usage: $0 --recipe HELPER" >&2; exit 2; }
  r="$(mktemp "${TMPDIR:-/tmp}/adapt-helpers-recipe.XXXXXX")"
  trap 'rm -f "$r"' EXIT
  render "$2" "$r"
  cat "$r"
  exit 0
fi
[ $# -eq 2 ] || { echo "usage: $0 DMG_ROOT STAGE | $0 --recipe HELPER" >&2; exit 2; }
RES="$1/Library/Filesystems/macfuse.fs/Contents/Resources"
STAGE=$2
for h in $HELPERS; do
  [ -f "$RES/$h" ] || { echo "adapt-helpers: no upstream $h in $RES" >&2; exit 1; }
done
. "$REPO_ROOT/build/msc.sh"
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
mkdir -p "$BUILD"
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "adapt-helpers: no clang22" >&2; exit 1; }
DDP="$(sh "$SHIPYARD_SCRIPTS/fetch_drydock.sh" "$REPO_ROOT/components/drydock")" || { echo "adapt-helpers: no Drydock $(cat "$REPO_ROOT/components/drydock/version")" >&2; exit 1; }
DD="$DDP/bin/drydock-macho-rewrite"
[ -x "$DD" ] || { echo "adapt-helpers: $DDP has no bin/drydock-macho-rewrite" >&2; exit 1; }
OUT="$STAGE$MACFUSE_PREFIX/fs/Contents/Resources"
W="$(mktemp -d "$BUILD/helpers.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for h in $HELPERS; do
  echo "== $h"
  # spec: share/man/man1/drydock-macho-rewrite.1 -- 10.9 runs only the x86_64 slice, and the rewrite is defined on a thin file
  "$CL/bin/llvm-lipo" -thin x86_64 "$RES/$h" -output "$W/$h.x86_64"
  render "$h" "$W/$h.drydock"
  cat "$W/$h.drydock"
  "$DD" "$W/$h.x86_64" "$W/$h" < "$W/$h.drydock"
  "$DD" verify "$W/$h"
  chmod 755 "$W/$h"
done
mkdir -p "$OUT"
for h in $HELPERS; do mv -f "$W/$h" "$OUT/$h"; done
echo "adapted $OUT/mount_macfuse and $OUT/load_macfuse"
