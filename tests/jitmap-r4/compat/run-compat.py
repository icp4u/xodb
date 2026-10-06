#!/usr/bin/env python3
"""C07-R4 / C05-R4 compatibility fixture (test-only; replaces C07-R3's).

usage: run-compat.py SRC_ROOT OUT_DIR [--synthetic]

SRC_ROOT is a tree with C05-R2's 01-c05-r2.patch, C05-R3's
03-c05-r3-admission.patch and 04-c05-r3-decode-file.patch, C05-R4's
07-c05-r4-stable-read.patch, C07-R4's jitmap-r4-cumulative.patch and this
test-only patch applied. c05-compat is built here against that reader and resolver (CC and
CFLAGS from the environment; CFLAGS may add sanitizers).

Default (live): one owned CPython process runs C05's own cooperative exporter
(tests/logical-frames/python_workload.py) under -Xperf_jit, so the
logical-frame document and the jitdump come from the same process instance.
CPython writes the jitdump to /tmp/jit-PID.dump; only the file of that PID is
moved into OUT_DIR (run inside a private mount namespace to keep /tmp
untouched). Start ticks are read from /proc while it runs; coverage end is
CLOCK_MONOTONIC after exit.

--synthetic: an owned synthetic C05-1 document and jitdump are written into
OUT_DIR instead; no runtime is started.

Either way the bridge stays null, and the document is a closed file this
process owns, so the C05-R4 reader must report input_stability "leased".
Prints one JSON object; exit 0 on pass.
"""
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time

src, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
synthetic = "--synthetic" in sys.argv[3:]
os.makedirs(out, mode=0o755, exist_ok=True)
binary = os.path.join(out, "c05-compat")
subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O2", "-g", "-Wall", "-Wextra", "-Werror",
                *os.environ.get("CFLAGS", "").split(), "-I", os.path.join(src, "src/profile"),
                os.path.join(src, "src/profile/logical_frames.c"), os.path.join(src, "src/profile/jitmap.c"),
                os.path.join(src, "tests/jitmap-r4/compat/c05-compat.c"), "-o", binary], check=True, timeout=300)


def synthetic_inputs():
    """Owned C05-1 document and jitdump for one declared process instance."""
    pid, boot = 31337, "10" * 16
    rows = [
        {"type": "header", "format": "xodb.logical-frames", "version": 1, "draft": "C05-1",
         "producer": {"name": "owned-synthetic", "version": "1", "kind": "cooperating_in_process", "sha256": None},
         "source_kind": "cooperative_sample",
         "runtime": {"language": "python", "implementation": "fixture", "version": "1", "build": None,
                     "executable": {"path": "fixture", "sha256": "a" * 64, "gnu_build_id": None}, "library": None},
         "process": {"pid": pid, "start_ticks": "1",
                     "boot_id": "-".join((boot[:8], boot[8:12], boot[12:16], boot[16:20], boot[20:]))},
         "clock": {"domain": "CLOCK_MONOTONIC", "unit": "ns"}, "command": ["fixture"],
         "collection": {"method": "synthetic", "trigger": "explicit", "interval_ns": None,
                        "atomicity": "all_threads_one_call"},
         "frame_order": "innermost_first", "weight_unit": "observation",
         "weight_semantics": "one synthetic observation"},
        {"type": "code", "id": "c", "kind": "source_file", "path": "fixture.py", "sha256": "a" * 64, "bytes": 10},
        {"type": "function", "id": "f", "name": "owned", "qualified": "owned", "code": "c", "first_line": 1,
         "frame_kind": "interpreter"},
        {"type": "thread", "id": "t", "language_id": "fixture:1", "name": "worker", "os_tid": pid,
         "os_tid_source": "synthetic"},
        {"type": "acquisition", "seq": 1, "start_ns": "100", "end_ns": "200", "stacks": 1},
        {"type": "stack", "id": "s", "acquisition": 1, "thread": "t", "start_ns": "110", "end_ns": "120",
         "trigger": "explicit", "weight": "1", "state": "complete", "omitted": None, "reason": None,
         "frames": [{"function": "f", "kind": "interpreter", "line": 1, "provenance": "runtime"}]},
    ]
    rows.append({"type": "end", "records": len(rows), "acquisitions": 1, "stacks": 1, "status": "complete"})
    doc = os.path.join(out, "synthetic.jsonl")
    with open(doc, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rows))
    body = struct.pack("<IIQQQQ", pid, pid, 0x9000, 0x9000, 1, 7) + b"owned\0A"
    data = (struct.pack("<6I2Q", 0x4A695444, 1, 40, 62, 0, pid, 1, 0) + struct.pack("<IIQ", 0, 16 + len(body), 100)
            + body + struct.pack("<IIQ", 3, 16, 200))
    dump = os.path.join(out, "synthetic.dump")
    with open(dump, "wb") as f:
        f.write(data)
    return doc, dump, pid, "1", boot, "20" * 16, 200, "worker", "owned", "owned"


