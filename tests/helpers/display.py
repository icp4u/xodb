"""Shared private headless display and live profiler MCP client.

Callers may override WORK before constructing a Display. The compositor,
pointer helper and all outputs belong to that run, never the desktop session.
"""
import json
import os
import select
import subprocess
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.join(ROOT, ".work", "timeline-"+datetime.now().strftime("%Y%m%dT%H%M%S%f"))
VPTR_XML = "/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml"

class Display:
    """A private headless Sway with its own runtime directory and caches."""

    def __init__(self, name, width=1280, height=800):
        self.dir = os.path.join(WORK, name)
        self.runtime = os.path.join(self.dir, "runtime")
        os.makedirs(self.runtime, mode=0o700)
        for d in ("tmp", "cache/nvidia", "cache/mesa"):
            os.makedirs(os.path.join(self.dir, d), exist_ok=True)
        subprocess.run(["wayland-scanner", "client-header", VPTR_XML, os.path.join(self.dir, "virtual-pointer.h")], check=True)
        subprocess.run(["wayland-scanner", "private-code", VPTR_XML, os.path.join(self.dir, "virtual-pointer.c")], check=True)
        self.vptr = os.path.join(self.dir, "vptr")
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", self.dir, os.path.join(HERE, "vptr.c"), os.path.join(self.dir, "virtual-pointer.c"), "-lwayland-client", "-lm", "-o", self.vptr], check=True)
        config = os.path.join(self.dir, "sway.conf")
        with open(config, "w") as f:
            f.write(f"xwayland disable\noutput HEADLESS-1 mode {width}x{height}\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n")
        env = dict(os.environ)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        env.update(TMPDIR=os.path.join(self.dir, "tmp"), XDG_CACHE_HOME=os.path.join(self.dir, "cache"), MESA_SHADER_CACHE_DIR=os.path.join(self.dir, "cache/mesa"), __GL_SHADER_DISK_CACHE_PATH=os.path.join(self.dir, "cache/nvidia"), XDG_RUNTIME_DIR=self.runtime, WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_LIBINPUT_NO_DEVICES="1")
        self.log = open(os.path.join(self.dir, "sway.log"), "wb")
        self.sway = subprocess.Popen(["sway", "--unsupported-gpu", "--config", config], env=env, stdout=self.log, stderr=subprocess.STDOUT)
        try:
            self.wait_ready(env)
        except BaseException:
            self.close()
            raise
        self.size = (width, height)

    def wait_ready(self, env):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            names = os.listdir(self.runtime)
            sockets = [n for n in names if n.startswith("wayland-") and not n.endswith(".lock")]
            ipc = [n for n in names if n.startswith("sway-ipc")]
            if sockets and ipc:
                break
            if self.sway.poll() is not None:
                raise RuntimeError("private compositor exited")
            time.sleep(0.05)
        else:
            raise TimeoutError("private compositor did not start")
        env.update(WAYLAND_DISPLAY=sockets[0], SWAYSOCK=os.path.join(self.runtime, ipc[0]), XODB_TEST_PRIVATE_DISPLAY="1")
        self.env = env

    def pointer(self, *commands):
        subprocess.run([self.vptr, str(self.size[0]), str(self.size[1]), *map(str, commands)], env=self.env, check=True, timeout=30)

    def shot(self, name):
        path = os.path.join(self.dir, name + ".png")
        subprocess.run(["grim", "-o", "HEADLESS-1", path], env=self.env, check=True, timeout=10)
        return path

    def resize(self, width, height):
        subprocess.run(["swaymsg", "output", "HEADLESS-1", "mode", f"{width}x{height}"], env=self.env, check=True, capture_output=True, timeout=5)
        self.size = (width, height)

    def close(self):
        self.sway.terminate()
        try:
            self.sway.wait(5)
        except subprocess.TimeoutExpired:
            self.sway.kill()
            self.sway.wait()
        self.log.close()

class Mcp:
    """The live profiler application with its MCP server on stdio."""

    def __init__(self, display, tree):
        self.log = open(os.path.join(display.dir, "xodb.log"), "wb")
        self.proc = subprocess.Popen(["./zig-out/bin/xodb", "--mcp", "--agent-scope", "control", "--break", "profile_ready", "--source", "tests/fixtures/profile.c", "--", "./zig-out/bin/xodb-profile-fixture"], cwd=tree, env=display.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)
        self.serial = 0
        self.pending = b""
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t09-timeline", "version": "1"}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')

    def call(self, method, params=None, timeout=10):
        self.serial += 1
        message = {"jsonrpc": "2.0", "id": self.serial, "method": method}
        if params is not None:
            message["params"] = params
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                response = json.loads(line)
                if response.get("id") == self.serial:
                    return response["result"]
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                break
            self.pending += chunk
        raise TimeoutError(method)

    def tool(self, name, **args):
        result = self.call("tools/call", {"name": name, "arguments": args})
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result}")
        return result["structuredContent"]

    def session(self):
        return self.tool("get_session")

    def await_state(self, state, reason=None, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            snap = self.session()
            if snap["state"] == state and (reason is None or any(t["reason"] == reason for t in snap["threads"])):
                return snap
            time.sleep(0.05)
        raise TimeoutError(f"state {state}")
