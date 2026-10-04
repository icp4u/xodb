"""Shared private Sway/input harness and current input smoke scenarios.

Imported by GUI regression tests and scripts/input-smoke.py. Callers select
their own WORK directory and compiled HELPER; no display starts on import.
"""
import glob
import json
import os
import re
import select
import signal
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VPTR = "/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml"
VKBD = "/usr/lib/wayland-debug/resources/protocols/wlroots/protocol/virtual-keyboard-unstable-v1.xml"
KEY = dict(esc=1, equal=13, tab=15, q=16, w=17, e=18, ctrl=29, a=30, d=32, g=34, j=36, k=37, semicolon=39, shift=42, space=57, f5=63, f6=64, f8=66, f10=68, f11=87)
results = []
M1 = ["--source", "tests/fixtures/m1.c", "--break", "change_value", "--", "./zig-out/bin/xodb-m1-fixture", "w"]
TARGET = ["--source", "tests/fixtures/target.c", "--", "./zig-out/bin/xodb-fixture"]
THREADS_PANE = "210x170+8+590"
SIDE_PANE = "250x450+1020+95"

def check(name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": str(detail)})
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ""), flush=True)
    return ok

def note(name, detail):
    """Something observed that is neither a pass nor a failure."""
    results.append({"check": name, "ok": None, "detail": str(detail)})
    print(f"note {name}: {detail}", flush=True)

