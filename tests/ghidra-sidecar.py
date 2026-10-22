#!/usr/bin/env python3
"""Fake-sidecar lifecycle coverage for xodb's persistent Ghidra producer.

The fake speaks the real JSON-line and framed-document protocol. It uses the
owned qx fixture and checked-in adapter export, so completed replies pass the
same identity admission and xsg adapter as a Ghidra reply.
"""
import atexit
import ctypes
import fcntl
import hashlib
import json
import os
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCER = "ghidra-jvm-sidecar-0.1.10"
CAPS = ["prime", "open_image", "decompile", "cancel", "status", "shutdown", "hints", "xsg", "pseudocode"]


def exchange(path, request, timeout=2):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        line = client.makefile("rb").readline(1 << 20)
    return json.loads(line)


def expected(reply):
    return (reply.get("state") == "ready" and reply.get("protocol") == 1 and
            reply.get("schema") == 1 and reply.get("producer") == PRODUCER and
            reply.get("uid") == os.getuid() and reply.get("healthy") is True and
            set(CAPS) - {"hints", "prime"} <= set(reply.get("capabilities", ())))


def serve():
    path = Path(os.environ["XODB_GHIDRA_SOCKET"])
    mode = os.environ.get("FAKE_GHIDRA_MODE", "correct")
    payload = json.loads(Path(os.environ["FAKE_GHIDRA_PAYLOAD"]).read_text())
    payload["producer"].update(kind="ghidra_java_sidecar", worker="XodbGhidraSidecar",
                               worker_version=PRODUCER, java=True)
    if mode == "text_only":
        payload["blocks"] = []
    encoded = json.dumps(payload, separators=(",", ":")).encode()
    stop = threading.Event()
    path.parent.mkdir(parents=True, exist_ok=True)
    try: path.unlink()
    except FileNotFoundError: pass
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(16)
    listener.settimeout(.1)

    def send(conn, obj, document=None):
        if document is not None: obj["payload_length"] = len(document)
        conn.sendall(json.dumps(obj, separators=(",", ":")).encode() + b"\n")
        if document is not None: conn.sendall(struct.pack(">Q", len(document)) + document)

    def handle(conn):
        with conn:
            try:
                line = conn.makefile("rb").readline(1 << 20)
                request = json.loads(line)
                verb = request.get("verb")
                requests = os.environ.get("FAKE_GHIDRA_REQUESTS")
                if requests:
                    with open(requests, "a") as log: log.write(json.dumps(request, separators=(",", ":")) + "\n")
                if verb == "hello":
                    send(conn, {"id": request.get("id"), "state": "ready",
                                "protocol": 999 if mode == "wrong" else 1, "schema": 1,
                                "producer": "ghidra-jvm-sidecar-0.1.0" if mode == "old" else PRODUCER, "ghidra_version": "fake-owned-fixture",
                                "uid": os.getuid(), "healthy": True,
                                "capabilities": [cap for cap in CAPS if cap != "prime" or mode != "no_prime"],
                                "log": os.environ.get("FAKE_GHIDRA_LOG", "fake-sidecar.log")})
                    if request.get("id") == "xodb-session":
                        while conn.recv(1): pass
                elif verb == "prime" and mode == "no_prime":
                    send(conn, {"id": request.get("id"), "state": "failed", "code": "unknown_verb", "detail": "prime"})
                elif verb == "prime":
                    send(conn, {"id": request.get("id"), "state": "ready", "progress": "ready"})
                elif verb == "open_image" and mode == "warm_hang" and request.get("id") == "xodb-warm-open":
                    send(conn, {"id": request.get("id"), "state": "pending",
                                "job": "warm:hang", "progress": "analyzing"})
                elif verb == "open_image":
                    try:
                        actual = hashlib.sha256(Path(request["path"]).read_bytes()).hexdigest()
                    except OSError as error:
                        send(conn, {"id": request.get("id"), "state": "failed",
                                    "code": "image_unreadable", "detail": str(error)})
                    else:
                        if actual != request.get("sha256"):
                            send(conn, {"id": request.get("id"), "state": "failed",
                                        "code": "image_identity_mismatch", "detail": actual})
                        else:
                            send(conn, {"id": request.get("id"), "state": "ready", "progress": "ready"})
                elif verb == "decompile":
                    if mode in ("die", "hang"):
                        send(conn, {"id": request.get("id"), "state": "pending",
                                    "job": "fake:" + mode, "progress": "decompiling"})
                    elif mode == "warm_decompile_hang" and request.get("background") is True:
                        send(conn, {"id": request.get("id"), "state": "pending",
                                    "job": "warm-decompile:" + str(request.get("entry")), "progress": "decompiling"})
                    else:
                        send(conn, {"id": request.get("id"), "state": "ready", "progress": "ready"}, encoded)
                elif verb == "status" and mode == "die" and request.get("job") == "fake:die":
                    os.kill(os.getpid(), signal.SIGKILL)
                elif verb == "status" and mode == "hang" and request.get("job") == "fake:hang":
                    send(conn, {"id": request.get("id"), "state": "pending",
                                "job": "fake:hang", "progress": "decompiling"})
                elif verb == "status" and mode == "warm_hang" and request.get("job") == "warm:hang":
                    send(conn, {"id": request.get("id"), "state": "pending",
                                "job": "warm:hang", "progress": "analyzing"})
                elif verb == "status" and mode == "warm_decompile_hang" and str(request.get("job", "")).startswith("warm-decompile:"):
                    send(conn, {"id": request.get("id"), "state": "pending",
                                "job": request.get("job"), "progress": "decompiling"})
                elif verb == "status":
                    send(conn, {"id": request.get("id"), "state": "ready", "healthy": True,
                                "heap_used": 0, "images_open": 1, "queue": 0})
                elif verb == "cancel":
                    marker = os.environ.get("FAKE_GHIDRA_CANCELLED")
                    if marker: Path(marker).write_text(str(request.get("job")))
                    send(conn, {"id": request.get("id"), "state": "ready"})
                elif verb == "shutdown":
                    send(conn, {"id": request.get("id"), "state": "ready"})
                    stop.set()
                else:
                    send(conn, {"id": request.get("id"), "state": "failed",
                                "code": "unknown_verb", "detail": str(verb)})
            except (BrokenPipeError, ConnectionError, ValueError):
                pass

    try:
        while not stop.is_set():
            try: conn, _ = listener.accept()
            except socket.timeout: continue
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    finally:
        listener.close()
        try: path.unlink()
        except FileNotFoundError: pass


