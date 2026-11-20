#!/bin/sh
# platform: host-agnostic
# usage: fetch-sources.sh OUTDIR
#        Fetches the four pinned upstream source trees (components/macfuse-sources/pins) into
#        OUTDIR/{library2,library3,mount,framework}, each GitHub's tarball of its pinned commit verified by its
#        SHA-256 (shipyard's fetch_pinned_source.sh). Exits non-zero, naming the pin, on any failure; OUTDIR is
#        touched only when all four have been fetched. No git: this runs on 10.9.
set -eu
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; export REPO_ROOT
. "$REPO_ROOT/build/lib.sh"
. "$REPO_ROOT/build/msc.sh"

[ $# -eq 1 ] || { echo "usage: $0 OUTDIR" >&2; exit 2; }
out=$1
[ -f "$MACFUSE_PINS" ] || { echo "fetch-sources: no pins file $MACFUSE_PINS" >&2; exit 1; }

stage="$(mktemp -d "$out.tmp.XXXXXX")" || exit 1
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pin() { sed -n "s/^$1=//p" "$MACFUSE_PINS"; }

printf '%s\n' "$MACFUSE_SOURCES" | while read -r key dir repo _gitlink; do
  digest="$(pin "${key}_DIGEST")"; sum="$(pin "${key}_SHA256")"
  [ -n "$digest" ] && [ -n "$sum" ] || { echo "fetch-sources: ${key}_DIGEST or ${key}_SHA256 is missing from $MACFUSE_PINS" >&2; exit 1; }
  sh "$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" "https://github.com/$repo" "$digest" "$sum" "$stage/$dir" \
    || { echo "fetch-sources: ${key} ($repo at $digest, sha256 $sum) failed" >&2; exit 1; }
done

for d in library2 library3 mount framework; do
  rm -rf "${out:?}/$d"
  mkdir -p "$out"
  mv "$stage/$d" "$out/$d"
done
echo "all sources fetched into $out"
