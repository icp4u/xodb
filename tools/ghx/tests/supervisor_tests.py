#!/usr/bin/env python3
"""ghx_supervise contract tests with fake workers (C01-R2, GPLv3).

usage: supervisor_tests.py SUPERVISE SCRATCH OUT.json [REAL_WORKER SLEIGHHOME ELF]

The fake workers isolate the supervisor protocol; they do not run Ghidra.
Covers the three review reproductions (publication into an existing
directory, stdout-close-then-sleep against a 100 ms deadline) plus existing
artifact preservation, stalled/blocked I/O, TERM-ignoring workers,
cancellation, restart, output limits, process-group cleanup and, when a real
worker is given, the allocation limit.  Every test checks that no worker or
grandchild it caused is left alive.  Writes per-test JSON with timings.
"""
import json
import os
import signal
import subprocess
import sys
import time

SUP, SCRATCH, OUT = sys.argv[1:4]
REAL = sys.argv[4:7] if len(sys.argv) >= 7 else None
PY = sys.executable
GRACE = 250
SLACK_MS = 600  # interpreter/process start-up allowance for the external wall clock
os.umask(0o022)
os.makedirs(SCRATCH, exist_ok=True)
os.chmod(SCRATCH, 0o755)
SNAPROOT = os.path.join(SCRATCH, "snaps")
os.makedirs(SNAPROOT, exist_ok=True)
ELF = os.path.join(SCRATCH, "dummy.elf")
with open(ELF, "wb") as f:
    f.write(b"\x7fELF" + bytes(124))

HEAD = "#!%s\nimport os, sys, time, signal\n" % PY
WORKERS = {
    # valid reply for every request (the review's worker-ok.py)
    "ok": """
for line in sys.stdin:
    if line.startswith('QUIT'): break
    f = dict(s.split('=', 1) for s in line.rstrip('\\n').split('\\t')[1:])
    if f['id'].startswith('slow'):
        time.sleep(30)
    body = b'{"status":"ok"}'
    sys.stdout.buffer.write(('RESULT\\tid=%s\\tstatus=ok\\tbytes=%d\\n' % (f['id'], len(body))).encode() + body)
    sys.stdout.buffer.flush()
""",
    # the review's worker-close-stdout.py
    "close_stdout": """
sys.stdin.readline()
os.close(1)
time.sleep(2)
""",
    "silent": """
sys.stdin.readline()
time.sleep(30)
""",
    "never_read": """
time.sleep(30)
""",
    "stall_after_header": """
line = sys.stdin.readline()
f = dict(s.split('=', 1) for s in line.rstrip('\\n').split('\\t')[1:])
sys.stdout.write('RESULT\\tid=%s\\tstatus=ok\\tbytes=1000\\n' % f['id'])
sys.stdout.write('{"partial":')
sys.stdout.flush()
time.sleep(30)
""",
    "term_ignoring": """
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.stdin.readline()
open(os.environ.get('GHX_TEST_PIDFILE', '/dev/null'), 'a').write('%d\\n' % os.getpid())
while True:
    time.sleep(1)
""",
    "huge": """
line = sys.stdin.readline()
f = dict(s.split('=', 1) for s in line.rstrip('\\n').split('\\t')[1:])
sys.stdout.write('RESULT\\tid=%s\\tstatus=ok\\tbytes=1000000000000\\n' % f['id'])
sys.stdout.flush()
time.sleep(30)
""",
    "garbage": """
sys.stdin.readline()
sys.stdout.write('HELLO\\n')
sys.stdout.flush()
time.sleep(30)
""",
    "crash": """
sys.stdin.readline()
os.abort()
""",
    # forks a grandchild that keeps stdout open, then hangs
    "grandchild": """
sys.stdin.readline()
pid = os.fork()
if pid == 0:
    time.sleep(30)
    os._exit(0)
open(os.environ['GHX_TEST_PIDFILE'], 'w').write('%d\\n' % pid)
time.sleep(30)
""",
}
paths = {}
for name, body in WORKERS.items():
    p = os.path.join(SCRATCH, "worker-%s.py" % name)
    with open(p, "w") as f:
        f.write(HEAD + body)
    os.chmod(p, 0o755)
    paths[name] = p

results = []


def alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            state = f.read().rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except OSError:
        return False


def req(rid, elf=ELF, extra=""):
    return "DECOMPILE\tid=%s\telf=%s\tentry=0x400000%s\n" % (rid, elf, extra)


