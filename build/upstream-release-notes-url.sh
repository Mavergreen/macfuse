#!/bin/sh
# platform: host-agnostic
#   usage: upstream-release-notes-url.sh UPSTREAM_VERSION
#          prints the URL of upstream's own notes for that release, for shipyard's upstream-notes.sh
set -eu
[ "$#" -eq 1 ] || { echo 'usage: upstream-release-notes-url.sh UPSTREAM_VERSION' >&2; exit 2; }
printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "upstream-release-notes-url: $1 is not a release" >&2; exit 1; }
printf 'https://github.com/macfuse/macfuse/releases/tag/macfuse-%s\n' "$1"
