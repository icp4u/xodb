#!/usr/bin/env python3
"""Exercise the local Ghidra sidecar against an owned live arm64 target."""
import argparse
import atexit
import ctypes
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT / "tests"))
from client import Client


def result(client, name, **arguments):
    reply = client.call("tools/call", {"name": name, "arguments": arguments})
    assert "error" not in reply, reply
    value = reply["result"]
    assert not value.get("isError"), value
    return value["structuredContent"]


def poll_decompile(client, symbol):
    deadline = time.monotonic() + 180
    while True:
        value = result(client, "decompile_function", symbol=symbol)
        if value.get("status") != "running": return value
        assert time.monotonic() < deadline, value
        time.sleep(.01)


parser = argparse.ArgumentParser()
parser.add_argument("--ssh", required=True, help="SSH host alias for the owned Linux target")
parser.add_argument("--agent", required=True, help="absolute target path to xodb-agent")
parser.add_argument("--fixture", required=True, help="absolute target path to the owned arm64 fixture")
parser.add_argument("--symbol", default="qx_alloc")
args = parser.parse_args()

ghidra = os.environ.get("GHIDRA_HOME") or os.environ.get("XODB_GHIDRA_HOME")
if not ghidra or not (Path(ghidra) / "support/analyzeHeadless").exists():
    print("skip: live arm64 Ghidra sidecar test (set GHIDRA_HOME)")
    raise SystemExit(0)

# The detached starter remains our descendant until it is stopped below.
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)
work = Path(tempfile.mkdtemp(prefix="xodb-gha-", dir=os.environ.get("XODB_TEST_TMPDIR")))
atexit.register(shutil.rmtree, work, True)
starter = ROOT / "scripts/ghidra-sidecar"
os.environ.update(
    XDG_RUNTIME_DIR=str(work / "run"),
    XODB_GHIDRA_SOCKET=str(work / "run/.xodb.ghidra.s"),
    XODB_GHIDRA_SIDECAR=str(starter),
    XODB_GHIDRA_HOME=ghidra,
    XODB_GHIDRA_CACHE=str(work / "cache"),
    XODB_GHIDRA_STATE=str(work / "state"),
    XODB_GHIDRA_XMX="2g",
    XODB_GHIDRA_SOFT_MAX="512m",
)

client = Client(
    "control",
    args.fixture,
    options=("--runtime-ssh", args.ssh, "--runtime-agent", args.agent, "--break", args.symbol),
    reply_seconds=30,
)
try:
    initial = client.stopped(seconds=30)
    assert initial["architecture"] == "aarch64", initial
    client.continue_initial_stop()
    stopped = client.stopped("breakpoint", seconds=60)
    assert stopped["architecture"] == "aarch64", stopped
    analysis = poll_decompile(client, args.symbol)
    assert analysis.get("status") == "completed", analysis
    assert analysis.get("producer", {}).get("name") == "ghidra_java_sidecar", analysis
    assert args.symbol in analysis.get("signature", "") and analysis.get("token_status") in ("ok", "partial_alignment"), analysis
    mapping = result(client, "get_decomp_mapping", artifact_id=analysis["artifact_id"], pc=analysis["function"]["entry"])
    assert mapping.get("tokens") or mapping.get("line") is not None, mapping
    print(f"pass: live arm64 {args.symbol} decompiled through the local Ghidra sidecar")
finally:
    client.close()
    subprocess.run([str(starter), "stop"], check=False, timeout=20,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.waitpid(-1, os.WNOHANG)[0] == 0:
            time.sleep(.02)
    except ChildProcessError:
        break
else:
    raise AssertionError("the stopped arm64 sidecar left a process behind")
