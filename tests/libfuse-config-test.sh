#!/bin/sh
# platform: host-agnostic
# spec: 2026-11-18-macfuse-spike-findings.md "libfuse 2 and 3" -- the hand-written config headers stand in for configure and meson. lib3 must not
#       claim pthread_setname_np (findings M1: upstream's meson probe fails on Darwin). lib2 must keep fuse.c's slab
#       allocator off as upstream's build does, which the pinned Recaulk's sys/mman.h defeats by defining
#       MAP_ANONYMOUS under _POSIX_C_SOURCE; the workaround stays exactly as long as that defect does.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
L2="$REPO_ROOT/libfuse/config/lib2/config.h"
L3="$REPO_ROOT/libfuse/config/lib3/fuse_config.h"
[ -f "$L2" ] || { echo "FAIL: no $L2" >&2; exit 1; }
[ -f "$L3" ] || { echo "FAIL: no $L3" >&2; exit 1; }

! grep -q 'HAVE_PTHREAD_SETNAME_NP' "$L3" || fail "lib3/fuse_config.h mentions HAVE_PTHREAD_SETNAME_NP; upstream's meson never sets it on Darwin (findings M1)"

T="$(mktemp -d "${TMPDIR:-/tmp}/libfuse-config-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
macfuse_toolchain libfuse-config-test || { echo "FAIL: no toolchain" >&2; exit 1; }
printf '%s\n' '#define _POSIX_C_SOURCE 200809L' '#include <sys/mman.h>' '#ifdef MAP_ANONYMOUS' 'recaulk_mman_defect' '#endif' > "$T/probe.c"
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -isysroot "$SDK" -isystem "$RC/include/recaulk" \
  -E "$T/probe.c" -o "$T/probe.i" || { echo "FAIL: cannot preprocess the sys/mman.h probe" >&2; exit 1; }

inc="$(grep -n '^#include <sys/mman.h>' "$L2" | head -1 | cut -d: -f1)"
und="$(grep -n '^#undef MAP_ANONYMOUS' "$L2" | head -1 | cut -d: -f1)"
if grep -q '^recaulk_mman_defect$' "$T/probe.i"; then
  if [ -z "$inc" ] || [ -z "$und" ] || [ "$inc" -ge "$und" ]; then
    fail "lib2/config.h must #include <sys/mman.h> and then #undef MAP_ANONYMOUS: the pinned Recaulk's sys/mman.h still defines MAP_ANONYMOUS under _POSIX_C_SOURCE. Exit: Recaulk's sys/mman.h fix (plan 1)"
  fi
  grep -q 'MAP_ANONYMOUS' "$REPO_ROOT/INGREDIENTS.md" || fail "INGREDIENTS.md does not declare the MAP_ANONYMOUS workaround (exit: Recaulk's sys/mman.h fix, plan 1)"
else
  [ -z "$und" ] || fail "the pinned Recaulk's sys/mman.h is fixed (no MAP_ANONYMOUS under _POSIX_C_SOURCE): drop the workaround from lib2/config.h"
  ! grep -q 'MAP_ANONYMOUS' "$REPO_ROOT/INGREDIENTS.md" || fail "the pinned Recaulk's sys/mman.h is fixed: drop the MAP_ANONYMOUS workaround from INGREDIENTS.md"
fi

[ "$fails" -eq 0 ] || exit 1
echo "libfuse-config-test: PASS"
