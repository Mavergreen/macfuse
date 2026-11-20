# platform: macOS-only -- calls Darwin syscalls through ctypes on a mounted FUSE volume, with 10.9's own python 2.7
# spec: 2026-11-18-macfuse-design.md "The kext" -- two syscalls whose vnode op macFUSE does not implement reach the
#       vnode-op table's default handler, which must answer ENOTSUP (45), never crash or hang: exchangedata(2)
#       (VNOP_EXCHANGE) and getdirentriesattr(2) (VNOP_READDIRATTR). getattrlist(2), generic VFS, must succeed.
#       From the spike's .superpowers/spike/t5b/default-op.py, made to assert. Python 2.7 (10.9's own).
# usage: python default-op.py FILE_A FILE_B DIR   (all on the FUSE volume under test; exits 1 on any wrong answer)
import ctypes, ctypes.util, errno, os, sys
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
a, b, d = sys.argv[1:4]
bad = []
def check(name, rc, want):
    e = ctypes.get_errno() if rc else 0
    print "%s rc=%d errno=%d (%s)" % (name, rc, e, os.strerror(e) if e else "ok")
    if e != want:
        bad.append("%s: errno %d, want %d" % (name, e, want))
class attrlist(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_ushort), ("commonattr", ctypes.c_uint),
                ("volattr", ctypes.c_uint), ("dirattr", ctypes.c_uint), ("fileattr", ctypes.c_uint),
                ("forkattr", ctypes.c_uint)]
ctypes.set_errno(0)
check("exchangedata", libc.exchangedata(a, b, 0), errno.ENOTSUP)
al = attrlist(5, 0, 0x00000001, 0, 0, 0, 0)  # ATTR_CMN_NAME
buf = ctypes.create_string_buffer(4096)
fd = os.open(d, os.O_RDONLY)
count = ctypes.c_uint(10); base = ctypes.c_uint(0); newstate = ctypes.c_uint(0)
ctypes.set_errno(0)
check("getdirentriesattr", libc.getdirentriesattr(fd, ctypes.byref(al), buf, 4096, ctypes.byref(count),
      ctypes.byref(base), ctypes.byref(newstate), 0), errno.ENOTSUP)
os.close(fd)
al2 = attrlist(5, 0, 0x00000001 | 0x00000008, 0, 0, 0, 0)  # ATTR_CMN_NAME | ATTR_CMN_OBJTYPE
ctypes.set_errno(0)
check("getattrlist", libc.getattrlist(a, ctypes.byref(al2), buf, 4096, 0), 0)
if bad:
    print >> sys.stderr, "default-op: FAIL: " + "; ".join(bad)
    sys.exit(1)
print "default-op: ok"
