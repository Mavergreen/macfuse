/*
 * fd-mountpoint.c -- libfuse 3 adopts a mountpoint of the form /dev/fd/N on
 * macOS, as Linux libfuse does: N is a device descriptor a privileged process
 * opened and mounted, and libfuse serves it without running mount_macfuse.
 * A socketpair stands in for /dev/macfuseN: this process plays the kernel, a
 * forked child is the file system. It is a stream socket, so that closing this
 * end ends the child's reads, as an unmount ends a daemon's reads of the
 * device; one message is in flight at a time, so the device's message
 * boundaries hold.
 *
 *   usage: fd-mountpoint LIBFUSE3
 *          LIBFUSE3 is the path the libfuse 3 under test must be loaded from.
 *
 * Each child refuses to fork (pthread_atfork), because forking is how libfuse
 * runs mount_macfuse, and answers FUSE_INIT on the socket. Then its loop must
 * end, in one case because the "kernel" end closes, in the other because of
 * SIGTERM with libfuse's signal handlers installed, which must leave the device
 * open, as Linux libfuse does, for fuse_session_unmount. The loop is the
 * single-threaded one: the multithreaded loop wakes its readers with the
 * device's interrupt ioctl, which a socket cannot take (the 10.9 acceptance
 * job stops a multithreaded daemon on the real device). Either way
 * fuse_session_unmount must then have closed the adopted descriptor and
 * unmounted nothing. Every wait is bounded. Prints PASS.
 */
#define FUSE_USE_VERSION FUSE_MAKE_VERSION(3, 17)
#include <fuse_lowlevel.h>
#include "fuse_kernel.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAIL(...) do { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); return 1; } while (0)

enum {
	DAEMON_OK = 0,
	DAEMON_FORKED = 97,
	DAEMON_NO_SESSION = 10,
	DAEMON_MOUNT_FAILED = 11,
	DAEMON_FD_LEFT_OPEN = 12,
	DAEMON_LOOP_FAILED = 13,
	DAEMON_NO_HANDLERS = 14,
	DAEMON_SIGNAL_CLOSED = 15,
};

enum ending { BY_CLOSE, BY_SIGTERM };

static void refuse_fork(void)
{
	static const char m[] = "daemon: libfuse forked, which is how it runs mount_macfuse\n";

	(void)write(2, m, sizeof m - 1);
	_exit(DAEMON_FORKED);
}

static void on_init(void *userdata, struct fuse_conn_info *conn)
{
	(void)userdata;
	(void)conn;
	fprintf(stderr, "daemon: init callback ran\n");
}