def run(worker, outdir, stdin_lines, t=100, extra_args=(), feed=None, env=None, term_after=None):
    """Run the supervisor; feed is a list of (delay_s, line) written later."""
    args = [SUP, "-w", worker, "-s", SCRATCH, "-o", outdir, "-t", str(t), "-g", str(GRACE),
            "-S", SNAPROOT] + list(extra_args)
    start = time.monotonic()
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env)
    p.stdin.write("".join(stdin_lines).encode())
    p.stdin.flush()
    for delay, line in feed or []:
        time.sleep(delay)
        p.stdin.write(line.encode())
        p.stdin.flush()
    if term_after is not None:
        time.sleep(term_after)
        p.send_signal(signal.SIGTERM)
    try:
        p.stdin.close()
    except BrokenPipeError:
        pass
    try:
        so, se = p.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
        so, se = p.communicate()
        raise AssertionError("supervisor did not finish within 60 s")
    wall = (time.monotonic() - start) * 1000
    lines = so.decode().splitlines()
    res = [dict(kv.split("=", 1) for kv in l.split("\t")[1:]) for l in lines if l.startswith("RESULT\t")]
    wpids = [int(dict(kv.split("=", 1) for kv in l.split("\t")[1:])["pid"]) for l in lines if l.startswith("WORKER\t")]
    return dict(rc=p.returncode, wall_ms=round(wall, 1), results=res, lines=lines, stderr=se.decode(),
                worker_pids=sorted(set(wpids)))


def test(name):
    def deco(fn):
        outdir = os.path.join(SCRATCH, name)
        rec = {"name": name}
        try:
            info = fn(outdir) or {}
            rec.update(info)
            rec["outcome"] = "pass"
        except AssertionError as e:
            rec["outcome"] = "fail"
            rec["error"] = str(e)
        except Exception as e:  # harness failure is a failure, never a skip
            rec["outcome"] = "fail"
            rec["error"] = "%s: %s" % (type(e).__name__, e)
        print("%s %s %s" % (rec["outcome"].upper(), name, rec.get("error", "")))
        results.append(rec)
        return fn
    return deco


def no_leftovers(r, extra_pids=()):
    time.sleep(0.05)
    live = [p for p in list(r["worker_pids"]) + list(extra_pids) if alive(p)]
    assert not live, "owned processes still alive: %s" % live
    left = os.listdir(SNAPROOT)
    assert not left, "spec snapshot directories left behind: %s" % left


def bounded(r, t):
    res = r["results"][0]
    ms, over = float(res["ms"]), float(res["overshoot_ms"])
    assert over <= GRACE, "overshoot %.1f ms exceeds cleanup allowance %d ms" % (over, GRACE)
    assert r["wall_ms"] <= t + GRACE + SLACK_MS, "wall %.1f ms exceeds %d+%d+%d" % (r["wall_ms"], t, GRACE, SLACK_MS)
    return dict(timeout_ms=t, grace_ms=GRACE, result_ms=ms, overshoot_ms=over,
                cleanup_ms=float(res["cleanup_ms"]), wall_ms=r["wall_ms"])


@test("review_b_publish_into_directory")
def _(outdir):
    os.makedirs(os.path.join(outdir, "repro.json"))
    r = run(paths["ok"], outdir, [req("repro")])
    res = r["results"][0]
    assert res["status"] == "publish_failed", res
    assert res["worker_status"] == "ok" and res["file"] == "", res
    assert r["rc"] == 4, "exit %d" % r["rc"]
    assert os.path.isdir(os.path.join(outdir, "repro.json"))
    rec = [json.loads(l) for l in open(os.path.join(outdir, "results.jsonl"))]
    assert rec[-1]["status"] == "publish_failed", rec
    no_leftovers(r)
    return dict(rc=r["rc"], status=res["status"])


@test("existing_regular_artifact_preserved")
def _(outdir):
    os.makedirs(outdir)
    prior = os.path.join(outdir, "repro.json")
    with open(prior, "w") as f:
        f.write("PRIOR ARTIFACT\n")
    r = run(paths["ok"], outdir, [req("repro")])
    assert r["results"][0]["status"] == "publish_failed" and r["rc"] == 4, r["results"]
    assert open(prior).read() == "PRIOR ARTIFACT\n", "existing artifact replaced"
    assert not [n for n in os.listdir(outdir) if n.endswith(".tmp")], "temporary left behind"
    no_leftovers(r)


