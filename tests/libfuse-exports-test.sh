#!/bin/sh
# platform: host-agnostic
# spec: README.md "Coming from macFUSE 4" -- the 10.9 libfuse 2 and 3 must be drop-in for upstream's: the same exported
#       names as upstream's x86_64 slices (207 and 225), the same install names and versions, the same headers and
#       pkg-config files, and only the imports the 10.9 build needs; no Recaulk name leaks out as an export.
# spec: INGREDIENTS.md "Conformance deviations" objc-measure -- each must pass the default compat guard; the strict one is
#       recorded and fails only outside the declared Drydock gaps (tests/lib/strict-measure.sh)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
. "$REPO_ROOT/tests/lib/strict-measure.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
UP="${MACFUSE_DMG_ROOT:-}/usr/local"
if [ -z "${MACFUSE_DMG_ROOT:-}" ] || [ ! -f "$UP/lib/libfuse.2.dylib" ] || [ ! -f "$UP/lib/libfuse3.4.dylib" ]; then
  echo "SKIP: MACFUSE_DMG_ROOT unset or lacks upstream's libfuse"; exit 77
fi
BUILD="${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}"
SRC="${MACFUSE_SRC:-$BUILD/src}"
for d in library2 library3 mount; do
  [ -d "$SRC/$d" ] || { echo "FAIL: no fetched $d sources at $SRC/$d (build/fetch-sources.sh)" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/libfuse-exports-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
macfuse_toolchain libfuse-exports-test || { echo "FAIL: no toolchain" >&2; exit 1; }
sh "$REPO_ROOT/build/build-mfmount.sh" "$SRC" "$T/stage" > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; echo "FAIL: build-mfmount.sh failed" >&2; exit 1; }
OURS="$T/stage$MACFUSE_PREFIX"
# spec: build/build-libfuse.sh -- it shares lib/ with the osrelease shim (build/build-shim.sh), so it
#       replaces only its own files: a foreign file survives, and a stale file inside its own include/fuse/ does not
mkdir -p "$OURS/lib" "$OURS/include/fuse"
echo foreign > "$OURS/lib/foreign.txt"
echo stale > "$OURS/include/fuse/stale.h"
echo stale > "$OURS/lib/libfuse.dylib"
sh "$REPO_ROOT/build/build-libfuse.sh" "$SRC" "$T/stage" "$T/ex" > "$T/build.log" 2>&1 || { tail -40 "$T/build.log" >&2; echo "FAIL: build-libfuse.sh failed" >&2; exit 1; }
[ -f "$OURS/lib/foreign.txt" ] || fail "build-libfuse.sh removed a file in lib/ that is not its own"
[ ! -e "$OURS/include/fuse/stale.h" ] || fail "build-libfuse.sh left a stale file in its own include/fuse/"
[ -L "$OURS/lib/libfuse.dylib" ] || fail "build-libfuse.sh left the stale regular file lib/libfuse.dylib instead of its link"
rm -f "$OURS/lib/foreign.txt"
NM="$CL/bin/llvm-nm"
OTOOL="$CL/bin/llvm-otool"
MFMOUNT=/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount
# spec: components/recaulk/version 20261120.1's dispatch overrides use the ObjC runtime, so libobjc is acceptable as a load command only
#       when every name bound to it is one librecaulk.a references, i.e. Recaulk brought it, not libfuse
OBJC=/usr/lib/libobjc.A.dylib
"$NM" -uj "$RC/lib/librecaulk.a" 2> /dev/null | LC_ALL=C sort -u > "$T/recaulk-undef.txt"
objc_from_recaulk() {
  "$CL/bin/llvm-objdump" --macho --bind --lazy-bind --weak-bind "$1" | awk 'NF > 1 && $(NF-1) == "libobjc" { print $NF }' | LC_ALL=C sort -u > "$T/objc-bound.txt"
  [ -s "$T/objc-bound.txt" ] || { fail "$(basename "$1"): loads libobjc but binds nothing to it"; return; }
  LC_ALL=C comm -23 "$T/objc-bound.txt" "$T/recaulk-undef.txt" > "$T/objc-own.txt"
  [ ! -s "$T/objc-own.txt" ] || { cat "$T/objc-own.txt" >&2; fail "$(basename "$1"): binds libobjc names librecaulk.a does not reference"; }
}
NM="$NM" sh "$REPO_ROOT/build/recaulk-unexported.sh" "$RC/lib/librecaulk.a" > "$T/recaulk-names.txt" || fail "recaulk-unexported.sh failed"

