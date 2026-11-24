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
 * open, as Linux libfuse does, for fuse_session_unmount. The daemon raises that
 * SIGTERM itself, from the handler of a STATFS the test sends after INIT, so it
 * arrives before the loop's next check: a SIGTERM sent from outside could land
 * between that check and the blocking read, and nothing would wake a read of a
 * socket. The loop is the single-threaded one: the multithreaded loop wakes its
 * readers with the device's interrupt ioctl, which a socket cannot take (the
 * 10.9 acceptance job stops a multithreaded daemon on the real device). Either
 * way fuse_session_unmount must then have closed the adopted descriptor and
 * unmounted nothing.
 *
 * Four more cases check how the single-threaded loop waits on an adopted
 * device, which it does in 1 s slices (libfuse/patches/library3). A wrapper
 * around MFChannelWaitForNextMessage, interposed by dyld, counts the slices
 * the daemon enters and, in one case, makes them blind. A request that was
 * queued before the loop looked is read without entering a slice; one sent
 * 1.3 s after INIT, past a slice, is answered; and when the kqueue a slice
 * waits on never reports (blind, as it may not for a dead device) the owner's
 * close still ends the loop, through the poll that follows a slice.
 * The fourth, below, is fuse_main -s -o remember=60.
 *
 * Two more cases send the SIGTERM from outside while the daemon is blocked
 * waiting for a request, as an operator's kill does: the loop is
 * fuse_session_loop in one, fuse_main -s (which uses it) in the other, and
 * fuse_main must return 8. libfuse's handler only notes the signal. The
 * daemon's main thread blocks SIGTERM and a second thread takes it, which is
 * what happens to a daemon that has other threads (lklfuse), so the blocked
 * wait is not ended by EINTR; and a socket gives the wait no device interrupt.
 * Only a loop that looks at the signal again on its own ends. Each must end
 * within 5 s, and the race of the signal arriving before the wait is harmless:
 * the loop would end then either way, so the test waits first.
 *
 * Two more children check what fuse_session_mount takes: /dev/fd/N with N
 * closed must be refused, and /dev/fd/N with anything after N is an ordinary
 * mountpoint, which leaves N alone. Neither may fork. Every wait is bounded.
 * Prints PASS.
 */
#define FUSE_USE_VERSION FUSE_MAKE_VERSION(3, 17)
#include <fuse_lowlevel.h>
#include <fuse.h>
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
#include <sys/statvfs.h>
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
	DAEMON_BAD_FD_TAKEN = 16,
	DAEMON_GARBAGE_ADOPTED = 17,
	DAEMON_MAIN_RETURNED = 18,
	DAEMON_SLICES_WRONG = 19,
	DAEMON_NO_INTERPOSE = 20,
};

enum ending {
	BY_CLOSE, BY_SIGTERM, BY_SENT_SIGTERM, BY_SENT_SIGTERM_MAIN, BY_SENT_SIGTERM_REMEMBER,
	BY_FAST_PATH, BY_LATE_REQUEST, BY_BLIND_CLOSE
};

static enum ending ending;

/*
 * tests/libfuse/interpose-wait.c, a dylib dyld interposes into this process
 * (an interpose section in the executable itself is not applied on 10.9),
 * counts the waits libfuse's single-threaded loop makes on an adopted device:
 * timeout 0 is the single poll, anything else a slice. blind makes a slice
 * sleep and report nothing, and delay_probe holds back the next single poll
 * while the test sends a request. Only the daemon child uses it.
 */
struct wait_state {
	volatile int wait_calls, slice_waits, blind, delay_probe;
};
static struct wait_state *ws;
static int verdict;

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
	if (ws != NULL) {
		ws->slice_waits = 0;
		ws->delay_probe = ending == BY_FAST_PATH;
	}
}

static void on_statfs(fuse_req_t req, fuse_ino_t ino)
{
	struct statvfs st;

	(void)ino;
	memset(&st, 0, sizeof st);
	fuse_reply_statfs(req, &st);
	if (ending == BY_FAST_PATH && ws->slice_waits != 0) {
		fprintf(stderr, "daemon: %d slices were entered for a request that was queued\n", ws->slice_waits);
		verdict = DAEMON_SLICES_WRONG;
	}
	if (ending == BY_LATE_REQUEST && ws->slice_waits < 2) {
		fprintf(stderr, "daemon: %d slices were entered before a request 1.3 s late\n", ws->slice_waits);
		verdict = DAEMON_SLICES_WRONG;
	}
	if (ending == BY_SIGTERM)
		raise(SIGTERM);
}

static void *take_signals(void *arg)
{
	(void)arg;
	for (;;)
		pause();
	return NULL;
}

/* SIGTERM is taken by a thread that is not the one waiting for requests */
static int move_signals_off_this_thread(void)
{
	pthread_t t;
	sigset_t set;

	if (pthread_create(&t, NULL, take_signals, NULL) != 0)
		return -1;
	sigemptyset(&set);
	sigaddset(&set, SIGTERM);
	return pthread_sigmask(SIG_BLOCK, &set, NULL);
}

