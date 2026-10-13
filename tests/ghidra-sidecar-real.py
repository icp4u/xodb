#!/usr/bin/env python3
"""Owned ELF smoke test for the real persistent Ghidra sidecar."""
import os
import re
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


def tool(client, name, /, **args):
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

SOURCE = "tests/fixtures/semq/qx.c"
CALLS = {"qx_alloc": ("malloc", "memset"), "qx_copy": ("memcpy",), "qx_sum": (), "qx_indirect": ()}


def gcc(output, *flags):
    subprocess.run(["gcc", "-O2", "-g", *flags, "-o", str(output)], check=True, timeout=120)
    return output


def elf_type(path):
    with open(path, "rb") as f: return int.from_bytes(f.read(18)[16:], sys.byteorder)


def link_address(path, symbol):
    for row in subprocess.run(["nm", str(path)], check=True, capture_output=True, text=True).stdout.splitlines():
        fields = row.split()
        if fields[-1] == symbol and len(fields) == 3: return int(fields[0], 16)
    raise AssertionError((path, symbol))


def checked(client, image, position_independent):
    """Decompile the qx functions of image in this live session; return their
    pseudo-C with the addresses Ghidra puts in generated names taken out."""
    assert (elf_type(image) == 3) == position_independent, (image, elf_type(image))
    texts = {}
    for symbol, calls in CALLS.items():
        result = poll(client, symbol)
        assert result.get("status") == "completed", (image, symbol, result)
        assert result["producer"]["name"] == "ghidra_java_sidecar" and result["function"]["module"] == str(image), result
        text = result["text"]
        # A call through a wrongly based GOT or PLT loses its name.
        assert symbol in result["signature"] and all(name + "(" in text for name in calls), (image, text)
        assert not re.search(r"\b(SUB|FUN)_", text), (image, text)
        texts[symbol] = re.sub(r"\b((?:[A-Za-z]+_)+)[0-9a-f]{8,16}\b", r"\1ADDR", text)
        if symbol != "qx_alloc": continue
        # The malloc line maps to code inside qx_alloc as this process loaded
        # it: by the session's symbol, its executable mappings and its line table.
        found = tool(client, "find_symbol", name=symbol)
        low = int(found["address"], 16)
        assert (low != link_address(image, symbol)) == position_independent, (image, found)
        row = next(i for i, line in enumerate(text.split("\n"), 1) if "malloc" in line)
        mapping = tool(client, "get_decomp_mapping", artifact_id=result["artifact_id"], line=row)
        pcs = [int(pc, 16) for pc in mapping.get("runtime_pcs", ())]
        assert pcs and all(low <= pc < low + found["size"] for pc in pcs), (image, found, mapping)
        code = [r for r in tool(client, "list_modules")["regions"] if r["path"] == str(image) and "x" in r["permissions"]]
        assert all(any(r["start"] <= pc < r["end"] for r in code) for pc in pcs), (image, pcs, code)
        wanted = next(i for i, line in enumerate(open(SOURCE), 1) if "malloc(n)" in line)
        called = [t for t in mapping["tokens"] if t["text"] == "malloc"]
        assert called and all(t["source"]["path"].endswith("qx.c") and t["source"]["line"] == wanted for t in called), (image, called)
    return texts


fixed = fixture_dir / "qx-gcc-O2"
client = Client("observe", str(fixed))
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
    fixed_texts = checked(client, fixed, False)
    # CET landing pads are decoded instructions, but Ghidra intentionally
    # drops them from high p-code. The adapter folds this exact no-effect
    # prefix into the first graph block and keeps the function identity.
    cet = fixture_dir / "qx-gcc-cet-O2"
    client.p.stdin.close(); client.p.wait(timeout=10)
    client = Client("observe", str(cet))
    for _ in range(200):
        if tool(client, "get_session").get("state") == "stopped": break
        time.sleep(.02)
    cet_texts = checked(client, cet, False)
    without_comments = lambda text: re.sub(r"\s+", " ", re.sub(r"/\*.*?\*/", "", text, flags=re.S)).strip()
    assert {name: without_comments(text) for name, text in cet_texts.items()} == {name: without_comments(text) for name, text in fixed_texts.items()}, (cet_texts, fixed_texts)
    status = subprocess.run(["scripts/ghidra-sidecar", "status"], capture_output=True, text=True, timeout=10)
    assert status.returncode == 0, status.stderr
    again = subprocess.run(["scripts/ghidra-sidecar", "start"], capture_output=True, text=True, timeout=30)
    assert again.returncode == 0 and "already running" in again.stdout, (again.stdout, again.stderr)
    client.p.stdin.close(); client.p.wait(timeout=10)
    alive = subprocess.run(["scripts/ghidra-sidecar", "status"], capture_output=True, text=True, timeout=10).returncode == 0
    assert alive, "the sidecar did not outlive its xodb"
    # xodb asks about link addresses. A position-independent executable links
    # at 0 and Ghidra would import it at a base of its own; the answers must
    # match the fixed-address build of the same source, and map into wherever
    # this process loaded the image.
    pie = gcc(work / "qx-pie", "-fPIE", "-pie", SOURCE)
    client = Client("observe", str(pie))
    for _ in range(200):
        if tool(client, "get_session").get("state") == "stopped": break
        time.sleep(.02)
    pie_texts = checked(client, pie, True)
    assert pie_texts == fixed_texts, (pie_texts, fixed_texts)
    client.p.stdin.close(); client.p.wait(timeout=10)
    # The same for a shared library, once its user has loaded it.
    library = gcc(work / "libqx.so", "-fPIC", "-shared", SOURCE)
    (work / "use.c").write_text("void *qx_alloc(unsigned, unsigned, int);\nint main(void) { return qx_alloc(1, 1, 0) == 0; }\n")
    user = gcc(work / "qx-use", str(work / "use.c"), "-L" + str(work), "-lqx", "-Wl,-rpath," + str(work))
    client = Client("control", str(user))
    client.action("set_breakpoint", symbol="main")
    client.continue_initial_stop()
    client.stopped("breakpoint")
    library_texts = checked(client, library, True)
    assert library_texts == fixed_texts, (library_texts, fixed_texts)
finally:
    # The sidecar is stopped even when the last xodb does not exit in time.
    try: client.p.stdin.close(); client.p.wait(timeout=10)
    finally:
        if client.p.poll() is None: client.p.kill()
        subprocess.run(["scripts/ghidra-sidecar", "stop"], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.waitpid(-1, os.WNOHANG)[0] == 0: time.sleep(.02)
    except ChildProcessError: break
else: raise AssertionError("the stopped sidecar left a process behind")
print(f"pass: real Ghidra sidecar ELF fixed, PIE, CET and shared library, warm cache {warm_ms:.1f} ms, process survived xodb exit; work {work}")
