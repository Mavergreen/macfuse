#!/bin/sh
# platform: host-agnostic -- reads release-notes/ and asks git which tags exist
# spec: build/package.sh -- the pkg's preinstall requires the Recaulk components/recaulk/version pins, so an unreleased tag's
#       release-notes/<tag>/requires/recaulk, the "Install recaulk X or later first." line, names that same version;
#       a released tag's note is history and is not compared
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/.." && pwd)}"
git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1 || { echo "SKIP: not a git checkout, so released tags are unknown"; exit 77; }
pin="$(tr -d ' \t\r\n' < "$REPO_ROOT/components/recaulk/version")"
fails=0
checked=0
for f in "$REPO_ROOT"/release-notes/*/requires/recaulk; do
  [ -f "$f" ] || continue
  tag="$(basename "$(dirname "$(dirname "$f")")")"
  [ -z "$(git -C "$REPO_ROOT" tag -l "$tag")" ] || continue
  checked=$((checked + 1))
  v="$(sed -n '1{s/[[:space:]]//g;p;}' "$f")"
  [ "$v" = "$pin" ] || { echo "FAIL: release-notes/$tag/requires/recaulk says '$v', but components/recaulk/version pins '$pin', which the preinstall requires" >&2; fails=$((fails + 1)); }
done
[ "$fails" -eq 0 ] || exit 1
echo "ok: $checked unreleased requires/recaulk note(s) name the pinned Recaulk $pin"