/* fuse_main -s on /dev/fd/N: the daemon of the last case */
static int daemon_fuse_main(int fd, int remember)
{
	char mp[32];
	char *argv[] = { "fd-mountpoint", "-s", "-f", mp, NULL, NULL, NULL };
	int argc = 4;
	struct fuse_operations ops;
	int rc;

	memset(&ops, 0, sizeof ops);
	snprintf(mp, sizeof mp, "/dev/fd/%d", fd);
	pthread_atfork(refuse_fork, NULL, NULL);
	if (move_signals_off_this_thread() != 0)
		return DAEMON_NO_HANDLERS;
	if (remember) {
		argv[argc++] = "-o";
		argv[argc++] = "remember=60";
	}
	rc = fuse_main(argc, argv, &ops, NULL);
	if (rc != 8) {
		fprintf(stderr, "daemon: fuse_main returned %d, not 8\n", rc);
		return DAEMON_MAIN_RETURNED;
	}
	if (fcntl(fd, F_GETFD) != -1) {
		fprintf(stderr, "daemon: fuse_main left %s open\n", mp);
		return DAEMON_FD_LEFT_OPEN;
	}
	return DAEMON_OK;
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
	ops.statfs = on_statfs;
	ending = how;
	if (how == BY_SENT_SIGTERM_MAIN || how == BY_SENT_SIGTERM_REMEMBER)
		return daemon_fuse_main(fd, how == BY_SENT_SIGTERM_REMEMBER);
	ws = dlsym(RTLD_DEFAULT, "mf_wait_state");
	if (ws == NULL && (how == BY_FAST_PATH || how == BY_LATE_REQUEST || how == BY_BLIND_CLOSE))
		return DAEMON_NO_INTERPOSE;
	if (ws != NULL)
		ws->blind = how == BY_BLIND_CLOSE;
	snprintf(mp, sizeof mp, "/dev/fd/%d", fd);
	pthread_atfork(refuse_fork, NULL, NULL);
	se = fuse_session_new(&args, &ops, sizeof ops, NULL);
	if (se == NULL)
		return DAEMON_NO_SESSION;
	if ((how == BY_SIGTERM || how == BY_SENT_SIGTERM) && fuse_set_signal_handlers(se) != 0)
		return DAEMON_NO_HANDLERS;
	if (how == BY_SENT_SIGTERM && move_signals_off_this_thread() != 0)
		return DAEMON_NO_HANDLERS;
	if (fuse_session_mount(se, mp) != 0)
		return DAEMON_MOUNT_FAILED;
	rc = fuse_session_loop(se);
	if (ws != NULL && ws->wait_calls == 0 && (how == BY_FAST_PATH || how == BY_LATE_REQUEST || how == BY_BLIND_CLOSE))
		return DAEMON_NO_INTERPOSE;
	if (verdict != 0)
		return verdict;
	if (how == BY_SIGTERM || how == BY_SENT_SIGTERM) {
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
		return "it was still running when the wait ended, and was killed";
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
	case DAEMON_SLICES_WRONG: return "the loop entered the wrong number of 1 s slices";
	case DAEMON_NO_INTERPOSE: return "the interposed wait was never called, so the case proved nothing";
	case DAEMON_MAIN_RETURNED: return "fuse_main did not return 8 after SIGTERM";
	case DAEMON_BAD_FD_TAKEN: return "fuse_session_mount took /dev/fd/N for a closed N";
	case DAEMON_GARBAGE_ADOPTED: return "fuse_session_mount adopted N from /dev/fd/N with more after it";
	case DAEMON_SIGNAL_CLOSED: return "SIGTERM closed the device before fuse_session_unmount, which Linux libfuse never does";
	}
	snprintf(s, sizeof s, "it exited %d", WEXITSTATUS(st));
	return s;
}

