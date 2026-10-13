#!/usr/bin/env python3
"""Owned ELF smoke test for the real persistent Ghidra sidecar."""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
ghidra = os.environ.get("GHIDRA_HOME") or os.environ.get("XODB_GHIDRA_HOME")
if not ghidra or not (Path(ghidra) / "support/analyzeHeadless").exists():
    print("skip: real Ghidra sidecar test (set GHIDRA_HOME to a Ghidra installation)")
    raise SystemExit(0)

sys.path.insert(0, str(ROOT / "tests"))
from client import Client
# The sidecar detaches from its starter. As a child subreaper this test stays
# its parent and reaps it after the stop, so the release runner adopts nothing.
import ctypes
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
work = Path(tempfile.mkdtemp(prefix="xodb-ghr-", dir=os.environ.get("XODB_TEST_TMPDIR")))
fixture_dir = work / "qx"
subprocess.run(["sh", "tests/fixtures/semq/build_fixtures.sh", str(fixture_dir)], check=True, timeout=60)
os.environ.update(XDG_RUNTIME_DIR=str(work / "run"), XODB_GHIDRA_SOCKET=str(work / "run/.xodb.ghidra.s"),
                  XODB_GHIDRA_SIDECAR=str(ROOT / "scripts/ghidra-sidecar"), XODB_GHIDRA_HOME=ghidra,
                  XODB_GHIDRA_CACHE=str(work / "cache"), XODB_GHIDRA_STATE=str(work / "state"),
                  XODB_GHIDRA_XMX="2g", XODB_GHIDRA_SOFT_MAX="512m")


def tool(client, name, **args):
    response = client.call("tools/call", {"name": name, "arguments": args})
    if "error" in response: return {"_protocol_error": response["error"]["message"]}
    result = response["result"]
    if result.get("isError"): return {"_error": result["content"][0]["text"]}
    return result["structuredContent"]


def poll(client, symbol="qx_alloc"):
    deadline = time.monotonic() + 120
    while True:
        result = tool(client, "decompile_function", symbol=symbol)
        if result.get("status") != "running" or time.monotonic() > deadline: return result
        time.sleep(.05)

client = Client("observe", str(fixture_dir / "qx-gcc-O2"))
try:
    for _ in range(200):
        if tool(client, "get_session").get("state") == "stopped": break
        time.sleep(.02)
    cold = poll(client)
    assert cold.get("status") == "completed", cold
    assert cold.get("producer", {}).get("name") == "ghidra_java_sidecar", cold
    assert "qx_alloc" in cold.get("signature", "") and cold.get("token_status") == "ok", cold
    before = time.monotonic(); warm = poll(client); warm_ms = (time.monotonic() - before) * 1000
    assert warm.get("artifact_id") == cold.get("artifact_id") and warm_ms < 1000, (warm_ms, warm)
    # Token columns are byte offsets into the printed line, indentation included.
    lines = cold["text"].split("\n")
    row = next(i for i, line in enumerate(lines, 1) if "malloc" in line)
    mapping = tool(client, "get_decomp_mapping", artifact_id=cold["artifact_id"], line=row)
    assert mapping.get("tokens") and mapping.get("runtime_pcs"), mapping
    for token in mapping["tokens"]:
        at = lines[row - 1].encode()[token["col"]:token["col"] + len(token["text"].encode())]
        assert at == token["text"].encode(), (token, lines[row - 1])
    # Memory reads and writes, an indirect call and a call with side effects
    # must all pass graph admission, not only the load-free qx_alloc.
    for symbol in ("qx_copy", "qx_sum", "qx_indirect", "qx_alias", "qx_escape"):
        other = poll(client, symbol)
        assert other.get("status") == "completed" and symbol in other.get("text", ""), (symbol, other.get("status"), other.get("job"))
    status = subprocess.run(["scripts/ghidra-sidecar", "status"], capture_output=True, text=True, timeout=10)
    assert status.returncode == 0, status.stderr
    again = subprocess.run(["scripts/ghidra-sidecar", "start"], capture_output=True, text=True, timeout=30)
    assert again.returncode == 0 and "already running" in again.stdout, (again.stdout, again.stderr)
finally:
    client.p.stdin.close(); client.p.wait(timeout=10)
    alive = subprocess.run(["scripts/ghidra-sidecar", "status"], capture_output=True, text=True, timeout=10).returncode == 0
    subprocess.run(["scripts/ghidra-sidecar", "stop"], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert alive, "the sidecar did not outlive its xodb"
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.waitpid(-1, os.WNOHANG)[0] == 0: time.sleep(.02)
    except ChildProcessError: break
else: raise AssertionError("the stopped sidecar left a process behind")
print(f"pass: real Ghidra sidecar ELF, warm cache {warm_ms:.1f} ms, process survived xodb exit; work {work}")
