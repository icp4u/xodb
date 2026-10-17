#!/usr/bin/env python3
"""Owned ELF smoke test for the real persistent Ghidra sidecar."""
import atexit
import hashlib
import json
import os
import re
import socket
import struct
import shutil
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
atexit.register(shutil.rmtree, work, True)
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


def poll(client, symbol="qx_alloc", **arguments):
    deadline = time.monotonic() + 120
    while True:
        result = tool(client, "decompile_function", symbol=symbol, **arguments)
        if result.get("status") != "running" or time.monotonic() > deadline: return result
        time.sleep(.005)


def exchange(request, timeout=10):
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


def status():
    return exchange({"id": "real-status", "verb": "status", "deadline_ms": 10000})[0]


def wait_work(reply, timeout=10):
    deadline = time.monotonic() + timeout
    payload = None
    while reply.get("state") == "pending" and time.monotonic() < deadline:
        time.sleep(.005)
        reply, payload = exchange({"id": "real-poll", "verb": "status", "job": reply["job"], "deadline_ms": 10000})
    return reply, payload


def rss_kib(pid):
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith("VmRSS:"): return int(line.split()[1])
    raise AssertionError(f"VmRSS absent for {pid}")


def native_decompilers(pid):
    children = set()
    for thread in Path(f"/proc/{pid}/task").iterdir():
        try: children.update(map(int, (thread / "children").read_text().split()))
        except (FileNotFoundError, ProcessLookupError): pass
    found = []
    for child in children:
        try: command = Path(f"/proc/{child}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except FileNotFoundError: continue
        if "decompile" in command: found.append(child)
    return found

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


def known_live_values(image, symbol, expected, options=(), max_steps=96, required=None):
    """Single-step one owned function and check every displayed value."""
    current = Client("control", str(image), options=options)
    seen = set()
    checked_values = 0
    try:
        current.action("set_breakpoint", symbol=symbol)
        current.continue_initial_stop()
        stopped = current.stopped("breakpoint")
        tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
        found = tool(current, "find_symbol", name=symbol)
        low, high = int(found["address"], 16), int(found["address"], 16) + found["size"]
        for _ in range(max_steps):
            registers = tool(current, "get_registers", tid=tid)["registers"]
            pc = int(registers.get("rip") or registers.get("pc"), 16)
            if not low <= pc < high: break
            live = poll(current, symbol, tid=tid, frame=0)
            assert live.get("status") == "completed", (symbol, hex(pc), live)
            for row in live.get("live_values", ()):
                assert row["name"] in expected, (symbol, hex(pc), row, live)
                assert row["display"] == expected[row["name"]], (symbol, hex(pc), row, expected[row["name"]])
                seen.add(row["name"])
                checked_values += 1
            current.action("step_instruction", tid=tid)
            current.stopped(seconds=10)
        required = set(expected) if required is None else set(required)
        assert required <= seen <= set(expected), (symbol, required, seen, expected)
        return checked_values
    finally:
        current.p.stdin.close()
        current.p.wait(timeout=20)


def checked(client, image, position_independent, entry_pad=False):
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
        if entry_pad:
            at_entry = tool(client, "get_decomp_mapping", artifact_id=result["artifact_id"], pc=hex(low))
            assert at_entry.get("tokens") and all(r.get("entry_pad") and r.get("pc") == hex(low) for r in at_entry["tokens"]), (image, found, at_entry)
            first_line = at_entry["tokens"][0]["line"]
            from_line = tool(client, "get_decomp_mapping", artifact_id=result["artifact_id"], line=first_line)
            assert hex(low) in from_line.get("runtime_pcs", ()) and any(r.get("entry_pad") for r in from_line.get("tokens", ())), (image, found, from_line)
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
    pooled_ms = []
    for symbol in ("qx_copy", "qx_sum", "qx_indirect", "qx_alias", "qx_escape"):
        other = poll(client, symbol)
        assert other.get("status") == "completed" and symbol in other.get("text", ""), (symbol, other.get("status"), other.get("job"))
        pooled_ms.append(other["producer"]["worker_ms"])
    pooled_status = status()
    assert pooled_status["open_programs"] == 1 and pooled_status["max_open_programs"] == 8, pooled_status
    assert sorted(pooled_ms)[len(pooled_ms) // 2] < 200, pooled_ms
    fixed_texts = checked(client, fixed, False)

    # A normal stop warms a previously untouched stack function. The first D
    # is then a document-cache read even though raw uncached graph export can
    # still exceed 100 ms for a complex function.
    client.p.stdin.close(); client.p.wait(timeout=10)
    preferences = work / "warm-preferences.json"
    preferences.write_text('{"decompiler":{"eager_library_bytes":0}}\n')
    client = Client("control", str(fixed), options=["--config", str(preferences)])
    client.action("set_breakpoint", symbol="qx_branch_s")
    baseline_documents = status()["documents_cached"]
    client.continue_initial_stop()
    client.stopped("breakpoint")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        current = status()
        if current["documents_cached"] > baseline_documents and current["queue"] == 0: break
        time.sleep(.02)
    before = time.monotonic(); first_d = poll(client, "qx_branch_s"); first_d_ms = (time.monotonic() - before) * 1000
    assert first_d.get("status") == "completed" and first_d_ms < 100, (first_d_ms, first_d)

    # A low-priority request from another client cannot hold a foreground D
    # behind it. qx_branch_u has not been warmed or requested yet.
    prime, _ = exchange({"id": "other-client-prime", "verb": "prime", "architecture": "aarch64", "deadline_ms": 10000})
    assert prime.get("state") in ("pending", "ready"), prime
    sha = hashlib.sha256(fixed.read_bytes()).hexdigest()
    # Export identity participates in the document cache key. A raw prefetch
    # without a build ID must not poison a later session-bound request.
    cache_option = "build-id-cache-test"
    no_id, no_id_payload = exchange({"id": "cache-no-id", "verb": "decompile", "path": str(fixed),
        "sha256": sha, "entry": hex(link_address(fixed, "qx_alloc")), "size": "0x0", "options": cache_option, "deadline_ms": 10000})
    no_id, no_id_payload = wait_work(no_id)
    with_id, with_id_payload = exchange({"id": "cache-with-id", "verb": "decompile", "path": str(fixed),
        "sha256": sha, "build_id": "0123", "entry": hex(link_address(fixed, "qx_alloc")), "size": "0x0", "options": cache_option, "deadline_ms": 10000})
    with_id, with_id_payload = wait_work(with_id)
    assert no_id.get("state") == with_id.get("state") == "ready" and no_id_payload and with_id_payload, (no_id, with_id)
    assert "gnu_build_id" not in json.loads(no_id_payload)["image"], json.loads(no_id_payload)["image"]
    assert json.loads(with_id_payload)["image"].get("gnu_build_id") == "0123", json.loads(with_id_payload)["image"]
    before = time.monotonic()
    foreground, foreground_payload = exchange({"id": "priority-foreground", "verb": "decompile", "path": str(fixed),
        "sha256": sha, "entry": hex(link_address(fixed, "qx_branch_u")), "size": "0x0", "options": "priority-test", "deadline_ms": 10000})
    foreground, foreground_payload = wait_work(foreground)
    priority_ms = (time.monotonic() - before) * 1000
    assert foreground.get("state") == "ready" and foreground_payload and priority_ms < 500, (priority_ms, foreground)

    # The sidecar exports a readable base register plus the subregister bit
    # offset and lifetime; this is what the stopped-frame overlay consumes.
    variable_reply, variable_payload = exchange({"id": "variables", "verb": "decompile", "path": str(fixed),
        "sha256": sha, "entry": hex(link_address(fixed, "qx_alloc")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    variable_reply, variable_payload = wait_work(variable_reply)
    assert variable_reply.get("state") == "ready" and variable_payload, variable_reply
    variables = json.loads(variable_payload)["variables"]
    registers = [row for row in variables if row.get("storage") == "register"]
    assert registers and all(row.get("register") and isinstance(row.get("register_bit_offset"), int) and
                             int(row["valid_start"], 16) <= int(row["valid_end"], 16) for row in registers), registers
    # A register interval is a proof, not a first-to-last-use span: a
    # parameter is live from the entry and never past the first call, where
    # its caller-saved register is free to change; a local starts after the
    # instruction that wrote it. An unproven row is empty.
    entry = link_address(fixed, "qx_alloc")
    listing = subprocess.run(["objdump", "-d", "--no-show-raw-insn", f"--start-address={entry:#x}", f"--stop-address={entry + 0x200:#x}", str(fixed)],
                             check=True, capture_output=True, text=True).stdout
    first_call = next(int(m.group(1), 16) for m in re.finditer(r"^\s*([0-9a-f]+):\s+call\b", listing, re.M))
    parameters = [row for row in registers if row["parameter"]]
    assert parameters and all(int(row["valid_start"], 16) == entry and entry < int(row["valid_end"], 16) <= first_call + 1 for row in parameters), (parameters, hex(first_call))
    assert all(int(row["valid_start"], 16) > entry or row["valid_start"] == row["valid_end"] for row in registers if not row["parameter"]), registers

    storage_image = gcc(work / "qx-storage", "-fno-pie", "-no-pie", "-Wl,--build-id=none", "tests/fixtures/semq/qx-storage.c")
    storage_sha = hashlib.sha256(storage_image.read_bytes()).hexdigest()
    storage_open, _ = exchange({"id": "storage-open", "verb": "open_image", "path": str(storage_image),
        "sha256": storage_sha, "deadline_ms": 10000})
    storage_open, _ = wait_work(storage_open, 120)
    assert storage_open.get("state") == "ready", storage_open
    stack_reply, stack_payload = exchange({"id": "stack-variables", "verb": "decompile", "path": str(storage_image),
        "sha256": storage_sha, "entry": hex(link_address(storage_image, "qx_stack")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    stack_reply, stack_payload = wait_work(stack_reply)
    assert stack_reply.get("state") == "ready" and stack_payload, stack_reply
    stack_variables = json.loads(stack_payload)["variables"]
    stack_parameter = next(row for row in stack_variables if row.get("name") == "seventh")
    stack_pieces = [piece for piece in stack_parameter.get("pieces", ()) if piece.get("storage") == "stack"]
    stack_entry = link_address(storage_image, "qx_stack")
    assert stack_pieces and all(isinstance(piece.get("cfa_offset"), int) for piece in stack_pieces), stack_parameter
    assert "stack_parameter_verified" not in stack_parameter, stack_parameter
    assert int(stack_parameter["valid_start"], 16) == stack_entry < int(stack_parameter["valid_end"], 16), stack_parameter

    split_reply, split_payload = exchange({"id": "split-variables", "verb": "decompile", "path": str(storage_image),
        "sha256": storage_sha, "entry": hex(link_address(storage_image, "qx_split")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    split_reply, split_payload = wait_work(split_reply)
    assert split_reply.get("state") == "ready" and split_payload, split_reply
    split_variables = json.loads(split_payload)["variables"]
    split_parameter = next(row for row in split_variables if row.get("name") == "pair")
    assert int(split_parameter["valid_start"], 16) < int(split_parameter["valid_end"], 16), split_parameter
    split_offsets = {piece.get("register"): piece.get("value_bit_offset")
                     for piece in split_parameter.get("pieces", ()) if piece.get("storage") == "register"}
    assert split_offsets == {"RDI": 0, "RSI": 64}, split_parameter
    assert split_parameter.get("padding") == [{"offset": 12, "size": 4}], split_parameter

    # Ghidra's decompiler assigns this x86-64 __int128 parameter to caller
    # stack memory even though the ABI puts it in RDI:RSI, and then gives RDI
    # to the next argument. The producer exports these candidates; the stopped
    # consumer below rejects both against current-PC DWARF.
    wide_reply, wide_payload = exchange({"id": "wide-variables", "verb": "decompile", "path": str(storage_image),
        "sha256": storage_sha, "entry": hex(link_address(storage_image, "qx_wide")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    wide_reply, wide_payload = wait_work(wide_reply)
    assert wide_reply.get("state") == "ready" and wide_payload, wide_reply
    wide_variables = json.loads(wide_payload)["variables"]
    wide_parameter = next(row for row in wide_variables if row.get("name") == "wide")
    assert any(piece.get("storage") == "stack" for piece in wide_parameter.get("pieces", ())), wide_parameter
    assert "stack_parameter_verified" not in wide_parameter, wide_parameter
    after_parameter = next(row for row in wide_variables if row.get("name") == "after")
    assert "stack_parameter_verified" not in after_parameter, after_parameter
    # A _Complex double is in XMM0:XMM1, but Ghidra places it in RDI:RSI and
    # its fifth and sixth integers on caller stack slots. All are refused.
    complex_reply, complex_payload = exchange({"id": "complex-variables", "verb": "decompile", "path": str(storage_image),
        "sha256": storage_sha, "entry": hex(link_address(storage_image, "qx_complex")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    complex_reply, complex_payload = wait_work(complex_reply)
    assert complex_reply.get("state") == "ready" and complex_payload, complex_reply
    complex_parameters = [row for row in json.loads(complex_payload)["variables"] if row.get("parameter")]
    assert len(complex_parameters) == 7 and all("stack_parameter_verified" not in row for row in complex_parameters), complex_parameters
    # Lossy Ghidra types no longer trigger producer name/placement rules.
    for function in ("qx_cfloat", "qx_vector_arg", "qx_aligned"):
        reply, payload = exchange({"id": f"{function}-variables", "verb": "decompile", "path": str(storage_image),
            "sha256": storage_sha, "entry": hex(link_address(storage_image, function)), "size": "0x0", "options": "default", "deadline_ms": 10000})
        reply, payload = wait_work(reply)
        assert reply.get("state") == "ready" and payload, reply
        rows = {row["name"]: row for row in json.loads(payload)["variables"] if row.get("parameter")}
        assert rows and all("stack_parameter_verified" not in row for row in rows.values()), (function, rows)

    # Prove the exported storage against the stopped target, through the MCP
    # surface that users consume. qx_stack's seventh argument is on the stack;
    # qx_split's aggregate is divided between RDI (low) and RSI (high).
    client.p.stdin.close(); client.p.wait(timeout=10)
    for symbol, name, expected in (("qx_stack", "seventh", "0x7"),
                                   ("qx_split", "pair", "0x????????000000090000000000000008")):
        client = Client("control", str(storage_image))
        client.action("set_breakpoint", symbol=symbol)
        client.continue_initial_stop()
        stopped = client.stopped("breakpoint")
        tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
        live = poll(client, symbol, tid=tid, frame=0)
        # Entry-wide fbreg descriptions are refused until the first source row
        # after the prologue: they can name uninitialized register home slots.
        for _ in range(4):
            if any(row["name"] == name for row in live.get("live_values", ())): break
            client.action("step_instruction", tid=tid)
            client.stopped(seconds=10)
            live = poll(client, symbol, tid=tid, frame=0)
        assert live.get("status") == "completed" and live.get("live_values_at", {}).get("tid") == tid, live
        values = {row["name"]: row["display"] for row in live.get("live_values", ())}
        assert values.get(name) == expected, (symbol, expected, values, live)
        if symbol != "qx_split":
            client.p.stdin.close(); client.p.wait(timeout=10)

    client.p.stdin.close(); client.p.wait(timeout=10)

    # O0's physical parameter homes are distinct from Ghidra's entry-register
    # symbols. Raw p-code must prove each exact register-to-stack spill; every
    # value accepted while stepping is checked against the call's constants.
    storage_o0 = work / "qx-storage-O0"
    subprocess.run(["gcc", "-O0", "-g", "-fno-omit-frame-pointer", "-fno-pie", "-no-pie", "-Wl,--build-id=none",
                    "tests/fixtures/semq/qx-storage.c", "-o", str(storage_o0)], check=True, timeout=120)
    stack_answers = {"a": "0x1", "b": "0x2", "c": "0x3", "d": "0x4", "e": "0x5", "f": "0x6", "seventh": "0x7"}
    o0_required = set(stack_answers) - {"seventh"}
    o0_checked = known_live_values(storage_o0, "qx_stack", stack_answers, required=o0_required)
    assert o0_checked >= len(o0_required), o0_checked

    # Split DWARF leaves only a skeleton in the imported image. Ghidra calls
    # its parameters param_N; the DWO's formal order plus exact storage proves
    # their identity without a name guess.
    storage_split = work / "qx-storage-split"
    subprocess.run(["gcc", "-O2", "-g", "-gsplit-dwarf", "-fno-pie", "-no-pie", "-Wl,--build-id=none",
                    str(ROOT / "tests/fixtures/semq/qx-storage.c"), "-o", storage_split.name], cwd=work, check=True, timeout=120)
    assert list(work.glob("qx-storage-split*.dwo")), list(work.iterdir())
    split_checked = known_live_values(storage_split, "qx_stack", stack_answers, required={"a"})
    assert split_checked >= 1, split_checked
    split_sha = hashlib.sha256(storage_split.read_bytes()).hexdigest()
    split_open, _ = exchange({"id": "split-dwarf-open", "verb": "open_image", "path": str(storage_split), "sha256": split_sha, "deadline_ms": 10000})
    split_open, _ = wait_work(split_open, 120)
    split_raw, split_raw_payload = exchange({"id": "split-dwarf-vars", "verb": "decompile", "path": str(storage_split),
        "sha256": split_sha, "entry": hex(link_address(storage_split, "qx_stack")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    if split_raw.get("state") == "pending": split_raw, split_raw_payload = wait_work(split_raw)
    assert split_raw.get("state") == "ready" and split_raw_payload, split_raw
    split_rows = [row for row in json.loads(split_raw_payload)["variables"] if row.get("parameter")]
    assert split_rows and all(isinstance(row.get("parameter_index"), int) for row in split_rows), split_rows
    assert any(row["name"].startswith("param_") for row in split_rows), split_rows

    # A build-ID companion supplies xodb's DWARF while Ghidra analyzes the
    # stripped image and again exports only param_N identities.
    storage_full = work / "qx-storage-build-id-full"
    storage_stripped = work / "qx-storage-build-id"
    subprocess.run(["gcc", "-O2", "-g", "-fno-pie", "-no-pie", "-Wl,--build-id=sha1",
                    "tests/fixtures/semq/qx-storage.c", "-o", str(storage_full)], check=True, timeout=120)
    notes = subprocess.run(["readelf", "-n", str(storage_full)], check=True, capture_output=True, text=True).stdout
    build_id = re.search(r"Build ID:\s*([0-9a-f]+)", notes).group(1)
    debug_root = work / "debug-root"
    companion = debug_root / ".build-id" / build_id[:2] / (build_id[2:] + ".debug")
    companion.parent.mkdir(parents=True)
    subprocess.run(["objcopy", "--only-keep-debug", str(storage_full), str(companion)], check=True, timeout=30)
    shutil.copy2(storage_full, storage_stripped)
    subprocess.run(["objcopy", "--strip-all", str(storage_stripped)], check=True, timeout=30)
    stripped_checked = known_live_values(storage_stripped, "qx_stack", stack_answers,
                                         options=("--debug-dir", str(debug_root)), required={"a"})
    assert stripped_checked >= 1, stripped_checked
    stripped_sha = hashlib.sha256(storage_stripped.read_bytes()).hexdigest()
    stripped_open, _ = exchange({"id": "stripped-open", "verb": "open_image", "path": str(storage_stripped),
        "sha256": stripped_sha, "deadline_ms": 10000})
    stripped_open, _ = wait_work(stripped_open, 120)
    stripped_raw, stripped_payload = exchange({"id": "stripped-vars", "verb": "decompile", "path": str(storage_stripped),
        "sha256": stripped_sha, "entry": hex(link_address(storage_full, "qx_stack")), "size": "0x0", "options": "default", "deadline_ms": 10000})
    if stripped_raw.get("state") == "pending": stripped_raw, stripped_payload = wait_work(stripped_raw)
    assert stripped_raw.get("state") == "ready" and stripped_payload, stripped_raw
    stripped_rows = [row for row in json.loads(stripped_payload)["variables"] if row.get("parameter")]
    assert stripped_rows and all(isinstance(row.get("parameter_index"), int) for row in stripped_rows), stripped_rows
    assert any(row["name"].startswith("param_") for row in stripped_rows), stripped_rows

    # The current contents of an exactly matched caller stack slot are valid
    # in frame 1. A callee write through an alias would be the current value,
    # not a reason to hide the slot.
    frame_source = work / "qx-frame.c"
    frame_source.write_text("""
__attribute__((noinline)) unsigned long qx_leaf(volatile unsigned long *p) { __asm__ volatile("" :: "r"(p)); return *p; }
__attribute__((noinline)) unsigned long qx_outer(unsigned long a) { volatile unsigned long kept = a + 1; return qx_leaf(&kept) + a; }
int main(void) { return (int)qx_outer(0x35); }
""")
    frame_image = work / "qx-frame"
    subprocess.run(["gcc", "-O0", "-g", "-fno-omit-frame-pointer", "-fno-pie", "-no-pie", "-Wl,--build-id=none",
                    str(frame_source), "-o", str(frame_image)], check=True, timeout=120)
    client = Client("control", str(frame_image))
    client.action("set_breakpoint", symbol="qx_leaf")
    client.continue_initial_stop()
    stopped = client.stopped("breakpoint")
    tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
    outer = poll(client, "qx_outer", tid=tid, frame=1)
    assert outer.get("status") == "completed", outer
    outer_values = {row["name"]: row["display"] for row in outer.get("live_values", ())}
    assert all(name in {"a", "kept"} for name in outer_values), outer
    assert outer_values.get("a") == "0x35", outer
    if "kept" in outer_values: assert outer_values["kept"] == "0x36", outer
    client.p.stdin.close(); client.p.wait(timeout=20)

    client = Client("control", str(storage_image))
    client.action("set_breakpoint", symbol="qx_wide")
    client.continue_initial_stop()
    stopped = client.stopped("breakpoint")
    tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
    live = poll(client, "qx_wide", tid=tid, frame=0)
    assert live.get("status") == "completed" and live.get("live_values_at", {}).get("tid") == tid, live
    assert not {"wide", "after"} & {row["name"] for row in live.get("live_values", ())}, live

    # At qx_inline_shadow's entry the innermost DWARF scope is the inlined
    # qx_triple, whose parameter `a` is b (0x22) in RSI, where Ghidra puts the
    # outer a. Inner-scope names must never prove the outer variable.
    client.p.stdin.close(); client.p.wait(timeout=10)
    client = Client("control", str(storage_image))
    client.action("set_breakpoint", symbol="qx_inline_shadow")
    client.continue_initial_stop()
    stopped = client.stopped("breakpoint")
    tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
    live = poll(client, "qx_inline_shadow", tid=tid, frame=0)
    assert live.get("status") == "completed" and live.get("live_values_at", {}).get("tid") == tid, live
    shadow = {row["name"]: row["display"] for row in live.get("live_values", ())}
    assert shadow.get("a", "0x21") == "0x21" and shadow.get("b", "0x22") == "0x22", live

    # Candidate storage alone is never enough. The same synthetic image with
    # its DWARF removed has no pseudo-C live values.
    client.p.stdin.close(); client.p.wait(timeout=10)
    storage_no_dwarf = work / "qx-storage-no-dwarf"
    shutil.copy2(storage_image, storage_no_dwarf)
    subprocess.run(["objcopy", "--strip-debug", str(storage_no_dwarf)], check=True, timeout=30)
    client = Client("control", str(storage_no_dwarf))
    client.action("set_breakpoint", symbol="qx_stack")
    client.continue_initial_stop()
    stopped = client.stopped("breakpoint")
    tid = next(thread["tid"] for thread in stopped["threads"] if thread["state"] == "stopped")
    live = poll(client, "qx_stack", tid=tid, frame=0)
    assert live.get("status") == "completed" and live.get("live_values_at", {}).get("tid") == tid, live
    assert not live.get("live_values"), live

    # Losing Ghidra's native decompiler child invalidates its pooled interface.
    # The request that encounters that death reopens the program and retries
    # once, rather than exposing a transient "Stream closed" failure.
    sidecar_pid = status()["pid"]
    children = native_decompilers(sidecar_pid)
    assert children, f"no native decompiler child below sidecar {sidecar_pid}"
    for child in children: os.kill(child, 9)
    crash_reply, crash_payload = exchange({"id": "crash-retry", "verb": "decompile", "path": str(fixed),
        "sha256": sha, "entry": hex(link_address(fixed, "qx_alias")), "size": "0x0", "options": "crash-retry", "deadline_ms": 10000})
    crash_reply, crash_payload = wait_work(crash_reply)
    assert crash_reply.get("state") == "ready" and crash_payload, crash_reply
    client.p.stdin.close(); client.p.wait(timeout=10)
    client = Client("observe", str(fixed))
    for _ in range(200):
        if tool(client, "get_session").get("state") == "stopped": break
        time.sleep(.02)
    # CET landing pads are decoded instructions, but Ghidra intentionally
    # drops them from high p-code. The adapter folds this exact no-effect
    # prefix into the first graph block and keeps the function identity.
    cet = fixture_dir / "qx-gcc-cet-O2"
    client.p.stdin.close(); client.p.wait(timeout=10)
    client = Client("observe", str(cet))
    for _ in range(200):
        if tool(client, "get_session").get("state") == "stopped": break
        time.sleep(.02)
    cet_texts = checked(client, cet, False, entry_pad=True)
    without_comments = lambda text: re.sub(r"\s+", " ", re.sub(r"/\*.*?\*/", "", text, flags=re.S)).strip()
    assert {name: without_comments(text) for name, text in cet_texts.items()} == {name: without_comments(text) for name, text in fixed_texts.items()}, (cet_texts, fixed_texts)
    status_result = subprocess.run(["scripts/ghidra-sidecar", "status"], capture_output=True, text=True, timeout=10)
    assert status_result.returncode == 0, status_result.stderr
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
    demo_status = status()
    demo_rss_kib = rss_kib(demo_status["pid"])
finally:
    # The sidecar is stopped even when the last xodb does not exit in time.
    try: client.p.stdin.close(); client.p.wait(timeout=10)
    finally:
        if client.p.poll() is None: client.p.kill()
        idle_seconds = float(os.environ.get("XODB_GHIDRA_MEASURE_IDLE_SECONDS", "0"))
        if idle_seconds > 0:
            time.sleep(idle_seconds)
            idle_status = status()
            idle_rss_kib = rss_kib(idle_status["pid"])
        else:
            idle_rss_kib = None
        subprocess.run(["scripts/ghidra-sidecar", "stop"], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.waitpid(-1, os.WNOHANG)[0] == 0: time.sleep(.02)
    except ChildProcessError: break
else: raise AssertionError("the stopped sidecar left a process behind")
print(f"pass: real Ghidra sidecar ELF fixed, PIE, CET and shared library; first warmed d {first_d_ms:.1f} ms; "
      f"warm cache {warm_ms:.1f} ms; pooled uncached median {sorted(pooled_ms)[len(pooled_ms)//2]:.1f} ms, "
      f"cross-client foreground {priority_ms:.1f} ms; RSS demo {demo_rss_kib / 1024:.1f} MiB" +
      (f", after {idle_seconds:.0f}s idle {idle_rss_kib / 1024:.1f} MiB" if idle_rss_kib is not None else "") +
      f"; DC9 known values O0={o0_checked} split={split_checked} stripped={stripped_checked} outer={len(outer_values)}" +
      f"; process survived xodb exit; work {work}")
