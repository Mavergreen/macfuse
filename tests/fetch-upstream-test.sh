#!/bin/sh
# platform: host-agnostic
# spec: build/fetch-upstream.sh (task 2), tested against a fixture release dir served over file://.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-upstream-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
V=9.9.9
rel="$T/rel/macfuse-$V"

mkfixture() {
  rm -rf "$T/rel"; mkdir -p "$rel"
  printf 'dmg bytes\n' > "$rel/macfuse-$V.dmg"
  printf 'tbz bytes\n' > "$rel/macfuse-$V-debug.tbz"
  printf 'src bytes\n' > "$rel/macfuse-$V-src.tbz"
  ( cd "$rel" && shasum -a 256 "macfuse-$V.dmg" "macfuse-$V-debug.tbz" "macfuse-$V-src.tbz" > "macfuse-$V.sha256" )
}
run() { # sets out, rc
  rm -rf "$T/out"
  rc=0
  out="$(MACFUSE_RELEASES="file://$T/rel" SHIPYARD_FETCH_BACKOFF=0 sh "$ROOT/build/fetch-upstream.sh" "$V" "$T/out" 2>&1)" || rc=$?
}

mkfixture; run
[ "$rc" -eq 0 ] || fail "all verified: exit $rc: $out"
for f in macfuse-$V.dmg macfuse-$V-debug.tbz macfuse-$V.sha256; do
  [ -f "$T/out/$f" ] || fail "missing output $f"
done
[ ! -e "$T/out/macfuse-$V-src.tbz" ] || fail "-src.tbz line was treated as an asset"

mkfixture; printf 'tampered\n' >> "$rel/macfuse-$V-debug.tbz"; run
[ "$rc" -ne 0 ] || fail "altered asset: exit 0"
case "$out" in *macfuse-$V-debug.tbz*) ;; *) fail "altered asset: output does not name it: $out" ;; esac

mkfixture; grep -v -- "-debug.tbz" "$rel/macfuse-$V.sha256" > "$T/s"; mv "$T/s" "$rel/macfuse-$V.sha256"; run
[ "$rc" -ne 0 ] || fail "unlisted asset: exit 0"
case "$out" in *macfuse-$V-debug.tbz*) ;; *) fail "unlisted asset: output does not name it: $out" ;; esac

mkfixture; grep -- "macfuse-$V.dmg" "$rel/macfuse-$V.sha256" >> "$rel/macfuse-$V.sha256"; run
[ "$rc" -ne 0 ] || fail "duplicated asset: exit 0"
case "$out" in *macfuse-$V.dmg*) ;; *) fail "duplicated asset: output does not name it: $out" ;; esac

[ "$fails" -eq 0 ] && echo "fetch-upstream-test: PASS" || { echo "fetch-upstream-test: $fails failure(s)" >&2; exit 1; }