def live_inputs():
    doc, meta = os.path.join(out, "py.jsonl"), os.path.join(out, "py-meta.json")
    p = subprocess.Popen([sys.executable, "-Xperf_jit", os.path.join(src, "tests/logical-frames/python_workload.py"),
                          doc, meta, "2", "5"], cwd=out)
    start_ticks = None
    for _ in range(200):
        try:
            st = open("/proc/%d/stat" % p.pid).read()
            start_ticks = st[st.rindex(")") + 2:].split()[19]
            break
        except OSError:
            time.sleep(0.01)
    boot_id = open("/proc/sys/kernel/random/boot_id").read().strip()
    timens = int(os.readlink("/proc/self/ns/time").split("[")[1].rstrip("]"))
    rc = p.wait(timeout=120)
    coverage_end = time.monotonic_ns()
    if rc != 0 or start_ticks is None:
        print(json.dumps({"status": "failed", "reason": "workload exit %s, start_ticks %s" % (rc, start_ticks)}))
        sys.exit(1)
    dump = "/tmp/jit-%d.dump" % p.pid
    if not os.path.exists(dump):
        print(json.dumps({"status": "unsupported", "reason": "CPython produced no jit-PID.dump"}))
        sys.exit(1)
    kept = os.path.join(out, "jit-%d.dump" % p.pid)
    shutil.move(dump, kept)  # only the file of the PID started above
    os.chmod(kept, 0o644)
    boot = bytes.fromhex(boot_id.replace("-", ""))
    scope = (boot[:8] + bytes(b ^ ((timens >> (8 * i)) & 0xff) for i, b in enumerate(boot[8:]))).hex()
    return doc, kept, p.pid, start_ticks, boot_id.replace("-", ""), scope, coverage_end, "py-fib", "fib", "py::fib:"


# The reader's own contract id (XLF_CONTRACT), so re-pinning to a later C05 needs no edit here.
contract = re.search(r'#define XLF_CONTRACT "([^"]+)"',
                     open(os.path.join(src, "src/profile/logical_frames.h")).read()).group(1)
doc, dump, pid, start_ticks, boot, scope, coverage_end, thread, function, jit_name = \
    synthetic_inputs() if synthetic else live_inputs()
sha = hashlib.sha256(open(dump, "rb").read()).hexdigest()
r = subprocess.run([binary, doc, dump, sha, str(pid), start_ticks, boot, scope, str(coverage_end), thread, function,
                    jit_name], capture_output=True, text=True, timeout=120)
result = {"status": "pass" if r.returncode == 0 else "fail", "mode": "synthetic" if synthetic else "live",
          "reader_contract": contract,
          "pid": pid, "stderr": r.stderr[-2000:],
          "inputs": {"document": os.path.basename(doc), "document_file_sha256":
                     hashlib.sha256(open(doc, "rb").read()).hexdigest(), "jitdump": os.path.basename(dump),
                     "jitdump_sha256": sha},
          "reader_sha256": {f: hashlib.sha256(open(os.path.join(src, f), "rb").read()).hexdigest()
                            for f in ("src/profile/logical_frames.c", "src/profile/logical_frames.h",
                                      "src/profile/jitmap.c", "src/profile/jitmap.h")}}
try:
    result["composition"] = json.loads(r.stdout)
except ValueError:
    result["stdout"] = r.stdout[-2000:]
    result["status"] = "fail"
if result["status"] == "pass":
    c = result["composition"]
    ok = (c["composition"]["bridge"] is None and c["composition"]["process_instance"] == "same_declared_instance"
          and c["composition"]["clock_relation"] == "unrelated_no_declared_mapping"
          and not c["composition"]["weights_are_cpu_time"] and c["logical"]["contract"] == contract
          and c["logical"]["input_stability"] == "leased"
          and c["jit"]["query"]["outcome"] in ("resolved", "unverified")
          and int(c["logical"]["function"]["inclusive"]) > 0)
    result["status"] = "pass" if ok else "fail"
print(json.dumps(result, indent=1))
sys.exit(0 if result["status"] == "pass" else 1)
