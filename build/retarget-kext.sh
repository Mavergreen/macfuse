#!/bin/sh
# platform: host-agnostic
# spec: tests/retarget-kext-test.sh -- retargets upstream's KernelExtension-12 kext for
#       10.9 without relinking it: the x86_64 slice only (llvm-lipo), the vnode-op table rewritten by kext/macfuse.drydock
#       (components/drydock/version, fetched by shipyard's fetch_drydock.sh), and an Info.plist edit. Reads and rewrites, never
#       executes, upstream's binary.
#   usage: retarget-kext.sh TBZ RECAULK_ROOT OUTDIR
#          TBZ is upstream's macfuse-<UPSTREAM_VERSION>-debug.tbz. RECAULK_ROOT is an extracted Recaulk payload root, holding
#          exactly one Library/Extensions/<name>.kext, Recaulk's kernel back-fill. Writes OUTDIR/macfuse.kext (directories and
#          the executable 755, Info.plist 644, no ._* files), replacing only that; on any error leaves an earlier one as it was.
#          The plist keeps CFBundleIdentifier and CFBundleVersion, sets every com.apple.kpi.* in OSBundleLibraries to 13.0.0,
#          drops com.apple.kpi.private, and adds the back-fill's CFBundleIdentifier at its OSBundleCompatibleVersion.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
[ $# -eq 3 ] || { echo "usage: $0 TBZ RECAULK_ROOT OUTDIR" >&2; exit 2; }
TBZ=$1
RCROOT=$2
OUTDIR=$3
die() { echo "retarget-kext: $*" >&2; exit 1; }
KPI_VERSION=13.0.0
[ -f "$TBZ" ] || die "no $TBZ"

# spec: components/recaulk/version -- the back-fill's bundle id and compatible version are read from the pinned Recaulk's
#       payload, never typed here, so a Recaulk bump carries them
set -- "$RCROOT"/Library/Extensions/*.kext
[ $# -eq 1 ] && [ -d "$1" ] || die "$RCROOT/Library/Extensions does not hold exactly one kext (Recaulk's back-fill)"
BF_PLIST="$1/Contents/Info.plist"
[ -f "$BF_PLIST" ] || die "no $BF_PLIST"
BF_ID="$(plist_string "$BF_PLIST" CFBundleIdentifier)" || die "$BF_PLIST has no CFBundleIdentifier string"
BF_VER="$(plist_string "$BF_PLIST" OSBundleCompatibleVersion)" || die "$BF_PLIST has no OSBundleCompatibleVersion string"
case "$BF_ID" in ''|*[!A-Za-z0-9.-]*) die "the back-fill's CFBundleIdentifier '$BF_ID' is not a bundle id" ;; esac
case "$BF_VER" in ''|*[!0-9.]*) die "the back-fill's OSBundleCompatibleVersion '$BF_VER' is not a version" ;; esac
echo "back-fill: $BF_ID, compatible version $BF_VER"

. "$REPO_ROOT/build/msc.sh"
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
mkdir -p "$BUILD" "$OUTDIR"
CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || die "no clang22"
DDP="$(sh "$SHIPYARD_SCRIPTS/fetch_drydock.sh" "$REPO_ROOT/components/drydock")" || die "no Drydock $(cat "$REPO_ROOT/components/drydock/version")"
DD="$DDP/bin/drydock-macho-rewrite"
[ -x "$DD" ] || die "$DDP has no bin/drydock-macho-rewrite"

W="$(mktemp -d "$BUILD/retarget-kext.XXXXXX")"
N="$(mktemp -d "$OUTDIR/.macfuse.kext.XXXXXX")"
trap 'rm -rf "$W" "$N"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MEMBER="macfuse-$(upstream_version)-debug/KernelExtension-12/macfuse.kext"
tar -xjf "$TBZ" -C "$W" "$MEMBER" || die "$TBZ holds no $MEMBER"
SRC="$W/$MEMBER"
EXE="$(plist_string "$SRC/Contents/Info.plist" CFBundleExecutable)" || die "$MEMBER's Info.plist has no CFBundleExecutable"
# spec: tests/retarget-kext-test.sh -- the bundle is exactly its Info.plist and executable: anything else (a signature,
#       resources) would ship unexamined
(cd "$SRC" && find . -type f ! -name '._*' | sort) > "$W/files"
printf '%s\n' ./Contents/Info.plist "./Contents/MacOS/$EXE" | sort > "$W/want"
cmp -s "$W/files" "$W/want" || { diff "$W/want" "$W/files" >&2 || :; die "$MEMBER holds files other than Contents/Info.plist and Contents/MacOS/$EXE"; }

K="$N/macfuse.kext"
mkdir -p "$K/Contents/MacOS"
"$CL/bin/llvm-lipo" -thin x86_64 "$SRC/Contents/MacOS/$EXE" -output "$W/$EXE.x86_64"
cat "$REPO_ROOT/kext/macfuse.drydock"
"$DD" "$W/$EXE.x86_64" "$K/Contents/MacOS/$EXE" < "$REPO_ROOT/kext/macfuse.drydock"
"$DD" verify "$K/Contents/MacOS/$EXE"

P="$K/Contents/Info.plist"
awk -v kpi="$KPI_VERSION" -v bid="$BF_ID" -v bver="$BF_VER" '
  function fail(m) { print "retarget-kext: Info.plist: " m > "/dev/stderr"; bad = 1; exit 1 }
  function inner(s, tag) { sub("^[ \t]*<" tag ">", "", s); sub("</" tag ">[ \t]*$", "", s); return s }
  function count(s, re,  n) { n = 0; while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
  state == 1 {
    if ($0 !~ /^[ \t]*<dict>[ \t]*$/) fail("OSBundleLibraries is not a dict")
    ind = $0; sub(/<dict>.*/, "", ind); ind = ind "\t"; state = 2; print; next
  }
  state == 2 {
    if ($0 ~ /^[ \t]*<\/dict>[ \t]*$/) {
      print ind "<key>" bid "</key>"; print ind "<string>" bver "</string>"; print; state = 3; next
    }
    if ($0 !~ /^[ \t]*<key>[^<]*<\/key>[ \t]*$/) fail("unexpected line in OSBundleLibraries: " $0)
    key = inner($0, "key"); kl = $0
    if ((getline val) <= 0 || val !~ /^[ \t]*<string>[^<]*<\/string>[ \t]*$/) fail("OSBundleLibraries:" key " is not a one-line <string>")
    if (key == "com.apple.kpi.private") next
    if (key !~ /^com\.apple\.kpi\.[a-z]+$/) fail("unexpected OSBundleLibraries entry " key)
    seen[key] = 1
    print kl; v = val; sub(/<string>[^<]*<\/string>/, "<string>" kpi "</string>", v); print v; next
  }
  state == 0 && depth == 1 && /^[ \t]*<key>OSBundleLibraries<\/key>[ \t]*$/ { state = 1; print; next }
  { depth += count($0, "<dict>") - count($0, "</dict>"); print }
  END {
    if (bad) exit 1
    if (state != 3) fail("no top-level OSBundleLibraries dict")
    if (bid in seen) fail("OSBundleLibraries already names " bid)
  }' "$SRC/Contents/Info.plist" > "$P"

for k in CFBundleIdentifier CFBundleVersion; do
  a="$(plist_string "$SRC/Contents/Info.plist" "$k")" || die "upstream's Info.plist has no $k"
  b="$(plist_string "$P" "$k")" || die "the rewritten Info.plist lost $k"
  [ "$a" = "$b" ] || die "$k changed: $a -> $b"
done
! grep -q 'com\.apple\.kpi\.private' "$P" || die "com.apple.kpi.private is still in the rewritten Info.plist"

find "$N" -name '._*' -exec rm -f {} +
find "$K" -type d -exec chmod 755 {} +
chmod 644 "$P"
chmod 755 "$K/Contents/MacOS/$EXE"
rm -rf "$OUTDIR/macfuse.kext"
mv "$K" "$OUTDIR/macfuse.kext"
echo "wrote $OUTDIR/macfuse.kext"