class Display:
    """A private headless Sway and one xodb inside it, with MCP on stdio."""

    def __init__(self, tree, args, trace=True, wayland_debug=False, hide_cursor=True):
        Display.count = getattr(Display, "count", 0) + 1
        self.tree = tree
        self.dir = os.path.join(WORK, f"run-{Display.count:02d}")
        self.runtime = os.path.join(WORK, "rt", str(Display.count))  # short: the Sway socket must fit in sun_path
        os.makedirs(self.dir)
        os.makedirs(self.runtime, mode=0o700)
        config = os.path.join(self.dir, "sway.conf")
        with open(config, "w") as f:
            f.write("xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\n" + ("seat seat0 hide_cursor 100\n" if hide_cursor else ""))
        env = dict(os.environ)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        env.update(TMPDIR=os.path.join(WORK, "tmp"), XDG_CACHE_HOME=os.path.join(WORK, "cache"), XDG_RUNTIME_DIR=self.runtime, WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_LIBINPUT_NO_DEVICES="1", XODB_TEST_PRIVATE_DISPLAY="1")
        self.env = env
        self.procs = []
        self.sway = subprocess.Popen(["sway", "--unsupported-gpu", "--config", config], env=env, stdout=open(os.path.join(self.dir, "sway.log"), "wb"), stderr=subprocess.STDOUT)
        self.procs.append(self.sway)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sockets = [p for p in glob.glob(os.path.join(self.runtime, "wayland-*")) if not p.endswith(".lock")]
            ipc = glob.glob(os.path.join(self.runtime, "sway-ipc*.sock"))
            if sockets and ipc:
                break
            if self.sway.poll() is not None:
                raise RuntimeError(open(os.path.join(self.dir, "sway.log")).read())
            time.sleep(0.05)
        else:
            raise TimeoutError("private compositor did not start")
        env["WAYLAND_DISPLAY"] = os.path.basename(sockets[0])
        env["SWAYSOCK"] = ipc[0]
        app_env = dict(env)
        if trace:
            app_env["XODB_INPUT_TRACE"] = "1"
        if wayland_debug:
            app_env["WAYLAND_DEBUG"] = "1"
        self.log = os.path.join(self.dir, "xodb.log")
        self.app = subprocess.Popen([os.path.join(tree, "zig-out", "bin", "xodb"), "--mcp", *args], cwd=tree, env=app_env, bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(self.log, "wb"))
        self.procs.append(self.app)
        self.serial = 0
        self.notifications = []
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "input-test", "version": "1"}})
        self.app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.app.stdin.flush()
        time.sleep(0.5)

    def request(self, method, params=None):
        self.serial += 1
        message = {"jsonrpc": "2.0", "id": self.serial, "method": method}
        if params is not None:
            message["params"] = params
        self.app.stdin.write((json.dumps(message) + "\n").encode())
        self.app.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.app.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            line = self.app.stdout.readline()
            if not line:
                break
            response = json.loads(line)
            if "id" not in response:
                self.notifications.append(response)
                continue
            return response.get("result")
        raise RuntimeError(f"no MCP response to {method}; log tail: {self.tail()}")

    def tool(self, name, **arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})["structuredContent"]

    def session(self):
        return self.tool("get_session")

    def events(self, kind):
        return [e for e in self.tool("query_events")["events"] if e["kind"] == kind]

    def wait(self, predicate, seconds=5):
        deadline = time.monotonic() + seconds
        snap = None
        while time.monotonic() < deadline:
            snap = self.session()
            if predicate(snap):
                return snap
            time.sleep(0.03)
        return None

    def stopped(self, reason=None, threads=1):
        return self.wait(lambda s: s["state"] == "stopped" and len(s["threads"]) >= threads and (reason is None or any(t["reason"] == reason for t in s["threads"])))

    def keys(self, *commands, wait=True):
        """Runs the input helper with a fresh US-layout keyboard unless the script chooses a layout."""
        script = [str(c) for c in commands]
        if "layout" not in script and any(c in script for c in ("down", "up", "tap", "burst")):
            script = ["layout", "us", *script]
        # Every injected action is logged, so a trace can be told apart from real input.
        with open(os.path.join(self.dir, "injected.jsonl"), "a") as f:
            f.write(json.dumps({"unix_time": round(time.time(), 3), "script": script}) + "\n")
        helper = subprocess.Popen([HELPER, "1280", "800", *script], env=self.env)
        self.procs.append(helper)
        if wait:
            code = helper.wait(timeout=60)
            if code != 0:
                raise RuntimeError(f"input helper exited {code} for {script}")
            time.sleep(0.15)
        return helper

    def shot(self, name, cursor=False):
        path = os.path.join(self.dir, name + ".png")
        subprocess.run(["grim", *(["-c"] if cursor else []), "-o", "HEADLESS-1", path], env=self.env, check=True, timeout=10)
        return path

    def trace(self):
        """Parsed XODB_INPUT_TRACE lines from the application's stderr."""
        out = []
        for line in open(self.log, errors="replace"):
            match = re.match(r'input (\w+) code=(\d+) sym=0x([0-9a-f]+) shortcut=(\S*) text="(.*)" mods=(\w*) t=(\d+)', line)
            if match:
                kind, code, keysym, shortcut, text, mods, stamp = match.groups()
                out.append({"kind": kind, "code": int(code), "sym": int(keysym, 16), "shortcut": shortcut, "text": text, "mods": mods, "t": int(stamp)})
        return out

    def tail(self):
        return open(self.log, errors="replace").read()[-300:]

    def alive(self):
        return self.app.poll() is None

    def close(self):
        for p in reversed(self.procs):
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
        for p in reversed(self.procs):
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

def differs(a, b, region):
    """True if two captures differ inside region "WxH+X+Y"."""
    done = subprocess.run(["magick", "compare", "-metric", "AE", "-extract", region, a, b, "null:"], capture_output=True, text=True)
    return float(done.stderr.split()[0]) > 0

