#!/bin/sh
# platform: host-agnostic
# spec: build/build-mfmount.sh links the whole librecaulk.a the way clang22 places it, and keeps every
#       Recaulk name image-local by passing this list to -Wl,-unexported_symbols_list
#   usage: recaulk-unexported.sh LIBRECAULK
#          Prints every public (external, defined) name in the archive, sorted, one per line, using
#          $NM (default llvm-nm). Fails, printing nothing, if the archive lists no names.
set -eu
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 LIBRECAULK" >&2; exit 2; }
out="$(${NM:-llvm-nm} -gUj "$1" | awk 'NF && $0 !~ /:$/' | LC_ALL=C sort -u)" || { echo "recaulk-unexported: nm failed on $1" >&2; exit 1; }
[ -n "$out" ] || { echo "recaulk-unexported: $1 lists no public names" >&2; exit 1; }
printf '%s\n' "$out"
