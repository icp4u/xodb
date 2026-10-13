#!/usr/bin/env python3
"""Fake-sidecar lifecycle coverage for xodb's persistent Ghidra producer.

The fake speaks the real JSON-line and framed-document protocol. It uses the
owned qx fixture and checked-in adapter export, so completed replies pass the
same identity admission and xsg adapter as a Ghidra reply.
"""
import fcntl
import hashlib
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCER = "ghidra-jvm-sidecar-0.1.0"
CAPS = ["open_image", "decompile", "cancel", "status", "shutdown", "hints", "xsg", "pseudocode"]


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
            set(CAPS) - {"hints"} <= set(reply.get("capabilities", ())))


def serve():
    path = Path(os.environ["XODB_GHIDRA_SOCKET"])
    mode = os.environ.get("FAKE_GHIDRA_MODE", "correct")
    payload = json.loads(Path(os.environ["FAKE_GHIDRA_PAYLOAD"]).read_text())
    payload["producer"].update(kind="ghidra_java_sidecar", worker="XodbGhidraSidecar",
                               worker_version=PRODUCER, java=True)
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
                if verb == "hello":
                    send(conn, {"id": request.get("id"), "state": "ready",
                                "protocol": 999 if mode == "wrong" else 1, "schema": 1,
                                "producer": PRODUCER, "ghidra_version": "fake-owned-fixture",
                                "uid": os.getuid(), "healthy": True, "capabilities": CAPS,
                                "log": os.environ.get("FAKE_GHIDRA_LOG", "fake-sidecar.log")})
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
                    else:
                        send(conn, {"id": request.get("id"), "state": "ready", "progress": "ready"}, encoded)
                elif verb == "status" and mode == "die" and request.get("job") == "fake:die":
                    os.kill(os.getpid(), signal.SIGKILL)
                elif verb == "status" and mode == "hang" and request.get("job") == "fake:hang":
                    send(conn, {"id": request.get("id"), "state": "pending",
                                "job": "fake:hang", "progress": "decompiling"})
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

work = Path(tempfile.mkdtemp(prefix="xodb-ghs-", dir=os.environ.get("XODB_TEST_TMPDIR")))
fixture_dir = work / "qx"
subprocess.run(["sh", "tests/fixtures/semq/build_fixtures.sh", str(fixture_dir)], check=True, timeout=60)
fixture = fixture_dir / "qx-gcc-O2"
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


def client():
    value = Client("observe", str(fixture))
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


# No endpoint: xodb invokes the configured starter and consumes its document.
case = configure("absent")
completed("absent socket starts the sidecar and admits its framed export")
record("absent socket starts one sidecar", (case / "starts").read_text().splitlines() == ["start"])
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
print(f"Summary: {sum(results)}/{len(results)} passed; work {work}")
raise SystemExit(0 if all(results) else 1)
