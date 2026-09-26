"""One host-wide advisory lock for local builds, releases and cache cleanup."""
import contextlib
import fcntl
import os
from pathlib import Path
import stat
import sys

KEY = "XDRIP_BUILD_LOCK_FD"

def lock_path():
    return Path("/private/tmp") / ("xdrip-build-cleanup-%d.lock" % os.getuid())

def inherited_fd():
    value = os.environ.get(KEY)
    if value is None:
        return None
    fd = int(value)
    actual, expected = os.fstat(fd), lock_path().lstat()
    if (not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.getuid() or
            actual.st_nlink != 1 or (actual.st_dev, actual.st_ino) !=
            (expected.st_dev, expected.st_ino)):
        raise RuntimeError("Invalid inherited build/cleanup lock")
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return fd

def pass_fds():
    fd = inherited_fd()
    return () if fd is None else (fd,)

@contextlib.contextmanager
def build_lock():
    if inherited_fd() is not None:
        yield
        return
    fd = os.open(str(lock_path()), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_nlink != 1:
            raise RuntimeError("Unsafe build/cleanup lock file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another build, release or cleanup holds the lock")
        os.set_inheritable(fd, True)
        os.environ[KEY] = str(fd)
        yield
    finally:
        os.environ.pop(KEY, None)
        os.close(fd)

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--child":
        # The waiting build shell still owns the lock. Xcode/simulator helpers
        # must not keep it alive by inheriting the descriptor into a daemon.
        fd = inherited_fd()
        if fd is None:
            raise RuntimeError("Build child requires the parent's lock")
        os.close(fd)
        os.environ.pop(KEY, None)
        os.execvp(sys.argv[2], sys.argv[2:])
    with build_lock():
        os.execvp(sys.argv[1], sys.argv[1:])