@test("second_session_does_not_replace")
def _(outdir):
    r1 = run(paths["ok"], outdir, [req("a1")])
    assert r1["rc"] == 0 and r1["results"][0]["status"] == "ok", r1["results"]
    before = open(os.path.join(outdir, "a1.json"), "rb").read()
    r2 = run(paths["ok"], outdir, [req("a1"), req("a2")])
    st = {x["id"]: x["status"] for x in r2["results"]}
    assert st == {"a1": "publish_failed", "a2": "ok"}, st
    assert r2["rc"] == 4
    assert open(os.path.join(outdir, "a1.json"), "rb").read() == before
    no_leftovers(r2)


def run_bounded(outdir, limit_s=5):
    """Supervisor start-up with a hard external bound (no 60 s wait)."""
    args = [SUP, "-w", paths["ok"], "-s", SCRATCH, "-o", outdir, "-t", "1000", "-g", str(GRACE), "-S", SNAPROOT]
    start = time.monotonic()
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        so, se = p.communicate(req("f1").encode(), timeout=limit_s)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise AssertionError("supervisor still blocked after %d s" % limit_s)
    return p.returncode, (time.monotonic() - start) * 1000, so.decode(), se.decode()


# C03-R2 D4 (PC2): an existing non-regular results.jsonl / worker-stderr.log
# must be refused with exit 2 before any work, never opened blocking.
for _log in ("results.jsonl", "worker-stderr.log"):
    for _reader in (False, True):
        @test("log_fifo_refused_%s%s" % (_log.split(".")[0].replace("-", "_"), "_with_reader" if _reader else ""))
        def _(outdir, log=_log, reader=_reader):
            os.makedirs(outdir)
            fifo = os.path.join(outdir, log)
            os.mkfifo(fifo, 0o644)
            rfd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK) if reader else -1
            try:
                rc, ms, so, se = run_bounded(outdir)
            finally:
                if rfd >= 0:
                    os.close(rfd)
            assert rc == 2, "exit %d (stderr %r)" % (rc, se)
            assert "RESULT" not in so and "WORKER" not in so, so
            assert log in se, se
            assert not os.path.exists(os.path.join(outdir, "f1.json"))
            return dict(rc=rc, ms=round(ms, 1))


@test("review_c_stdout_close_then_sleep")
def _(outdir):
    # The review's exact command: under host load the worker's interpreter may
    # not even start within 100 ms, so timeout is as valid as worker_died; the
    # property is bounded completion with the child reaped.
    r = run(paths["close_stdout"], outdir, [req("repro")], t=100)
    res = r["results"][0]
    assert res["status"] in ("worker_died", "timeout"), res
    assert r["rc"] == 0
    assert any("event=killed" in l and "reap=done" in l for l in r["lines"]), r["lines"]
    info = bounded(r, 100)
    no_leftovers(r)
    return info


@test("stdout_eof_path_does_not_wait_for_exit")
def _(outdir):
    # Deterministic EOF path: a 5 s deadline, a worker that closes stdout and
    # lives 2 s more.  The original supervisor blocked in waitpid for ~2 s.
    r = run(paths["close_stdout"], outdir, [req("eof")], t=5000)
    res = r["results"][0]
    assert res["status"] == "worker_died", res
    assert r["wall_ms"] < 1500, "EOF handling waited for the worker: %.1f ms" % r["wall_ms"]
    assert any("event=killed" in l and "reap=done" in l for l in r["lines"]), r["lines"]
    no_leftovers(r)
    return dict(timeout_ms=5000, grace_ms=GRACE, result_ms=float(res["ms"]), overshoot_ms=float(res["overshoot_ms"]),
                cleanup_ms=float(res["cleanup_ms"]), wall_ms=r["wall_ms"])


@test("stall_after_header_times_out")
def _(outdir):
    r = run(paths["stall_after_header"], outdir, [req("s1")], t=300)
    assert r["results"][0]["status"] == "timeout", r["results"]
    info = bounded(r, 300)
    no_leftovers(r)
    return info


@test("silent_worker_times_out")
def _(outdir):
    r = run(paths["silent"], outdir, [req("s1")], t=200)
    assert r["results"][0]["status"] == "timeout", r["results"]
    info = bounded(r, 200)
    no_leftovers(r)
    return info


