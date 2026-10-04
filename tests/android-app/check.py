#!/usr/bin/env python3
"""JNI breakpoint/locals/step/watch checks on an owned host fixture or reviewed APK.

--device requires the reviewed opt-in debug APK already installed. This test
never installs an APK; AppDemo uploads only its scoped service/source files.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import runpy
import select
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


class Rpc:
    def __init__(self, send, receive):
        self.send, self.receive = send, receive
        self.pending = b""
        self.transcript = []
        self.runtime_signals = []
        self.android = False
        self.request("initialize", dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="jni-check", version="1")))
        self.send(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')

    def request(self, method, params=None):
        identity = len(self.transcript) + 1
        message = dict(jsonrpc="2.0", id=identity, method=method, params=params or {})
        self.send((json.dumps(message) + "\n").encode())
        deadline = time.monotonic() + 10
        while True:
            while b"\n" not in self.pending:
                assert select.select([self.receive], [], [], max(0, deadline - time.monotonic()))[0], "MCP timeout"
                data = os.read(self.receive.fileno(), 65536)
                assert data, "MCP closed before reply"
                self.pending += data
            line, self.pending = self.pending.split(b"\n", 1)
            response = json.loads(line)
            if "id" not in response:
                continue
            assert response["id"] == identity, response
            self.transcript.append(dict(request=message, response=response))
            assert "error" not in response, response
            return response["result"]

    def tool(self, tool_name, **args):
        result = self.request("tools/call", dict(name=tool_name, arguments=args))
        assert not result.get("isError"), result
        return result["structuredContent"]

    def action(self, tool_name, **args):
        return self.tool(tool_name, generation=self.tool("get_session")["generation"], **args)

    def clear_breakpoints(self):
        # The loader rendezvous belongs to xodb and may disappear when the
        # last user breakpoint is removed. Do not remove its cached ID.
        for probe in self.tool("get_breakpoints")["breakpoints"]:
            if not probe["internal"]:
                self.action("remove_breakpoint", id=probe["id"])

    def stopped(self, reason=None):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            session = self.tool("get_session")
            if session["state"] == "stopped":
                for thread in session["threads"]:
                    if reason is None or thread["reason"] == reason:
                        return thread["tid"]
                if self.android and reason is not None:
                    signals = [t for t in session["threads"] if t["reason"] == "signal"]
                    if signals:
                        # ART can use handled SIGSEGVs. Preserve and forward the
                        # signal through ordinary Continue; never suppress it.
                        assert len(self.runtime_signals) < 3 and all(t["signal"] == 11 for t in signals), signals
                        views = [self.tool("get_debug_view", tid=t["tid"]) for t in signals]
                        evidence = dict(threads=signals, frames=[v["frames"] for v in views], instructions=[v["instructions"][:3] for v in views])
                        self.runtime_signals.append(evidence)
                        print("Forwarding demo SIGSEGV through Continue:", evidence["frames"], flush=True)
                        self.action("continue")
            time.sleep(.01)
        raise AssertionError(session)


def exercise(rpc, source, device):
    rpc.android = device
    session = rpc.tool("get_session")
    assert session["state"] == "stopped"
    if not device:
        rpc.action("continue")
        rpc.stopped("breakpoint")  # main: shared library is now mapped.
    rpc.clear_breakpoints()
    line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if "XODB_WATCH_WRITE" in text)
    rpc.tool("find_symbol", name="xodb_demo_tick")
    probe = rpc.action("set_breakpoint", file="xodb_demo.c", line=line)["id"]
    rpc.action("continue")
    tid = rpc.stopped("breakpoint")
    view = rpc.tool("get_debug_view", tid=tid)
    assert view["frames"][0]["symbol"] == "xodb_demo_tick", view
    assert view["frames"][0]["source"]["line"] == line, view["frames"]
    assert view["registers"] and view["instructions"]
    assert "XODB_WATCH_WRITE" in view["source"]["text"]
    locals = {v["name"]: v for v in view["locals"]}
    before = int(locals["value"]["display"])
    assert int(locals["amount"]["display"]) == 5 and int(locals["next"]["display"]) == before + 5, locals
    assert rpc.tool("evaluate_expression", tid=tid, expression="value")["value"]["display"] == str(before)
    address = locals["value"]["address"]
    assert address and locals["value"]["size"] == 4, locals["value"]
    watch = rpc.action("set_watchpoint", address=hex(address), length=4, kind="write")["id"]
    rpc.action("remove_breakpoint", id=probe)
    hits = []
    for expected in (before + 5, before + 10):
        rpc.action("continue")
        tid = rpc.stopped("watchpoint")
        view = rpc.tool("get_debug_view", tid=tid)
        hit = view["watch_hits"][0]
        assert (hit["before"], hit["after"]) == (expected - 5, expected), hit
        assert hit["phase"] == ("completed" if device else "after_access"), hit
        assert rpc.tool("evaluate_expression", tid=tid, expression="value")["value"]["display"] == str(expected)
        hits.append(hit)
    rpc.action("remove_watchpoint", id=watch)
    previous = rpc.tool("get_debug_view", tid=tid)["frames"][0]["source"]["line"]
    rpc.action("step_source", tid=tid)
    rpc.stopped()
    after = rpc.tool("get_debug_view", tid=tid)
    assert after["frames"][0]["source"]["line"] != previous, after["frames"]
    if device:
        rpc.action("detach")
    return dict(architecture=view["architecture"], tid=tid, line=line, initial_value=before, hits=hits, runtime_signals=rpc.runtime_signals,
                checks="JNI symbol, source breakpoint, locals/static storage, eval, two hardware writes, source step, " + ("detach" if device else "owned-target cleanup"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=ROOT / "zig-out/bin/xodb")
    parser.add_argument("--device", action="store_true")
    parser.add_argument("--execute-reviewed-plan", action="store_true")
    args = parser.parse_args()
    if args.device and not args.execute_reviewed_plan:
        parser.error("Device writes require review of docs/ANDROID_APP_PLAN.md and --execute-reviewed-plan")
    os.chdir(ROOT)
    run = ROOT / ".work" / ("jni-check-" + datetime.now().strftime("%Y%m%dT%H%M%S%f"))
    run.mkdir()
    rpc = device = process = sock = None
    try:
        if args.device:
            AppDemo = runpy.run_path(str(ROOT / "scripts/demo-android-app"))["AppDemo"]
            device = AppDemo(args.server, args.demo, 90)
            device.start()
            device.identity()
            sock = socket.create_connection(("127.0.0.1", device.port), timeout=10)
            sock.settimeout(None)
            rpc = Rpc(sock.sendall, sock)
        else:
            source = args.demo.resolve() / "xodb_demo.c"
            subprocess.run(["cc", "-shared", "-fPIC", "-g", "-gdwarf-4", "-O0", "-Wall", "-Wextra", "-Werror",
                            "-I/usr/lib/jvm/java-21-openjdk/include", "-I/usr/lib/jvm/java-21-openjdk/include/linux",
                            str(source), "-o", str(run / "libxodb_demo.so")], check=True)
            (run / "main.c").write_text("#include <unistd.h>\nextern int xodb_demo_tick(int);\nint main(void) { alarm(30); for(int i=0;i<100;i++) { xodb_demo_tick(5); usleep(20000); } return 0; }\n")
            subprocess.run(["cc", "-g", "-O0", str(run / "main.c"), "-L" + str(run), "-lxodb_demo", "-Wl,-rpath," + str(run), "-o", str(run / "fixture")], check=True)
            with (run / "server.log").open("wb") as log:
                process = subprocess.Popen([str(args.server.resolve()), "--headless", "--mcp", "--agent-scope", "control",
                                            "--source", str(source), "--break", "main", "--", str(run / "fixture")],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
            rpc = Rpc(lambda data: process.stdin.write(data), process.stdout)
        result = exercise(rpc, args.demo / "xodb_demo.c", args.device)
        (run / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        if rpc:
            (run / "transcript.json").write_text(json.dumps(rpc.transcript, indent=2) + "\n")
        if sock:
            sock.close()
        if process:
            process.stdin.close()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=5)
        if device:
            device.close()
        print(run)


if __name__ == "__main__":
    main()
