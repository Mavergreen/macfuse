/* include/config.h for libfuse 2 (macfuse/library, Library-2) on Mac OS X 10.9.
 * Hand-written in place of autoconf's: a native 10.9 build has no autotools.
 * Values are what configure.ac finds with the 10.9 SDK plus the pinned Recaulk's
 * headers and librecaulk.a (utimensat comes from Recaulk). PACKAGE_VERSION must
 * match configure.ac's AC_INIT; build/build-libfuse.sh refuses a mismatch. */
#define PACKAGE "fuse"
#define PACKAGE_NAME "fuse"
#define PACKAGE_VERSION "2.9.9"
#define VERSION "2.9.9"
#define _POSIX_C_SOURCE 200809L
#define HAVE_FORK 1
#define HAVE_SETXATTR 1
#define HAVE_UTIMENSAT 1
#define HAVE_FDATASYNC 1
#define HAVE_DISPATCH_DISPATCH_H 1
#define HAVE_STRUCT_STAT_ST_ATIMENSEC 1
#define HAVE_ICONV 1
#define ICONV_CONST
/* Upstream's build (_POSIX_C_SOURCE, modern SDK) has no MAP_ANONYMOUS, so fuse.c
 * turns FUSE_NODE_SLAB off and uses no mmap/munmap. The pinned Recaulk's
 * sys/mman.h defines MAP_ANONYMOUS (as MAP_ANON, which the 10.9 SDK hides under
 * _POSIX_C_SOURCE) and would turn the slab allocator on. Include it here, under
 * its guard, and take MAP_ANONYMOUS back out so fuse.c matches upstream.
 * Exit: Recaulk's sys/mman.h fix (INGREDIENTS.md; tests/libfuse-config-test.sh
 * fails once the pinned Recaulk no longer needs this). */
#include <sys/mman.h>
#undef MAP_ANONYMOUS
