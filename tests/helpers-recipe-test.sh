#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-18-macfuse-design.md decisions C and D -- the rendered mount_macfuse recipe is exactly the spike's five statements, and the
#       load_macfuse recipe its two, with the shim's and libRecaulkSystem's paths taken from build/lib.sh; no recipe
#       loads anything through /Library/Filesystems. After build/adapt-helpers.sh, mount_macfuse binds _sysctlbyname
#       to the shim and ____chkstk_darwin and _malloc_type_malloc to libRecaulkSystem; both helpers are thin x86_64,
#       unsigned, verified by drydock-macho-rewrite, load only real tree paths, and pass the default and the strict
#       compat guard with only their declared sdk-pin deviations. The binary half SKIPs (77) without MACFUSE_DMG_ROOT.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$REPO_ROOT/tests/lib/strict-measure.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/helpers-recipe-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

want_mount() {
  printf '%s\n' \
    'target        10.9' \
    'load-command  delete    codesig' \
    "dylib         append    $1/lib/libmfosrelease.dylib" \
    "import        redirect  _sysctlbyname  /usr/lib/libSystem.B.dylib  $1/lib/libmfosrelease.dylib" \
    "dylib         replace   /usr/lib/libSystem.B.dylib  $2/lib/libRecaulkSystem.dylib"
}
want_load() {
  printf '%s\n' 'target        10.9' 'load-command  delete    codesig'
}
for p in "$MACFUSE_PREFIX $RECAULK_PREFIX" "/x/m /x/r"; do
  set -- $p
  for h in mount_macfuse load_macfuse; do
    MACFUSE_PREFIX=$1 RECAULK_PREFIX=$2 sh "$REPO_ROOT/build/adapt-helpers.sh" --recipe "$h" > "$T/$h.got" 2> "$T/err" ||
      { cat "$T/err" >&2; fail "adapt-helpers.sh --recipe $h failed (prefixes $1 $2)"; continue; }
    case $h in mount_macfuse) want_mount "$1" "$2" ;; *) want_load ;; esac > "$T/$h.want"
    diff "$T/$h.want" "$T/$h.got" > "$T/diff" || { cat "$T/diff" >&2; fail "the rendered $h recipe (prefixes $1 $2) is not the expected one"; }
    grep -q '/Library/Filesystems' "$T/$h.got" && fail "the rendered $h recipe names /Library/Filesystems"
    grep -q '@' "$T/$h.got" && fail "the rendered $h recipe keeps a placeholder"
  done
done
echo "== rendered mount_macfuse recipe"
sh "$REPO_ROOT/build/adapt-helpers.sh" --recipe mount_macfuse || fail "adapt-helpers.sh --recipe mount_macfuse failed"
echo "== rendered load_macfuse recipe"
sh "$REPO_ROOT/build/adapt-helpers.sh" --recipe load_macfuse || fail "adapt-helpers.sh --recipe load_macfuse failed"

UPRES="${MACFUSE_DMG_ROOT:-}/Library/Filesystems/macfuse.fs/Contents/Resources"
if [ -z "${MACFUSE_DMG_ROOT:-}" ] || [ ! -f "$UPRES/mount_macfuse" ] || [ ! -f "$UPRES/load_macfuse" ]; then
  [ "$fails" -eq 0 ] || exit 1
  echo "SKIP: recipes pass; MACFUSE_DMG_ROOT unset or lacks upstream's helpers"; exit 77
fi

SHIM="$MACFUSE_PREFIX/lib/libmfosrelease.dylib"
RSYS="$RECAULK_PREFIX/lib/libRecaulkSystem.dylib"
macfuse_toolchain helpers-recipe-test || { echo "FAIL: no toolchain" >&2; exit 1; }
# spec: 2026-11-18-macfuse-design.md decision C -- the libRecaulkSystem.dylib the recipe names is the pinned Recaulk's, and it provides ____chkstk_darwin
[ "$("$CL/bin/llvm-otool" -D "$RC/lib/libRecaulkSystem.dylib" | sed 1d)" = "$RSYS" ] || fail "the pinned Recaulk's libRecaulkSystem.dylib is not installed at $RSYS"
"$CL/bin/llvm-nm" -gUj "$RC/lib/libRecaulkSystem.dylib" | grep -qx ____chkstk_darwin || fail "the pinned Recaulk's libRecaulkSystem.dylib lacks ____chkstk_darwin"
DDP="$(sh "$SHIPYARD_SCRIPTS/fetch_drydock.sh" "$REPO_ROOT/components/drydock")" || { echo "FAIL: no Drydock" >&2; exit 1; }
DD="$DDP/bin/drydock-macho-rewrite"
[ -x "$DD" ] || { echo "FAIL: $DDP has no bin/drydock-macho-rewrite" >&2; exit 1; }

