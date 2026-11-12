#!/usr/bin/env python3
"""Private, read-only IPC fingerprint reader. Stdout is a bounded NUL protocol.

Never copies/deletes files or writes backup state. No caching across requests.
Linux parent-death notification and descriptor closure prevent orphan locks.
"""
import ctypes
import os
import signal
import stat
import sys
import time

VERSION = b"ipc-history-v1"


def fingerprint(path):
    # GNU stat is a fresh process per read; refresh timezone rules too.
    time.tzset()
    try:
        info = os.stat(path, follow_symlinks=False)
    except OSError:
        return None
    if not stat.S_ISREG(info.st_mode):
        return None

    def timestamp(value):
        seconds, nanoseconds = divmod(value, 1_000_000_000)
        local = time.localtime(seconds)
        return (
            f"{local.tm_year:04d}-{local.tm_mon:02d}-{local.tm_mday:02d} "
            f"{local.tm_hour:02d}:{local.tm_min:02d}:{local.tm_sec:02d}."
            f"{nanoseconds:09d} {time.strftime('%z', local)}"
        )

    return (
        f"{info.st_dev}:{info.st_ino}:{info.st_size}:"
        f"{timestamp(info.st_mtime_ns)}:{timestamp(info.st_ctime_ns)}"
    ).encode("ascii")


def close_inherited_descriptors():
    # Do this before READY: never retain Bash's instance/metadata lock, manifest
    # or pipe descriptors. listdir's temporary fd is already closed on return.
    for name in os.listdir("/proc/self/fd"):
        descriptor = int(name)
        if descriptor > 2:
            try:
                os.close(descriptor)
            except OSError:
                pass


def field(reader, limit):
    value = bytearray()
    while True:
        item = reader.read(1)
        if not item:
            if value:
                raise ValueError("truncated request")
            return None
        if item == b"\0":
            return bytes(value)
        value.extend(item)
        if len(value) > limit:
            raise ValueError("oversized request")


def main():
    if sys.version_info < (3, 8) or len(sys.argv) != 2 or not sys.argv[1].isdigit():
        return 2
    parent = int(sys.argv[1])
    close_inherited_descriptors()
    # A closed stdin also ends the loop. PDEATHSIG additionally handles a parent
    # killed while some unrelated child still holds a copy of the pipe writer.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or os.getppid() != parent:
        return 2
    time.tzset()
    reader, writer = sys.stdin.buffer, sys.stdout.buffer
    writer.write(b"READY\0" + VERSION + b"\0" + str(os.getpid()).encode() + b"\0")
    writer.flush()
    while True:
        sequence = field(reader, 19)
        if sequence is None:
            return 0
        if not sequence or not sequence.isdigit():
            raise ValueError("invalid sequence")
        path = field(reader, 65536)
        if path is None or not path:
            raise ValueError("invalid path")
        value = fingerprint(path)
        if value is None:
            writer.write(sequence + b"\0MISS\0\0")
        else:
            writer.write(sequence + b"\0OK\0" + value + b"\0")
        writer.flush()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BrokenPipeError, ValueError, OSError, OverflowError):
        # No partial reply can count as success: parent discards the session
        # and executes its original stat path on EOF/timeout/protocol failure.
        raise SystemExit(2)
