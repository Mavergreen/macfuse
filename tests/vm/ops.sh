#!/bin/sh
# platform: macOS-only -- runs 10.9's own mv, xattr and python 2.7 against a mounted FUSE volume in the acceptance job
# spec: 2026-11-19-macfuse-product/task-11-brief.md Scenario A -- the passthrough3 ops: write, read, rename, rename over an
#       existing file and an existing (empty) directory, xattr set/get/remove, mkdir/rmdir, unlink. Grown from the spike's
#       .superpowers/spike/t5b/ops.sh, which printed results to diff; this one asserts each and stops at the first failure.
#   usage: ops.sh DIR    (DIR is a directory on the volume under test, empty or not; ops.sh works in DIR/ops.$$)
set -u
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: ops.sh DIR" >&2; exit 2; }
D="$1/ops.$$"
fail() { echo "ops: FAIL: $*" >&2; exit 1; }
ok() { echo "ops: ok: $*"; }
# platform: 10.9 has python 2.7 and no python3; os.rename is rename(2), which mv does not give for a directory over a directory
pyrename() { python -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2"; }

mkdir "$D" || fail "mkdir $D"
cd "$D" || fail "cd $D"
printf 'line1\nline2\n' > a || fail "write"
printf 'line3\n' >> a || fail "append"
[ "$(cat a)" = "$(printf 'line1\nline2\nline3')" ] || fail "read back: $(cat a)"
[ "$(wc -c < a | tr -d ' ')" = 18 ] || fail "size after write is not 18"
ok "write, append, read"
mv a b || fail "rename a b"
[ ! -e a ] && [ "$(head -n 1 b)" = line1 ] || fail "after rename, a remains or b is wrong"
ok "rename"
echo other > c || fail "write c"
mv c b || fail "rename c over existing b"
[ ! -e c ] && [ "$(cat b)" = other ] || fail "after rename over existing, b is '$(cat b)'"
ok "rename over an existing file"
mkdir d1 d2 || fail "mkdir d1 d2"
echo inside > d1/f || fail "write d1/f"
pyrename d1 d2 || fail "rename directory d1 over empty directory d2"
[ ! -e d1 ] && [ "$(cat d2/f)" = inside ] || fail "after directory rename over existing, d2/f is wrong"
ok "rename a directory over an existing empty directory"
pyrename d2 d4 || fail "rename directory d2 d4"
[ -f d4/f ] || fail "after directory rename, d4/f missing"
ok "rename a directory"
xattr -w user.mavergreen hello b || fail "xattr -w"
[ "$(xattr -p user.mavergreen b)" = hello ] || fail "xattr -p gives '$(xattr -p user.mavergreen b 2>&1)'"
xattr b | grep -qx user.mavergreen || fail "xattr list lacks user.mavergreen"
xattr -d user.mavergreen b || fail "xattr -d"
xattr -p user.mavergreen b > /dev/null 2>&1 && fail "xattr still readable after -d"
ok "xattr set, get, list, remove"
mkdir -p sub/deeper || fail "mkdir -p sub/deeper"
mv b sub/ || fail "mv b into sub"
[ -f sub/b ] || fail "sub/b missing"
rmdir sub/deeper || fail "rmdir sub/deeper"
rm sub/b || fail "unlink sub/b"
[ ! -e sub/b ] || fail "sub/b remains after unlink"
rmdir sub || fail "rmdir sub"
ok "mkdir, rmdir, unlink"
dd if=/dev/zero of=big bs=65536 count=64 2>/dev/null || fail "dd 4 MiB"
[ "$(wc -c < big | tr -d ' ')" = 4194304 ] || fail "big is not 4 MiB"
ok "a 4 MiB file"
rm -f big d4/f && rmdir d4 || fail "cleanup in $D"
cd .. && rmdir "$D" || fail "cleanup"
[ ! -e "$D" ] || fail "cleanup left $D"
ok "all"
