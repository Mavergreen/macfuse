/*
 * osrelease.c -- libmfosrelease.dylib, the one-symbol shim that lets macFUSE's
 * closed mount_macfuse past its Darwin >= 21 gate on Mac OS X 10.9 (design
 * decision C).
 *
 * mount_macfuse's main() calls sysctlbyname("kern.osrelease"), takes strtol()
 * of the part before the first '.', and refuses (errx 69, error 22) when that
 * is below 21 (macOS 12). The value is used for nothing else: the register
 * holding it is dead after the compare (spike findings, Task 5a).
 * build/adapt-helpers.sh redirects mount_macfuse's _sysctlbyname import here
 * with Drydock's `import redirect` (helpers/mount_macfuse.drydock.in); every
 * other name is passed through to the kernel, among them the kext's
 * vfs.generic.macfuse.version.number, which mount_macfuse reads next.
 *
 * This file defines sysctlbyname itself, so it must not call sysctlbyname (a
 * call from inside this image would bind to this definition). It goes through
 * sysctlnametomib() + sysctl(), which is what libSystem's sysctlbyname does.
 */
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/sysctl.h>

#define SPOOFED_OSRELEASE "21.0.0"

int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
{
	int mib[CTL_MAXNAME];
	size_t miblen = CTL_MAXNAME;

	if (name != NULL && strcmp(name, "kern.osrelease") == 0 && newp == NULL) {
		size_t need = sizeof(SPOOFED_OSRELEASE);
		if (oldlenp == NULL) {
			errno = EINVAL;
			return -1;
		}
		if (oldp == NULL) {
			*oldlenp = need;
			return 0;
		}
		if (*oldlenp < need) {
			errno = ENOMEM;
			return -1;
		}
		memcpy(oldp, SPOOFED_OSRELEASE, need);
		*oldlenp = need;
		return 0;
	}
	if (sysctlnametomib(name, mib, &miblen) == -1)
		return -1;
	return sysctl(mib, (u_int)miblen, oldp, oldlenp, newp, newlen);
}
