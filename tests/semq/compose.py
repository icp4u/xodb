#!/usr/bin/env python3
"""Immutable ELF -> supervised C01 worker -> adapter -> xsq, checked against
source-grounded expectations (C02-R2, GPLv3).

usage: compose.py --supervise S --worker W --sleighhome H --xsq X --adapter A
                  --qx QXDIR --fx FXDIR --scratch DIR --out OUT.json

QXDIR/FXDIR hold binaries from tests/fixtures/semq/build_fixtures.sh and
tools/ghx/fixtures/build_fixtures.sh (gcc/clang, -O0/-O2) with .oracle maps.

What makes an expectation independent of the C01/C02 pipeline:
  * parameters are identified by the SysV x86-64 argument registers (ABI),
    never by Ghidra's inferred prototype;
  * calls are selected by import/symbol name from the ELF's own relocations
    and symbol table (the worker's import list is cross-checked against
    objdump's call targets);
  * each expectation states a property of the C source in qx.c/fx.c (which
    parameter can or cannot reach a value, which predicate guards a call);
    where the compiler legitimately changes the property (restrict reload,
    vectorised loop index) the expectation is derived from GNU objdump of
    the same bytes, not from the pipeline;
  * every instruction a result cites must be an instruction of the export
    whose bytes equal the file bytes at that address and that starts an
    objdump instruction.
Outcomes: pass, fail, declared_unreliable (the producer's graph-level
qualification says the graph cannot answer this) or declared_partial (a
call-level qualification -- inferred argument list or assumed callee ABI --
explains exactly the missing fact).  Declared outcomes are counted
separately and never as a pass.
"""
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

ap = argparse.ArgumentParser()
for k in ("supervise", "worker", "sleighhome", "xsq", "adapter", "qx", "fx", "scratch", "out"):
    ap.add_argument("--" + k, required=True)
A = ap.parse_args()
os.umask(0o022)
os.makedirs(A.scratch, exist_ok=True)
os.chmod(A.scratch, 0o755)

ARGREGS = [{"RDI", "EDI", "DI", "DIL"}, {"RSI", "ESI", "SI", "SIL"}, {"RDX", "EDX", "DX", "DL"},
           {"RCX", "ECX", "CX", "CL"}, {"R8", "R8D", "R8W", "R8B"}, {"R9", "R9D", "R9W", "R9B"}]
DATA = {"direct", "possible"}
SIGNED = {"INT_SLESS", "INT_SLESSEQUAL", "INT_SBORROW", "INT_SCARRY"}
UNSIGNED = {"INT_LESS", "INT_LESSEQUAL", "INT_CARRY"}
QX = ["qx-gcc-O0", "qx-gcc-O2", "qx-clang-O0", "qx-clang-O2"]
FX = ["fx-gcc-O0", "fx-gcc-O2", "fx-clang-O0", "fx-clang-O2"]
QX_FUNCS = ["qx_alloc", "qx_copy", "qx_branch_s", "qx_branch_u", "qx_sum", "qx_merge", "qx_indirect",
            "qx_alias", "qx_noalias", "qx_escape", "main"]
FX_FUNCS = ["fx_add", "fx_arith", "fx_switch", "fx_calls", "fx_loop", "main"]
results = []


def oracle(path):
    out = {}
    for line in open(path + ".oracle"):
        n, e, s = line.split()
        out[n] = (int(e, 16), int(s, 16))
    return out


# ---- export through the supervisor ------------------------------------------------

def requests():
    reqs = []
    for b in QX:
        path = os.path.join(A.qx, b)
        o = oracle(path)
        for fn in QX_FUNCS:
            reqs.append(("%s.%s" % (b, fn), path, o[fn], ""))
    for b in FX:
        path = os.path.join(A.fx, b)
        o = oracle(path)
        for fn in FX_FUNCS:
            reqs.append(("%s.%s" % (b, fn), path, o[fn], ""))
        if b.endswith("O2"):
            reqs.append(("%s.stripped.fx_calls" % b, path + ".stripped", o["fx_calls"], ""))
            reqs.append(("%s.stripped-map.fx_calls" % b, path + ".stripped", o["fx_calls"],
                         "\tfunction_map=%s.oracle" % path))
    return reqs


