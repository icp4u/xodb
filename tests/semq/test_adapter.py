#!/usr/bin/env python3
"""Adapter tests on fresh C01-R2 exports: deterministic conversion,
qualification passthrough, and loud failure on generated malformed variants.
usage: test_adapter.py ADAPTER EXPORT.json [WRONG_EXPORT.json]
EXPORT is an ok export of fx-gcc-O0 fx_loop (block layout used below);
WRONG_EXPORT is a known-wrong stripped -O2 fx_calls export (PIC heuristic)."""
import copy
import shutil
import json
import os
import subprocess
import sys
import tempfile

adapter, src = sys.argv[1], sys.argv[2]
wrong = sys.argv[3] if len(sys.argv) > 3 else None
base = json.load(open(src))
fails = []
tmp = tempfile.mkdtemp(prefix="xsq-adapter-", dir=os.environ.get("TMPDIR"))
os.chmod(tmp, 0o755)

def convert(doc, extra=()):
    path = os.path.join(tmp, "in.json")
    with open(path, "w") as f:
        json.dump(doc, f)
    out = os.path.join(tmp, "out.xsg")
    p = subprocess.run([sys.executable, adapter, path, out] + list(extra),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    return p.returncode, p.stderr.decode(), out

# determinism on the unmodified real export
outs = []
for k in range(2):
    out = os.path.join(tmp, "det%d.xsg" % k)
    subprocess.run([sys.executable, adapter, src, out], check=True, stdout=subprocess.DEVNULL)
    outs.append(open(out, "rb").read())
if outs[0] != outs[1]:
    fails.append("conversion not deterministic")
q = base["qualification"]
want = "qualification level=%s" % q["level"]
line = [l for l in outs[0].decode().splitlines() if l.startswith("qualification ")]
if not line or not line[0].startswith(want) or ("artifact=" + base["artifact_id"]) not in line[0]:
    fails.append("qualification not passed through: %r" % line)

def mutate(name, fn, needle):
    doc = copy.deepcopy(base)
    fn(doc)
    rc, err, _ = convert(doc)
    if rc != 1 or needle not in err:
        fails.append("%s: rc=%d err=%r" % (name, rc, err.strip()[-200:]))

h = lambda d: d["high_pcode"]
def first(d, opcode):
    return next(o for o in h(d)["ops"] if o["opcode"] == opcode)

mutate("schema", lambda d: d.update(schema="other"), "not an xodb.ghidra.function_graph")
mutate("version", lambda d: d.update(schema_version="0.9.0"), "unsupported schema_version")
# exports the validator does not admit are refused too (C01-R3 review N5)
for v in ("0.1.0", "0.2.0", "0.3.0"):
    mutate("version-" + v, lambda d, v=v: d.update(schema_version=v), "unsupported schema_version")
mutate("status", lambda d: d.update(status="error"), "export status")
mutate("raw-kind", lambda d: h(d).update(kind="raw_pcode"), "not decompiler_final_ssa")
mutate("space-type", lambda d: d["address_spaces"][2].update(type="weird"), "unknown address space type")
mutate("block-unknown-op", lambda d: d["blocks"][0]["ops"].append("op:999999"), "lists unknown op")
mutate("op-two-blocks", lambda d: d["blocks"][1]["ops"].append(d["blocks"][0]["ops"][0]), "listed in two blocks")
mutate("pred-no-succ", lambda d: d["blocks"][0]["pred"].append("bb:6"), "no matching succ")
mutate("succ-no-pred", lambda d: d["blocks"][6]["succ"].append({"to": "bb:0", "slot": 0, "kind": "flow", "flags": []}), "without matching pred")
mutate("unknown-pred", lambda d: d["blocks"][0]["pred"].append("bb:77"), "unknown predecessor")
mutate("edge-kind", lambda d: d["blocks"][0]["succ"][0].update(kind="sideways"), "unknown edge kind")
mutate("unknown-vn", lambda d: first(d, "INT_SLESS")["in"].__setitem__(0, "vn:999999"), "unknown varnode")
mutate("free-vn", lambda d: next(v for v in h(d)["varnodes"] if "input" in v["flags"])["flags"].remove("input") or
       next(v for v in h(d)["varnodes"] if v["def"] is None and v["space"] == "register")["flags"].append("free"), "free non-constant")
mutate("numeric-offset", lambda d: h(d)["varnodes"][0].update(offset=4198932), "canonical hex string")
mutate("offset-65-bits", lambda d: h(d)["varnodes"][0].update(offset="0x1" + "0" * 16), "exceeds 64 bits")
def bad_id(d):
    op = first(d, "COPY")
    for b in d["blocks"]:
        b["ops"] = ["operation-12" if x == op["id"] else x for x in b["ops"]]
    op["id"] = "operation-12"
mutate("bad-op-id", bad_id, "bad id")
mutate("orphan-op", lambda d: h(d)["ops"].append(dict(first(d, "COPY"), id="op:88888")), "is in no block")
mutate("unknown-space", lambda d: h(d)["varnodes"][0].update(space="nowhere"), "unknown space")
# --elf must match the export's image hash
rc, err, _ = convert(base, ["--elf", adapter])
if rc != 1 or "does not match" not in err:
    fails.append("elf hash mismatch accepted: %r" % err)
# A real C01 wrong decompilation (stripped -O2, "PIC construction") is refused,
# and its producer qualification says unreliable.
if wrong:
    w = json.load(open(wrong))
    if w["qualification"]["level"] != "unreliable":
        fails.append("wrong export not qualified unreliable")
    p = subprocess.run([sys.executable, adapter, wrong, os.path.join(tmp, "w.xsg")],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if p.returncode != 1 or b"no block starts at function entry" not in p.stderr:
        fails.append("entry-less real export accepted")
shutil.rmtree(tmp)
for f in fails:
    print("FAIL", f)
print("adapter: %d failures" % len(fails))
sys.exit(1 if fails else 0)
