#!/usr/bin/env python3
"""Bounded mutation fuzz of xodb-jvm-import (use a sanitizer build).

  fuzz.py IMPORTER SEED_DIR OUT_DIR [--iterations N] [--seconds S] [--seed N]

SEED_DIR holds *.jfr.json, *.dump.json, *.print.txt and *.probes.json seeds. A
finding is a crash, sanitizer report, timeout or exit status outside the
documented set {0,1,2,4,5}; each is saved for reproduction.
"""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import time

os.umask(0o022)
SOURCES = {".jfr.json": "jfr-json", ".dump.json": "thread-dump-json",
           ".print.txt": "thread-print", ".probes.json": "coroutine-probes"}
TOKENS = [b"{", b"}", b"[", b"]", b'"', b"\\", b"\\u", b"\\ud800", b"\\udc00", b"\xff", b"\xc3",
          b"\xed\xa0\x80", b"\x00", b"\n", b"-", b"1e999", b"18446744073709551616", b"null", b"true",
          b'"frames":', b'"truncated":true', b"\tat ", b'"x" #', b" tid=0x", b" nid=0x", b"(", b")",
          b"_COROUTINE._CREATION._(x.kt:1)", b"/0x1f", b"@", b"//", b":", b",", b"-1"]


def mutate(rng, data):
    data = bytearray(data)
    for _ in range(rng.randint(1, 8)):
        op = rng.randrange(6)
        pos = rng.randrange(len(data) + 1)
        if op == 0 and data:
            data[min(pos, len(data) - 1)] = rng.randrange(256)
        elif op == 1:
            data[pos:pos] = rng.choice(TOKENS)
        elif op == 2 and data:
            del data[pos:pos + rng.randint(1, 64)]
        elif op == 3 and data:
            a = rng.randrange(len(data))
            data[pos:pos] = data[a:a + rng.randint(1, 256)]
        elif op == 4:
            data = data[:pos]
        else:
            data[pos:pos] = rng.choice(TOKENS) * rng.randint(1, 300)
    return bytes(data[: 4 << 20])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("importer")
    ap.add_argument("seeds")
    ap.add_argument("out")
    ap.add_argument("--iterations", type=int, default=4000)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--seed", type=int, default=6)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    seeds = [(p, src) for p in sorted(Path(a.seeds).iterdir()) for suf, src in SOURCES.items()
             if p.name.endswith(suf)]
    if not seeds:
        raise SystemExit("no seeds")
    work = out / "case"
    findings, counts, deadline = [], {}, time.time() + a.seconds
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1", UBSAN_OPTIONS="halt_on_error=1")
    i = 0
    for i in range(a.iterations):
        if time.time() > deadline:
            break
        path, src = seeds[i % len(seeds)]
        data = mutate(rng, path.read_bytes())
        work.write_bytes(data)
        query = rng.choice([["--query", "document"], ["--query", "lframes"], ["--query", "lframes-check"],
                            ["--query", "evidence"], ["--query", "evidence", "--max-total-bytes", "1500000"],
                            ["--query", "aggregate", "--kind", "execution_sample", "--by", "stack"],
                            ["--query", "stacks", "--limit", "3"], ["--max-records", "3"],
                            ["--max-stack-frames", "2"]])
        argv = [a.importer, "--source", src, *query, str(work)]
        try:
            p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, env=env)
            rc, err = p.returncode, p.stderr.decode("utf-8", "replace")
            out_text = p.stdout.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            rc, err, out_text = "timeout", "", ""
        counts[str(rc)] = counts.get(str(rc), 0) + 1
        # C05-R2: an accepted import must always adapt into a document the shared
        # reader accepts and that agrees with it (lframes-check exit 6 = disagreement).
        # C05-R3: the evidence bundle prefixes errors by phase; a document the
        # adapter emitted but the reader refused ("decode:") or that does not join
        # back to the import ("index:") is a composition defect. Budget refusals are not.
        compose_defect = '"api":"jvm_evidence"' in out_text and \
            ('"message":"decode: ' in out_text or '"message":"index: ' in out_text) and \
            '"error":"memory_limit"' not in out_text
        if rc not in (0, 1, 2, 4, 5) or compose_defect or "Sanitizer" in err or "runtime error" in err:
            name = out / f"finding-{len(findings)}-{src}"
            name.write_bytes(data)
            findings.append({"file": name.name, "argv": argv[:-1], "exit": rc, "stderr": err[-3000:]})
    report = {"iterations": i + 1, "seed": a.seed, "exit_counts": counts, "findings": findings,
              "seeds": [p.name for p, _ in seeds]}
    work.unlink(missing_ok=True)
    (out / "fuzz-report.json").write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "findings"}), "findings:", len(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