def controls(tree):
    """Space/F5/F6, F10/F11, F8, W, Tab, J/K, D, Q and Escape still do what they did."""
    d = Display(tree, M1)
    try:
        d.stopped()
        d.keys("tap", KEY["f8"])
        check("F8 grants agent control", d.wait(lambda s: s["agent_scope"] == "control"))
        d.keys("tap", KEY["f8"])
        check("F8 revokes agent control", d.wait(lambda s: s["agent_scope"] == "observe"))
        d.keys("tap", KEY["space"])
        check("Space continues to the breakpoint", d.stopped("breakpoint"))
        d.keys("tap", KEY["f11"])
        check("F11 steps", d.stopped("single_step"))
        generation = d.session()["generation"]
        d.keys("tap", KEY["f10"])
        check("F10 steps over", d.wait(lambda s: s["state"] == "stopped" and s["generation"] > generation))
        before = d.shot("tab-before")
        d.keys("tap", KEY["tab"])
        check("Tab switches locals and registers", differs(before, d.shot("tab-after"), SIDE_PANE))
        d.keys("tap", KEY["tab"], "click", 1130, 195, "tap", KEY["w"])
        check("W starts a watch on the selected value", len([w for w in d.tool("get_breakpoints")["watchpoints"] if w]) == 1)
        before = d.shot("g-before")
        d.keys("tap", KEY["g"])
        check("G opens the control-flow view", differs(before, d.shot("g-after"), "380x450+620+95"))
        d.keys("tap", KEY["g"], "tap", KEY["d"])
        check("D detaches", d.wait(lambda s: s["state"] == "idle"))
        d.keys("tap", KEY["q"])
        check("Q quits cleanly", d.app.wait(timeout=5) == 0 and "clean shutdown" in d.tail())
    finally:
        d.close()
    d = Display(tree, TARGET)
    try:
        d.stopped()
        d.keys("tap", KEY["f5"])
        check("F5 continues", d.wait(lambda s: s["state"] == "running" and len(s["threads"]) == 2))
        d.keys("tap", KEY["f6"])
        check("F6 interrupts", d.stopped(threads=2))
        before = d.shot("j-before")
        d.keys("tap", KEY["j"])
        moved = d.shot("j-after")
        check("J selects the next thread", differs(before, moved, THREADS_PANE))
        d.keys("tap", KEY["k"])
        check("K selects the previous thread", not differs(before, d.shot("k-after"), THREADS_PANE))
        d.keys("tap", KEY["esc"])
        check("Escape quits cleanly", d.app.wait(timeout=5) == 0)
    finally:
        d.close()

def holding(tree):
    """A held execution key acts once; a held navigation key repeats."""
    d = Display(tree, TARGET)
    try:
        d.stopped()
        d.keys("down", KEY["space"], "w", 2000, "up", KEY["space"])
        repeats = [e for e in d.trace() if e["kind"] == "repeat" and e["code"] == KEY["space"]]
        check("holding Space for 2 s delivers repeat events", len(repeats) >= 20, f"{len(repeats)} repeats")
        check("and continues the target exactly once", len(d.events("continued")) == 1 and d.session()["state"] == "running", f"{len(d.events('continued'))} continued events, state {d.session()['state']}")
        stops = len(d.events("stop"))
        d.keys("down", KEY["f6"], "w", 2000, "up", KEY["f6"])
        check("holding F6 for 2 s interrupts once and does not resume", d.session()["state"] == "stopped" and len(d.events("continued")) == 1, f"{len(d.events('stop')) - stops} new stop events")
        generation = d.session()["generation"]
        d.keys("down", KEY["f8"], "w", 1500, "up", KEY["f8"])
        check("holding F8 toggles agent scope once", d.session()["agent_scope"] == "control" and len([n for n in d.notifications if n["method"] == "notifications/tools/list_changed"]) == 1)
        d.keys("down", KEY["q"], "w", 300, "up", KEY["q"])
        check("Q quits on the press", d.app.wait(timeout=5) == 0, f"generation was {generation}")
    finally:
        d.close()
    d = Display(tree, ["--", os.path.join(WORK, "threads")])
    try:
        d.stopped()
        d.keys("tap", KEY["space"], "w", 500, "tap", KEY["space"])
        d.stopped(threads=41)
        before = d.shot("hold-j-before")
        d.keys("down", KEY["j"], "w", 2000, "up", KEY["j"])
        repeats = [e for e in d.trace() if e["kind"] == "repeat" and e["code"] == KEY["j"]]
        gaps = [b["t"] - a["t"] for a, b in zip(repeats, repeats[1:])]
        check("holding J for 2 s repeats at the compositor's rate", 25 <= len(repeats) <= 40 and max(gaps) <= 60, f"{len(repeats)} repeats, intervals {min(gaps)}-{max(gaps)} ms")
        check("and the thread selection moves with it", differs(before, d.shot("hold-j-after"), THREADS_PANE))
    finally:
        d.close()

