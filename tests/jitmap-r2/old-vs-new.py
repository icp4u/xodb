#!/usr/bin/env python3
"""Compare the original C07 CLI (nested scan) with the C07-R2 CLI (index).

usage: old-vs-new.py OLD_XODB_JITMAP NEW_XODB_JITMAP INPUT_DIR [TIMEOUT_SECONDS]

INPUT_DIR holds jitdumps written by `jitmap-scaling --write DIR`, named
FAMILY-N.dump. For each input both CLIs run (a) preparation only and (b) six
hot-address queries in one invocation, each bounded by TIMEOUT (default 300 s).
Prints one JSON object per input: input sha256, wall times, and whether
outcomes, exact totals, reasons and stored candidates agree. A timeout is
reported as such, never as agreement. Differences allowed by contract v1 are
counted separately: when more than 16 candidates exist, R2 reports the reason
union of its stored candidates only (a subset of the original union).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

PID, T0 = 31337, 1000000
A = 0x7F0000100000
BOOT = "b0" + "00" * 15
SCOPE = "010203" + "00" * 13
MAPPED = "070707" + "00" * 13


def last_time(family, n):
    if family == "same_time":
        return T0
    if family == "nested":
        return T0 + n - 1
    return T0 + 10 * (n - 1)


def hot(family, n):
    return A + 16 * n if family == "nested" else A + 8


def run(cli, args, timeout):
    start = time.monotonic()
    try:
        p = subprocess.run([cli, "resolve"] + args, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, time.monotonic() - start, "timeout"
    elapsed = time.monotonic() - start
    if p.returncode != 0:
        return None, elapsed, "exit %d: %s" % (p.returncode, p.stderr.decode(errors="replace")[:200])
    return json.loads(p.stdout), elapsed, None


def summary(result):
    r = result["result"]
    cands = [(c["code"]["version"], c["state"], tuple(c["reasons"])) for c in r["candidates"]]
    return r["outcome"], r["total_candidates"], set(r["reasons"]), cands


def main():
    old, new, directory = sys.argv[1], sys.argv[2], sys.argv[3]
    timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 300.0
    inputs = []
    for name in os.listdir(directory):
        m = re.match(r"(.+)-(\d+)\.dump$", name)
        if m:
            inputs.append((m.group(1), int(m.group(2)), name))
    for family, n, name in sorted(inputs):
        path = os.path.join(directory, name)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        last = last_time(family, n)
        base = ["--pid", str(PID), "--start-ticks", "1", "--boot-id", BOOT, "--clock", "monotonic",
                "--clock-scope", SCOPE, "--coverage-end", str(last + 100000)]
        if family == "uncertain":
            base += ["--slack", "25", "--map-offset", "1000", "--map-uncertainty", "40", "--map-target-scope", MAPPED]
        base += ["--jitdump", path]
        times = [T0 - 1, T0, (T0 + last) // 2, (T0 + last) // 2 + 5, last + 1]
        ats = ["%#x@%d" % (hot(family, n), t) for t in times] + ["%#x" % hot(family, n)]
        query_args = base + sum((["--at", a] for a in ats), [])
        row = {"family": family, "versions": n, "input_sha256": sha, "queries": len(ats)}
        for label, cli in (("old", old), ("new", new)):
            _, prep, err = run(cli, base, timeout)
            out, total, qerr = run(cli, query_args, timeout)
            row[label] = {"prepare_seconds": round(prep, 6), "prepare_plus_queries_seconds": round(total, 6),
                          "error": err or qerr}
            row[label + "_results"] = out
        o, nw = row.pop("old_results"), row.pop("new_results")
        if o is None or nw is None:
            row["comparison"] = "not_compared"
        else:
            exact = allowed = differ = 0
            for ro, rn in zip(o["results"], nw["results"]):
                so, sn = summary(ro), summary(rn)
                if so == sn:
                    exact += 1
                elif (so[0] == sn[0] == "ambiguous" and so[1] == sn[1] and so[1] > 16
                      and sn[2] <= so[2] and rn["result"]["total_exact"]):
                    allowed += 1
                else:
                    differ += 1
            row["comparison"] = {"identical": exact, "truncated_reason_subset": allowed, "different": differ}
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
