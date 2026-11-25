/*
 * raw-names.c -- libfuse 3's high-level library names nodes by the bytes the
 * kernel sent when the file system asks for it with -o nonorm_insensitive, and
 * normalizes them to NFD otherwise (libfuse/patches/library3, DETAILS.md "File
 * names: normalized unless you ask").
 *
 *   usage: raw-names LIBFUSE3
 *          LIBFUSE3 is the path the libfuse 3 under test must be loaded from.
 *
 * As tests/libfuse/fd-mountpoint.c does, a socketpair stands in for
 * /dev/macfuseN, given to a forked child as the mountpoint /dev/fd/N: this
 * process plays the kernel, the child is a high-level file system whose
 * getattr answers every path with a regular file and reports the path, byte
 * for byte, on a pipe. Per case, the "kernel" sends:
 *
 *   1. LOOKUP of "café" in the root, composed (NFC: e9 as c3 a9);
 *   2. LOOKUP of "café" decomposed (NFD: e then U+0301, cc 81);
 *   3. GETATTR of the node the first LOOKUP returned.
 *
 * A LOOKUP's path is built from the name as sent, whatever the option, so 1
 * and 2 must reach getattr unchanged. 3's path is built from the name the node
 * table stored. Normalizing (no option, or -o norm_insensitive): both LOOKUPs
 * return one node, stored as NFD, so 3 asks about the NFD path, which is what
 * makes a name created as NFC on a byte-preserving disk unreachable. With
 * -o nonorm_insensitive: two nodes, and 3 asks about the NFC path it was given.
 * In every case fuse_new must accept the options, which shows the library
 * consumed them: the session refuses an option nobody knows. Prints PASS.
 */
#define FUSE_USE_VERSION FUSE_MAKE_VERSION(3, 17)
#include <fuse.h>
#include "fuse_kernel.h"

#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAIL(...) do { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); return 1; } while (0)

static const char NFC[] = "caf\xc3\xa9";
static const char NFD[] = "cafe\xcc\x81";

enum { DAEMON_OK = 0, DAEMON_NEW_FAILED = 10, DAEMON_MOUNT_FAILED = 11, DAEMON_FORKED = 97 };

static int report_fd = -1;

static void refuse_fork(void)
{
	static const char m[] = "daemon: libfuse forked, which is how it runs mount_macfuse\n";

	(void)write(2, m, sizeof m - 1);
	_exit(DAEMON_FORKED);
}

/* every path is a regular file; the path goes to the test, length first */
static int fs_getattr(const char *path, struct stat *st, struct fuse_file_info *fi)
{
	unsigned char len = (unsigned char)strlen(path);

	(void)fi;
	(void)write(report_fd, &len, 1);
	(void)write(report_fd, path, len);
	memset(st, 0, sizeof *st);
	st->st_mode = strcmp(path, "/") == 0 ? S_IFDIR | 0755 : S_IFREG | 0644;
	st->st_nlink = 1;
	return 0;
}

static int daemon_main(int fd, const char *opt)
{
	char mp[32];
	char *argv[] = { "raw-names", NULL, NULL, NULL };
	int argc = 1;
	struct fuse_args args;
	struct fuse_operations ops;
	struct fuse *f;

	if (opt != NULL) {
		argv[argc++] = "-o";
		argv[argc++] = (char *)opt;
	}
	args = (struct fuse_args)FUSE_ARGS_INIT(argc, argv);
	memset(&ops, 0, sizeof ops);
	ops.getattr = fs_getattr;
	snprintf(mp, sizeof mp, "/dev/fd/%d", fd);
	pthread_atfork(refuse_fork, NULL, NULL);
	f = fuse_new(&args, &ops, sizeof ops, NULL);
	if (f == NULL)
		return DAEMON_NEW_FAILED;
	if (fuse_mount(f, mp) != 0)
		return DAEMON_MOUNT_FAILED;
	(void)fuse_loop(f);
	fuse_unmount(f);
	fuse_destroy(f);
	return DAEMON_OK;
}

/* waits up to secs for pid; kills it on timeout; returns its wait status, or -1 */
static int reap(pid_t pid, int secs)
{
	int st, i;

	for (i = 0; i < secs * 10; i++) {
		if (waitpid(pid, &st, WNOHANG) == pid)
			return st;
		usleep(100000);
	}
	kill(pid, SIGKILL);
	waitpid(pid, &st, 0);
	return -1;
}

/* writes one request and reads its reply into rep; returns the reply's length, or -1 */
static ssize_t call(int dev, const void *req, size_t len, unsigned char *rep, size_t cap)
{
	struct pollfd p = { dev, POLLIN, 0 };
	ssize_t n;

	if (write(dev, req, len) != (ssize_t)len)
		return -1;
	if (poll(&p, 1, 10000) != 1 || (n = read(dev, rep, cap)) <= 0)
		return -1;
	return n;
}

/* reads the next path getattr reported; returns 0, or -1 */
static int reported(int rd, char *path, size_t cap)
{
	struct pollfd p = { rd, POLLIN, 0 };
	unsigned char len;

	if (poll(&p, 1, 10000) != 1 || read(rd, &len, 1) != 1 || len >= cap)
		return -1;
	if (len > 0 && read(rd, path, len) != len)
		return -1;
	path[len] = '\0';
	return 0;
}

static void header(struct fuse_in_header *h, uint32_t len, uint32_t opcode, uint64_t unique, uint64_t nodeid)
{
	memset(h, 0, sizeof *h);
	h->len = len;
	h->opcode = opcode;
	h->unique = unique;
	h->nodeid = nodeid;
	h->uid = getuid();
	h->gid = getgid();
	h->pid = getpid();
}

