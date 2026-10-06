"""Semantic checks of real Ruby/CPython exports through the C reader CLI.

usage: check_exports.py XODB_LFRAMES {python|ruby|ruby-locations} EXPORT.jsonl META.json WORKLOAD_SOURCE
Prints one JSON result object; exits nonzero on any failed check.
"""
import hashlib
import json
import os
import subprocess
import sys

cli, kind, export, meta_path, source = sys.argv[1:6]
meta = json.load(open(meta_path))
results = []


def check(name, ok, detail=None):
    results.append({"check": name, "ok": bool(ok), "detail": detail})


def run(*args):
    p = subprocess.run([cli, *args], capture_output=True, text=True, timeout=120)
    return p.returncode, json.loads(p.stdout) if p.stdout.strip().startswith("{") else p.stdout


def line_of(text, after=None):
    lines = open(source).read().split("\n")
    start = 0
    if after:
        start = next(i for i, l in enumerate(lines) if after in l)
    return next(i for i, l in enumerate(lines[start:], start) if text in l) + 1


rc, summary = run("validate", export, "--strict")
check("validate --strict exit 0", rc == 0, summary if rc else None)
check("complete with end record", summary.get("complete") is True)
counts = summary.get("counts", {})
check("no native PC on any frame", counts.get("frames_with_native_pc") == 0)
check("source_kind is cooperative_sample", summary.get("source_kind") == "cooperative_sample")
check("producer labelled cooperating_in_process", summary["producer"]["kind"] == "cooperating_in_process")

# Independent re-read of the raw JSONL must agree with the C summary.
raw = [json.loads(l) for l in open(export, encoding="utf-8")]
by_type = {}
for r in raw:
    by_type.setdefault(r["type"], []).append(r)
check("independent reader agrees on stacks/frames",
      len(by_type["stack"]) == counts["stacks"] and sum(len(s["frames"]) for s in by_type["stack"]) == counts["frames"],
      {"python_stacks": len(by_type["stack"]), "c_stacks": counts["stacks"]})
check("input digest matches", hashlib.sha256(open(export, "rb").read()).hexdigest() == summary["input_sha256"])
header = raw[0]
exe = header["runtime"]["executable"]
check("executable identity hashes the running binary",
      exe["sha256"] == hashlib.sha256(open(exe["path"], "rb").read()).hexdigest(), exe["path"])
src_real = os.path.realpath(source)
codes = [c for c in by_type["code"] if c.get("path") and os.path.realpath(c["path"]) == src_real]
check("workload source identity", codes and codes[0]["sha256"] == hashlib.sha256(open(source, "rb").read()).hexdigest())
check("process pid matches workload", header["process"]["pid"] == meta["pid"])

rc, threads = run("threads", export)
# A language thread may get a second record (same language_id) once its OS
# thread is gone (native id nil while exiting); compare the record with a TID.
named = {}
for t in threads["threads"]:
    if t["name"] and t["os_tid"] and t["name"] not in named:
        named[t["name"]] = t
for name, tid in meta["native_ids"].items():
    check("thread %s language->OS TID" % name, name in named and named[name]["os_tid"] == tid,
          named.get(name, {}).get("os_tid"))
tids = [t["os_tid"] for t in threads["threads"] if t["os_tid"]]
check("OS TIDs distinct", len(tids) == len(set(tids)))
comms = {t["name"]: t.get("x_os_comm") for t in by_type["thread"] if t.get("name") and t.get("os_tid")}
check("kernel comm agrees with language thread name (first 15 bytes)",
      all(comms.get(n) == n[:15] for n in meta["native_ids"]), comms)

rc, stacks = run("stacks", export, "--limit", "1000000")
check("stacks listing complete", stacks["shown"] == stacks["matched"] == counts["stacks"])
all_stacks = stacks["stacks"]


def labels(s):
    return [f["label"] for f in s["frames"]]


def find(pred):
    return [s for s in all_stacks if pred(s)]