OUT="$T/stage$MACFUSE_PREFIX/fs/Contents/Resources"
# spec: 2026-11-19-macfuse-product/task-7-brief.md (task 4 review Minor 1) -- a build script replaces only its own outputs in the shared STAGE tree
mkdir -p "$OUT"
echo foreign > "$OUT/foreign.txt"
echo stale > "$OUT/mount_macfuse"
sh "$REPO_ROOT/build/adapt-helpers.sh" "$MACFUSE_DMG_ROOT" "$T/stage" > "$T/adapt.log" 2>&1 || { cat "$T/adapt.log" >&2; echo "FAIL: adapt-helpers.sh failed" >&2; exit 1; }
[ -f "$OUT/foreign.txt" ] || fail "adapt-helpers.sh removed a file in Resources/ that is not its own"

for h in mount_macfuse load_macfuse; do
  b="$OUT/$h"
  [ -f "$b" ] || { fail "no $b"; continue; }
  [ -x "$b" ] || fail "$h is not executable"
  "$CL/bin/llvm-lipo" -info "$b" > "$T/info" 2>&1 || :
  grep -q '^Non-fat file: .* is architecture: x86_64 *$' "$T/info" || { cat "$T/info" >&2; fail "$h is not thin x86_64"; }
  "$CL/bin/llvm-otool" -l "$b" > "$T/l"
  grep -q 'cmd LC_CODE_SIGNATURE' "$T/l" && fail "$h keeps LC_CODE_SIGNATURE"
  awk '/cmd LC_VERSION_MIN_MACOSX/ { v = 1 } v && $1 == "version" { print $2; exit }' "$T/l" | grep -qx 10.9 || fail "$h's minimum is not 10.9"
  "$CL/bin/llvm-otool" -L "$b" | sed 1d | awk '{ print $1 }' > "$T/loads"
  echo "== $h loads"; cat "$T/loads"
  grep -e '^/Library/Filesystems/' -e '^/usr/local/lib/' "$T/loads" && fail "$h loads through a /Library/Filesystems or /usr/local/lib link"
  echo "== drydock-macho-rewrite verify $h"
  "$DD" verify "$b" || fail "drydock-macho-rewrite verify failed on $h"
  sh "$REPO_ROOT/build/compat-guard.sh" --default "$b" || fail "the default compat guard failed on $h"
  strict_measure "$b" "$T/strict.txt" || fail "the strict compat guard failed on $h"
done

M="$OUT/mount_macfuse"
if [ -f "$M" ]; then
  "$DD" imports "$M" > "$T/imports"
  echo "== drydock-macho-rewrite imports mount_macfuse (the moved names)"
  awk -F '\t' 'NR == 1 || $5 == "_sysctlbyname" || $5 == "____chkstk_darwin" || $5 == "_malloc_type_malloc"' "$T/imports"
  for s in "_sysctlbyname $SHIM" "____chkstk_darwin $RSYS" "_malloc_type_malloc $RSYS"; do
    set -- $s
    awk -F '\t' -v s="$1" '$5 == s { print $4 }' "$T/imports" | sort -u > "$T/libs"
    [ "$(cat "$T/libs")" = "$2" ] || fail "mount_macfuse binds $1 to '$(tr '\n' ' ' < "$T/libs")', not $2"
  done
  awk -F '\t' '$4 == "/usr/lib/libSystem.B.dylib"' "$T/imports" | grep -q . && fail "mount_macfuse still binds a name to /usr/lib/libSystem.B.dylib"
  "$CL/bin/llvm-otool" -L "$M" | sed 1d | awk '{ print $1 }' > "$T/loads"
  for l in "$SHIM" "$RSYS"; do grep -qx "$l" "$T/loads" || fail "mount_macfuse does not load $l"; done
fi

[ "$fails" -eq 0 ] || exit 1
echo "helpers-recipe-test: PASS"