def bursts(tree, label, expect):
    """Several keys, and a press plus release, arriving in one dispatch."""
    d = Display(tree, TARGET, trace=expect)
    try:
        d.stopped()
        note = "" if expect else " (the defect this patch fixes)"
        d.keys("burst", 2, KEY["f8"], KEY["f8"])
        time.sleep(0.3)
        scope = d.session()["agent_scope"]
        check(f"{label}: two F8 presses in one batch toggle agent scope twice", (scope == "observe") == expect, f"scope {scope}" + note)
        if not expect:
            d.keys("tap", KEY["f8"])  # back to observe for the next check
        d.keys("burst", 2, KEY["f8"], KEY["space"])
        time.sleep(0.4)
        snap = d.session()
        check(f"{label}: F8 then Space in one batch both act, in order", (snap["agent_scope"] == "control" and snap["state"] == "running") == expect, f"scope {snap['agent_scope']}, state {snap['state']}" + note)
        if expect:
            check(f"{label}: no event was dropped", "dropped" not in d.tail())
    finally:
        d.close()
    d = Display(tree, TARGET, trace=expect)
    try:
        d.stopped()
        d.keys("fastclick", 90, 65)
        time.sleep(0.4)
        state = d.session()["state"]
        check(f"{label}: a click whose press and release arrive together is acted on", (state == "running") == expect, f"state {state}" + note)
    finally:
        d.close()

def layouts(tree):
    """Shortcuts follow the active layout's letters; text follows the layout; Ctrl is not a plain key."""
    d = Display(tree, TARGET)
    try:
        d.stopped()
        d.keys("layout", "fr", "tap", KEY["q"])
        check("French layout: the key labelled A (QWERTY Q position) does not quit", d.alive() and d.trace()[-1]["shortcut"] in ("a", ""), d.trace()[-2:])
        # A opens the allocation inspector, which owns keys until dismissed.
        d.keys("tap", KEY["esc"])
        d.keys("layout", "fr", "tap", KEY["a"])
        check("French layout: the key labelled Q quits", d.app.wait(timeout=5) == 0)
    finally:
        d.close()
    d = Display(tree, TARGET)
    try:
        d.stopped()
        d.keys("layout", "de", "tap", KEY["semicolon"], "tap", KEY["equal"], "tap", KEY["a"])
        texts = [e["text"] for e in d.trace() if e["kind"] == "press"]
        # A plain letter: E opens the expression field (T19), which then owns typed keys.
        check("German layout: text is o-umlaut, and dead acute plus a composes", texts[-3:] == ["ö", "", "á"], texts[-3:])
        d.keys("tap", KEY["esc"]) # Close the inspector opened by the A shortcut.
        d.keys("down", KEY["ctrl"], "tap", KEY["q"], "up", KEY["ctrl"])
        press = [e for e in d.trace() if e["kind"] == "press" and e["code"] == KEY["q"]][-1]
        check("Ctrl+Q is not the Q shortcut and carries no text", d.alive() and "C" in press["mods"] and press["text"] == "", press)
        before = d.shot("shift-j-before")
        d.keys("tap", KEY["space"], "w", 400, "tap", KEY["space"], "w", 400, "down", KEY["shift"], "tap", KEY["j"], "up", KEY["shift"])
        press = [e for e in d.trace() if e["kind"] == "press" and e["code"] == KEY["j"]][-1]
        check("Shift+J keeps its identity (shortcut j, text J)", press["shortcut"] == "j" and press["text"] == "J" and "S" in press["mods"], press)
        # Layouts without Latin letters: letter shortcuts have no identity. Falling back to
        # another layout or the physical position is deferred (docs/research/input.md).
        d.keys("layout", "ru", "tap", KEY["q"], "tap", KEY["f8"])
        press = [e for e in d.trace() if e["kind"] == "press" and e["code"] == KEY["q"]][-1]
        check("Russian layout: the Q position types Cyrillic and is not the Q shortcut", d.alive() and press["shortcut"] == "NoSymbol" and press["text"] == "й", press)
        check("Russian layout: F8 still acts", d.wait(lambda s: s["agent_scope"] == "control"))
        d.keys("layout", "ru", "tap", KEY["esc"])
        check("Russian layout: Escape still quits", d.app.wait(timeout=5) == 0)
    finally:
        d.close()

