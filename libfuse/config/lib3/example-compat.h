/* example-compat.h -- force-included into libfuse 3's example/passthrough.c for
 * Mac OS X 10.9. Upstream's meson does not build the examples on darwin, and
 * passthrough.c uses three things no 10.9 SDK (and, for O_DIRECT, no macOS)
 * has. Recaulk supplies the other *at() calls it uses (openat, mkdirat, ...). */
#ifndef MACFUSE_EXAMPLE_COMPAT_H
#define MACFUSE_EXAMPLE_COMPAT_H
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
/* macOS has no O_DIRECT (it has F_NOCACHE); 0 makes the direct_io branch dead. */
#ifndef O_DIRECT
#define O_DIRECT 0
#endif
/* mkfifoat/mknodat arrived in macOS 13. passthrough.c only passes AT_FDCWD. */
static inline int macfuse_at_path_ok(int dirfd, const char *path)
{
	if (dirfd == AT_FDCWD || path[0] == '/')
		return 1;
	errno = ENOTSUP;
	return 0;
}
static inline int mkfifoat(int dirfd, const char *path, mode_t mode)
{
	return macfuse_at_path_ok(dirfd, path) ? mkfifo(path, mode) : -1;
}
static inline int mknodat(int dirfd, const char *path, mode_t mode, dev_t dev)
{
	return macfuse_at_path_ok(dirfd, path) ? mknod(path, mode, dev) : -1;
}
#endif
