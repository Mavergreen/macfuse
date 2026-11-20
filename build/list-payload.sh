#!/bin/sh
# platform: host-agnostic
# spec: the listing comes from the payload archive (cpio), because stevedore 20261027.1 has no BOM reader
# usage: list-payload.sh PAYLOAD.cpio OUT
# Writes "./path<TAB>octal-mode<TAB>uid/gid" per entry. Fails, leaving no OUT, if cpio fails or lists nothing.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 PAYLOAD.cpio OUT" >&2; exit 2; }
cpio_in=$1
bom=$2
list="$bom.list.$$"
trap 'rm -f "$list" "$bom"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# platform: listed to a file, not piped, so a failing cpio fails here rather than leaving a truncated listing
cpio -itnv < "$cpio_in" > "$list" || { echo "list-payload: cpio could not list $cpio_in" >&2; exit 1; }
[ -s "$list" ] || { echo "list-payload: $cpio_in lists no entries" >&2; exit 1; }
# bsdcpio -tnv: "<symbolic mode> <nlink> <uid> <gid> <size> <3-word date> <name>[ -> target]"
awk '
  function oct(s,   i, c, d, p, sp, t) {
    t = substr(s, 1, 1)
    p = 0
    for (i = 0; i < 3; i++) {
      d = 0
      c = substr(s, 2 + i * 3, 1); if (c == "r") d += 4
      c = substr(s, 3 + i * 3, 1); if (c == "w") d += 2
      c = substr(s, 4 + i * 3, 1)
      if (c == "x" || c == "s" || c == "t") d += 1
      p = p * 8 + d
    }
    sp = 0
    c = substr(s, 4, 1); if (c == "s" || c == "S") sp += 4
    c = substr(s, 7, 1); if (c == "s" || c == "S") sp += 2
    c = substr(s, 10, 1); if (c == "t" || c == "T") sp += 1
    return sprintf("%s%04o", (t == "d") ? "4" : (t == "l") ? "12" : "10", sp * 512 + p)
  }
  {
    mode = $1; uid = $3; gid = $4
    name = $0
    for (i = 0; i < 8; i++) sub(/^[^ ]+ +/, "", name)
    if (substr(mode, 1, 1) == "l") sub(/ -> .*$/, "", name)
    printf "%s\t%s\t%s/%s\n", name, oct(mode), uid, gid
  }' "$list" > "$bom"
[ -s "$bom" ] || { echo "list-payload: empty listing" >&2; exit 1; }
trap - EXIT
rm -f "$list"
