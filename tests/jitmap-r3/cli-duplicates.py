#!/usr/bin/env python3
"""C07-R3 duplicate-evidence checks through the candidate CLI.

usage: cli-duplicates.py XODB_JITMAP OUT_DIR

Writes owned synthetic jitdumps and perf maps into OUT_DIR (created; must not
exist), runs `XODB_JITMAP resolve` on source combinations and prints one JSON
line per case plus a summary. Exits 1 when any case differs from contract v3
section 5: conflicting sources stay ambiguous and uncorroborated; explicitly
identical copies resolve with `corroborated`; mixed perf-map/jitdump and
separate perf maps never corroborate.
"""
import json
import os
import struct
import subprocess
import sys

PID = 31337
ADDR = 0x9000


def header(endian="<", mach=62, time=1):
    return struct.pack(endian + "6I2Q", 0x4A695444, 1, 40, mach, 0, PID, time, 0)


def load(index, code, t=100, name=b"owned", tid=PID, endian="<"):
    body = struct.pack(endian + "IIQQQQ", PID, tid, ADDR, ADDR, len(code), index) + name + b"\0" + code
    return struct.pack(endian + "IIQ", 0, 16 + len(body), t) + body


def close(t=200, endian="<"):
    return struct.pack(endian + "IIQ", 3, 16, t)


def main():
    cli, out = sys.argv[1], sys.argv[2]
    os.makedirs(out)
    files = {
        "object-a.dump": header() + load(7, b"A") + close(),
        "object-b.dump": header() + load(8, b"B") + close(),
        "object-a-copy.dump": header() + load(7, b"A") + close(),
        "object-a-swapped.dump": header(">") + load(7, b"A", endian=">") + close(endian=">"),
        "object-a-index-8.dump": header() + load(8, b"A") + close(),
        "object-a-byte-b.dump": header() + load(7, b"B") + close(),
        "object-a-later.dump": header() + load(7, b"A", t=110) + close(),
        "object-a-other-tid.dump": header() + load(7, b"A", tid=PID + 1) + close(),
        "object-a-other-producer.dump": header(time=2) + load(7, b"A") + close(),
        "owned.map": b"9000 1 owned\n",
        "owned-copy.map": b"9000 1 owned\n",
    }
    for name, data in files.items():
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
    cases = [
        ("conflicting-sources", "defect", ["object-a.dump", "object-b.dump"], "ambiguous", False),
        ("different-code-index", "defect", ["object-a.dump", "object-a-index-8.dump"], "ambiguous", False),
        ("different-code-bytes", "defect", ["object-a.dump", "object-a-byte-b.dump"], "ambiguous", False),
        ("different-load-time", "defect", ["object-a.dump", "object-a-later.dump"], "ambiguous", False),
        ("different-thread", "defect", ["object-a.dump", "object-a-other-tid.dump"], "ambiguous", False),
        ("different-producer-header", "defect", ["object-a.dump", "object-a-other-producer.dump"], "ambiguous", False),
        ("mixed-jitdump-perfmap", "defect", ["object-a.dump", "owned.map"], "ambiguous", False),
        ("two-perfmaps", "defect", ["owned.map", "owned-copy.map"], "ambiguous", False),
        ("identical-copy", "duplicate", ["object-a.dump", "object-a-copy.dump"], "resolved", True),
        ("identical-other-byte-order", "duplicate", ["object-a.dump", "object-a-swapped.dump"], "resolved", True),
        ("single-source", "baseline", ["object-a.dump"], "resolved", False),
    ]
    ident = ["--pid", str(PID), "--start-ticks", "1", "--boot-id", "10" * 16, "--clock", "monotonic",
             "--clock-scope", "20" * 16, "--coverage-end", "1000000"]
    failed = 0
    for name, claim, sources, outcome, corroborated in cases:
        args = [cli, "resolve"] + ident
        for s in sources:
            args += ["--perfmap" if s.endswith(".map") else "--jitdump", os.path.join(out, s)]
        args += ["--at", "%#x@150" % ADDR]
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
        with open(os.path.join(out, name + ".json"), "w") as f:
            f.write(p.stdout)
        r = json.loads(p.stdout)["results"][0]["result"] if p.returncode == 0 else None
        got = r["outcome"] if r else "exit %d" % p.returncode
        corr = bool(r) and "corroborated" in r["reasons"]
        ok = r is not None and got == outcome and corr == corroborated and r["total_candidates"] == len(sources)
        failed += not ok
        print(json.dumps({"case": name, "claim": claim, "outcome": got, "expected": outcome, "corroborated": corr,
                          "total": r["total_candidates"] if r else None, "pass": ok}))
    print(json.dumps({"summary": "cli-duplicates", "cases": len(cases), "failed": failed}))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
