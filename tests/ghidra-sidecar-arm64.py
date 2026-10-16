#!/usr/bin/env python3
"""Exercise the local Ghidra sidecar against an owned live arm64 target."""
import argparse
import atexit
import ctypes
import hashlib
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT / "tests"))
from client import Client


def link_address(path, symbol):
    for line in subprocess.check_output(["nm", str(path)], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == symbol:
            return int(fields[0], 16)
    raise AssertionError((path, symbol))


def listening(process, port):
    assert process.poll() is None, "QEMU exited before listening"
    inodes = set()
    for fd in Path(f"/proc/{process.pid}/fd").iterdir():
        try:
            link = os.readlink(fd)
            if link.startswith("socket:["): inodes.add(link[8:-1])
        except FileNotFoundError:
            pass
    for family in ("tcp", "tcp6"):
        for line in Path(f"/proc/{process.pid}/net/{family}").read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == "0A" and fields[9] in inodes and int(fields[1].split(":")[1], 16) == port:
                return True
    return False


def result(client, name, **arguments):
    reply = client.call("tools/call", {"name": name, "arguments": arguments})
    assert "error" not in reply, reply
    value = reply["result"]
    assert not value.get("isError"), value
    return value["structuredContent"]


def poll_decompile(client, symbol=None, **arguments):
    deadline = time.monotonic() + 180
    while True:
        if symbol is not None:
            arguments["symbol"] = symbol
        value = result(client, "decompile_function", **arguments)
        if value.get("status") != "running": return value
        assert time.monotonic() < deadline, value
        time.sleep(.01)


def exchange(request, timeout=30):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(os.environ["XODB_GHIDRA_SOCKET"])
        connection.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        stream = connection.makefile("rb")
        reply = json.loads(stream.readline(1 << 20))
        payload = None
        if "payload_length" in reply:
            length = struct.unpack(">Q", stream.read(8))[0]
            assert length == reply["payload_length"]
            payload = stream.read(length)
            assert len(payload) == length
        return reply, payload


def wait_work(reply, payload=None, timeout=180):
    deadline = time.monotonic() + timeout
    while reply.get("state") == "pending" and time.monotonic() < deadline:
        time.sleep(.01)
        reply, payload = exchange({"id": "arm64-poll", "verb": "status", "job": reply["job"], "deadline_ms": 10000})
    return reply, payload


parser = argparse.ArgumentParser()
transport = parser.add_mutually_exclusive_group(required=True)
transport.add_argument("--ssh", help="SSH host alias for the owned Linux target")
transport.add_argument("--qemu", help="Local qemu-aarch64 executable for an owned user-mode target")
parser.add_argument("--agent", help="absolute target path to xodb-agent (required with --ssh)")
parser.add_argument("--fixture", required=True, help="absolute target path to the owned arm64 fixture")
parser.add_argument("--symbol", default="qx_alloc")
parser.add_argument("--expected-value", action="append", default=[], metavar="NAME=DISPLAY",
                    help="require this exact proven pseudo-C live value; repeatable")
args = parser.parse_args()
if args.ssh and not args.agent:
    parser.error("--agent is required with --ssh")
expected_values = dict(value.split("=", 1) for value in args.expected_value)
if not expected_values:
    parser.error("at least one --expected-value NAME=DISPLAY is required")

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

qemu_process = None
client = None
try:
    if args.qemu:
        fixture = Path(args.fixture).resolve()
        entry = link_address(fixture, args.symbol)
        subprocess.run([str(starter), "start"], check=True, timeout=90,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
        reply, payload = exchange({"id": "arm64-open", "verb": "open_image", "path": str(fixture),
                                   "sha256": digest, "deadline_ms": 10000})
        reply, payload = wait_work(reply, payload)
        assert reply.get("state") == "ready", reply
        reply, payload = exchange({"id": "arm64-variables", "verb": "decompile", "path": str(fixture),
                                   "sha256": digest, "entry": hex(entry), "size": "0x0",
                                   "options": "known-values", "deadline_ms": 120000})
        reply, payload = wait_work(reply, payload)
        assert reply.get("state") == "ready" and payload, reply
        variables = json.loads(payload)["variables"]
        split = next(row for row in variables if row.get("name") == "pair")
        offsets = {piece.get("register", "").lower(): piece.get("value_bit_offset")
                   for piece in split.get("pieces", ()) if piece.get("storage") == "register"}
        assert offsets == {"x0": 0, "x1": 64}, split
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        qemu_process = subprocess.Popen([str(Path(args.qemu).resolve()), "-g", str(port), str(fixture)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while not listening(qemu_process, port):
            assert time.monotonic() < deadline, "QEMU readiness deadline"
            time.sleep(.01)
        client = Client("control", None, options=("--gdb-remote", f"127.0.0.1:{port}", "--exe", str(fixture)), reply_seconds=30)
    else:
        options = ("--runtime-ssh", args.ssh, "--runtime-agent", args.agent, "--break", args.symbol)
        client = Client("control", args.fixture, options=options, reply_seconds=30)
    initial = client.stopped(seconds=30)
    assert initial["architecture"] == "aarch64", initial
    if args.qemu:
        client.action("set_breakpoint", address=hex(entry))
        client.action("continue")
    else:
        client.continue_initial_stop()
    stopped = client.stopped("breakpoint", seconds=60)
    assert stopped["architecture"] == "aarch64", stopped
    tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
    analysis = poll_decompile(client, None if args.qemu else args.symbol,
                              **({"address": hex(entry)} if args.qemu else {}), tid=tid, frame=0)
    assert analysis.get("status") == "completed", analysis
    assert analysis.get("producer", {}).get("name") == "ghidra_java_sidecar", analysis
    assert args.symbol in analysis.get("signature", "") and analysis.get("token_status") in ("ok", "partial_alignment"), analysis
    mapping = result(client, "get_decomp_mapping", artifact_id=analysis["artifact_id"], pc=analysis["function"]["entry"])
    assert mapping.get("tokens") or mapping.get("line") is not None, mapping
    live_values = {row["name"]: row["display"] for row in analysis.get("live_values", ())}
    assert all(live_values.get(name) == display for name, display in expected_values.items()), (expected_values, live_values, analysis)
    if args.qemu:
        print(f"pass: live arm64 {args.symbol} decompiled and proved {len(expected_values)} known live values through xodb and the local Ghidra sidecar")
    else:
        print(f"pass: live arm64 {args.symbol} decompiled with {len(expected_values)} known live values through the local Ghidra sidecar")
finally:
    if client is not None:
        client.close()
    if qemu_process is not None:
        try: qemu_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qemu_process.terminate(); qemu_process.wait(timeout=5)
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
