# platform: host-agnostic
# spec: maintainer, 2026-11-19 (interim prefix until shipyard's P4 moves the family off /usr/local) -- sourced by every build
#       script; the ONE place the install prefixes are spelled: every path a setuid helper loads derives from MACFUSE_PREFIX
#       or RECAULK_PREFIX, so the P4 move is a change here alone
if [ -z "${REPO_ROOT:-}" ]; then
  [ -f ./build/lib.sh ] || { echo "lib.sh: set REPO_ROOT, or source from the repo root" >&2; return 1 2>/dev/null || exit 1; }
  REPO_ROOT="$(pwd)"
fi
MACFUSE_PREFIX="${MACFUSE_PREFIX:-/usr/local/mavergreen/macfuse}"
RECAULK_PREFIX="${RECAULK_PREFIX:-/usr/local/mavergreen/recaulk}"
export REPO_ROOT MACFUSE_PREFIX RECAULK_PREFIX
# spec: build/adapt-helpers.sh -- the two dylibs the setuid mount_macfuse loads, at real tree paths, never through a link a
#       non-root user could repoint
MACFUSE_OSRELEASE_SHIM="$MACFUSE_PREFIX/lib/libmfosrelease.dylib"
RECAULK_SYSTEM_DYLIB="$RECAULK_PREFIX/lib/libRecaulkSystem.dylib"
export MACFUSE_OSRELEASE_SHIM RECAULK_SYSTEM_DYLIB
# spec: DETAILS.md "Install" -- one line per path third-party FUSE binaries and builds
#       have built in: the path (relative to the volume) and the tree path under MACFUSE_PREFIX its symlink names (build/stage.sh);
#       the last three are upstream 4.0.5's osxfuse compatibility names, which its core receipt installs and the takeover removes
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
usr/local/include/fuse3 include/fuse3
Library/Frameworks/OSXFUSE.framework Frameworks/OSXFUSE.framework
usr/local/lib/libosxfuse.2.dylib lib/libfuse.2.dylib
usr/local/lib/libosxfuse_i64.2.dylib lib/libfuse.2.dylib"
# spec: maintainer, 2026-11-20 (ship the osxfuse compatibility links) -- links
#       build/stage.sh makes inside the tree, as tree path and relative target, for those names: upstream 4.0.5's
#       OSXFUSE.framework held only Versions/A/OSXFUSE, a link to macFUSE.framework's binary; Resources, macFUSE.framework's,
#       gives the bundle the identity artifact conformance reads (io.macfuse.frameworks.macfuse, a declared deviation)
MACFUSE_TREE_LINKS="Frameworks/OSXFUSE.framework/Versions/A/OSXFUSE ../../../macFUSE.framework/Versions/A/macFUSE
Frameworks/OSXFUSE.framework/Resources ../macFUSE.framework/Resources"

# spec: tests/takeover-test.sh -- "macfuse_preinstall_hook OUT" writes the --preinstall-hook that
#       build/package.sh hands stage_product.sh: MACFUSE_PREFIX and MACFUSE_LINKS as above, packaging/lib-fuse-mounts.sh,
#       then packaging/preinstall-hook.sh, so the pkg's preinstall carries everything the takeover reads
macfuse_preinstall_hook() {
  case "$MACFUSE_PREFIX$MACFUSE_LINKS" in *"'"*) echo "macfuse_preinstall_hook: MACFUSE_PREFIX or MACFUSE_LINKS holds a quote" >&2; return 1 ;; esac
  {
    printf "MACFUSE_PREFIX='%s'\n" "$MACFUSE_PREFIX"
    printf "MACFUSE_LINKS='%s'\n" "$MACFUSE_LINKS"
    cat "$REPO_ROOT/packaging/lib-fuse-mounts.sh" "$REPO_ROOT/packaging/preinstall-hook.sh"
  } > "$1"
}

# spec: INGREDIENTS.md "Declared state" -- UPSTREAM_VERSION holds the bare upstream version; it is read from the file, never spelled here
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

# spec: tests/retarget-kext-test.sh -- Info.plist is read with POSIX awk, never PlistBuddy or plutil (a Linux build has
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
