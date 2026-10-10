"""Own and reap orphaned descendants, so a test leaves no process behind.

Wine helpers and a sanitizer's symbolizer outlive the process that started
them. Without this they are handed to the release runner, which reports the
step as leaking processes."""
import ctypes
import os
import time


def adopt():
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, 'child subreaper'


def reap(seconds=10):
    """Wait for every child that is left. True when none remains."""
    until = time.monotonic() + seconds
    while True:
        try:
            if os.waitpid(-1, os.WNOHANG)[0]:
                continue
        except ChildProcessError:
            return True
        if time.monotonic() >= until:
            return False
        time.sleep(0.02)