def fake_start():
    if os.environ.get("FAKE_GHIDRA_MODE") == "start_fail":
        raise SystemExit(1)
    path = Path(os.environ["XODB_GHIDRA_SOCKET"])
    lock_path = Path(str(path) + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if expected(exchange(path, {"id": "start", "verb": "hello"})):
                return
        except (OSError, ValueError):
            pass
        try: exchange(path, {"id": "replace", "verb": "shutdown"})
        except (OSError, ValueError): pass
        for _ in range(50):
            if not path.exists(): break
            time.sleep(.01)
        if path.exists(): path.unlink()
        with Path(os.environ["FAKE_GHIDRA_COUNT"]).open("a") as count:
            count.write("start\n")
        manager = os.environ.get("FAKE_GHIDRA_MANAGER")
        if manager:
            with socket.socket(socket.AF_UNIX) as control:
                control.connect(manager)
                launch_env = {key: value for key, value in os.environ.items()
                              if key.startswith("XODB_GHIDRA_") or key.startswith("FAKE_GHIDRA_")}
                control.sendall(json.dumps(launch_env, separators=(",", ":")).encode() + b"\n")
                process_pid = int(control.makefile("rb").readline())
        else:
            process = subprocess.Popen([sys.executable, __file__, "serve"], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True, close_fds=True)
            process_pid = process.pid
        Path(os.environ["FAKE_GHIDRA_PID"]).write_text(str(process_pid))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                reply = exchange(path, {"id": "wait", "verb": "hello"}, .2)
                if reply.get("state") == "ready": return
            except (OSError, ValueError): pass
            time.sleep(.02)
        raise SystemExit("fake sidecar did not start")


if len(sys.argv) == 2 and sys.argv[1] == "serve":
    serve(); raise SystemExit()
if len(sys.argv) == 2 and sys.argv[1] == "start":
    fake_start(); raise SystemExit()

os.chdir(ROOT)
sys.path.insert(0, str(ROOT / "tests"))
from client import Client

# Launch prestart is detached. Adopt its short-lived starter so this test,
# rather than the release runner, reaps every process that it creates.
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER

# A native worker in the caller's environment would answer the cases below that
# expect a typed sidecar failure; the fallback case passes its own explicitly.
os.environ.pop("XODB_STATIC_ANALYSIS", None)
work = Path(tempfile.mkdtemp(prefix="xodb-ghs-", dir=os.environ.get("XODB_TEST_TMPDIR")))
atexit.register(shutil.rmtree, work, True)
fixture_dir = work / "qx"
subprocess.run(["sh", "tests/fixtures/semq/build_fixtures.sh", str(fixture_dir)], check=True, timeout=60)
fixture = fixture_dir / "qx-gcc-O2"
fixture_sha256 = hashlib.sha256(fixture.read_bytes()).hexdigest()
if '--wrong-image-identity' in sys.argv:
    fixture_sha256 = '0' * 64


def fixture_request(request):
    """Remote imports name a host snapshot, not the target's filesystem path.

    Check both the claimed identity and the actual bytes admitted by the sidecar.
    The fake server independently validates open_image's digest as well.
    """
    if request.get('sha256') != fixture_sha256:
        return False
    try:
        return hashlib.sha256(Path(request['path']).read_bytes()).hexdigest() == fixture_sha256
    except (OSError, KeyError):
        return False


# The same bytes at another path match; a same-size wrong image does not, even
# when it claims the fixture's digest. --wrong-image-identity plants a bad oracle.
copy = work / 'image-copy'
copy.write_bytes(fixture.read_bytes())
assert fixture_request(dict(path=str(copy), sha256=fixture_sha256)), 'renamed image identity'
wrong = bytearray(copy.read_bytes()); wrong[0] ^= 1
copy.write_bytes(wrong)
assert not fixture_request(dict(path=str(copy), sha256=fixture_sha256)), 'wrong image admitted'
copy.unlink()
payload = ROOT / "src/semq/adapter_fixture.json"
results = []
managed_processes = []
manager_path = work / "manager.s"
manager_stop = threading.Event()
manager_socket = socket.socket(socket.AF_UNIX)
manager_socket.bind(str(manager_path)); manager_socket.listen(8); manager_socket.settimeout(.1)

def manage_servers():
    while not manager_stop.is_set():
        try: connection, _ = manager_socket.accept()
        except socket.timeout: continue
        with connection:
            launch_env = json.loads(connection.makefile("rb").readline(1 << 20))
            env = dict(os.environ); env.update(launch_env)
            process = subprocess.Popen([sys.executable, __file__, "serve"], env=env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, close_fds=True)
            managed_processes.append(process)
            connection.sendall(f"{process.pid}\n".encode())
manager_thread = threading.Thread(target=manage_servers, daemon=True); manager_thread.start()
os.environ["FAKE_GHIDRA_MANAGER"] = str(manager_path)


def record(case, ok, detail=""):
    results.append(ok)
    print(f'{"pass" if ok else "fail":5} {case}' + ("" if ok or not detail else f": {str(detail)[:500]}"), flush=True)


def tool(client, name, **args):
    response = client.call("tools/call", {"name": name, "arguments": args})
    if "error" in response: return {"_protocol_error": response["error"]["message"]}
    result = response["result"]
    if result.get("isError"): return {"_error": result["content"][0]["text"]}
    return result["structuredContent"]


def wait_stopped(client):
    for _ in range(200):
        value = tool(client, "get_session")
        if value.get("state") == "stopped": return
        time.sleep(.02)
    raise AssertionError("fixture did not stop")


def poll_decompile(client, retry=False):
    args = {"symbol": "qx_alloc"}
    if retry: args["retry"] = True
    deadline = time.monotonic() + 10
    while True:
        value = tool(client, "decompile_function", **args)
        if value.get("status") != "running" or time.monotonic() > deadline: return value
        time.sleep(.03)


def client(options=(), scope="observe"):
    value = Client(scope, str(fixture), options=options)
    wait_stopped(value)
    return value


def close(value):
    value.p.stdin.close()
    value.p.wait(timeout=10)


def configure(name, mode="correct"):
    case = work / name
    case.mkdir()
    os.environ.update(XDG_RUNTIME_DIR=str(case), XODB_GHIDRA_SOCKET=str(case / ".xodb.ghidra.s"),
                      XODB_GHIDRA_SIDECAR=str(Path(__file__).resolve()), XODB_GHIDRA_HOME="fake",
                      FAKE_GHIDRA_MODE=mode, FAKE_GHIDRA_PAYLOAD=str(payload),
                      FAKE_GHIDRA_COUNT=str(case / "starts"), FAKE_GHIDRA_PID=str(case / "pid"),
                      FAKE_GHIDRA_CANCELLED=str(case / "cancelled"), FAKE_GHIDRA_LOG=str(case / "sidecar.log"))
    os.environ["FAKE_GHIDRA_REQUESTS"] = str(case / "requests")
    return case


def stop_server():
    path = os.environ["XODB_GHIDRA_SOCKET"]
    try: exchange(path, {"id": "stop", "verb": "shutdown"})
    except (OSError, ValueError): pass
    for _ in range(100):
        if not Path(path).exists(): return
        time.sleep(.01)


def completed(case):
    value = client()
    try:
        result = poll_decompile(value)
        record(case, result.get("status") == "completed" and
               result.get("producer", {}).get("name") == "ghidra_java_sidecar" and
               "qx_alloc" in result.get("signature", ""), result)
    finally: close(value)


# No endpoint: xodb starts at launch, imports the mapped executable, warms real
# stack functions, then consumes the same sidecar's document.
case = configure("absent")
value = client()
deadline = time.monotonic() + 10
requests = []
while time.monotonic() < deadline:
    requests = [json.loads(line) for line in (case / "requests").read_text().splitlines()] if (case / "requests").exists() else []
    verbs = [request.get("verb") for request in requests]
    if "open_image" in verbs: break
    time.sleep(.02)
record("configured sidecar starts before the first decompile request", (case / "starts").exists() and
       (case / "starts").read_text().splitlines() == ["start"])
record("throwaway priming is replaced by real-function warm-ahead",
       not any(request.get("verb") == "prime" for request in requests), requests)
record("the mapped executable is imported before pseudo-C is requested", any(request.get("verb") == "open_image" and
       fixture_request(request) for request in requests), requests)
record("eager imports are marked as background work", any(request.get("id") == "xodb-warm-open" and
       request.get("background") is True for request in requests), requests)
try:
    result = poll_decompile(value)
    record("launch-warmed sidecar admits its framed export", result.get("status") == "completed" and
           result.get("producer", {}).get("name") == "ghidra_java_sidecar" and "qx_alloc" in result.get("signature", ""), result)
finally: close(value)
record("absent socket starts one sidecar", (case / "starts").read_text().splitlines() == ["start"])
stop_server()

# The CLI opt-out suppresses both launch and target warmup, while an explicit
# pseudo-C request retains the on-demand behavior.
case = configure("prestart-off")
value = client(("--no-ghidra-prestart",))
record("--no-ghidra-prestart leaves the sidecar idle", not (case / "starts").exists())
try:
    result = poll_decompile(value)
    record("prestart opt-out keeps on-demand pseudo-C", result.get("status") == "completed", result)
finally: close(value)
stop_server()

# The eager byte preference always admits the main executable but leaves every
# library to an explicit stop/request when the bound is zero.
case = configure("eager-bound")
preferences = case / "preferences.json"
preferences.write_text('{"decompiler":{"eager_library_bytes":0}}\n')
value = client(("--config", str(preferences)))
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    requests = [json.loads(line) for line in (case / "requests").read_text().splitlines()] if (case / "requests").exists() else []
    if any(request.get("verb") == "decompile" and request.get("background") is True for request in requests): break
    tool(value, "get_session")
    time.sleep(.02)
opened = [request for request in requests
          if request.get("verb") == "open_image" and request.get("background") is True]
record("eager library byte bound keeps the main image eligible and skips libraries",
       opened and all(fixture_request(request) for request in opened), opened)
warm_images = [request for request in requests
              if request.get("background") is True and request.get("verb") in ("open_image", "decompile")]
record("outer stack frames cannot bypass the eager library bound",
       warm_images and all(fixture_request(request) for request in warm_images), warm_images)
close(value)
stop_server()

# Stops produced by a tight instruction-step loop do not start background work.
# The final stop remains eligible once it has been stable for the debounce.
case = configure("warm-step-delay")
value = client(scope="control")
value.action("set_breakpoint", symbol="qx_alloc")
value.continue_initial_stop()
value.stopped("breakpoint")
time.sleep(.3)
(case / "requests").write_text("")
for _ in range(3):
    state = tool(value, "get_session")
    tid = next(thread["tid"] for thread in state["threads"] if thread["state"] == "stopped")
    value.action("step_instruction", tid=tid)
    value.stopped("single_step")
fast_requests = [json.loads(line) for line in (case / "requests").read_text().splitlines()]
fast_background = [request for request in fast_requests if request.get("background") is True]
record("fast instruction steps do not start warm-ahead", not fast_background, fast_background)
deadline = time.monotonic() + 2
while time.monotonic() < deadline:
    tool(value, "get_session")
    logged = [json.loads(line) for line in (case / "requests").read_text().splitlines()]
    if any(request.get("background") is True for request in logged): break
    time.sleep(.02)
record("a stable stop becomes eligible for warm-ahead after the delay",
       any(request.get("background") is True for request in logged), logged)
close(value)
stop_server()

# Pseudo-C survives an adapter refusal; graph-only queries carry the reason.
case = configure("text-only", "text_only")
value = client()
try:
    result = poll_decompile(value)
    graph = result.get("graph", {})
    record("refused graph still returns pseudo-C with its typed reason",
           result.get("status") == "completed" and "qx_alloc" in result.get("text", "") and
           graph.get("available") is False and graph.get("reason") == "adapter_refused", result)
    analysis = tool(value, "analyze_function", symbol="qx_alloc")
    record("graph queries report graph_unavailable without discarding text",
           analysis.get("status") == "graph_unavailable" and analysis.get("decompile_available") is True and
           analysis.get("reason") == "adapter_refused", analysis)
finally: close(value)
stop_server()

# A sidecar without the optional compatibility prime capability keeps serving,
# and images are still imported ahead of the request.
case = configure("no-prime", "no_prime")
value = client()
deadline = time.monotonic() + 10
requests = []
while time.monotonic() < deadline:
    requests = [json.loads(line) for line in (case / "requests").read_text().splitlines()] if (case / "requests").exists() else []
    if any(request.get("verb") == "open_image" for request in requests): break
    time.sleep(.02)
try:
    result = poll_decompile(value)
    record("a sidecar without prime is kept and still imports and answers", result.get("status") == "completed" and
           (case / "starts").read_text().splitlines() == ["start"] and
           any(request.get("verb") == "open_image" for request in requests) and
           not any(request.get("verb") == "prime" for request in requests), requests)
finally: close(value)
stop_server()

# An interactive request cancels a background image analysis before entering
# the sidecar's single Ghidra queue.
case = configure("warm-cancel", "warm_hang")
value = client()
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    if (case / "requests").exists() and any(json.loads(line).get("job") == "warm:hang" for line in (case / "requests").read_text().splitlines()): break
    time.sleep(.02)
try:
    result = poll_decompile(value)
    for _ in range(20):
        tool(value, "get_session")
        time.sleep(.03)
    logged = [json.loads(line) for line in (case / "requests").read_text().splitlines()]
    eager_opens = [request for request in logged if request.get("id") == "xodb-warm-open" and
                   fixture_request(request)]
    record("interactive pseudo-C cancels queued background import", result.get("status") == "completed" and
           (case / "cancelled").exists() and (case / "cancelled").read_text() == "warm:hang", result)
    record("a cancelled import backs off instead of restarting after each foreground poll",
           len(eager_opens) == 1, eager_opens)
finally: close(value)
stop_server()

# Resume cancels low-priority function warm-ahead. The queue is hard bounded
# even when the fake keeps the first warm decompile pending.
case = configure("warm-resume", "warm_decompile_hang")
value = client(scope="control")
value.action("set_breakpoint", symbol="qx_alloc")
value.continue_initial_stop()
value.stopped("breakpoint")
deadline = time.monotonic() + 10
warm_requests = []
warm_pending = False
while time.monotonic() < deadline:
    if (case / "requests").exists():
        logged = [json.loads(line) for line in (case / "requests").read_text().splitlines()]
        warm_requests = [request for request in logged if request.get("verb") == "decompile" and request.get("background") is True]
        # Receipt of decompile is earlier than the client's adoption of the
        # pending job ID. Witness its first status poll before testing cancel.
        warm_pending = any(request.get("verb") == "status" and
                           str(request.get("job", "")).startswith("warm-decompile:")
                           for request in logged)
        if warm_requests and warm_pending: break
    time.sleep(.02)
record("warm-ahead queues stack functions at low priority within the hard bound",
       0 < len(warm_requests) <= 16 and warm_pending, warm_requests)
value.action("continue")
deadline = time.monotonic() + 5
while time.monotonic() < deadline and not (case / "cancelled").exists(): time.sleep(.02)
record("resume cancels a pending warm decompile without waiting on the owner path",
       (case / "cancelled").exists() and (case / "cancelled").read_text().startswith("warm-decompile:"))
close(value)
stop_server()

# A refused-connect Unix socket file is replaced under the starter lock.
case = configure("stale")
stale = socket.socket(socket.AF_UNIX); stale.bind(os.environ["XODB_GHIDRA_SOCKET"]); stale.close()
os.chmod(os.environ["XODB_GHIDRA_SOCKET"], 0o600)
completed("stale socket is replaced")
record("stale socket starts one sidecar", (case / "starts").read_text().splitlines() == ["start"])
stop_server()

# An answering older protocol is shut down and replaced once.
case = configure("wrong-replaced", "wrong")
fake_start()
os.environ["FAKE_GHIDRA_MODE"] = "correct"
completed("wrong hello is replaced once by the expected protocol")
record("wrong hello replacement adds exactly one process", len((case / "starts").read_text().splitlines()) == 2)
stop_server()

# An installed xodb may see an old shared sidecar without having its starter
# installed. Name both versions and the searched locations once; never dump the
# hello document on repeated startup paths.
case = configure("old-no-starter", "old")
fake_start()
isolated = case / "installed/bin/xodb"
isolated.parent.mkdir(parents=True)
shutil.copy2(os.environ.get("XODB_BIN", ROOT / "zig-out/bin/xodb"), isolated)
saved_bin, saved_log, saved_starter = os.environ.get("XODB_BIN"), os.environ.get("XODB_LOG"), os.environ["XODB_GHIDRA_SIDECAR"]
os.environ.update(XODB_BIN=str(isolated), XODB_LOG="debug", XODB_GHIDRA_SIDECAR=str(case / "missing-starter"))
value = client()
for _ in range(40):  # about one second of owner polls with the target stopped
    tool(value, "get_session")
    time.sleep(.025)
close(value)
diagnostics = value.p.stderr.read().decode()
line = "running sidecar is 0.1.0, this xodb needs 0.1.10"
logged = [json.loads(entry) for entry in (case / "requests").read_text().splitlines()] if (case / "requests").exists() else []
hellos = [entry for entry in logged if entry.get("verb") == "hello"]
record("an incompatible sidecar is not asked again on every owner poll", len(hellos) <= 4, len(hellos))
record("old sidecar without a starter has one concise version diagnostic",
       diagnostics.count(line) == 1 and "no starter found to replace it (looked in " in diagnostics and '"capabilities"' not in diagnostics,
       diagnostics)
if saved_bin is None: os.environ.pop("XODB_BIN", None)
else: os.environ["XODB_BIN"] = saved_bin
if saved_log is None: os.environ.pop("XODB_LOG", None)
else: os.environ["XODB_LOG"] = saved_log
os.environ["XODB_GHIDRA_SIDECAR"] = saved_starter
stop_server()

# If the replacement is still wrong, the job reports the exact protocol gate.
case = configure("wrong-gated", "wrong")
fake_start()
value = client()
try:
    result = poll_decompile(value)
    failure = result.get("job", {}).get("failure", {})
    record("wrong hello after one restart is a typed gate",
           result.get("status") == "failed" and failure.get("code") == "sidecar_protocol_mismatch" and
           "expected protocol 1" in failure.get("detail", "") and "after one restart" in failure.get("detail", ""), result)
    record("xodb remains usable after protocol gate", tool(value, "get_session").get("state") == "stopped")
finally: close(value)
stop_server()

# Two independent xodbs race through one flock and share the resulting server.
case = configure("race")
clients = [client(), client()]
answers = [None, None]
def request(index): answers[index] = poll_decompile(clients[index])
threads = [threading.Thread(target=request, args=(i,)) for i in range(2)]
for thread in threads: thread.start()
for thread in threads: thread.join(15)
record("two clients racing to start both complete", all(a and a.get("status") == "completed" for a in answers), answers)
record("two clients racing share one sidecar", (case / "starts").read_text().splitlines() == ["start"])
for value in clients: close(value)
stop_server()

# Cancelling the xodb job forwards a best-effort cancel for the sidecar job.
case = configure("cancel", "hang")
value = client()
try:
    first = tool(value, "decompile_function", symbol="qx_alloc")
    assert first.get("status") == "running", first
    # Cancel only once the sidecar holds a pending job; cancelling while the
    # starter still runs is also valid but has no sidecar job to reach.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        seen = tool(value, "decompile_function", symbol="qx_alloc")
        if seen.get("status") != "running" or seen.get("job", {}).get("progress") == "decompiling": break
        time.sleep(.02)
    cancelled = tool(value, "cancel_static_analysis", job_id=first["job"]["id"])
    result = poll_decompile(value)
    failure = result.get("job", {}).get("failure", {})
    record("cancel reaches a pending sidecar job", result.get("status") == "cancelled" and
           failure.get("code") == "cancelled" and (case / "cancelled").exists() and
           (case / "cancelled").read_text() == "fake:hang", result)
finally: close(value)
stop_server()

# A selected sidecar that cannot start falls back in the same x86-64 request
# to the configured native worker, and the response names that producer.
def native_toolchain():
    directory = work / "native-fallback"
    (directory / "ghidra-src/Ghidra/Processors/x86/data/languages").mkdir(parents=True)
    (directory / "ghidra-src/Ghidra/Processors/x86/data/languages/x86-64.sla").write_text("placeholder\n")
    subprocess.run(["cc", "-std=c11", "-O2", "-D_GNU_SOURCE", "-o", str(directory / "ghx_supervise"),
                    "tools/ghx/ghx_supervise.c"], check=True, timeout=60)
    worker = directory / "ghx_worker"
    worker.write_text("#!/usr/bin/env python3\n" +
                      "import sys\nfrom pathlib import Path\n" +
                      f"payload=Path({str(payload)!r}).read_bytes()\n" +
                      "for line in sys.stdin.buffer:\n"
                      " if line == b'HELLO\\n':\n"
                      "  sys.stdout.write('HELLO\\tprotocol=1\\tproducer=ghx_worker/0.4.2\\tschema=xodb.ghidra.function_graph/0.4.1\\tcapabilities=decompile,function_map,immutable_snapshot,strict_bounds\\n'); sys.stdout.flush(); continue\n"
                      " ident=next((field[3:] for field in line.decode().strip().split('\\t') if field.startswith('id=')),'f')\n"
                      " sys.stdout.buffer.write(f'RESULT\\tid={ident}\\tstatus=ok\\tbytes={len(payload)}\\n'.encode()+payload)\n"
                      " sys.stdout.buffer.flush()\n")
    worker.chmod(0o755)
    return directory

case = configure("native-fallback", "start_fail")
value = client(("--static-analysis", str(native_toolchain())))
try:
    result = poll_decompile(value)
    record("sidecar startup failure falls back to the native worker",
           result.get("status") == "completed" and result.get("producer", {}).get("name") == "ghidra_native_decompiler" and
           "qx_alloc" in result.get("text", ""), result)
finally: close(value)

# A process death between a pending reply and status is typed; debugger lives.
configure("dies", "die")
value = client()
try:
    result = poll_decompile(value)
    failure = result.get("job", {}).get("failure", {})
    record("sidecar killed mid-request is typed", result.get("status") == "failed" and
           failure.get("code") == "sidecar_died", result)
    record("xodb remains usable after sidecar death", tool(value, "get_session").get("state") == "stopped")
finally: close(value)

manager_stop.set(); manager_thread.join(2); manager_socket.close()
for process in managed_processes:
    try: process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.terminate(); process.wait(timeout=2)
deadline = time.monotonic() + 5
while True:
    try:
        pid, _ = os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        break
    if pid > 0:
        continue
    if time.monotonic() >= deadline:
        raise AssertionError("a detached fake-sidecar starter is still running")
    time.sleep(.02)
print(f"Summary: {sum(results)}/{len(results)} passed; work {work}")
raise SystemExit(0 if all(results) else 1)
