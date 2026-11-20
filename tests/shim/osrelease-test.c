/*
 * osrelease-test.c -- the spike's four cases for libmfosrelease.dylib
 * (shim/osrelease.c), linked against the shim so that sysctlbyname binds to
 * it: the size query and the value of kern.osrelease are the spoofed
 * "21.0.0" (7 bytes with its NUL), kern.ostype passes through to the kernel,
 * and an unknown name fails as the kernel's does. Prints PASS when all hold.
 */
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/sysctl.h>

static int fails;

static void check(int ok, const char *what)
{
	printf("%s: %s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		fails++;
}

int main(void)
{
	char buf[64];
	size_t len, need = 0;
	int rc;

	rc = sysctlbyname("kern.osrelease", NULL, &need, NULL, 0);
	printf("size query: rc=%d need=%zu\n", rc, need);
	check(rc == 0 && need == 7, "kern.osrelease size query is 7");

	len = sizeof(buf);
	memset(buf, 0, sizeof(buf));
	rc = sysctlbyname("kern.osrelease", buf, &len, NULL, 0);
	printf("kern.osrelease: rc=%d \"%s\" len=%zu\n", rc, buf, len);
	check(rc == 0 && strcmp(buf, "21.0.0") == 0 && len == 7, "kern.osrelease is \"21.0.0\", length 7");

	len = sizeof(buf);
	memset(buf, 0, sizeof(buf));
	rc = sysctlbyname("kern.ostype", buf, &len, NULL, 0);
	printf("kern.ostype (passed through): rc=%d \"%s\"\n", rc, buf);
	check(rc == 0 && strcmp(buf, "Darwin") == 0, "kern.ostype passes through as \"Darwin\"");

	len = sizeof(buf);
	rc = sysctlbyname("no.such.name", buf, &len, NULL, 0);
	printf("no.such.name (passed through): rc=%d\n", rc);
	check(rc == -1, "no.such.name fails with -1");

	if (fails)
		return 1;
	printf("PASS\n");
	return 0;
}
