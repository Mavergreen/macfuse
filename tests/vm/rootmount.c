/*
 * rootmount.c -- the 10.9 acceptance job's privileged mounter: root mounts, an
 * unprivileged daemon serves the mount through libfuse's /dev/fd/N mountpoint.
 *
 *   usage: rootmount MNT USER DAEMON [ARG...]          (as root)
 *
 * As root it runs mount_macfuse as libfuse does (_FUSE_COMMFD, _FUSE_COMMVERS 2,
 * _FUSE_CALL_BY_LIB, _FUSE_DAEMON_PATH) with allow_other, which macFUSE allows
 * only root or an admin, and takes the /dev/macfuseN descriptor the helper sends.
 * It starts DAEMON as USER, with that descriptor inherited, as
 * "DAEMON /dev/fd/N ARG...", and closes its own copy. mount_macfuse's mount(2)
 * ends once the daemon has answered the kernel's INIT; the helper then sends
 * its 4-byte status here, not to the daemon. On status 0 it prints "READY <its pid> <the daemon's pid>".
 * On SIGTERM (or after 300 s, or when the daemon exits) it unmounts MNT, not
 * forced, waits up to 30 s for the daemon, and prints "UNMOUNTED" (or why
 * not) and "DAEMON-EXIT <exit code>", or "DAEMON-SIGNAL <signal>". A daemon
 * that exits while MNT is mounted is reported as "DAEMON-GONE-WHILE-MOUNTED".
 * Exits 0 only when MNT was mounted and unmounted and the daemon exited 0.
 * Root never reads the file system. Every wait is bounded.
 */
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MOUNT_MACFUSE "/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"

static volatile sig_atomic_t stop;

static void on_stop(int sig)
{
	(void)sig;
	stop = 1;
}

