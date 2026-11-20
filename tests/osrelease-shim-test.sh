#!/bin/sh
# platform: host-agnostic
# spec: shim/osrelease.c -- libmfosrelease.dylib, at $MACFUSE_PREFIX/lib/libmfosrelease.dylib, exports only _sysctlbyname
#       and imports only from libSystem, and passes the default and the strict compat guard outright. Its executing half
#       (four cases, tests/shim/osrelease-test.c) runs only on a host that executes x86_64 (the 10.9 VM
#       job); on any other host the test SKIPs (77) once the static half has passed.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/osrelease-shim-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

INSTALL="$MACFUSE_PREFIX/lib/libmfosrelease.dylib"
# spec: build/build-shim.sh -- a build script replaces only its own outputs in the shared STAGE tree
mkdir -p "$T/stage$MACFUSE_PREFIX/lib"
echo foreign > "$T/stage$MACFUSE_PREFIX/lib/foreign.txt"
sh "$REPO_ROOT/build/build-shim.sh" "$T/stage" > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; echo "FAIL: build-shim.sh failed" >&2; exit 1; }
SHIM="$T/stage$INSTALL"
[ -f "$SHIM" ] || { echo "FAIL: no $SHIM" >&2; exit 1; }
[ -f "$T/stage$MACFUSE_PREFIX/lib/foreign.txt" ] || fail "build-shim.sh removed a file in lib/ that is not its own"

CL="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")"
"$CL/bin/llvm-lipo" -info "$SHIM" > "$T/info" 2>&1 || :
grep -q '^Non-fat file: .* is architecture: x86_64 *$' "$T/info" || { cat "$T/info" >&2; fail "not thin x86_64"; }
id="$("$CL/bin/llvm-otool" -D "$SHIM" | sed 1d)"
[ "$id" = "$INSTALL" ] || fail "install name is '$id', not $INSTALL"
"$CL/bin/llvm-nm" -gUj "$SHIM" > "$T/exports.txt"
echo "exports: $(tr '\n' ' ' < "$T/exports.txt")"
[ "$(cat "$T/exports.txt")" = _sysctlbyname ] || fail "exports more or less than _sysctlbyname"
# spec: shim/osrelease.c -- a setuid-root binary loads the shim, so its symbol table is reviewed
#       whole: it defines only _sysctlbyname (and the linker's own __dyld_private), so no librecaulk.a member is linked in
#       unreviewed, and it binds only these names, each from libSystem (memcpy of the 7 bytes is inlined)
"$CL/bin/llvm-nm" -Uj "$SHIM" | LC_ALL=C sort > "$T/defined.txt"
printf '%s\n' __dyld_private _sysctlbyname > "$T/want-defined.txt"
diff "$T/want-defined.txt" "$T/defined.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "defines other symbols than _sysctlbyname and __dyld_private"; }
"$CL/bin/llvm-nm" -uj "$SHIM" | LC_ALL=C sort > "$T/undefined.txt"
echo "binds: $(tr '\n' ' ' < "$T/undefined.txt")"
printf '%s\n' ___error ___stack_chk_fail ___stack_chk_guard _strcmp _sysctl _sysctlnametomib dyld_stub_binder | LC_ALL=C sort > "$T/want-undefined.txt"
diff "$T/want-undefined.txt" "$T/undefined.txt" > "$T/diff.txt" || { cat "$T/diff.txt" >&2; fail "binds other names than the reviewed libSystem set"; }
"$CL/bin/llvm-nm" -m "$SHIM" | grep '(undefined)' | grep -v '(from libSystem)$' > "$T/not-libsystem.txt" || :
[ ! -s "$T/not-libsystem.txt" ] || { cat "$T/not-libsystem.txt" >&2; fail "binds a name from outside libSystem"; }
"$CL/bin/llvm-otool" -L "$SHIM" | sed 1,2d | awk '{ print $1 }' > "$T/imports.txt"
echo "imports: $(tr '\n' ' ' < "$T/imports.txt")"
[ "$(cat "$T/imports.txt")" = /usr/lib/libSystem.B.dylib ] || fail "loads more or less than /usr/lib/libSystem.B.dylib"
sh "$REPO_ROOT/build/compat-guard.sh" --default "$SHIM" || fail "the default compat guard failed on the shim"
sh "$REPO_ROOT/build/compat-guard.sh" "$SHIM" || fail "the strict compat guard failed on the shim"
[ "$fails" -eq 0 ] || exit 1

if [ "$(uname -s)" != Darwin ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
  echo "SKIP: static half passed; this host cannot execute x86_64 (not Darwin, or Apple silicon)"; exit 77
fi
SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
"$CL/bin/clang" --no-default-config --target=x86_64-apple-macos10.9 -isysroot "$SDK" -O2 -Wall -fuse-ld=lld \
  "$REPO_ROOT/tests/shim/osrelease-test.c" "$SHIM" -o "$T/osrelease-test"
DYLD_LIBRARY_PATH="$(dirname "$SHIM")" "$T/osrelease-test" > "$T/out.txt" 2>&1 || { cat "$T/out.txt" >&2; echo "FAIL: osrelease-test" >&2; exit 1; }
cat "$T/out.txt"
grep -q '^PASS$' "$T/out.txt" || { echo "FAIL: no PASS line" >&2; exit 1; }
echo "osrelease-shim-test: PASS"
