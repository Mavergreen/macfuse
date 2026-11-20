#!/bin/sh
# platform: macOS-only -- the strict analyzer (shipyard's objc-compat.sh, the pinned Drydock's drydock-objc) runs on macOS only
#   usage: compat-guard.sh [--default] BINARY...
#          The 10.9 compatibility gate for this port's own binaries (MFMount, libfuse.2.dylib, libfuse3.4.dylib,
#          macFUSE.framework): shipyard's assert_binary_compatible.sh opted into MAVERGREEN_OBJC_STRICT, x86_64
#          only, with clang22's Mach-O readers and this repo's INGREDIENTS.md deviations. Each binary is
#          analyzed relative to MACFUSE_OBJC_ROOT (default: the binary's own directory). --default runs the same
#          guard without the strict analyzer (its selector list). Strict refuses, with exit 4, a shipyard whose
#          Drydock pin predates v0.5.0. Exit as assert_binary_compatible.sh: 0 clean, 1 a check failed, 2 misuse,
#          4 cannot measure.
set -eu
STRICT=1
[ "${1:-}" != --default ] || { STRICT=; shift; }
[ $# -ge 1 ] || { echo "usage: compat-guard.sh [--default] BINARY..." >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
# spec: Drydock v0.5.0 (shipyard v1.0.736, components/drydock/version) classifies objc_{get,set}AssociatedObject, which librecaulk.a's dispatch
#       back-fills import; an older pin reports them as unclassified-objc-runtime-import and cannot measure any binary here
if [ -n "$STRICT" ]; then
  pin="$SHIPYARD_SCRIPTS/../components/drydock/version"
  dd="$(tr -d ' \t\r\n' < "$pin" 2> /dev/null || :)"
  if ! printf '%s\n' "$dd" | awk -F. '{ sub(/^v/, "", $1) } !($1 > 0 || $2 >= 5) { exit 1 }'; then
    echo "compat-guard: shipyard at $SHIPYARD_SCRIPTS pins Drydock '${dd:-?}'; the strict guard needs Drydock v0.5.0 or later (shipyard v1.0.736 or later)" >&2
    exit 4
  fi
fi
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "compat-guard: no clang22" >&2; exit 4; }
status=0
for b in "$@"; do
  [ -f "$b" ] || { echo "compat-guard: no $b" >&2; exit 2; }
  abs="$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")"
  rc=0
  if [ -n "$STRICT" ]; then
    MAVERGREEN_OBJC_STRICT=1 MAVERGREEN_OBJC_ROOT="${MACFUSE_OBJC_ROOT:-$(dirname "$abs")}" MAVERICKS_DEVIATIONS_ROOT="$REPO_ROOT" \
      MAVERICKS_ALLOW_ARCHS=x86_64 LIPO="$CL/bin/llvm-lipo" NM="$CL/bin/llvm-nm" OTOOL="$CL/bin/llvm-otool" STRINGS="$CL/bin/llvm-strings" \
      sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$abs" || rc=$?
  else
    MAVERICKS_DEVIATIONS_ROOT="$REPO_ROOT" MAVERICKS_ALLOW_ARCHS=x86_64 \
      LIPO="$CL/bin/llvm-lipo" NM="$CL/bin/llvm-nm" OTOOL="$CL/bin/llvm-otool" STRINGS="$CL/bin/llvm-strings" \
      sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$abs" || rc=$?
  fi
  case $rc in
    0) ;;
    4) [ "$status" = 1 ] || [ "$status" = 2 ] || status=4 ;;
    *) [ "$status" = 2 ] || status=$rc ;;
  esac
done
exit "$status"