for spec in "libfuse.2.dylib 207 12.0.0 12.9.0" "libfuse3.4.dylib 225 4.0.0 4.0.0"; do
  set -- $spec
  lib=$1; n=$2; compat=$3; cur=$4
  ours="$OURS/lib/$lib"
  [ -f "$ours" ] || { fail "no $ours"; continue; }
  "$NM" --arch=x86_64 -gUj "$UP/lib/$lib" | LC_ALL=C sort > "$T/up.txt"
  "$NM" -gUj "$ours" | LC_ALL=C sort > "$T/ours.txt"
  [ "$(wc -l < "$T/up.txt" | tr -d ' ')" -eq "$n" ] || fail "$lib: upstream exports $(wc -l < "$T/up.txt" | tr -d ' '), not $n"
  diff "$T/up.txt" "$T/ours.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "$lib: exports differ from upstream's"; }
  grep -qx -e _clock_gettime -e _aligned_alloc "$T/ours.txt" && fail "$lib: exports _clock_gettime or _aligned_alloc"
  LC_ALL=C comm -12 "$T/recaulk-names.txt" "$T/ours.txt" > "$T/leaked.txt"
  [ ! -s "$T/leaked.txt" ] || { cat "$T/leaked.txt" >&2; fail "$lib: exports Recaulk names"; }

  # spec: libfuse/config/lib2/config.h -- libfuse 2's slab allocator stays off (no _mmap/_munmap) and neither names its
  #       threads; upstream's libfuse 3 does import _mmap/_munmap (outside the slab), so the sets must match upstream's
  "$NM" -uj "$ours" | grep -x -e _mmap -e _munmap -e _pthread_setname_np > "$T/undef.txt" || :
  "$NM" --arch=x86_64 -uj "$UP/lib/$lib" | grep -x -e _mmap -e _munmap -e _pthread_setname_np > "$T/up-undef.txt" || :
  diff "$T/up-undef.txt" "$T/undef.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "$lib: imports of _mmap, _munmap, _pthread_setname_np differ from upstream's"; }
  grep -qx _pthread_setname_np "$T/undef.txt" && fail "$lib: imports _pthread_setname_np"
  [ "$lib" = libfuse.2.dylib ] && [ -s "$T/undef.txt" ] && fail "$lib: imports $(tr '\n' ' ' < "$T/undef.txt")(the slab allocator is on)"

  "$OTOOL" -L "$ours" | sed 1d > "$T/L.txt"
  echo "== $lib"; cat "$T/L.txt"
  awk '{ print $1 }' "$T/L.txt" | LC_ALL=C sort > "$T/imports.txt"
  { printf '%s\n' "/usr/local/lib/$lib" "$MFMOUNT" \
      /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
      /System/Library/Frameworks/DiskArbitration.framework/Versions/A/DiskArbitration \
      /usr/lib/libicucore.A.dylib /usr/lib/libiconv.2.dylib /usr/lib/libSystem.B.dylib; } | LC_ALL=C sort > "$T/want.txt"
  if grep -qx "$OBJC" "$T/imports.txt"; then objc_from_recaulk "$ours"; echo "($lib: $OBJC from Recaulk, binding: $(tr '\n' ' ' < "$T/objc-bound.txt"))"; fi
  grep -vx "$OBJC" "$T/imports.txt" | diff "$T/want.txt" - > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "$lib: load commands differ from the expected set"; }
  grep -qF "$MFMOUNT (compatibility version 3.0.0, current version 4.0.0)" "$T/L.txt" || fail "$lib: MFMount not loaded at 3.0.0/4.0.0"

  "$OTOOL" -l "$ours" | awk '/cmd LC_ID_DYLIB/ { id = 1 } id && /current version/ { c = $3 } id && /compatibility version/ { k = $3; id = 0 } END { print k, c }' > "$T/ver.txt"
  [ "$(cat "$T/ver.txt")" = "$compat $cur" ] || fail "$lib: LC_ID_DYLIB compat/current are $(cat "$T/ver.txt"), not $compat $cur"

  sh "$REPO_ROOT/build/compat-guard.sh" --default "$ours" || fail "$lib: the default compat guard failed"
  strict_measure "$ours" "$T/strict.txt" || fail "$lib: the strict compat guard failed"