if kind == "python":
    worker = {"fib": "py-fib", "explicit": "MainThread"}
    explicit = find(lambda s: s["trigger"] == "explicit" and s["thread_name"] == "MainThread")
    check("explicit stack exact order", explicit and labels(explicit[0]) == ["explicit_leaf", "explicit_mid", "explicit_top", "<module>"],
          explicit and labels(explicit[0]))
    if explicit:
        f = explicit[0]["frames"]
        check("explicit stack lines are real source lines",
              f[0]["line"] == line_of('exporter.emit_here("explicit")', "def explicit_leaf") and f[1]["line"] == line_of("explicit_leaf()", "def explicit_mid"),
              [x["line"] for x in f])
    fib = find(lambda s: s["thread_name"] == "py-fib" and s["frames"] and s["frames"][0]["label"] == "fib")
    deep = [s for s in fib if labels(s)[:3] == ["fib"] * 3]
    check("recursive fib stacks sampled", len(deep) > 0, len(fib))
    if deep:
        l = labels(deep[0])
        n = next(i for i, x in enumerate(l) if x != "fib")
        check("recursion ordering: fib* then fib_worker then Thread.run", l[n:n + 2] == ["fib_worker", "Thread.run"] and l[-1] == "Thread._bootstrap", l)
    exc = find(lambda s: s["trigger"] == "exception")
    check("exception stacks emitted", len(exc) > 0)
    if exc:
        l = labels(exc[0])
        check("exception stack: raise site innermost, 6 recursive frames", l[:7] == ["raise_at_depth"] * 6 + ["raiser_worker"], l)
        check("exception raise line", exc[0]["frames"][0]["line"] == line_of('raise ValueError("fixture failure'), exc[0]["frames"][0]["line"])
        check("exception type recorded", exc[0]["exception"] == "builtins.ValueError")
    cb = find(lambda s: s["thread_name"] == "py-qsort" and s["trigger"] == "explicit")
    check("callback-in-native stack", cb and labels(cb[0])[:4] == ["compare", "libc.so.6:qsort", "sort_with_qsort", "qsort_worker"],
          cb and labels(cb[0]))
    if cb:
        m = cb[0]["frames"][1]
        check("transition marker is cooperative, without PC or line",
              m["kind"] == "native_transition" and m["provenance"] == "cooperative_annotation" and m["line"] is None and "pc" not in m)
    blocked = find(lambda s: s["thread_name"] == "py-qsort" and s["trigger"] == "timer" and s["frames"][0]["kind"] == "native_transition")
    check("timer samples inside native qsort show innermost marker", len(blocked) > 0, len(blocked))
    nested = find(lambda s: s["thread_name"] == "py-nested" and "nested_d" in labels(s))
    check("nested chain order", nested and labels(nested[0])[labels(nested[0]).index("nested_d"):][:5] == ["nested_d", "nested_c", "nested_b", "nested_a", "nested_worker"],
          nested and labels(nested[0]))
else:
    with_ext = kind == "ruby"
    explicit = find(lambda s: s["trigger"] == "explicit" and labels(s)[:1] == ["Object#explicit_leaf"])
    check("explicit stack exact order", explicit and labels(explicit[0]) == ["Object#explicit_leaf", "Object#explicit_mid", "Object#explicit_top", "<main>"],
          explicit and labels(explicit[0]))
    if explicit:
        check("explicit stack line", explicit[0]["frames"][0]["line"] == line_of('def explicit_leaf'), explicit[0]["frames"][0]["line"])
    fib = find(lambda s: s["thread_name"] == "rb-fib" and labels(s)[:3] == ["Object#fib"] * 3)
    check("recursive fib stacks sampled", len(fib) > 0)
    exc = find(lambda s: s["trigger"] == "exception")
    check("exception stacks emitted", len(exc) > 0)
    if exc:
        l = labels(exc[0])
        check("exception stack: 6 recursive raise frames innermost", l[:6] == ["Object#raise_at_depth"] * 6, l)
        check("exception raise line", exc[0]["frames"][0]["line"] == line_of('raise ArgumentError'), exc[0]["frames"][0]["line"])
        check("exception frames unclassified (Location API)", all(f["kind"] == "unclassified" for f in exc[0]["frames"]))
    nested = find(lambda s: s["thread_name"] == "rb-nested" and "Object#nested_d" in labels(s))
    check("nested chain sampled", len(nested) > 0)
    if with_ext:
        if nested:
            l = labels(nested[0])
            i = l.index("Object#nested_d")
            check("C method Kernel#sleep innermost and kind native",
                  l[:i + 4] == ["Kernel#sleep", "Object#nested_d", "Object#nested_c", "Object#nested_b", "Object#nested_a"][:i + 4]
                  and nested[0]["frames"][0]["kind"] == "native", l)
        through = find(lambda s: s["thread_name"] == "rb-cfunc" and s["trigger"] == "explicit")
        check("owned C extension transition reported by runtime", through and labels(through[0])[:3] == ["Object#through_native", "XodbNative.through_c", "Object#through_native"]
              and through[0]["frames"][1]["kind"] == "native" and through[0]["frames"][1]["provenance"] == "runtime",
              through and labels(through[0]))
    else:
        check("fallback frames are unclassified", all(f["kind"] == "unclassified" for s in all_stacks for f in s["frames"]))