static int recv_fd(int sock, int timeout_ms)
{
	struct pollfd p = { sock, POLLIN, 0 };
	struct msghdr msg;
	struct iovec iov;
	char b, cc[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *c;
	int fd;

	if (poll(&p, 1, timeout_ms) != 1)
		return -1;
	memset(&msg, 0, sizeof msg);
	iov.iov_base = &b;
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cc;
	msg.msg_controllen = sizeof cc;
	if (recvmsg(sock, &msg, 0) <= 0)
		return -1;
	c = CMSG_FIRSTHDR(&msg);
	if (c == NULL || c->cmsg_type != SCM_RIGHTS)
		return -1;
	memcpy(&fd, CMSG_DATA(c), sizeof fd);
	return fd;
}

/* MNT is in the mount table; MNT_NOWAIT, so the file system is not asked */
static int is_mounted(const char *mnt)
{
	struct statfs *m;
	int n, i;

	n = getmntinfo(&m, MNT_NOWAIT);
	for (i = 0; i < n; i++)
		if (strcmp(m[i].f_mntonname, mnt) == 0)
			return 1;
	return 0;
}

/* waits up to secs for pid; returns 1 with *st filled when it exited */
static int reap(pid_t pid, int secs, int *st)
{
	int i;

	for (i = 0; i < secs * 10; i++) {
		if (waitpid(pid, st, WNOHANG) == pid)
			return 1;
		usleep(100000);
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *mnt, *user, *daemon_path;
	struct passwd *pw;
	int cs[2], devfd, w, st = -1, rc = 1, i;
	int32_t status = -1;
	pid_t mpid, dpid;
	char commfd[16], mp[32], real[MAXPATHLEN];
	char **dargv;
	struct pollfd p;
	time_t t0;

	if (argc < 4) {
		fprintf(stderr, "usage: rootmount MNT USER DAEMON [ARG...]\n");
		return 2;
	}
	if (getuid() != 0) {
		fprintf(stderr, "rootmount: run as root\n");
		return 2;
	}
	mnt = argv[1];
	user = argv[2];
	daemon_path = argv[3];
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	signal(SIGALRM, on_stop);
	signal(SIGPIPE, SIG_IGN);
	alarm(300);
	pw = getpwnam(user);
	if (pw == NULL || pw->pw_uid == 0) {
		fprintf(stderr, "rootmount: no unprivileged user %s\n", user);
		return 1;
	}
	if (realpath(mnt, real) == NULL) {
		fprintf(stderr, "rootmount: %s: %s\n", mnt, strerror(errno));
		return 1;
	}

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, cs) != 0) {
		perror("rootmount: socketpair");
		return 1;
	}
	mpid = fork();
	if (mpid == -1) {
		perror("rootmount: fork");
		return 1;
	}
	if (mpid == 0) {
		close(cs[1]);
		snprintf(commfd, sizeof commfd, "%d", cs[0]);
		setenv("_FUSE_DAEMON_PATH", daemon_path, 1);
		setenv("_FUSE_COMMFD", commfd, 1);
		setenv("_FUSE_COMMVERS", "2", 1);
		setenv("_FUSE_CALL_BY_LIB", "1", 1);
		execl(MOUNT_MACFUSE, MOUNT_MACFUSE, "-o", "allow_other,volname=rootmount,fsname=rootmount", real, (char *)NULL);
		_exit(127);
	}
	close(cs[0]);
	devfd = recv_fd(cs[1], 30000);
	if (devfd < 0) {
		fprintf(stderr, "rootmount: mount_macfuse sent no device descriptor within 30 s\n");
		kill(mpid, SIGTERM);
		reap(mpid, 10, &w);
		return 1;
	}
	printf("rootmount: mount_macfuse sent the device; it is fd %d here\n", devfd);
	fflush(stdout);

	dargv = calloc((size_t)argc, sizeof *dargv);
	if (dargv == NULL)
		return 1;
	snprintf(mp, sizeof mp, "/dev/fd/%d", devfd);
	dargv[0] = (char *)daemon_path;
	dargv[1] = mp;
	for (i = 4; i < argc; i++)
		dargv[i - 2] = argv[i];
	dpid = fork();
	if (dpid == -1) {
		perror("rootmount: fork");
		return 1;
	}
	if (dpid == 0) {
		int fd, sg;
		sigset_t none;

		for (fd = 3; fd < getdtablesize(); fd++)
			if (fd != devfd)
				close(fd);
		for (sg = 1; sg < NSIG; sg++)
			if (sg != SIGKILL && sg != SIGSTOP)
				signal(sg, SIG_DFL);
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		alarm(0);
		fcntl(devfd, F_SETFD, 0);
		if (initgroups(pw->pw_name, (int)pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 || setuid(pw->pw_uid) != 0 ||
		    getuid() != pw->pw_uid || geteuid() != pw->pw_uid || setuid(0) != -1) {
			fprintf(stderr, "rootmount: could not become %s\n", user);
			_exit(126);
		}
		execv(daemon_path, dargv);
		_exit(127);
	}
	/* as after a mount libfuse made: the daemon holds the device, and its exit ends the connection */
	close(devfd);

	/* the helper's mount(2) returns once the daemon has answered INIT */
	p.fd = cs[1];
	p.events = POLLIN;
	t0 = time(NULL);
	while (!stop && time(NULL) - t0 < 60) {
		if (poll(&p, 1, 1000) == 1) {
			if (recv(cs[1], &status, sizeof status, 0) != (ssize_t)sizeof status)
				status = -1;
			break;
		}
		if (waitpid(dpid, &st, WNOHANG) == dpid) {
			fprintf(stderr, "rootmount: the daemon exited (status %d) before the mount finished\n", st);
			dpid = -1;
			break;
		}
	}
	printf("rootmount: mount_macfuse reported mount status %d\n", (int)status);
	if (status == 0) {
		printf("READY %d %d\n", (int)getpid(), (int)dpid);
		fflush(stdout);
		while (!stop && dpid > 0) {
			if (waitpid(dpid, &st, WNOHANG) == dpid) {
				printf("DAEMON-GONE-WHILE-MOUNTED\n");
				fflush(stdout);
				dpid = -1;
				break;
			}
			sleep(1);
		}
	}
	fflush(stdout);

	if (is_mounted(real)) {
		if (unmount(real, 0) == 0) {
			printf("UNMOUNTED\n");
			if (status == 0)
				rc = 0;
		} else {
			printf("rootmount: unmount %s failed: %s (not forced)\n", real, strerror(errno));
		}
	} else {
		printf("rootmount: %s is not a mount point\n", real);
	}
	if (dpid > 0) {
		if (!reap(dpid, 30, &st)) {
			printf("rootmount: the daemon was still running 30 s after the unmount; killing it\n");
			kill(dpid, SIGKILL);
			reap(dpid, 10, &st);
			rc = 1;
		}
	}
	if (st != -1 && WIFEXITED(st))
		printf("DAEMON-EXIT %d\n", WEXITSTATUS(st));
	else if (st != -1 && WIFSIGNALED(st))
		printf("DAEMON-SIGNAL %d\n", WTERMSIG(st));
	else
		printf("rootmount: no exit status from the daemon\n");
	if (st == -1 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
		rc = 1;
	if (!reap(mpid, 10, &w)) {
		kill(mpid, SIGTERM);
		reap(mpid, 10, &w);
	}
	return rc;
}
