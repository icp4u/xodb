#!/usr/bin/env python3
"""Independent exact-integer oracle for xodb-lframes aggregates (C05-R2).

Generates deterministic documents whose weights sit at u64 boundaries, computes
every aggregate class with Python integers from the parsed JSON Lines (no shared
code with the C reader), and compares the CLI's decimal strings exactly. Also
checks the retained overflow fixture and CLI budget boundaries.
Usage: exact_oracle.py XODB_LFRAMES [--fixture FILE] [--cases N] [--seed S] [--json OUT]
"""
import argparse, json, os, random, subprocess, sys, tempfile

U64 = 2**64
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append({"name": name, "status": "pass" if ok else "fail", "detail": str(detail)[:500]})
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    return ok


HEADER = {"type": "header", "format": "xodb.logical-frames", "version": 1, "draft": "C05-1",
          "producer": {"name": "oracle", "version": "1", "kind": "cooperating_in_process", "sha256": None},
          "source_kind": "cooperative_sample",
          "runtime": {"language": "python", "implementation": "cpython", "version": "3", "build": None,
                      "executable": {"path": None, "sha256": None, "gnu_build_id": None, "unavailable": "oracle"},
                      "library": None},
          "process": {"pid": None, "start_ticks": None, "boot_id": None, "unavailable": "oracle"},
          "clock": None, "clock_unavailable": "oracle", "command": None,
          "collection": {"method": "m", "trigger": "t", "interval_ns": None, "atomicity": "single_thread"},
          "frame_order": "innermost_first", "weight_unit": "observation", "weight_semantics": "oracle"}


def generate(rng, nfun, nthr, nstk):
    recs = [HEADER]
    for f in range(nfun):
        recs.append({"type": "function", "id": f"f{f}", "name": f"fn{f}", "qualified": None, "code": None,
                     "first_line": None, "frame_kind": "logical"})
    for t in range(nthr):
        recs.append({"type": "thread", "id": f"t{t}", "language_id": None, "name": f"th{t}", "os_tid": None,
                     "os_tid_reason": "oracle"})
    boundary = [1, 2, 2**63 - 1, 2**63, 2**63 + 1, U64 - 2, U64 - 1]
    for s in range(nstk):
        recs.append({"type": "acquisition", "seq": s + 1, "start_ns": None, "end_ns": None, "stacks": 1})
        w = rng.choice(boundary) if rng.random() < 0.7 else rng.randrange(1, U64)
        state = rng.choice(["complete"] * 3 + ["partial", "truncated"])
        depth = rng.randrange(0 if state != "complete" else 1, 9)
        frames = []
        for _ in range(depth):
            if rng.random() < 0.15:
                frames.append({"function": None, "kind": "unknown", "line": None, "provenance": "runtime",
                               "label": "gap", "reason": "oracle"})
            else:
                # Small function pool per stack forces recursion.
                frames.append({"function": f"f{rng.randrange(nfun)}", "kind": "logical", "line": 1,
                               "provenance": "runtime"})
        recs.append({"type": "stack", "id": f"s{s}", "acquisition": s + 1, "thread": f"t{rng.randrange(nthr)}",
                     "start_ns": None, "end_ns": None, "trigger": "t", "weight": str(w), "state": state,
                     "omitted": None, "reason": None if state == "complete" else "oracle", "frames": frames})
    for _ in range(rng.randrange(0, 3)):
        recs.append({"type": "loss", "reason": "r", "count": str(rng.choice(boundary)), "acquisition": None})
    recs.append({"type": "end", "records": len(recs), "acquisitions": nstk, "stacks": nstk, "status": "complete"})
    return "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in recs)


def oracle(text, thread=None):
    """Exact aggregates from the JSON Lines text using Python integers."""
    agg = {"total": 0, "partial": 0, "marker": 0, "unknown_leaf": 0, "stacks": 0, "partial_stacks": 0,
           "lost": 0, "self": {}, "inclusive": {}}
    for line in text.splitlines():
        r = json.loads(line)
        if r["type"] == "loss":
            agg["lost"] += int(r["count"])
        if r["type"] != "stack" or (thread is not None and r["thread"] != thread):
            continue
        w = int(r["weight"])
        fr = r["frames"]
        agg["total"] += w
        agg["stacks"] += 1
        if r["state"] != "complete":
            agg["partial"] += w
            agg["partial_stacks"] += 1
        if any(f["function"] is None for f in fr):
            agg["marker"] += w
        if not fr or fr[0]["function"] is None:
            agg["unknown_leaf"] += w
        if fr and fr[0]["function"] is not None:
            agg["self"][fr[0]["function"]] = agg["self"].get(fr[0]["function"], 0) + w
        for fn in {f["function"] for f in fr if f["function"] is not None}:
            agg["inclusive"][fn] = agg["inclusive"].get(fn, 0) + w
    return agg


def run(binary, *args):
    p = subprocess.run([binary, *args], capture_output=True, text=True, timeout=120)
    out = p.stdout.strip().splitlines()
    try:
        doc = json.loads(out[-1]) if out else None
    except ValueError:
        doc = None
    return p.returncode, doc, p.stderr


