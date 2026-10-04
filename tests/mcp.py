#!/usr/bin/env python3
"""Exercise the real stdio server and a traced fixture, with bounded waits."""
import json
import os
from pathlib import Path
import select
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
process = subprocess.Popen(["./zig-out/bin/xodb", "--headless", "--mcp", "--", "./zig-out/bin/xodb-fixture"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
sequence = 0

def receive():
    ready, _, _ = select.select([process.stdout], [], [], 5)
    assert ready, "MCP response timeout"
    line = process.stdout.readline()
    assert line, process.stderr.read().decode()
    return json.loads(line)

def request(method, params=None):
    global sequence
    sequence += 1
    request = {"jsonrpc": "2.0", "id": sequence, "method": method}
    if params is not None:
        request["params"] = params
    process.stdin.write((json.dumps(request) + "\n").encode())
    process.stdin.flush()
    response = receive()
    assert response["id"] == sequence
    return response

def tool(name, arguments=None):
    return request("tools/call", {"name": name, "arguments": arguments or {}})

pid = None
try:
    assert request("tools/list")["error"]["code"] == -32002
    assert request("initialize", {})["error"]["code"] == -32602
    response = request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "xodb-test", "version": "1"}})
    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert request("tools/list")["error"]["code"] == -32002
    process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    process.stdin.flush()
    tools = request("tools/list")["result"]["tools"]
    assert len(tools) >= 6 and all(t["annotations"]["readOnlyHint"] for t in tools)
    session = tool("get_session")["result"]["structuredContent"]
    assert session["state"] == "stopped"
    pid = session["pid"]
    tid = session["threads"][0]["tid"]
    generation = session["generation"]
    registers = tool("get_registers", {"tid": tid, "generation": generation})["result"]["structuredContent"]["registers"]
    assert int(registers["rip"], 16) > 0
    memory = tool("read_memory", {"address": registers["rip"], "length": 32})["result"]["structuredContent"]
    assert memory["bytes_read"] == 32 and len(memory["hex"]) == 64
    # Compare with an independent kernel interface while the target is stopped.
    fd = os.open(f"/proc/{pid}/mem", os.O_RDONLY)
    try:
        assert os.pread(fd, 32, int(registers["rip"], 16)).hex() == memory["hex"]
    finally:
        os.close(fd)
    instructions = tool("disassemble", {"address": registers["rip"]})["result"]["structuredContent"]["instructions"]
    assert instructions and instructions[0]["address"] == registers["rip"]
    events = tool("query_events")["result"]["structuredContent"]["events"]
    assert events[0]["kind"] == "launch" and events[-1]["kind"] == "stop"
    assert tool("get_registers", {"tid": tid, "generation": generation + 1})["result"]["isError"]
    assert tool("read_memory", {"address": "1", "length": 32})["result"]["isError"]
    assert tool("read_memory", {"address": registers["rip"], "length": 4097})["error"]["code"] == -32602
    assert tool("get_session", {"unexpected": True})["error"]["code"] == -32602
    assert tool("continue")["result"]["isError"]
    assert request("not/a/method")["error"]["code"] == -32601
    process.stdin.write(b'{broken json}\n')
    process.stdin.flush()
    assert receive()["error"]["code"] == -32700
    assert request("ping")["result"] == {}
    process.stdin.close()
    assert process.wait(timeout=5) == 0
    assert not Path(f"/proc/{pid}").exists(), "Owned inferior survived MCP EOF"
    print("MCP integration passed: lifecycle, schema, inspection, independent memory comparison, errors, EOF cleanup")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