rc, agg = run("aggregate", export, "--top", "1000")
check("aggregate total equals stack count", int(agg["total_weight"]) == counts["stacks"])
check("aggregate inclusive never exceeds total", all(int(r["inclusive"]) <= int(agg["total_weight"]) for r in agg["rows"]))
check("aggregate self sums to function-leaf weight",
      sum(int(r["self"]) for r in agg["rows"]) + int(agg["unknown_leaf_weight"]) == int(agg["total_weight"]))

# C05-R2: exact relationships against an independent Python-integer oracle.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from exact_oracle import oracle  # noqa: E402

text = open(export, encoding="utf-8").read()
want = oracle(text)
check("R2 exact totals equal the independent oracle",
      [agg[k] for k in ("total_weight", "partial_weight", "marker_weight", "unknown_leaf_weight", "lost")]
      == [str(want[k]) for k in ("total", "partial", "marker", "unknown_leaf", "lost")],
      {k: agg[k] for k in ("total_weight", "partial_weight", "marker_weight", "unknown_leaf_weight", "lost")})
rows = {r["function"]: r for r in agg["rows"]}
check("R2 per-function self/inclusive equal the oracle",
      set(rows) == set(want["inclusive"]) and all(rows[f]["inclusive"] == str(v) and rows[f]["self"] == str(want["self"].get(f, 0))
                                                   for f, v in want["inclusive"].items()))
check("R2 aggregate reports budgets", agg.get("contract") == "C05-R2-1" and agg["budget"]["combined_peak_bytes"]
      == agg["budget"]["retained_bytes"] + agg["budget"]["query_peak_bytes"], agg.get("budget"))
fib_thread = "py-fib" if kind == "python" else "rb-fib"
fib_name = "fib" if kind == "python" else "Object#fib"
fns = {r["id"]: r for r in by_type["function"]}
fib_ids = {i for i, f in fns.items() if f["name"] == fib_name or f.get("qualified") == fib_name}
tids = {t["id"] for t in by_type["thread"] if t.get("name") == fib_thread}
fib_stacks = [s for s in by_type["stack"] if s["thread"] in tids and any(f["function"] in fib_ids for f in s["frames"])]
fib_frames = sum(1 for s in fib_stacks for f in s["frames"] if f["function"] in fib_ids)
stack_weight = sum(int(s["weight"]) for s in fib_stacks)
rc, tagg = run("aggregate", export, "--thread", fib_thread, "--top", "100000")
incl = sum(int(r["inclusive"]) for r in tagg["rows"] if r["function"] in fib_ids) if rc == 0 else None
check("recursion counted once per stack: inclusive(fib) == weight of stacks containing fib < fib frame count",
      rc == 0 and incl == stack_weight and fib_frames > len(fib_stacks) > 0,
      {"inclusive": incl, "stack_weight": stack_weight, "stacks": len(fib_stacks), "fib_frames": fib_frames})
tw = 0
for t in by_type["thread"]:
    rc, ta = run("aggregate", export, "--thread", t["id"], "--top", "0")
    tw += int(ta["total_weight"]) if rc == 0 else 0
check("per-thread totals sum exactly to the document total", tw == int(agg["total_weight"]), tw)
failed = [r for r in results if not r["ok"]]
print(json.dumps({"export": export, "kind": kind, "checks": len(results), "failed": len(failed), "results": results,
                  "summary": summary}, indent=1))
sys.exit(1 if failed else 0)
