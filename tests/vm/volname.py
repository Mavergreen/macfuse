# platform: macOS-only -- calls Darwin syscalls through ctypes on a mounted FUSE volume, with 10.9's own python 2.7
# spec: tests/smoke-mavericks.sh -- volname= must take effect: prints the volume name getattrlist(2)
#       (ATTR_VOL_NAME) reports for a mount point. Python 2.7 (10.9's own).
# usage: python volname.py MOUNTPOINT
import ctypes, ctypes.util, struct, sys
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
class AL(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_ushort),
                ("commonattr", ctypes.c_uint), ("volattr", ctypes.c_uint), ("dirattr", ctypes.c_uint),
                ("fileattr", ctypes.c_uint), ("forkattr", ctypes.c_uint)]
al = AL(5, 0, 0, 0x80000000 | 0x00002000, 0, 0, 0)   # ATTR_VOL_INFO | ATTR_VOL_NAME
buf = ctypes.create_string_buffer(1024)
if libc.getattrlist(sys.argv[1], ctypes.byref(al), buf, 1024, 0) != 0:
    print >> sys.stderr, "volname: getattrlist errno=%d" % ctypes.get_errno()
    sys.exit(1)
raw = buf.raw
off, ln = struct.unpack_from("iI", raw, 4)
print raw[4 + off:4 + off + ln].rstrip("\0")
