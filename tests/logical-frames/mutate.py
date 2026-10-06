"""Deterministic mutation runs of real exports through the (sanitized) reader.

usage: mutate.py XODB_LFRAMES EXPORT.jsonl COUNT SEED
Every run must exit 0 (accepted, possibly with warnings) or 2 (rejected with
a named error); a crash, sanitizer report, hang or malformed output fails.
Line-boundary truncations must be accepted and reported incomplete.
"""
import collections
import json
import os
import random
import subprocess
import sys
import tempfile

cli, export, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = open(export, "rb").read()
lines = data.split(b"\n")[:-1]
rng = random.Random(seed)
outcomes = collections.Counter()
failures = []
workdir = tempfile.mkdtemp(prefix="lf-mutate-", dir=os.environ.get("TMPDIR"))
os.chmod(workdir, 0o755)
path = os.path.join(workdir, "m.jsonl")


def mutation(i):
    kind = i % 8
    if kind == 0:  # arbitrary byte truncation
        return "truncate_bytes", data[:rng.randrange(len(data))]
    if kind == 1:  # truncate at a line boundary (interrupted producer)
        n = rng.randrange(1, len(lines))
        return "truncate_lines", b"\n".join(lines[:n]) + b"\n"
    if kind == 2:  # flip one byte
        b = bytearray(data)
        b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
        return "bitflip", bytes(b)
    if kind == 3:  # random byte
        b = bytearray(data)
        b[rng.randrange(len(b))] = rng.randrange(256)
        return "byte", bytes(b)
    if kind == 4:  # delete a line
        n = rng.randrange(len(lines))
        return "delete_line", b"\n".join(lines[:n] + lines[n + 1:]) + b"\n"
    if kind == 5:  # duplicate a line
        n = rng.randrange(len(lines))
        return "duplicate_line", b"\n".join(lines[:n + 1] + lines[n:]) + b"\n"
    if kind == 6:  # swap two lines
        a, c = rng.randrange(len(lines)), rng.randrange(len(lines))
        m = list(lines)
        m[a], m[c] = m[c], m[a]
        return "swap_lines", b"\n".join(m) + b"\n"
    # splice a random record into another position
    a, c = rng.randrange(len(lines)), rng.randrange(len(lines))
    return "splice", b"\n".join(lines[:c] + [lines[a][: rng.randrange(1, len(lines[a]) + 1)]] + lines[c:]) + b"\n"


for i in range(count):
    name, blob = mutation(i)
    with open(path, "wb") as f:
        f.write(blob)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:exitcode=99",
               UBSAN_OPTIONS="halt_on_error=1:exitcode=98")
    try:
        p = subprocess.run([cli, "validate", path], capture_output=True, timeout=30, env=env)
    except subprocess.TimeoutExpired:
        failures.append({"i": i, "mutation": name, "problem": "timeout"})
        continue
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = None
    if p.returncode not in (0, 2) or out is None or p.stderr:
        failures.append({"i": i, "mutation": name, "rc": p.returncode, "stderr": p.stderr.decode(errors="replace")[:400]})
        continue
    if name == "truncate_lines" and p.returncode == 0 and out.get("complete") is not False:
        failures.append({"i": i, "mutation": name, "problem": "line truncation reported complete"})
    outcomes["%s:%s" % (name, out.get("error", "accepted_complete" if out.get("complete") else "accepted_incomplete"))] += 1
os.unlink(path)
os.rmdir(workdir)
print(json.dumps({"export": export, "runs": count, "seed": seed, "failures": failures,
                  "outcomes": dict(sorted(outcomes.items()))}, indent=1))
sys.exit(1 if failures else 0)