static int scenario(enum ending how)
{
	const char *name = how == BY_CLOSE ? "the device closed" :
			   how == BY_SIGTERM ? "SIGTERM" :
			   how == BY_SENT_SIGTERM ? "a SIGTERM sent to fuse_session_loop" :
			   how == BY_SENT_SIGTERM_MAIN ? "a SIGTERM sent to fuse_main -s" :
			   how == BY_SENT_SIGTERM_REMEMBER ? "a SIGTERM sent to fuse_main -s -o remember=60" :
			   how == BY_FAST_PATH ? "a request queued before the loop looked" :
			   how == BY_LATE_REQUEST ? "a request 1.3 s after INIT" :
						    "the device closed, with a blind slice wait";
	int sv[2], st;
	pid_t pid;
	struct {
		struct fuse_in_header h;
		struct fuse_init_in i;
	} req;
	unsigned char rep[4096];
	struct fuse_out_header *oh = (struct fuse_out_header *)rep;
	struct fuse_init_out *io = (struct fuse_init_out *)(rep + sizeof *oh);
	struct fuse_in_header sreq;
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

	if (how == BY_SENT_SIGTERM || how == BY_SENT_SIGTERM_MAIN || how == BY_SENT_SIGTERM_REMEMBER) {
		/* the daemon is idle, waiting for a request: signal it from here */
		usleep(500000);
		if (kill(pid, SIGTERM) != 0)
			FAIL("kill: %s", strerror(errno));
		st = reap(pid, 5);
		close(sv[0]);
		if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != DAEMON_OK)
			FAIL("after %s, %s", name, daemon_said(st));
		printf("ok: after %s the daemon ended within 5 s, left the mount alone, and ran no helper\n", name);
		return 0;
	}
	if (how == BY_SIGTERM || how == BY_FAST_PATH || how == BY_LATE_REQUEST) {
		/* BY_SIGTERM: the daemon raises SIGTERM as it answers */
		if (how == BY_FAST_PATH)
			usleep(100000);	/* inside the daemon's 300 ms hold on its first poll */
		if (how == BY_LATE_REQUEST)
			usleep(1300000);
		memset(&sreq, 0, sizeof sreq);
		sreq.len = sizeof sreq;
		sreq.opcode = FUSE_STATFS;
		sreq.unique = 2;
		sreq.nodeid = FUSE_ROOT_ID;
		sreq.uid = getuid();
		sreq.gid = getgid();
		sreq.pid = getpid();
		if (write(sv[0], &sreq, sizeof sreq) != (ssize_t)sizeof sreq) {
			kill(pid, SIGKILL);
			reap(pid, 10);
			FAIL("writing FUSE_STATFS to the stand-in device: %s", strerror(errno));
		}
		if (poll(&p, 1, 10000) != 1 || (n = read(sv[0], rep, sizeof rep)) <= 0 || oh->unique != 2) {
			kill(pid, SIGKILL);
			reap(pid, 10);
			FAIL("no FUSE_STATFS reply on the stand-in device within 10 s");
		}
	} else {
		close(sv[0]);
	}
	if (how == BY_FAST_PATH || how == BY_LATE_REQUEST)
		close(sv[0]);
	st = reap(pid, 10);
	if (how == BY_SIGTERM)
		close(sv[0]);
	if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != DAEMON_OK)
		FAIL("after %s, %s", name, daemon_said(st));
	printf("ok: after %s the daemon ended, its unmount closed the descriptor, and it ran no helper\n", name);
	return 0;
}

/* in a child that refuses to fork: what fuse_session_mount makes of a bad /dev/fd/N */
static int mount_check_main(void)
{
	char mp[40];
	char *argv[] = { "fd-mountpoint", NULL };
	struct fuse_args args = FUSE_ARGS_INIT(1, argv);
	struct fuse_lowlevel_ops ops;
	struct fuse_session *se;
	int fd;

	memset(&ops, 0, sizeof ops);
	pthread_atfork(refuse_fork, NULL, NULL);
	fd = open("/dev/null", O_RDONLY);
	if (fd < 0)
		return DAEMON_NO_SESSION;

	se = fuse_session_new(&args, &ops, sizeof ops, NULL);
	if (se == NULL)
		return DAEMON_NO_SESSION;
	close(fd);
	snprintf(mp, sizeof mp, "/dev/fd/%d", fd);
	if (fuse_session_mount(se, mp) != -1)
		return DAEMON_BAD_FD_TAKEN;
	fuse_session_destroy(se);

	fd = open("/dev/null", O_RDONLY);
	args = (struct fuse_args)FUSE_ARGS_INIT(1, argv);
	se = fuse_session_new(&args, &ops, sizeof ops, NULL);
	if (fd < 0 || se == NULL)
		return DAEMON_NO_SESSION;
	snprintf(mp, sizeof mp, "/dev/fd/%dx", fd);
	/*
	 * An ordinary mountpoint: on macOS the mount waits for the loop, so
	 * nothing forks yet (fuse_session_fd would start it). Unmounting
	 * before then would close an adopted N, and leaves anything else.
	 */
	if (fuse_session_mount(se, mp) != 0)
		return DAEMON_MOUNT_FAILED;
	fuse_session_unmount(se);
	fuse_session_destroy(se);
	if (fcntl(fd, F_GETFD) == -1)
		return DAEMON_GARBAGE_ADOPTED;
	return DAEMON_OK;
}

static int mount_checks(void)
{
	pid_t pid;
	int st;

	fflush(stdout);
	pid = fork();
	if (pid == -1)
		FAIL("fork: %s", strerror(errno));
	if (pid == 0)
		_exit(mount_check_main());
	st = reap(pid, 10);
	if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != DAEMON_OK)
		FAIL("checking bad /dev/fd/N mountpoints, %s", daemon_said(st));
	printf("ok: /dev/fd/N with N closed was refused, /dev/fd/Nx left N alone, and neither forked\n");
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
	if (mount_checks() != 0 || scenario(BY_CLOSE) != 0 || scenario(BY_SIGTERM) != 0 ||
	    scenario(BY_SENT_SIGTERM) != 0 || scenario(BY_SENT_SIGTERM_MAIN) != 0 ||
	    scenario(BY_SENT_SIGTERM_REMEMBER) != 0 || scenario(BY_FAST_PATH) != 0 || scenario(BY_LATE_REQUEST) != 0 ||
	    scenario(BY_BLIND_CLOSE) != 0)
		return 1;
	printf("PASS\n");
	return 0;
}