def compare(binary, path, text, label, thread=None):
    args = ["aggregate", path, "--top", "1000000"] + (["--thread", thread] if thread else [])
    rc, got, err = run(binary, *args)
    if not check(f"{label}: aggregate exits 0", rc == 0 and got and got.get("status") == "ok", err or got):
        return False
    want = oracle(text, thread)
    ok = True
    for key, field in [("total", "total_weight"), ("partial", "partial_weight"), ("marker", "marker_weight"),
                       ("unknown_leaf", "unknown_leaf_weight"), ("lost", "lost")]:
        ok &= got[field] == str(want[key])
        if got[field] != str(want[key]):
            print(f"     {label}: {field} got {got[field]} want {want[key]}")
    ok &= got["stacks"] == want["stacks"] and got["partial_stacks"] == want["partial_stacks"]
    rows = {r["function"]: r for r in got["rows"]}
    ok &= set(rows) == set(want["inclusive"])
    for fn, inc in want["inclusive"].items():
        r = rows.get(fn)
        if not r or r["inclusive"] != str(inc) or r["self"] != str(want["self"].get(fn, 0)):
            ok = False
            print(f"     {label}: {fn} got {r} want self {want['self'].get(fn, 0)} inclusive {inc}")
    beyond = sum(1 for v in [want["total"]] + list(want["inclusive"].values()) if v >= U64)
    return check(f"{label}: all counters exact ({beyond} values >= 2^64)", ok, got)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--fixture")
    ap.add_argument("--cases", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261005)
    ap.add_argument("--json")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    base = os.environ.get("XODB_TEST_TMPDIR") or None
    with tempfile.TemporaryDirectory(prefix="xlf-oracle-", dir=base) as tmp:
        os.chmod(tmp, 0o755)
        for i in range(a.cases):
            text = generate(rng, rng.randrange(1, 6), rng.randrange(1, 4), rng.randrange(0, 12))
            path = os.path.join(tmp, f"case{i}.jsonl")
            with open(path, "w") as f:
                f.write(text)
            compare(a.binary, path, text, f"random case {i}")
            if i % 10 == 0:
                compare(a.binary, path, text, f"random case {i} thread t0", "t0")
        if a.fixture:
            text = open(a.fixture).read()
            compare(a.binary, a.fixture, text, "retained fixture c05-weight-overflow")
            rc, got, _ = run(a.binary, "aggregate", a.fixture)
            check("fixture total is 18446744073709551690, never 74",
                  rc == 0 and got["total_weight"] == "18446744073709551690", got and got.get("total_weight"))
            rc, v, _ = run(a.binary, "validate", a.fixture)
            peak = v["budget"]["decode_peak_bytes"]
            rc1, ok1, _ = run(a.binary, "validate", a.fixture, "--max-memory", str(peak))
            rc2, bad2, _ = run(a.binary, "validate", a.fixture, "--max-memory", str(peak - 1))
            check(f"CLI decode budget boundary: {peak} ok, {peak - 1} memory_limit",
                  rc1 == 0 and rc2 == 2 and bad2["error"] == "memory_limit" and bad2["phase"] == "decode", bad2)
            rc, g, _ = run(a.binary, "aggregate", a.fixture)
            qp, cp = g["budget"]["query_peak_bytes"], g["budget"]["combined_peak_bytes"]
            r1 = run(a.binary, "aggregate", a.fixture, "--max-query-memory", str(qp))
            r2 = run(a.binary, "aggregate", a.fixture, "--max-query-memory", str(qp - 1))
            r3 = run(a.binary, "aggregate", a.fixture, "--max-combined-memory", str(cp))
            r4 = run(a.binary, "aggregate", a.fixture, "--max-combined-memory", str(cp - 1))
            check(f"CLI query budget boundaries: query {qp}, combined {cp} exact",
                  r1[0] == 0 and r2[0] == 2 and r2[1]["phase"] == "query" and r2[1]["error"] == "memory_limit"
                  and r3[0] == 0 and r4[0] == 2 and r4[1]["error"] == "memory_limit", [r2[1], r4[1]])
        # Malformed weights are refused, never wrapped.
        for w, why in [("18446744073709551616", "2^64"), ("0", "zero"), ("-1", "negative"), ("01", "leading zero")]:
            text = generate(random.Random(1), 1, 1, 1)
            stack = next(json.loads(l) for l in text.splitlines() if json.loads(l)["type"] == "stack")
            text = text.replace(f'"weight":"{stack["weight"]}"', f'"weight":"{w}"', 1)
            path = os.path.join(tmp, "bad.jsonl")
            open(path, "w").write(text)
            rc, got, _ = run(a.binary, "aggregate", path)
            check(f"weight {why} refused with schema error", rc == 2 and got["error"] == "schema", got)
    fails = sum(r["status"] == "fail" for r in RESULTS)
    print(f"{len(RESULTS)} checks, {fails} failures")
    if a.json:
        json.dump({"tool": "exact_oracle.py", "binary": a.binary, "seed": a.seed, "results": RESULTS}, open(a.json, "w"),
                  indent=1)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
