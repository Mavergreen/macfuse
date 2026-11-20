#!/bin/sh
# platform: host-agnostic
# spec: build/build-mfmount.sh links the whole librecaulk.a the way clang22 places it, and keeps every
#       Recaulk name image-local by passing this list to -Wl,-unexported_symbols_list
#   usage: recaulk-unexported.sh LIBRECAULK
#          Prints every public (external, defined) name in the archive, sorted, one per line, using
#          $NM (default llvm-nm). Fails, printing nothing, if $NM fails or the archive lists no names.
set -eu
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 LIBRECAULK" >&2; exit 2; }
# platform: POSIX sh has no pipefail, so nm's status is taken on its own before the list is filtered
raw="$(${NM:-llvm-nm} -gUj "$1")" || { echo "recaulk-unexported: nm failed on $1" >&2; exit 1; }
out="$(printf '%s\n' "$raw" | awk 'NF && $0 !~ /:$/' | LC_ALL=C sort -u)" || { echo "recaulk-unexported: cannot sort the names of $1" >&2; exit 1; }
[ -n "$out" ] || { echo "recaulk-unexported: $1 lists no public names" >&2; exit 1; }
printf '%s\n' "$out"