done

for l in libfuse.dylib:libfuse.2.dylib libfuse3.dylib:libfuse3.4.dylib; do
  [ "$(readlink "$OURS/lib/${l%%:*}" 2> /dev/null)" = "${l#*:}" ] || fail "lib/${l%%:*} is not a link to ${l#*:}"
done

(cd "$UP/include" && find . -type f | LC_ALL=C sort) > "$T/up-h.txt"
(cd "$OURS/include" && find . -type f | LC_ALL=C sort) > "$T/ours-h.txt" 2> /dev/null || :
diff "$T/up-h.txt" "$T/ours-h.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "staged headers are not upstream's set"; }
while read -r h; do
  cmp -s "$UP/include/$h" "$OURS/include/$h" || fail "include/$h differs from upstream's"
done < "$T/up-h.txt"

# spec: build/build-libfuse.sh -- the only intended differences are the link flags of the 10.9 build
for f in pkgconfig/fuse.pc:Libs.private pkgconfig/fuse3.pc:NONE libfuse.la:dependency_libs; do
  p=${f%%:*}; k=${f#*:}
  [ -f "$OURS/lib/$p" ] || { fail "no lib/$p"; continue; }
  grep -v "^$k" "$UP/lib/$p" > "$T/a"; grep -v "^$k" "$OURS/lib/$p" > "$T/b"
  diff "$T/a" "$T/b" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "lib/$p differs from upstream's beyond $k"; }
done
grep -q '^Libs.private:.*-liconv' "$OURS/lib/pkgconfig/fuse.pc" || fail "fuse.pc Libs.private lacks -liconv"
grep -q -- '-delay_framework' "$OURS/lib/pkgconfig/fuse.pc" && fail "fuse.pc still names -delay_framework, which no 10.9 linker has"

for e in hello2 hello3 passthrough3; do
  [ -f "$T/ex/$e" ] || { fail "no example $e"; continue; }
  case $e in hello2) want=/usr/local/lib/libfuse.2.dylib ;; *) want=/usr/local/lib/libfuse3.4.dylib ;; esac
  "$OTOOL" -L "$T/ex/$e" | sed 1d | awk '{ print $1 }' | LC_ALL=C sort > "$T/imports.txt"
  printf '%s\n' "$want" /usr/lib/libSystem.B.dylib | LC_ALL=C sort > "$T/want.txt"
  if grep -qx "$OBJC" "$T/imports.txt"; then objc_from_recaulk "$T/ex/$e"; grep -vx "$OBJC" "$T/imports.txt" > "$T/i2.txt" || :; mv "$T/i2.txt" "$T/imports.txt"; fi
    LC_ALL=C comm -13 "$T/want.txt" "$T/imports.txt" > "$T/extra.txt"
  [ ! -s "$T/extra.txt" ] || { cat "$T/extra.txt" >&2; fail "example $e loads more than its libfuse and libSystem"; }
  grep -qx "$want" "$T/imports.txt" || fail "example $e does not load $want"
done

[ "$fails" -eq 0 ] || exit 1
echo "libfuse-exports-test: PASS"
