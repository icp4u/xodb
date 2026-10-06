#!/usr/bin/env python3
"""Decode real jitdump/perf-map output from owned, freshly started runtimes.
Only processes started here are recorded; /tmp/jit-PID.dump and
/tmp/perf-PID.map files of those PIDs are moved into OUT_DIR. Missing runtimes
are reported as not_tested, never as passed.

usage: jitmap-runtime-producers.py BUILD_DIR OUT_DIR [DECLARATIONS_JSON]

Version-specific producer facts (Node's +0x40 debug-address bias, its
microsecond timestamp granularity) come from DECLARATIONS_JSON (default
tests/jitmap-r2/producer-declarations.json) and apply only to the exact
runtime version declared there. Every perf-map line is queried: an untimed
snapshot must never resolve confidently.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

build, out = sys.argv[1], os.path.abspath(sys.argv[2])
decl_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                "jitmap-r2", "producer-declarations.json")
declarations = json.load(open(decl_path))
decl_sha = hashlib.sha256(open(decl_path, "rb").read()).hexdigest()
cli = os.path.join(build, "xodb-jitmap")
os.makedirs(out, mode=0o755, exist_ok=True)
results, failures = [], []

PY_CHILD = r'''
import json, os, sys, time
def foo(n):
    s = 0
    for i in range(n): s += i
    return s
def bar(n): return foo(n)
def baz(n): return bar(n)
baz(200000)
st = open('/proc/self/stat').read()
print(json.dumps({"pid": os.getpid(), "start_ticks": st[st.rindex(')') + 2:].split()[19],
                  "boot_id": open('/proc/sys/kernel/random/boot_id').read().strip(),
                  "time_ns": os.readlink('/proc/self/ns/time'), "runtime": "CPython " + sys.version.split()[0],
                  "end_monotonic_ns": time.monotonic_ns()}))
'''
JS_CHILD = r'''
function f(n){let s=0;for(let i=0;i<n;i++)s+=i;return s}
for(let k=0;k<200;k++) f(100000);
const fs=require("fs"); const st=fs.readFileSync("/proc/self/stat","utf8");
console.log(JSON.stringify({pid:process.pid, start_ticks: st.slice(st.lastIndexOf(")")+2).split(" ")[19],
  boot_id: fs.readFileSync("/proc/sys/kernel/random/boot_id","utf8").trim(),
  time_ns: fs.readlinkSync("/proc/self/ns/time"), runtime: "node " + process.version,
  end_monotonic_ns: String(process.hrtime.bigint())}));
'''


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def scope(info):
    boot = bytes.fromhex(info["boot_id"].replace("-", ""))
    ns = int(info["time_ns"].split("[")[1].rstrip("]"))
    return (boot[:8] + bytes(b ^ ((ns >> (8 * i)) & 0xff) for i, b in enumerate(boot[8:]))).hex()


def declared(runtime, kind):
    for d in declarations["declarations"]:
        if d["runtime"] == runtime and d["artifact"].startswith(kind):
            return d
    return None


def run(name, argv, kind, cwd, artifact, wants_declaration, expect_names):
    exe = shutil.which(argv[0])
    entry = {"name": name, "command": argv[:-1] + ["<inline script>"], "kind": kind}
    if not exe:
        entry["status"] = "not_tested"
        entry["reason"] = argv[0] + " not installed"
        results.append(entry)
        return
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        entry.update(status="failed", reason="runtime exit %d: %s" % (p.returncode, p.stderr[-400:]))
        results.append(entry)
        failures.append(name)
        return
    info = json.loads(p.stdout.strip().splitlines()[-1])
    src = artifact.format(pid=info["pid"], cwd=cwd)
    if not os.path.exists(src):
        entry.update(status="unsupported", reason="runtime produced no " + src, runtime=info["runtime"])
        results.append(entry)
        return
    extra = []
    decl = declared(info["runtime"], kind) if wants_declaration else None
    if wants_declaration:
        entry["declaration_status"] = "matched" if decl else "none_for_version"
        entry["declarations_sha256"] = decl_sha
    if decl:
        extra = ["--debug-address-bias", str(decl["debug_address_bias"]), "--slack", str(decl["slack_ns"])]
    dst = os.path.join(out, "%s-%s" % (name, os.path.basename(src)))
    shutil.move(src, dst)  # only the file of the PID started above
    os.chmod(dst, 0o644)
    args = ["--pid", str(info["pid"]), "--start-ticks", info["start_ticks"], "--boot-id", info["boot_id"],
            "--clock", "monotonic", "--clock-scope", scope(info), "--coverage-end", str(info["end_monotonic_ns"]),
            *extra, "--" + kind, dst]
    d = json.loads(subprocess.run([cli, "decode", *args], check=True, capture_output=True, text=True, timeout=60).stdout)
    s = d["sources"][0]
    names = [v.get("name") or "" for v in d["versions"]]
    found = {n: any(n in x for x in names) for n in expect_names}
    diag = {}
    for x in d["diagnostics"]:
        diag[x["code"]] = diag.get(x["code"], 0) + 1
    ok = s["complete"] and s["malformed_records"] == 0 and s["unknown_records"] == 0 and all(found.values()) \
        and not diag and len(d["versions"]) > 0
    entry.update(status="supported" if ok else "failed", runtime=info["runtime"], pid=info["pid"],
                 artifact=os.path.basename(dst), sha256=sha(dst), bytes=s["bytes"], records=s["records"],
                 versions=len(d["versions"]), expected_names=found, diagnostics=diag, declared=extra,
                 unwind_attached=sum(1 for v in d["versions"] if "unwind" in v),
                 debug_attached=sum(1 for v in d["versions"] if "debug" in v),
                 moves=sum(1 for v in d["versions"] if v["begin"]["kind"] == "move_in"))
    if kind == "jitdump":
        entry["header_time"] = s["jitdump"]["header_time"]
        entry["first_record_time"] = s["jitdump"].get("first_record_time")
        entry["header_time_note"] = "not in record clock" if int(s["jitdump"]["header_time"]) > \
            int(info["end_monotonic_ns"]) else "plausibly record clock"
    # A perf map must never yield a confident attribution.
    v = d["versions"][0]
    when = int(v["begin"]["time"]) + 2001 if kind == "jitdump" else int(info["end_monotonic_ns"]) - 1
    r = json.loads(subprocess.run([cli, "resolve", *args, "--at", "%s@%d" % (v["start"], when)],
                                  check=True, capture_output=True, text=True, timeout=60).stdout)["results"][0]["result"]
    entry["sample_resolution"] = {"address": v["start"], "time": str(when), "outcome": r["outcome"], "reasons": r["reasons"]}
    if kind == "perfmap":
        # Query every line (bounded): an untimed snapshot is never confident.
        ats = []
        for v in d["versions"][:256]:
            ats += ["--at", "%s@%d" % (v["start"], when)]
        rs = json.loads(subprocess.run([cli, "resolve", *args, *ats], check=True, capture_output=True, text=True,
                                       timeout=120).stdout)["results"]
        outcomes = {}
        for x in rs:
            outcomes[x["result"]["outcome"]] = outcomes.get(x["result"]["outcome"], 0) + 1
        entry["all_lines_outcomes"] = outcomes
        if "resolved" in outcomes or r["outcome"] == "resolved":
            ok = False
            entry["status"] = "failed"
    if kind == "jitdump" and wants_declaration and decl:
        # Re-measure the declared bias on this run: debug entries outside their range with the declaration.
        out_of_range = sum(1 for x in d["diagnostics"] if x["code"] == "debug_out_of_range")
        entry["declared_bias_out_of_range_records"] = out_of_range
    results.append(entry)
    if not ok:
        failures.append(name)


py = sys.executable or "python3"
run("cpython-perf-jit", [py, "-Xperf_jit", "-c", PY_CHILD], "jitdump", out, "/tmp/jit-{pid}.dump", True,
    ["py::foo:<string>", "py::bar:<string>", "py::baz:<string>"])
run("cpython-perf", [py, "-Xperf", "-c", PY_CHILD], "perfmap", out, "/tmp/perf-{pid}.map", False,
    ["py::foo:<string>"])
# V8 debug entry addresses were observed biased by 0x40 relative to code start;
# that is a declared, version-keyed input (DECLARATIONS_JSON), not a guess.
run("node-perf-prof", ["node", "--perf-prof", "--perf-prof-unwinding-info", "-e", JS_CHILD], "jitdump", out,
    "{cwd}/jit-{pid}.dump", True, ["JS:"])
run("node-perf-basic-prof", ["node", "--perf-basic-prof", "-e", JS_CHILD], "perfmap", out, "/tmp/perf-{pid}.map",
    False, ["JS:"])
for name in os.listdir(out):  # V8 also writes an isolate log in cwd; keep it out of artifacts
    if name.startswith("isolate-") and name.endswith("-v8.log"):
        os.remove(os.path.join(out, name))
print(json.dumps({"producers": results, "failures": failures, "declarations": decl_path,
                  "declarations_sha256": decl_sha}, indent=1))
sys.exit(1 if failures else 0)