REQS = requests()
OUTDIR = os.path.join(A.scratch, "exports")
lines = "".join("DECOMPILE\tid=%s\telf=%s\tentry=0x%x\tsize=0x%x%s\n" % (rid, path, e, s, extra)
                for rid, path, (e, s), extra in REQS)
sup = subprocess.run([A.supervise, "-w", A.worker, "-s", A.sleighhome, "-o", OUTDIR, "-t", "60000"],
                     input=lines.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900,
                     env=dict(os.environ, TMPDIR=os.path.join(A.scratch)))
status = {}
for l in sup.stdout.decode().splitlines():
    if l.startswith("RESULT\t"):
        f = dict(kv.split("=", 1) for kv in l.split("\t")[1:])
        status[f["id"]] = f["status"]
EXPORT_OK = sup.returncode == 0 and all(status.get(r[0]) == "ok" for r in REQS)
results.append({"case": "export_all", "outcome": "pass" if EXPORT_OK else "fail",
                "detail": {"supervisor_rc": sup.returncode, "requests": len(REQS),
                           "not_ok": {k: v for k, v in status.items() if v != "ok"}}})


# ---- independent ELF facts ------------------------------------------------------------

_elf = {}


def elf(path):
    if path not in _elf:
        data = open(path, "rb").read()
        phoff, = struct.unpack_from("<Q", data, 32)
        phnum, = struct.unpack_from("<H", data, 56)
        segs = []
        for i in range(phnum):
            t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", data, phoff + 56 * i)
            if t == 1:
                segs.append((va, fsz, off))
        dis = subprocess.run(["objdump", "-d", "-w", "--no-show-raw-insn", path], stdout=subprocess.PIPE,
                             check=True, timeout=120).stdout.decode()
        starts, calls, funcs, cur = set(), {}, {}, None
        for line in dis.splitlines():
            m = re.match(r"^([0-9a-f]+) <([^>]+)>:$", line)
            if m:
                cur = m.group(2)
                funcs[cur] = []
                continue
            m = re.match(r"^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
            if m:
                a = int(m.group(1), 16)
                starts.add(a)
                if cur:
                    funcs[cur].append((a, m.group(2), m.group(3)))
                t = re.match(r"([0-9a-f]+) <([^>]+)>", m.group(3))
                if m.group(2) in ("call", "jmp") and t:
                    calls[a] = (int(t.group(1), 16), t.group(2).split("@")[0])
        _elf[path] = dict(data=data, segs=segs, starts=starts, calls=calls, funcs=funcs,
                          sha=hashlib.sha256(data).hexdigest())
    return _elf[path]


def file_bytes(e, addr, n):
    for va, fsz, off in e["segs"]:
        if va <= addr and addr + n <= va + fsz:
            return e["data"][off + addr - va: off + addr - va + n]
    return None


# ---- pipeline helpers ---------------------------------------------------------------------

class Case:
    def __init__(self, rid, path):
        self.rid, self.path = rid, path
        self.j = json.load(open(os.path.join(OUTDIR, rid + ".json")))
        self.xsg = os.path.join(A.scratch, rid + ".xsg")
        p = subprocess.run([sys.executable, A.adapter, os.path.join(OUTDIR, rid + ".json"), self.xsg],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        self.adapter_error = None if p.returncode == 0 else p.stderr.decode().strip()
        self.level = self.j["qualification"]["level"]
        self.codes = {r["code"] for r in self.j["qualification"]["reasons"]}
        self.ops = {o["id"]: o for o in self.j["high_pcode"]["ops"]}
        self.insn = {int(i["addr"], 16): i for i in self.j["instructions"]}
        self.params = {}
        for v in self.j["high_pcode"]["varnodes"]:
            if "input" in v["flags"] and v.get("register"):
                for i, fam in enumerate(ARGREGS):
                    if v["register"] in fam:
                        self.params.setdefault(i, []).append(int(v["id"][3:]))

    def calls_to(self, name):
        return [c for c in self.j["calls"] if c.get("target_name") == name]

    def returns(self):
        return [o for o in self.ops.values() if o["opcode"] == "RETURN" and len(o["in"]) >= 2]

    def xsq(self, *args):
        p = subprocess.run([A.xsq] + list(args[:1]) + [self.xsg] + list(args[1:]) + ["--json", "-", "--rows", "100000"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        if p.returncode not in (0, 3):
            raise AssertionError("xsq %s exited %d: %s" % (args, p.returncode, p.stderr.decode()[-300:]))
        r = json.loads(p.stdout)
        self.check_result(r)
        return r

    def check_result(self, r):
        q = r["input_qualification"]
        if q["level"] != self.level or q["artifact_id"] != self.j["artifact_id"]:
            raise AssertionError("qualification not preserved: %s vs %s" % (q, self.level))
        if r["verified_semantics"] is not False:
            raise AssertionError("xsq claimed verified semantics")
        e = elf(self.path)
        for c in r.get("instructions", []):
            a = int(c["address"], 16)
            ins = self.insn.get(a)
            if ins is None:
                raise AssertionError("cited %s is not an instruction of the export" % c["address"])
            fb = file_bytes(e, a, min(ins["length"], 32))
            if fb is None or fb.hex() != ins["bytes"] or a not in e["starts"]:
                raise AssertionError("citation %s does not resolve to file bytes/objdump" % c["address"])
        self.cited = getattr(self, "cited", 0) + len(r.get("instructions", []))

    def slice_op(self, op, k, data_only=False):
        args = ["slice", "--op", op["id"][3:], "--in", str(k)]
        return self.xsq(*(args + (["--data-only"] if data_only else [])))

    def rel(self, r, i):
        ids = set(self.params.get(i, []))
        if not ids:
            return "absent"
        best = None
        rank = {"direct": 0, "possible": 1, "control": 2}
        for row in r["contributions"]["rows"]:
            if row["value"]["id"] in ids and (best is None or rank[row["certainty"]] < rank[best]):
                best = row["certainty"]
        if best:
            return best
        return "irrelevant" if r["status"] == "ok" and r["exhaustive"] else "unknown"

    def in_data(self, r, i):
        return self.rel(r, i) in DATA

    def controls(self, op):
        return self.xsq("controls", "--op", op["id"][3:])


def record(case, build, prop, fn):
    rec = {"case": case, "build": build, "property": prop}
    try:
        detail = fn()
        rec["outcome"] = "pass"
        if detail:
            rec["detail"] = detail
    except Unreliable as u:
        rec["outcome"] = "declared_unreliable"
        rec["detail"] = str(u)
    except Partial as u:
        rec["outcome"] = "declared_partial"
        rec["detail"] = str(u)
    except AssertionError as e:
        rec["outcome"] = "fail"
        rec["detail"] = str(e)[:1500]
    except Exception as e:
        rec["outcome"] = "fail"
        rec["detail"] = "%s: %s" % (type(e).__name__, str(e)[:1500])
    results.append(rec)
    print("%-20s %-22s %-14s %s" % (rec["outcome"], build, case, rec.get("detail", "") if rec["outcome"] != "pass" else ""),
          flush=True)


class Unreliable(Exception):
    pass


class Partial(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise AssertionError(msg)


def usable(c):
    """A graph the producer declared unreliable is never used as an oracle-passing answer."""
    if c.adapter_error:
        if c.level == "unreliable":
            raise Unreliable("adapter refused an unreliable graph: %s" % c.adapter_error[-200:])
        raise AssertionError("adapter failed on a %s graph: %s" % (c.level, c.adapter_error[-300:]))
    if c.level == "unreliable":
        raise Unreliable("producer qualification unreliable: %s" % sorted(c.codes))


def one_call(c, name):
    cs = c.calls_to(name)
    if not cs:
        raise AssertionError("no call to %s in the export" % name)
    return c.ops[cs[0]["op"]]


def arg(c, name, k):
    op = one_call(c, name)
    if len(op["in"]) <= k + 1:
        call = [x for x in c.j["calls"] if x["op"] == op["id"]][0]
        if call.get("prototype") == "inferred" and "call_arguments_inferred" in c.codes:
            raise Partial("argument %d of %s not recovered; export declares call_arguments_inferred at %s"
                          % (k, name, call["pc"]))
        raise AssertionError("argument %d of %s not recovered (call has %d inputs, prototype %s)"
                             % (k, name, len(op["in"]) - 1, call.get("prototype")))
    return op, k + 1


def cond_params(c, ctl_result):
    direct = [x for x in ctl_result["controls"]["rows"] if x["relation"] == "direct"]
    need(direct, "no direct control dependence")
    out = []
    for d in direct:
        s = c.xsq("slice", "--vn", str(d["condition"]["id"]), "--data-only")
        ops = {d["condition_defined_by"]["opcode"]} if d.get("condition_defined_by") else set()
        for p in s["paths"]:
            ops |= {st["read_by"]["opcode"] for st in p["steps"] if st.get("read_by")}
        out.append((s, ops))
    return out


# ---- expectations -----------------------------------------------------------------------

def objdump_reload_into_eax(path, fn):
    """True if the function loads its return register through a non-frame pointer."""
    body = elf(path)["funcs"].get(fn, [])
    return any(m == "mov" and re.match(r"^(0x[0-9a-f]+)?\(%r(?!bp|sp)\w+\),%eax$", ops) for _, m, ops in body)


def qx_cases(b):
    path = os.path.join(A.qx, b)
    C = {fn: Case("%s.%s" % (b, fn), path) for fn in QX_FUNCS}

    def alloc():
        c = C["qx_alloc"]; usable(c)
        op, k = arg(c, "malloc", 0)
        r = c.slice_op(op, k, data_only=True)
        need(c.in_data(r, 0) and c.in_data(r, 1), "count/size must reach malloc's size: %s %s" % (c.rel(r, 0), c.rel(r, 1)))
        need(not c.in_data(r, 2), "flag must not reach malloc's size (got %s)" % c.rel(r, 2))
        conds = cond_params(c, c.controls(op))
        need(any(c.in_data(s, 0) and not c.in_data(s, 1) and not c.in_data(s, 2) for s, _ in conds),
             "malloc must be guarded by a predicate on count only")
        return {"malloc_size": {i: c.rel(r, i) for i in range(3)}}

    def copy():
        c = C["qx_copy"]; usable(c)
        op, k = arg(c, "memcpy", 2)
        r = c.slice_op(op, k, data_only=True)
        need(c.in_data(r, 2), "len must reach memcpy's length")
        for i in (0, 1, 3):
            need(not c.in_data(r, i), "param %d must not reach memcpy's length (got %s)" % (i, c.rel(r, i)))
        conds = cond_params(c, c.controls(op))
        need(any(c.in_data(s, 2) and c.in_data(s, 3) for s, _ in conds), "memcpy must be guarded by len vs cap")

    def branch(fn, signed):
        def check():
            c = C[fn]; usable(c)
            for callee, mine, other in (("qx_left", 0, 1), ("qx_right", 1, 0)):
                op, k = arg(c, callee, 0)
                r = c.slice_op(op, k, data_only=True)
                need(c.in_data(r, mine) and not c.in_data(r, other),
                     "%s argument: param %d %s, param %d %s" % (callee, mine, c.rel(r, mine), other, c.rel(r, other)))
                conds = cond_params(c, c.controls(op))
                need(any(c.in_data(s, 0) and c.in_data(s, 1) for s, _ in conds), "%s guard must compare a and b" % callee)
                ops = set().union(*(o for _, o in conds))
                want, avoid = (SIGNED, UNSIGNED) if signed else (UNSIGNED, SIGNED)
                need(ops & want and not ops & avoid, "%s guard comparison ops %s (want %s)" % (callee, sorted(ops), "signed" if signed else "unsigned"))
        return check

    def sum_():
        c = C["qx_sum"]; usable(c)
        rets = c.returns()
        need(rets, "no RETURN with a value")
        rs = [c.slice_op(op, 1) for op in rets]
        need(any(c.in_data(r, 2) for r in rs), "bias must reach the return value")
        need(any(c.in_data(r, 0) for r in rs), "v must reach the return value (loaded elements)")
        need(any(c.rel(r, 1) in DATA | {"control"} for r in rs), "n must control the return value")
        need(all(not r["memory_complete"] for r in rs if c.in_data(r, 0)), "loads of v[i] must leave memory incomplete")

    def merge():
        c = C["qx_merge"]; usable(c)
        rets = c.returns()
        if not rets and "callee_abi_assumed" in c.codes:
            raise Partial("return value not recovered; export declares callee_abi_assumed (the callee "
                          "preserves RAX here although the default ABI says it may clobber it)")
        need(rets, "no RETURN with a value")
        for op in rets:
            d = c.slice_op(op, 1, data_only=True)
            need(c.in_data(d, 1) and c.in_data(d, 2), "x and y must reach the merged value")
            need(not c.in_data(d, 0), "c must not be data of the merged value (got %s)" % c.rel(d, 0))
            f = c.slice_op(op, 1)
            need(c.rel(f, 0) == "control", "c must select (control) the merged value, got %s" % c.rel(f, 0))

    def indirect():
        c = C["qx_indirect"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1)
            need(c.rel(r, 2) == "direct", "y must directly reach f(x)+y (got %s)" % c.rel(r, 2))
            need({b["kind"] for b in r["boundaries"]} & {"call_result"}, "unknown callee result must be a boundary")
            need(not r["exhaustive"], "a slice through an unknown call cannot be exhaustive")
            need(c.rel(r, 1) == "possible", "x reaches only through the unknown callee (possible), got %s" % c.rel(r, 1))

    def alias():
        c = C["qx_alias"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1, data_only=True)
            need(c.in_data(r, 3), "b may reach *p through q==p (must not be excluded), got %s" % c.rel(r, 3))
            need(c.in_data(r, 2), "a must reach *p")
            need(not r["memory_complete"], "may-alias load cannot be memory-complete")

    def noalias():
        c = C["qx_noalias"]; usable(c)
        reload = objdump_reload_into_eax(path, "qx_noalias")
        for op in c.returns():
            r = c.slice_op(op, 1, data_only=True)
            need(c.in_data(r, 2), "a must reach the return")
            if reload:
                need(c.in_data(r, 3), "objdump shows a reload through p: b may reach it, got %s" % c.rel(r, 3))
            else:
                need(not c.in_data(r, 3), "objdump shows no reload (restrict): b must not reach the return, got %s" % c.rel(r, 3))
        return {"objdump_reload": reload}

    def escape():
        c = C["qx_escape"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1)
            need(c.in_data(r, 0), "a must reach x+1")
            kinds = {b["kind"] for b in r["boundaries"]}
            need(kinds & {"call_may_write", "indirect_call"}, "escaped local must be bounded by the call (%s)" % sorted(kinds))
            need(not r["exhaustive"], "escaped local cannot be exhaustive")

    def main_noreturn():
        c = C["main"]
        e = elf(path)
        objcalls = [a for a, (t, n) in e["calls"].items() if n == "__stack_chk_fail"
                    and oracle(path)["main"][0] <= a < sum(oracle(path)["main"])]
        need(objcalls, "objdump: main has no __stack_chk_fail call")
        stk = c.calls_to("__stack_chk_fail")
        need(stk, "export: call to __stack_chk_fail not named")
        blocks = {b["id"]: b for b in c.j["blocks"]}
        for s in stk:
            blk = blocks[c.ops[s["op"]]["block"]]
            need(not blk["succ"], "block with the __stack_chk_fail call must not fall through (succ %s)" % blk["succ"])
        need("flow_past_unknown_noreturn_candidate" not in c.codes, "flow past noreturn still flagged")

    record("alloc_size", b, "count,size reach malloc size; flag excluded; guard on count", alloc)
    record("copy_len", b, "len reaches memcpy length; guard compares len and cap", copy)
    record("branch_signed", b, "callee arguments and signed guard", branch("qx_branch_s", True))
    record("branch_unsigned", b, "callee arguments and unsigned guard", branch("qx_branch_u", False))
    record("sum_loop", b, "bias,v data; n control; memory explicit", sum_)
    record("merge_gating", b, "x,y data; c only selects", merge)
    record("indirect_call", b, "y direct; callee result boundary; x possible", indirect)
    record("alias", b, "b may alias into *p", alias)
    record("noalias", b, "restrict reload decided by objdump", noalias)
    record("escape", b, "escaped local bounded by call", escape)
    record("noreturn_main", b, "__stack_chk_fail ends flow", main_noreturn)
    return C


def fx_cases(b):
    path = os.path.join(A.fx, b)
    C = {fn: Case("%s.%s" % (b, fn), path) for fn in FX_FUNCS}

    def add():
        c = C["fx_add"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1)
            need(c.rel(r, 0) == "direct" and c.rel(r, 1) == "direct", "a,b direct")
            need(r["exhaustive"] and r["status"] == "ok", "a+b slice must be exhaustive")
            need(c.rel(r, 2) in ("absent", "irrelevant"), "no third input")

    def arith():
        c = C["fx_arith"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1)
            for i in range(3):
                need(c.rel(r, i) == "direct", "param %d must be direct (got %s)" % (i, c.rel(r, i)))
            need(not [x for x in c.controls(op)["controls"]["rows"] if x["relation"] == "direct"],
                 "straight-line function has no control dependence")

    def switch():
        c = C["fx_switch"]; usable(c)
        rets = c.returns()
        need(rets, "no RETURN with a value")
        d = [c.slice_op(op, 1, data_only=True) for op in rets]
        f = [c.slice_op(op, 1) for op in rets]
        need(any(c.in_data(r, 1) for r in d), "x must reach the result")
        need(not any(c.in_data(r, 0) for r in d), "k selects only; must not be data")
        need(any(c.rel(r, 0) == "control" for r in f), "k must control the result")

    def calls():
        c = C["fx_calls"]; usable(c)
        for op in c.returns():
            r = c.slice_op(op, 1)
            need(c.in_data(r, 1) and c.in_data(r, 2), "a and b must reach f(fx_add(a,b), b)")
            need(c.rel(r, 0) != "irrelevant", "sel selects the callee; it cannot be irrelevant")
            if "jump_table_hypothesis" not in c.codes:
                need({x["kind"] for x in r["boundaries"]} & {"call_result", "indirect_call"},
                     "indirect call result must be a boundary")

    def loop():
        c = C["fx_loop"]; usable(c)
        rets = c.returns()
        rs = [c.slice_op(op, 1) for op in rets]
        need(any(c.in_data(r, 0) for r in rs), "v must reach s")
        need(any(c.rel(r, 1) in DATA | {"control"} for r in rs), "n must control s")

    record("fx_add", b, "a+b exact", add)
    record("fx_arith", b, "all three params direct, no control", arith)
    record("fx_switch", b, "x data, k control only", switch)
    record("fx_calls", b, "a,b data through unknown/indirect call", calls)
    record("fx_loop", b, "v data, n control", loop)
    if b.endswith("O2"):
        def stripped():
            nomap = Case("%s.stripped.fx_calls" % b, path + ".stripped")
            withmap = Case("%s.stripped-map.fx_calls" % b, path + ".stripped")
            add_entry = oracle(path)["fx_add"][0]
            truth = any(t == add_entry for a, (t, n) in elf(path + ".stripped")["calls"].items()
                        if oracle(path)["fx_calls"][0] <= a < sum(oracle(path)["fx_calls"]))
            need(truth, "objdump: fx_calls does not call fx_add")
            has = lambda cs: any(x.get("target") and int(x["target"], 16) == add_entry for x in cs.j["calls"])
            need(has(withmap) and withmap.level != "unreliable", "function_map export must keep the call")
            if not has(nomap):
                need(nomap.level == "unreliable", "wrong stripped graph must be unreliable, is %s" % nomap.level)
                if nomap.adapter_error is None:
                    r = nomap.xsq("slice", "--op", nomap.returns()[0]["id"][3:], "--in", "1")
                    need(r["result_trust"] == "graph_unreliable", "query over it must say graph_unreliable")
            return {"nomap_level": nomap.level, "nomap_has_call": has(nomap),
                    "adapter": "refused" if nomap.adapter_error else "accepted"}
        record("stripped_no_map", b, "missing function starts: correct or unreliable, preserved downstream", stripped)
    return C


for b in QX:
    if EXPORT_OK:
        qx_cases(b)
for b in FX:
    if EXPORT_OK:
        fx_cases(b)

# The documented demonstration query (also printed in HANDOFF.md).
counts = {k: sum(1 for r in results if r["outcome"] == k)
          for k in ("pass", "fail", "declared_unreliable", "declared_partial")}
with open(A.out, "w") as f:
    json.dump({"suite": "compose", "counts": counts, "results": results,
               "export_requests": len(REQS)}, f, indent=1)
print("compose: %(pass)d pass, %(fail)d fail, %(declared_unreliable)d declared_unreliable, "
      "%(declared_partial)d declared_partial" % counts)
sys.exit(1 if counts["fail"] or not EXPORT_OK else 0)