@test("blocked_request_write_times_out")
def _(outdir):
    # 4 KiB pipe and a worker that never reads: the request write itself blocks
    longelf = "/" + "./" * 1900 + ELF.lstrip("/")
    fmap = os.path.join(SCRATCH, "fmap.txt")
    with open(fmap, "w") as f:
        f.write("f 0x400000 0x1\n")
    longmap = "/" + "./" * 1500 + fmap.lstrip("/")
    line = req("w1", elf=longelf, extra="\tfunction_map=%s" % longmap)
    assert len(line) > 6000, len(line)
    r = run(paths["never_read"], outdir, [line], t=300, extra_args=["-T", "-P", "4096"])
    assert r["results"][0]["status"] == "timeout", r["results"]
    info = bounded(r, 300)
    info["request_bytes"] = len(line)
    no_leftovers(r)
    return info


@test("term_ignoring_worker_killed_on_timeout")
def _(outdir):
    pidfile = os.path.join(SCRATCH, "term.pids")
    env = dict(os.environ, GHX_TEST_PIDFILE=pidfile)
    r = run(paths["term_ignoring"], outdir, [req("t1")], t=300, env=env)
    assert r["results"][0]["status"] == "timeout", r["results"]
    info = bounded(r, 300)
    no_leftovers(r)
    return info


@test("supervisor_sigterm_with_term_ignoring_worker")
def _(outdir):
    pidfile = os.path.join(SCRATCH, "term2.pids")
    env = dict(os.environ, GHX_TEST_PIDFILE=pidfile)
    r = run(paths["term_ignoring"], outdir, [req("t1"), req("t2")], t=20000, env=env, term_after=0.5)
    st = {x["id"]: x["status"] for x in r["results"]}
    assert st.get("t1") == "cancelled", st
    assert st.get("t2") == "cancelled", "queued request not reported: %s" % st
    assert r["rc"] == 130, r["rc"]
    assert r["wall_ms"] < 500 + GRACE + SLACK_MS + 200, r["wall_ms"]
    no_leftovers(r)
    return dict(wall_ms=r["wall_ms"])


@test("cancel_in_flight")
def _(outdir):
    r = run(paths["silent"], outdir, [req("c1")], t=20000, feed=[(0.3, "CANCEL\tid=c1\n")])
    res = r["results"][0]
    assert res["status"] == "cancelled", res
    assert float(res["ms"]) < 300 + GRACE + SLACK_MS, res
    assert float(res["cleanup_ms"]) <= GRACE, res
    no_leftovers(r)
    return dict(result_ms=float(res["ms"]), cleanup_ms=float(res["cleanup_ms"]))


@test("cancel_queued")
def _(outdir):
    r = run(paths["ok"], outdir, [req("slow1"), req("q2")], t=1500, feed=[(0.2, "CANCEL\tid=q2\n")])
    st = {x["id"]: x["status"] for x in r["results"]}
    assert st == {"q2": "cancelled", "slow1": "timeout"}, st
    j = json.load(open(os.path.join(outdir, "q2.json")))
    assert j["error"]["message"] == "cancelled while queued", j
    no_leftovers(r)


@test("restart_after_timeout")
def _(outdir):
    r = run(paths["ok"], outdir, [req("slow1"), req("n2")], t=2000)
    st = {x["id"]: x["status"] for x in r["results"]}
    assert st == {"slow1": "timeout", "n2": "ok"}, st
    assert len(r["worker_pids"]) == 2, r["worker_pids"]
    no_leftovers(r)


@test("crash_then_restart")
def _(outdir):
    r = run(paths["crash"], outdir, [req("k1")], t=2000)
    assert r["results"][0]["status"] == "worker_died", r["results"]
    no_leftovers(r)


@test("output_limit_header")
def _(outdir):
    r = run(paths["huge"], outdir, [req("h1")], t=2000, extra_args=["-m", "4096"])
    assert r["results"][0]["status"] == "output_limit", r["results"]
    assert float(r["results"][0]["ms"]) < 2000, r["results"]
    no_leftovers(r)


@test("protocol_error")
def _(outdir):
    r = run(paths["garbage"], outdir, [req("g1")], t=2000)
    assert r["results"][0]["status"] == "worker_died", r["results"]
    no_leftovers(r)


