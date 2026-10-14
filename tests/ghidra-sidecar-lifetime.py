#!/usr/bin/env python3
"""Real JVM sidecar exits after idle and after losing its bound endpoint."""
import atexit
import ctypes
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
ghidra = os.environ.get("GHIDRA_HOME") or os.environ.get("XODB_GHIDRA_HOME")
if not ghidra or not (Path(ghidra) / "support/analyzeHeadless").exists():
    print("skip: real Ghidra sidecar lifetime test (set GHIDRA_HOME)")
    raise SystemExit(0)

ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
work = Path(tempfile.mkdtemp(prefix="xodb-ghl-", dir=os.environ.get("XODB_TEST_TMPDIR")))
atexit.register(shutil.rmtree, work, True)
endpoint = work / "run/.xodb.ghidra.s"
os.environ.update(
    XDG_RUNTIME_DIR=str(work / "run"),
    XODB_GHIDRA_SOCKET=str(endpoint),
    XODB_GHIDRA_HOME=ghidra,
    XODB_GHIDRA_CACHE=str(work / "cache"),
    XODB_GHIDRA_STATE=str(work / "state"),
    XODB_GHIDRA_XMX="1g",
    XODB_GHIDRA_SOFT_MAX="256m",
    XODB_GHIDRA_IDLE="0.02",  # minutes: 1.2 seconds
)


def command(action, timeout=90):
    return subprocess.run(["scripts/ghidra-sidecar", action], capture_output=True,
                          text=True, timeout=timeout)


def status():
    result = command("status", 10)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return json.loads(result.stdout.splitlines()[-1])


def process_alive(pid):
    state = Path(f"/proc/{pid}/status")
    if not state.exists():
        return False
    try:
        return not any(line.startswith("State:") and "Z" in line for line in state.read_text().splitlines())
    except FileNotFoundError:
        return False


def wait_gone(pid, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_alive(pid):
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            return
        time.sleep(.05)
    raise AssertionError(f"sidecar {pid} did not exit")


def reap_adopted(timeout=5):
    """Wait through the short setsid/reparent window and reap every child."""
    deadline = time.monotonic() + timeout
    quiet_since = None
    while time.monotonic() < deadline:
        try:
            child, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            child = -1
        now = time.monotonic()
        if child > 0:
            quiet_since = None
            continue
        if child == 0:  # A child is alive but has not exited yet.
            quiet_since = None
        elif quiet_since is None:
            quiet_since = now
        elif now - quiet_since >= 1:
            return
        time.sleep(.02)
    raise AssertionError("sidecar launcher left an adopted child alive")


replacement = None
try:
    started = command("start")
    assert started.returncode == 0, (started.stdout, started.stderr)
    first = status()
    assert abs(first["idle_limit_seconds"] - 1.2) < .01 and first["idle_seconds"] >= 0
    pid = first["pid"]

    # A live connection suppresses idle exit even when it sends no requests.
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(str(endpoint))
        client.sendall(b'{"id":"held","verb":"hello"}\n')
        assert json.loads(client.makefile("rb").readline())["state"] == "ready"
        time.sleep(2.5)
        assert process_alive(pid), "connected client did not keep the sidecar alive"
    wait_gone(pid)
    assert not endpoint.exists(), "idle exit left its socket behind"

    started = command("start")
    assert started.returncode == 0, (started.stdout, started.stderr)
    second = status()
    pid = second["pid"]
    endpoint.unlink()
    replacement = socket.socket(socket.AF_UNIX)
    replacement.bind(str(endpoint))
    replacement.listen(1)
    os.chmod(endpoint, 0o600)
    wait_gone(pid)
    assert endpoint.exists() and endpoint.is_socket(), "old sidecar removed the replacement endpoint"
finally:
    if replacement is not None:
        replacement.close()
        try:
            endpoint.unlink()
        except FileNotFoundError:
            pass
    command("stop", 10)

reap_adopted()
print("pass: connected client holds sidecar; idle and replaced endpoint exit cleanly")
