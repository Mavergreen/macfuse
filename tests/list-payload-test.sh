#!/bin/sh
# platform: host-agnostic
# spec: build/list-payload.sh (task 2 fix) fails, and leaves no listing, on a corrupt or empty payload.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/list-payload-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/root/a"; printf x > "$T/root/a/f"; chmod 4755 "$T/root/a/f"
( cd "$T/root" && find . | cpio -o 2>/dev/null > "$T/good.cpio" )
rc=0; sh "$ROOT/build/list-payload.sh" "$T/good.cpio" "$T/good.txt" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "good payload: exit $rc"
grep -q "^./a/f	104755	" "$T/good.txt" || fail "good payload: setuid file not 104755: $(cat "$T/good.txt")"

printf 'this is not a cpio archive, just junk bytes\n' > "$T/bad.cpio"
rc=0; sh "$ROOT/build/list-payload.sh" "$T/bad.cpio" "$T/bad.txt" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "corrupt payload: exit 0"
[ ! -e "$T/bad.txt" ] || fail "corrupt payload: left a listing behind"

: > "$T/empty.cpio"
rc=0; sh "$ROOT/build/list-payload.sh" "$T/empty.cpio" "$T/empty.txt" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "empty payload: exit 0"
[ ! -e "$T/empty.txt" ] || fail "empty payload: left a listing behind"
ls "$T" | grep -q 'list\.' && fail "temp list left behind" || :

[ "$fails" -eq 0 ] && echo "list-payload-test: PASS" || { echo "list-payload-test: $fails failure(s)" >&2; exit 1; }
