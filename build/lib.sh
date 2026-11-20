# platform: host-agnostic
# Sourced by every build script. The ONE place the install prefixes are spelled: every path a setuid
# helper loads derives from MACFUSE_PREFIX or RECAULK_PREFIX. Interim prefix, see the design spec.
if [ -z "${REPO_ROOT:-}" ]; then
  [ -f ./build/lib.sh ] || { echo "lib.sh: set REPO_ROOT, or source from the repo root" >&2; return 1 2>/dev/null || exit 1; }
  REPO_ROOT="$(pwd)"
fi
MACFUSE_PREFIX="${MACFUSE_PREFIX:-/usr/local/mavergreen/macfuse}"
RECAULK_PREFIX="${RECAULK_PREFIX:-/usr/local/mavergreen/recaulk}"
export REPO_ROOT MACFUSE_PREFIX RECAULK_PREFIX

# The bare upstream version (5.5.0), read from the file, never spelled here.
upstream_version() { tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_VERSION"; echo; }

# The pinned upstream sources: KEY, output directory, GitHub repository, gitlink in macfuse/macfuse.
# build/fetch-sources.sh and scripts/pin-sources.sh both read this table; components/macfuse-sources/pins holds the pins.
MACFUSE_SOURCES="LIBRARY2 library2 macfuse/library Library-2
LIBRARY3 library3 macfuse/library Library-3
MOUNT mount macfuse/mount Mount
FRAMEWORK framework macfuse/framework Framework"
MACFUSE_PINS="${MACFUSE_PINS:-$REPO_ROOT/components/macfuse-sources/pins}"
export MACFUSE_PINS
