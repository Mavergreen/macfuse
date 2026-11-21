#!/bin/sh
# platform: host-agnostic
# spec: DETAILS.md "MFMount is a C stand-in" -- the C stand-in must export exactly upstream's MFMount API (the 34 _MF*/__MF*
#       names of its x86_64 slice) and import only from /usr/lib and /System/Library/Frameworks; API drift in a new
#       upstream turns this red.
# spec: INGREDIENTS.md "Conformance deviations" objc-measure -- MFMount is outside the Drydock gaps, so it must pass the
#       default and the strict compat guard (build/compat-guard.sh) outright
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
SRC="${MFMOUNT_SRC:-$BUILD/src}"
UP="${MACFUSE_DMG_ROOT:-}/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount"
if [ -z "${MACFUSE_DMG_ROOT:-}" ] || [ ! -f "$UP" ]; then echo "SKIP: MACFUSE_DMG_ROOT unset or lacks upstream's MFMount"; exit 77; fi
[ -f "$SRC/mount/Mount/Bridge/Trampoline.c" ] || { echo "FAIL: no fetched mount sources at $SRC/mount (build/fetch-sources.sh)" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mfmount-exports-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")"
sh "$REPO_ROOT/build/build-mfmount.sh" "$SRC" "$T/stage" > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; fail "build-mfmount.sh failed"; exit 1; }
FW="$T/stage$MACFUSE_PREFIX/fs/Contents/Frameworks/MFMount.framework"
OURS="$FW/Versions/A/MFMount"
[ -f "$OURS" ] || { fail "no $OURS"; exit 1; }

"$CL/bin/llvm-nm" --arch=x86_64 -gUj "$UP" | grep -E '^_{1,2}MF' | sort > "$T/up.txt"
"$CL/bin/llvm-nm" -gUj "$OURS" | grep -E '^_{1,2}MF' | sort > "$T/ours.txt"
[ "$(wc -l < "$T/up.txt" | tr -d ' ')" -eq 34 ] || fail "upstream exports $(wc -l < "$T/up.txt" | tr -d ' ') MF names, not 34"
[ "$(grep -c '^_MF' "$T/up.txt")" -eq 18 ] || fail "upstream: not 18 _MF names"
[ "$(grep -c '^__MF' "$T/up.txt")" -eq 16 ] || fail "upstream: not 16 __MF names"
diff "$T/up.txt" "$T/ours.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "exported MF names differ from upstream's"; }

"$CL/bin/llvm-otool" -L "$OURS" | sed 1,2d | awk '{ print $1 }' > "$T/imports.txt"
cat "$T/imports.txt"
[ -s "$T/imports.txt" ] || fail "lists no imported libraries"
grep -v -e '^/usr/lib/' -e '^/System/Library/Frameworks/' "$T/imports.txt" > "$T/bad-imports.txt" || :
[ ! -s "$T/bad-imports.txt" ] || { cat "$T/bad-imports.txt" >&2; fail "imports something outside /usr/lib and /System/Library/Frameworks"; }
NM="$CL/bin/llvm-nm" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$BUILD/recaulk-tree/lib/librecaulk.a" > "$T/recaulk-names.txt" || fail "recaulk-unexported.sh failed"
"$CL/bin/llvm-nm" -gUj "$OURS" | LC_ALL=C sort > "$T/all-exports.txt"
LC_ALL=C comm -12 "$T/recaulk-names.txt" "$T/all-exports.txt" > "$T/leaked.txt"
[ ! -s "$T/leaked.txt" ] || { cat "$T/leaked.txt" >&2; fail "exports Recaulk names"; }

sh "$REPO_ROOT/build/compat-guard.sh" --default "$OURS" || fail "the default compat guard failed on MFMount"
sh "$REPO_ROOT/build/compat-guard.sh" "$OURS" || fail "the strict compat guard failed on MFMount"

[ "$fails" -eq 0 ] || exit 1
echo "mfmount-exports-test: PASS"