def lifecycle(tree):
    """Keymap replacement and keyboard removal cancel repeat and reset modifiers, without a crash."""
    d = Display(tree, ["--", os.path.join(WORK, "threads")])
    try:
        d.stopped()
        d.keys("layout", "us", "down", KEY["j"], "w", 1200, "layout", "fr", "w", 1200, "up", KEY["j"], "tap", KEY["q"])
        events = d.trace()
        swap = max(i for i, e in enumerate(events) if e["kind"] == "repeat" and e["shortcut"] == "j")
        after = [e for e in events[swap + 1 :] if e["kind"] == "repeat"]
        check("keymap replacement while J is held: repeat ran before and stopped after", swap > 5 and not after, f"{swap} events before the last repeat, {len(after)} repeats after")
        check("the same physical key has the new layout's identity afterwards", events[-2]["code"] == KEY["q"] and events[-2]["shortcut"] == "a" and d.alive(), events[-2])

        mark = len(d.trace())
        d.keys("layout", "us", "down", KEY["shift"], "down", KEY["j"], "w", 1200, "detach", "w", 1500)
        events = d.trace()[mark:]
        last = max(e["t"] for e in events if e["kind"] == "repeat")
        first = min(e["t"] for e in events if e["kind"] == "repeat")
        check("keyboard removed while Shift+J is held: repeat stops", 400 <= last - first <= 900 and d.alive(), f"repeats spanned {last - first} ms of the 2.7 s the helper stayed connected")
        mark = len(d.trace())
        d.keys("layout", "us", "tap", KEY["j"])
        press = [e for e in d.trace()[mark:] if e["kind"] == "press"][-1]
        check("a new keyboard starts with no modifiers held", press["mods"] == "" and press["text"] == "j", press)
        check("no keymap was rejected and nothing was dropped", "dropped" not in d.tail() and d.alive())
    finally:
        d.close()

def cursor(tree):
    """The cursor-shape requests the patch sends; and whether a capture can show the cursor at all."""
    d = Display(tree, TARGET, trace=False, wayland_debug=True, hide_cursor=False)
    try:
        d.stopped()
        d.keys("m", 300, 300, "w", 200)
        d.shot("cursor-default", cursor=True)
        hover = d.keys("m", 300, 300, "m", 614, 300, "w", 1500, wait=False)
        time.sleep(0.8)  # the pointer is now resting on the divider
        with_cursor = d.shot("cursor-divider", cursor=True)
        without_cursor = d.shot("cursor-divider-plain")
        hover.wait(timeout=10)
        d.keys("m", 614, 300, "m", 900, 300, "w", 200)
        log = open(d.log, errors="replace").read()
        shapes = [int(s) for s in re.findall(r"wp_cursor_shape_device_v1#\d+\.set_shape\(\d+, (\d+)\)", log)]
        check("compositor advertises wp_cursor_shape_manager_v1 and the client binds it", "wp_cursor_shape_manager_v1" in log)
        check("default shape on enter, col-resize over the divider, default again after", 30 in shapes and shapes and shapes[0] == 1 and shapes[-1] == 1, shapes)
        check("no protocol error", "error" not in log.lower().replace("stderr", "") and d.alive())
        # Only a capture that changes when the cursor is requested can show what the cursor looks like.
        visible = differs(with_cursor, without_cursor, "96x96+566+252")
        note("cursor appearance", "a cursor image is present in the capture; inspect cursor-divider.png" if visible else "NOT visually verified: the headless compositor's captures contain no cursor image")
        d.keys("tap", KEY["q"])
        check("teardown with a cursor device is clean", d.app.wait(timeout=5) == 0 and "clean shutdown" in open(d.log, errors="replace").read())
    finally:
        d.close()
