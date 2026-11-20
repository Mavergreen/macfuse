# platform: host-agnostic
# spec: 2026-11-18-macfuse-design.md decision F -- sourced by every build script; the ONE place the (interim) install
#       prefixes are spelled: every path a setuid helper loads derives from MACFUSE_PREFIX or RECAULK_PREFIX
if [ -z "${REPO_ROOT:-}" ]; then
  [ -f ./build/lib.sh ] || { echo "lib.sh: set REPO_ROOT, or source from the repo root" >&2; return 1 2>/dev/null || exit 1; }
  REPO_ROOT="$(pwd)"
fi
MACFUSE_PREFIX="${MACFUSE_PREFIX:-/usr/local/mavergreen/macfuse}"
RECAULK_PREFIX="${RECAULK_PREFIX:-/usr/local/mavergreen/recaulk}"
export REPO_ROOT MACFUSE_PREFIX RECAULK_PREFIX
# spec: 2026-11-18-macfuse-design.md decision C -- the two dylibs the adapted mount_macfuse loads, at real tree paths (never through a link)
MACFUSE_OSRELEASE_SHIM="$MACFUSE_PREFIX/lib/libmfosrelease.dylib"
RECAULK_SYSTEM_DYLIB="$RECAULK_PREFIX/lib/libRecaulkSystem.dylib"
export MACFUSE_OSRELEASE_SHIM RECAULK_SYSTEM_DYLIB
# spec: 2026-11-19-macfuse-product/global-constraints.md "Upstream's paths" -- one line per path third-party FUSE binaries and builds
#       have built in: the path (relative to the volume) and the tree path under MACFUSE_PREFIX its symlink names (build/stage.sh)
MACFUSE_LINKS="Library/Filesystems/macfuse.fs fs
Library/Frameworks/macFUSE.framework Frameworks/macFUSE.framework
usr/local/lib/libfuse.2.dylib lib/libfuse.2.dylib
usr/local/lib/libfuse.dylib lib/libfuse.dylib
usr/local/lib/libfuse.la lib/libfuse.la
usr/local/lib/libfuse3.4.dylib lib/libfuse3.4.dylib
usr/local/lib/libfuse3.dylib lib/libfuse3.dylib
usr/local/lib/pkgconfig/fuse.pc lib/pkgconfig/fuse.pc
usr/local/lib/pkgconfig/fuse3.pc lib/pkgconfig/fuse3.pc
usr/local/include/fuse.h include/fuse.h
usr/local/include/fuse include/fuse
usr/local/include/fuse3 include/fuse3"

# spec: 2026-11-19-macfuse-product/global-constraints.md -- UPSTREAM_VERSION holds the bare upstream version (5.5.0); it is read from the file, never spelled here
upstream_version() { tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_VERSION"; echo; }

# spec: build/fetch-sources.sh and scripts/pin-sources.sh both read this table of the pinned upstream sources (KEY,
#       output directory, GitHub repository, gitlink in macfuse/macfuse); components/macfuse-sources/pins holds the pins
MACFUSE_SOURCES="LIBRARY2 library2 macfuse/library Library-2
LIBRARY3 library3 macfuse/library Library-3
MOUNT mount macfuse/mount Mount
FRAMEWORK framework macfuse/framework Framework"
MACFUSE_PINS="${MACFUSE_PINS:-$REPO_ROOT/components/macfuse-sources/pins}"
export MACFUSE_PINS

# spec: build/build-mfmount.sh and build/build-libfuse.sh share the family toolchain: "macfuse_toolchain CALLER || exit 1"
#       sets BUILD (the build root), CL (clang22), SDK (the 10.9 SDK) and RC (the pinned Recaulk release, extracted
#       under BUILD, never installed). Needs build/msc.sh sourced.
macfuse_toolchain() {
  BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
  mkdir -p "$BUILD" || return 1
  CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")" || { echo "$1: no clang22" >&2; return 1; }
  SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || { echo "$1: no 10.9 SDK" >&2; return 1; }
  _mt_rc="$(tr -d ' \t\r\n' < "$REPO_ROOT/components/recaulk/version")"
  sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" recaulk "$_mt_rc" "$BUILD/recaulk-tree" > /dev/null || { echo "$1: no Recaulk $_mt_rc" >&2; return 1; }
  RC="$BUILD/recaulk-tree"
  [ -f "$RC/lib/librecaulk.a" ] && [ -d "$RC/include/recaulk" ] || { echo "$1: Recaulk $_mt_rc lacks lib/librecaulk.a or include/recaulk" >&2; return 1; }
  unset _mt_rc
}

# spec: 2026-11-19-macfuse-product/task-8-brief.md Step 4 -- Info.plist is read with POSIX awk, never PlistBuddy or plutil (a Linux build has
#       neither): "plist_string FILE KEY" prints the <string> value of KEY in the top-level dict of an Xcode-style XML plist (one
#       element per line), and fails when KEY is absent there or its value is not a one-line <string>
plist_string() {
  awk -v k="$2" '
    function count(s, re,  n) { n = 0; while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
    want { if ($0 ~ /^[ \t]*<string>[^<]*<\/string>[ \t]*$/) { sub(/^[ \t]*<string>/, ""); sub(/<\/string>[ \t]*$/, ""); print; found = 1 } exit }
    depth == 1 && /^[ \t]*<key>[^<]*<\/key>[ \t]*$/ { t = $0; sub(/^[ \t]*<key>/, "", t); sub(/<\/key>[ \t]*$/, "", t); if (t == k) { want = 1; next } }
    { depth += count($0, "<dict>") - count($0, "</dict>") }
    END { exit !found }' "$1"
}
