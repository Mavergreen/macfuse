/* fuse_config.h for libfuse 3 (macfuse/library, Library-3) on Mac OS X 10.9.
 * Hand-written in place of meson's: a native 10.9 build has no meson. Values are
 * what meson.build finds with the 10.9 SDK plus the pinned Recaulk (utimensat
 * comes from Recaulk). Booleans meson writes as #undef are left out, among them
 * the pthread_setname_np one: meson probes the 2-argument glibc form, which fails on
 * Darwin, so upstream's libfuse3 neither names its threads nor imports it.
 * PACKAGE_VERSION must match meson.build's; build/build-libfuse.sh refuses a
 * mismatch. */
#define PACKAGE_VERSION "3.18.3"
#define HAVE_FORK 1
#define HAVE_FDATASYNC 1
#define HAVE_UTIMENSAT 1
#define HAVE_SYS_XATTR_H 1
#define HAVE_SETXATTR 1
#define HAVE_ICONV 1
#define HAVE_BACKTRACE 1
#define HAVE_STRUCT_STAT_ST_ATIMESPEC 1