@test("grandchild_killed_with_process_group")
def _(outdir):
    pidfile = os.path.join(SCRATCH, "grand.pid")
    env = dict(os.environ, GHX_TEST_PIDFILE=pidfile)
    r = run(paths["grandchild"], outdir, [req("p1")], t=1500, env=env)
    assert r["results"][0]["status"] == "timeout", r["results"]
    gpid = int(open(pidfile).read())
    no_leftovers(r, [gpid])
    return dict(grandchild_pid_dead=True)


@test("bad_requests_never_reach_worker")
def _(outdir):
    lines = [req("x1", elf="relative/path"), "DECOMPILE\tid=../evil\telf=%s\tentry=0x1\n" % ELF,
             req("x2", extra="\tshell=$(id)"), req("x3", extra="\ttest_crash=1"), req("x4"), req("x4")]
    r = run(paths["ok"], outdir, lines, t=2000)
    st = [(x["id"], x["status"]) for x in r["results"]]
    assert st == [("x1", "bad_request"), ("-", "bad_request"), ("x2", "bad_request"), ("x3", "bad_request"),
                  ("x4", "ok"), ("-", "bad_request")], st
    assert not os.path.exists(os.path.join(SCRATCH, "evil.json"))
    no_leftovers(r)


@test("outdir_symlink_rejected")
def _(outdir):
    target = outdir + ".real"
    os.makedirs(target)
    os.symlink(target, outdir)
    r = run(paths["ok"], outdir, [req("z1")])
    assert r["rc"] == 2 and not r["results"], (r["rc"], r["results"])
    assert os.listdir(target) == []


@test("results_log_unwritable_is_explicit")
def _(outdir):
    os.makedirs(os.path.join(outdir, "results.jsonl"))
    r = run(paths["ok"], outdir, [req("z1")])
    assert r["rc"] == 2 and not r["results"], (r["rc"], r["results"])


if REAL:
    worker, sleighhome, elf = REAL

    def real(outdir, lines, extra):
        args = [SUP, "-w", worker, "-s", sleighhome, "-o", outdir, "-t", "30000", "-g", str(GRACE),
                "-S", SNAPROOT] + extra
        p = subprocess.run(args, input="".join(lines).encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=120)
        lines = p.stdout.decode().splitlines()
        res = [dict(kv.split("=", 1) for kv in l.split("\t")[1:]) for l in lines if l.startswith("RESULT\t")]
        wp = [int(dict(kv.split("=", 1) for kv in l.split("\t")[1:])["pid"]) for l in lines if l.startswith("WORKER\t")]
        return dict(rc=p.returncode, results=res, worker_pids=sorted(set(wp)), lines=lines)

    @test("real_worker_allocation_limit")
    def _(outdir):
        r = real(outdir, [req("m1", elf=elf, extra="\ttest_alloc_mb=3072"), req("m2", elf=elf, extra="\ttest_alloc_mb=16")],
                 ["-T", "-M", "1024"])
        st = {x["id"]: x["status"] for x in r["results"]}
        assert st == {"m1": "error", "m2": "error"}, st  # m2: entry 0x400000 is not code in this image
        j1 = json.load(open(os.path.join(outdir, "m1.json")))
        assert j1["error"]["code"] == "out_of_memory", j1["error"]
        j2 = json.load(open(os.path.join(outdir, "m2.json")))
        assert j2["error"]["code"] != "out_of_memory", j2["error"]
        no_leftovers(r)

    @test("real_worker_output_limit")
    def _(outdir):
        oracle = elf + ".oracle"
        entry = [l.split() for l in open(oracle) if l.split()[0] == "main"][0]
        line = "DECOMPILE\tid=o1\telf=%s\tentry=0x%x\tsize=0x%x\n" % (elf, int(entry[1], 16), int(entry[2], 16))
        r = real(outdir, [line], ["-m", "4096"])
        assert r["results"][0]["status"] == "error", r["results"]
        j = json.load(open(os.path.join(outdir, "o1.json")))
        assert j["error"]["code"] == "output_limit", j["error"]
        no_leftovers(r)

fails = [r for r in results if r["outcome"] != "pass"]
with open(OUT, "w") as f:
    json.dump({"suite": "ghx_supervise", "grace_ms": GRACE, "external_slack_ms": SLACK_MS,
               "tests": results, "passed": len(results) - len(fails), "failed": len(fails)}, f, indent=1)
print("supervisor tests: %d passed, %d failed" % (len(results) - len(fails), len(fails)))
sys.exit(1 if fails else 0)
