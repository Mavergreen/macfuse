#!/bin/sh
# platform: host-agnostic
# spec: build/recaulk-unexported.sh feeds -Wl,-unexported_symbols_list for every Recaulk link; a failed or empty
#       llvm-nm run must fail the build, never hand the linker a short list (Recaulk names would leak as exports)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
S="$REPO_ROOT/build/recaulk-unexported.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/recaulk-unexported-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$T/librecaulk.a"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }

stub good 'printf "\n%s:\n_b\n_a\n___recaulk_x\n_a\n" "$2(m.o)"'
if NM="$T/good" sh "$S" "$T/librecaulk.a" > "$T/out" 2> "$T/err"; then
  printf '%s\n' ___recaulk_x _a _b | cmp -s - "$T/out" || { cat "$T/out" >&2; fail "good nm: not the sorted, unique names"; }
else
  cat "$T/err" >&2; fail "good nm: failed"
fi

stub partial 'printf "_a\n_b\n"; echo "llvm-nm: error: bad member" >&2; exit 1'
if NM="$T/partial" sh "$S" "$T/librecaulk.a" > "$T/out" 2> "$T/err"; then
  fail "nm failing on one member: exited 0"
fi
[ ! -s "$T/out" ] || { cat "$T/out" >&2; fail "nm failing on one member: printed a list"; }

stub empty 'exit 0'
if NM="$T/empty" sh "$S" "$T/librecaulk.a" > "$T/out" 2> "$T/err"; then
  fail "empty list: exited 0"
fi
[ ! -s "$T/out" ] || fail "empty list: printed something"

stub headers 'printf "\n%s:\n\n" "$2(m.o)"'
if NM="$T/headers" sh "$S" "$T/librecaulk.a" > "$T/out" 2> "$T/err"; then
  fail "only member headers: exited 0"
fi

if NM="$T/does-not-exist" sh "$S" "$T/librecaulk.a" > "$T/out" 2> "$T/err"; then
  fail "missing nm: exited 0"
fi

[ "$fails" -eq 0 ] || exit 1
echo "recaulk-unexported-test: PASS"
