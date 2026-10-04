#!/usr/bin/env python3
"""Found while testing T07, not an input defect: continue, interrupt, continue
leaves the target stopped again without anyone asking.

    tests/stale-interrupt.py [path/to/xodb] [path/to/xodb-fixture]

Uses headless MCP only (no display, no input). Expected: the second line
"after continue" reports running. Observed on 2026-09-30: stopped, reason
interrupt, with two new stop events after the continued event. Target control
belongs to the coordinator; this is the reproduction.
"""
import json
import subprocess
import sys
import time

xodb = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/xodb"
fixture = sys.argv[2] if len(sys.argv) > 2 else "./zig-out/bin/xodb-fixture"
app = subprocess.Popen([xodb, "--headless", "--mcp", "--agent-scope", "control", "--", fixture], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
serial = 0


def request(method, params=None):
    global serial
    serial += 1
    message = {"jsonrpc": "2.0", "id": serial, "method": method}
    if params is not None:
        message["params"] = params
    app.stdin.write((json.dumps(message) + "\n").encode())
    app.stdin.flush()
    while True:
        response = json.loads(app.stdout.readline())
        if "id" in response:
            return response.get("result")


def tool(name, **arguments):
    return request("tools/call", {"name": name, "arguments": arguments})["structuredContent"]


request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "stale-interrupt", "version": "1"}})
app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
app.stdin.flush()
time.sleep(0.3)
states = []
for step in ("continue", "interrupt", "continue"):
    tool(step, generation=tool("get_session")["generation"])
    time.sleep(0.5)
    session = tool("get_session")
    states.append(session["state"])
    print(f"after {step}: {session['state']}", [(t["tid"], t["reason"]) for t in session["threads"]])
app.stdin.close()
app.wait(timeout=5)
sys.exit(0 if states == ["running", "stopped", "running"] else 1)