/* LOOKUP name in the root; returns the node id, or 0 */
static uint64_t lookup(int dev, uint64_t unique, const char *name)
{
	struct {
		struct fuse_in_header h;
		char name[64];
	} req;
	unsigned char rep[4096];
	struct fuse_out_header *oh = (struct fuse_out_header *)rep;
	struct fuse_entry_out *eo = (struct fuse_entry_out *)(rep + sizeof *oh);
	size_t len = sizeof req.h + strlen(name) + 1;
	ssize_t n;

	header(&req.h, (uint32_t)len, FUSE_LOOKUP, unique, FUSE_ROOT_ID);
	strcpy(req.name, name);
	n = call(dev, &req, len, rep, sizeof rep);
	if (n < (ssize_t)sizeof *oh || oh->unique != unique || oh->error != 0)
		return 0;
	return eo->nodeid;
}

static const char *shown(const char *path)
{
	static char s[4][128];
	static int i;
	char *o = s[i = (i + 1) % 4];
	const unsigned char *p;

	*o = '\0';
	for (p = (const unsigned char *)path; *p != '\0'; p++)
		snprintf(o + strlen(o), 128 - strlen(o), *p < 0x80 ? "%c" : "\\x%02x", *p);
	return o;
}

static int scenario(const char *opt, int raw)
{
	const char *name = opt != NULL ? opt : "no option";
	int sv[2], rp[2], st;
	pid_t pid;
	struct {
		struct fuse_in_header h;
		struct fuse_init_in i;
	} init;
	struct {
		struct fuse_in_header h;
		struct fuse_getattr_in g;
	} ga;
	unsigned char rep[4096];
	struct fuse_out_header *oh = (struct fuse_out_header *)rep;
	char path[256], want[256];
	uint64_t composed, decomposed;
	ssize_t n;

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0 || pipe(rp) != 0)
		FAIL("socketpair or pipe: %s", strerror(errno));
	fflush(stdout);
	pid = fork();
	if (pid == -1)
		FAIL("fork: %s", strerror(errno));
	if (pid == 0) {
		close(sv[0]);
		close(rp[0]);
		report_fd = rp[1];
		_exit(daemon_main(sv[1], opt));
	}
	close(sv[1]);
	close(rp[1]);

	header(&init.h, sizeof init, FUSE_INIT, 1, 0);
	memset(&init.i, 0, sizeof init.i);
	init.i.major = 7;
	init.i.minor = 19;
	init.i.max_readahead = 65536;
	n = call(sv[0], &init, sizeof init, rep, sizeof rep);
	if (n < (ssize_t)sizeof *oh || oh->unique != 1 || oh->error != 0) {
		close(sv[0]);
		st = reap(pid, 10);
		FAIL("%s: no FUSE_INIT reply; the daemon %s %d", name,
		     st != -1 && WIFEXITED(st) ? "exited" : "was killed, status", st != -1 && WIFEXITED(st) ? WEXITSTATUS(st) : st);
	}

	composed = lookup(sv[0], 2, NFC);
	if (composed == 0 || reported(rp[0], path, sizeof path) != 0)
		FAIL("%s: LOOKUP of the composed name failed", name);
	snprintf(want, sizeof want, "/%s", NFC);
	if (strcmp(path, want) != 0)
		FAIL("%s: a LOOKUP of %s reached getattr as %s", name, shown(want), shown(path));

	decomposed = lookup(sv[0], 3, NFD);
	if (decomposed == 0 || reported(rp[0], path, sizeof path) != 0)
		FAIL("%s: LOOKUP of the decomposed name failed", name);
	snprintf(want, sizeof want, "/%s", NFD);
	if (strcmp(path, want) != 0)
		FAIL("%s: a LOOKUP of %s reached getattr as %s", name, shown(want), shown(path));
	if (raw ? composed == decomposed : composed != decomposed)
		FAIL("%s: the composed and decomposed names are %s node (%llu, %llu)", name,
		     raw ? "one" : "two", (unsigned long long)composed, (unsigned long long)decomposed);

	header(&ga.h, sizeof ga, FUSE_GETATTR, 4, composed);
	memset(&ga.g, 0, sizeof ga.g);
	n = call(sv[0], &ga, sizeof ga, rep, sizeof rep);
	if (n < (ssize_t)sizeof *oh || oh->unique != 4 || oh->error != 0 || reported(rp[0], path, sizeof path) != 0)
		FAIL("%s: GETATTR of the composed name's node failed", name);
	snprintf(want, sizeof want, "/%s", raw ? NFC : NFD);
	if (strcmp(path, want) != 0)
		FAIL("%s: GETATTR of the node looked up as %s reached getattr as %s, not %s", name,
		     shown(NFC), shown(path), shown(want));

	close(sv[0]);
	st = reap(pid, 10);
	close(rp[0]);
	if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != DAEMON_OK)
		FAIL("%s: the daemon did not end cleanly when the device closed (status %d)", name, st);
	printf("ok: %s: %s\n", name, raw ? "names are the bytes sent, one node each" :
					   "both forms are one node, which getattr is asked about as NFD");
	return 0;
}

int main(int argc, char **argv)
{
	Dl_info info;

	if (argc != 2) {
		fprintf(stderr, "usage: raw-names LIBFUSE3\n");
		return 2;
	}
	if (dladdr((void *)fuse_loop, &info) == 0 || info.dli_fname == NULL)
		FAIL("cannot tell which libfuse 3 is loaded");
	if (strcmp(info.dli_fname, argv[1]) != 0)
		FAIL("libfuse 3 came from %s, not %s", info.dli_fname, argv[1]);
	if (scenario(NULL, 0) || scenario("norm_insensitive", 0) || scenario("nonorm_insensitive", 1))
		return 1;
	printf("PASS\n");
	return 0;
}
