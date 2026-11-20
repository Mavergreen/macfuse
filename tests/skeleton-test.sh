#!/bin/sh
# platform: host-agnostic
# Task 1 skeleton: release-notes URL, build/lib.sh defaults, msc.sh byte-identical to shipyard's template.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
SHIPYARD_SCRIPTS="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

got="$(sh build/upstream-release-notes-url.sh 5.5.0 2>&1)" || true
want='https://github.com/macfuse/macfuse/releases/tag/macfuse-5.5.0'
[ "$got" = "$want" ] || fail "release-notes url: got '$got'"

want_ver="$(tr -d '[:space:]' < UPSTREAM_VERSION 2>/dev/null)" || want_ver=
[ -n "$want_ver" ] || fail "UPSTREAM_VERSION missing or empty"
got="$(env -u MACFUSE_PREFIX -u RECAULK_PREFIX REPO_ROOT="$ROOT" sh -c '. build/lib.sh; upstream_version' 2>&1)" || true
[ "$got" = "$want_ver" ] || fail "upstream_version: got '$got', want '$want_ver'"

got="$(env -u MACFUSE_PREFIX -u RECAULK_PREFIX REPO_ROOT="$ROOT" sh -c '. build/lib.sh; printf "%s %s" "$MACFUSE_PREFIX" "$RECAULK_PREFIX"' 2>&1)" || true
[ "$got" = "/usr/local/mavergreen/macfuse /usr/local/mavergreen/recaulk" ] || fail "default prefixes: got '$got'"

got="$(MACFUSE_PREFIX=/x/m RECAULK_PREFIX=/x/r REPO_ROOT="$ROOT" sh -c '. build/lib.sh; printf "%s %s" "$MACFUSE_PREFIX" "$RECAULK_PREFIX"' 2>&1)" || true
[ "$got" = "/x/m /x/r" ] || fail "overridden prefixes: got '$got'"

got="$(env -u REPO_ROOT sh -c '. build/lib.sh; printf "%s" "$REPO_ROOT"' 2>&1)" || true
[ "$got" = "$ROOT" ] || fail "REPO_ROOT default: got '$got'"

cmp build/msc.sh "$SHIPYARD_SCRIPTS/templates/msc.sh" || fail "build/msc.sh differs from shipyard template"

[ "$fails" -eq 0 ] || exit 1
echo "skeleton-test: ok"
