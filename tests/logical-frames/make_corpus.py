"""Derive a small adversarial corpus from real exports and check the reader's verdicts.

usage: make_corpus.py XODB_LFRAMES PY_EXPORT RB_EXPORT OUT_DIR
Writes OUT_DIR/*.jsonl and OUT_DIR/expected.json; exits nonzero if any verdict differs.
"""
import json
import os
import subprocess
import sys

cli, py_export, rb_export, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)


def load(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")]


def dump(name, records, raw_tail=b""):
    path = os.path.join(out, name + ".jsonl")
    with open(path, "wb") as f:
        for r in records:
            f.write((json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
        f.write(raw_tail)
    return path


def first(records, pred):
    return next(i for i, r in enumerate(records) if pred(r))


py, rb = load(py_export), load(rb_export)
cases = []

# Interrupted producer: whole lines, no end record.
cases.append(("interrupted_lines", dump("interrupted_lines", py[: len(py) // 2]), [], 0, {"complete": False, "warnings": ["no_end_record"]}))
# Truncated in the middle of a record.
mid = json.dumps(py[len(py) // 2], separators=(",", ":")).encode()[:40]
cases.append(("truncated_mid_record", dump("truncated_mid_record", py[: len(py) // 2], mid), [], 0,
              {"complete": False, "warnings": ["no_end_record", "truncated_tail"]}))
# Mismatched process identity on a thread record.
m = [dict(r) for r in py]
i = first(m, lambda r: r["type"] == "thread")
m[i]["pid"] = m[0]["process"]["pid"] + 1
cases.append(("thread_pid_mismatch", dump("thread_pid_mismatch", m), [], 2, {"error": "bad_identity"}))
# Missing clock while stacks still carry times.
m = [dict(r) for r in py]
m[0] = dict(m[0], clock=None, clock_unavailable="clock dropped by converter")
cases.append(("missing_clock_with_times", dump("missing_clock_with_times", m), [], 2, {"error": "clock"}))
# Invented native PC on an interpreter frame.
m = json.loads(json.dumps(py))
i = first(m, lambda r: r["type"] == "stack")
m[i]["frames"][0]["pc"] = "0x7f0000401000"
cases.append(("invented_pc_on_interpreter_frame", dump("invented_pc_on_interpreter_frame", m), [], 2, {"error": "invented_pc"}))
# High-bit PC on a runtime-reported native (C method) frame: accepted exactly.
m = json.loads(json.dumps(rb))
i = first(m, lambda r: r["type"] == "stack" and any(f["kind"] == "native" for f in r["frames"]))
j = next(k for k, f in enumerate(m[i]["frames"]) if f["kind"] == "native")
m[i]["frames"][j]["pc"] = "0xffffffffffffffff"
cases.append(("high_bit_pc_on_native_frame", dump("high_bit_pc_on_native_frame", m), [], 0, {"complete": True, "frames_with_native_pc": 1}))
# Address reuse: JIT code records overlapping while both live, and with unknown lifetimes.
def jit(cid, start, end, load, unload):
    return {"type": "code", "id": cid, "kind": "jit", "path": None, "sha256": None, "unavailable": "jit code", "bytes": None,
            "range": {"start": start, "end": end, "load_ns": load, "unload_ns": unload}}
m = json.loads(json.dumps(py))
m[1:1] = [jit("jit1", "0x7f0000001000", "0x7f0000002000", "10", "50"), jit("jit2", "0x7f0000001800", "0x7f0000002800", "20", None)]
m[-1]["records"] += 2
cases.append(("jit_overlap_live", dump("jit_overlap_live", m), [], 2, {"error": "address"}))
m[2] = jit("jit2", "0x7f0000001800", "0x7f0000002800", "50", None)
cases.append(("jit_reuse_after_unload", dump("jit_reuse_after_unload", m), [], 0, {"complete": True, "warnings": ["loss_records"]}))
m[1] = jit("jit1", "0x7f0000001000", "0x7f0000002000", None, None)
cases.append(("jit_overlap_unknown_lifetime", dump("jit_overlap_unknown_lifetime", m), [], 0, {"warnings": ["address_reuse_ambiguous"]}))
# Duplicate record id.
m = json.loads(json.dumps(py))
s = [k for k, r in enumerate(m) if r["type"] == "stack"]
m[s[1]]["id"] = m[s[0]]["id"]
cases.append(("duplicate_stack_id", dump("duplicate_stack_id", m), [], 2, {"error": "duplicate_id"}))
# Partial stack with reason: accepted and reported.
m = json.loads(json.dumps(py))
m[s[0]].update(state="partial", reason="thread exited during walk", frames=m[s[0]]["frames"][:1])
cases.append(("partial_stack", dump("partial_stack", m), [], 0, {"warnings": ["partial_stacks"]}))
# Language-to-OS thread ambiguity: two language threads claim one TID.
m = json.loads(json.dumps(py))
t = [k for k, r in enumerate(m) if r["type"] == "thread" and r.get("os_tid")]
m[t[1]]["os_tid"] = m[t[0]]["os_tid"]
cases.append(("os_tid_ambiguous", dump("os_tid_ambiguous", m), [], 0, {"warnings": ["os_tid_shared"]}))
# Budget exhaustion on a valid real export.
cases.append(("budget_total_frames", py_export, ["--max-frames", "100"], 2, {"error": "input_limit"}))
cases.append(("budget_memory", py_export, ["--max-memory", "65536"], 2, {"error": "memory_limit"}))
cases.append(("budget_bytes", py_export, ["--max-bytes", "1000"], 2, {"error": "input_limit"}))
# Relabelled as simpleperf: refused.
m = json.loads(json.dumps(py))
m[0]["format"] = "xodb.simpleperf"
cases.append(("relabelled_simpleperf", dump("relabelled_simpleperf", m), [], 2, {"error": "version_unsupported"}))

results, bad = [], 0
for name, path, extra, want_rc, want in cases:
    p = subprocess.run([cli, "validate", path, *extra], capture_output=True, text=True, timeout=60)
    got = json.loads(p.stdout)
    ok = p.returncode == want_rc
    for k, v in want.items():
        if k == "warnings":
            ok = ok and all(w in got.get("warnings", []) for w in v)
        elif k == "frames_with_native_pc":
            ok = ok and got.get("counts", {}).get(k) == v
        else:
            ok = ok and got.get(k) == v
    bad += not ok
    results.append({"case": name, "file": os.path.basename(path), "args": extra, "rc": p.returncode, "ok": ok,
                    "expected": want, "verdict": {k: got.get(k) for k in ("status", "error", "line", "message", "complete", "warnings") if k in got}})
json.dump(results, open(os.path.join(out, "expected.json"), "w"), indent=1)
for r in results:
    print("%-4s %-34s rc=%d %s" % ("ok" if r["ok"] else "FAIL", r["case"], r["rc"], r["verdict"].get("error") or r["verdict"].get("warnings")))
sys.exit(1 if bad else 0)