static int daemon_main(int fd, enum ending how)
{
	char mp[32];
	char *argv[] = { "fd-mountpoint", NULL };
	struct fuse_args args = FUSE_ARGS_INIT(1, argv);
	struct fuse_lowlevel_ops ops;
	struct fuse_session *se;
	int rc;

	memset(&ops, 0, sizeof ops);
	ops.init = on_init;
	snprintf(mp, sizeof mp, "/dev/fd/%d", fd);
	pthread_atfork(refuse_fork, NULL, NULL);
	se = fuse_session_new(&args, &ops, sizeof ops, NULL);
	if (se == NULL)
		return DAEMON_NO_SESSION;
	if (how == BY_SIGTERM && fuse_set_signal_handlers(se) != 0)
		return DAEMON_NO_HANDLERS;
	if (fuse_session_mount(se, mp) != 0)
		return DAEMON_MOUNT_FAILED;
	rc = fuse_session_loop(se);
	if (how == BY_SIGTERM) {
		fuse_remove_signal_handlers(se);
		if (rc == SIGTERM)
			rc = 0;
		if (fuse_session_fd(se) < 0) {
			fprintf(stderr, "daemon: the signal took the device away before fuse_session_unmount\n");
			return DAEMON_SIGNAL_CLOSED;
		}
	}
	fuse_session_unmount(se);
	if (fcntl(fd, F_GETFD) != -1) {
		fprintf(stderr, "daemon: fuse_session_unmount left %s open\n", mp);
		return DAEMON_FD_LEFT_OPEN;
	}
	fuse_session_destroy(se);
	return rc == 0 ? DAEMON_OK : DAEMON_LOOP_FAILED;
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

static const char *daemon_said(int st)
{
	static char s[128];

	if (st == -1)
		return "it was still running after 10 s and was killed";
	if (WIFSIGNALED(st)) {
		snprintf(s, sizeof s, "it was killed by signal %d", WTERMSIG(st));
		return s;
	}
	switch (WEXITSTATUS(st)) {
	case DAEMON_OK: return "it exited 0";
	case DAEMON_FORKED: return "libfuse forked to run the mount helper";
	case DAEMON_NO_SESSION: return "fuse_session_new failed";
	case DAEMON_NO_HANDLERS: return "fuse_set_signal_handlers failed";
	case DAEMON_MOUNT_FAILED: return "fuse_session_mount refused the /dev/fd/N mountpoint";
	case DAEMON_FD_LEFT_OPEN: return "fuse_session_unmount left the adopted descriptor open";
	case DAEMON_LOOP_FAILED: return "fuse_session_loop returned an error";
	case DAEMON_SIGNAL_CLOSED: return "SIGTERM closed the device before fuse_session_unmount, which Linux libfuse never does";
	}
	snprintf(s, sizeof s, "it exited %d", WEXITSTATUS(st));
	return s;
}

static int scenario(enum ending how)
{
	const char *name = how == BY_CLOSE ? "the device closed" : "SIGTERM";
	int sv[2], st;
	pid_t pid;
	struct {
		struct fuse_in_header h;
		struct fuse_init_in i;
	} req;
	unsigned char rep[4096];
	struct fuse_out_header *oh = (struct fuse_out_header *)rep;
	struct fuse_init_out *io = (struct fuse_init_out *)(rep + sizeof *oh);
	struct pollfd p;
	ssize_t n;

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
		FAIL("socketpair: %s", strerror(errno));
	fflush(stdout);
	pid = fork();
	if (pid == -1)
		FAIL("fork: %s", strerror(errno));
	if (pid == 0) {
		close(sv[0]);
		_exit(daemon_main(sv[1], how));
	}
	close(sv[1]);

	memset(&req, 0, sizeof req);
	req.h.len = sizeof req;
	req.h.opcode = FUSE_INIT;
	req.h.unique = 1;
	req.h.uid = getuid();
	req.h.gid = getgid();
	req.h.pid = getpid();
	req.i.major = 7;
	req.i.minor = 19;
	req.i.max_readahead = 65536;
	if (write(sv[0], &req, sizeof req) != (ssize_t)sizeof req)
		FAIL("writing FUSE_INIT to the stand-in device: %s", strerror(errno));

	p.fd = sv[0];
	p.events = POLLIN;
	if (poll(&p, 1, 10000) != 1 || (n = read(sv[0], rep, sizeof rep)) <= 0) {
		close(sv[0]);
		st = reap(pid, 10);
		FAIL("no FUSE_INIT reply on the stand-in device within 10 s; the daemon: %s", daemon_said(st));
	}
	if ((size_t)n < sizeof *oh + 8 || oh->len != (uint32_t)n || oh->unique != 1 || oh->error != 0 || io->major != 7) {
		kill(pid, SIGKILL);
		reap(pid, 10);
		FAIL("a malformed FUSE_INIT reply: %ld bytes, len %u, unique %llu, error %d", (long)n, oh->len,
		     (unsigned long long)oh->unique, oh->error);
	}
	printf("ok: the daemon answered FUSE_INIT on /dev/fd/N (protocol %u.%u)\n", io->major, io->minor);

	if (how == BY_SIGTERM)
		kill(pid, SIGTERM);
	else
		close(sv[0]);
	st = reap(pid, 10);
	if (how == BY_SIGTERM)
		close(sv[0]);
	if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != DAEMON_OK)
		FAIL("after %s, %s", name, daemon_said(st));
	printf("ok: after %s the daemon ended, its unmount closed the descriptor, and it ran no helper\n", name);
	return 0;
}

int main(int argc, char **argv)
{
	Dl_info info;
	char want[PATH_MAX], got[PATH_MAX];

	if (argc != 2) {
		fprintf(stderr, "usage: fd-mountpoint LIBFUSE3\n");
		return 2;
	}
	if (dladdr((void *)fuse_session_loop, &info) == 0 || realpath(info.dli_fname, got) == NULL ||
	    realpath(argv[1], want) == NULL || strcmp(got, want) != 0)
		FAIL("libfuse 3 was loaded from %s, not %s", info.dli_fname ? info.dli_fname : "?", argv[1]);
	if (scenario(BY_CLOSE) != 0 || scenario(BY_SIGTERM) != 0)
		return 1;
	printf("PASS\n");
	return 0;
}
