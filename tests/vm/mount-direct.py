# platform: macOS-only -- execs the installed setuid mount_macfuse on a Mac OS X 10.9 guest, with 10.9's own python 2.7
# spec: 2026-11-19-macfuse-product/task-11-brief.md Scenario A ("mount_macfuse with an unknown option") -- runs
#       mount_macfuse -o OPTION MOUNTPOINT directly, with the environment libfuse's fuse_mount_core gives it
#       (_FUSE_CALL_BY_LIB, _FUSE_COMMFD on one end of a socketpair, _FUSE_COMMVERS 2, _FUSE_DAEMON_PATH), and holds the
#       other end the way a daemon would, but answers no INIT. Prints how many bytes mount_macfuse sent on the socket
#       (1, with the device fd attached, once it opened the device) and exits with mount_macfuse's status.
#   usage: python mount-direct.py MOUNTPOINT OPTION DAEMON_PATH
import os
import socket
import subprocess
import sys

if len(sys.argv) != 4:
    sys.stderr.write("usage: mount-direct.py MOUNTPOINT OPTION DAEMON_PATH\n")
    sys.exit(2)
mp, opt, daemon = sys.argv[1], sys.argv[2], sys.argv[3]
tool = "/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"
ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
env = dict(os.environ, _FUSE_CALL_BY_LIB="1", _FUSE_COMMFD=str(theirs.fileno()), _FUSE_COMMVERS="2",
           _FUSE_DAEMON_PATH=daemon)
child = subprocess.Popen([tool, "-o", opt, mp], env=env, close_fds=False)
theirs.close()
ours.settimeout(90)
try:
    got = len(ours.recv(64))
except socket.timeout:
    got = 0
print("mount-direct: mount_macfuse sent %d byte(s) on _FUSE_COMMFD" % got)
sys.stdout.flush()
rc = child.wait()
ours.close()
sys.exit(rc)
