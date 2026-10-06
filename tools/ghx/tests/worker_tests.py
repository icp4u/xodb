#!/usr/bin/env python3
"""ghx_worker identity, race, citation and flow tests (C01-R2, GPLv3).

usage: worker_tests.py WORKER SLEIGHHOME FIXDIR SCRATCH OUT.json

FIXDIR holds fixtures built by fixtures/build_fixtures.sh (fx-{gcc,clang}-{O0,O2}
with .stripped copies and .oracle maps).  Independent oracles used here: the
ELF bytes themselves (parsed by this script, not by the worker), GNU objdump
instruction boundaries and call targets, and nm-derived function bounds.
Schema-valid status=ok alone is never counted as a semantic pass.
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

WORKER, SLEIGH, FIX, SCRATCH, OUT = sys.argv[1:6]
HERE = os.path.dirname(os.path.abspath(__file__))
VALIDATE = os.path.join(HERE, "..", "ghx_validate.py")
os.umask(0o022)
os.makedirs(SCRATCH, exist_ok=True)
os.chmod(SCRATCH, 0o755)
TMP = os.path.join(SCRATCH, "tmp")
os.makedirs(TMP, exist_ok=True)
ENV = dict(os.environ, TMPDIR=TMP)
BUILDS = ["fx-gcc-O0", "fx-gcc-O2", "fx-clang-O0", "fx-clang-O2"]
FUNCS = ["fx_arith", "fx_loop", "fx_struct", "fx_calls", "fx_switch", "fx_add", "main"]
VOLATILE_TOP = ("timing",)
results = []


def sha(b):
    return hashlib.sha256(b).hexdigest()


def oracle(build):
    out = {}
    for line in open(os.path.join(FIX, build + ".oracle")):
        n, e, s = line.split()
        out[n] = (int(e, 16), int(s, 16))
    return out


def request(rid, elf, fn, build, extra=""):
    e, s = oracle(build)[fn]
    return "DECOMPILE\tid=%s\telf=%s\tentry=0x%x\tsize=0x%x\tname=%s%s\n" % (rid, elf, e, s, fn, extra)


class Worker:
    def __init__(self, sleighhome=SLEIGH, extra=()):
        self.p = subprocess.Popen([WORKER, "--sleighhome", sleighhome, "--test-hooks"] + list(extra),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)

    def send(self, line):
        self.p.stdin.write(line.encode())
        self.p.stdin.flush()

    def read(self):
        hdr = self.p.stdout.readline().decode()
        if not hdr.startswith("RESULT\t"):
            raise AssertionError("bad worker header %r (stderr %s)" % (hdr, self.p.stderr.read(2000)))
        f = dict(kv.split("=", 1) for kv in hdr.rstrip("\n").split("\t")[1:])
        body = self.p.stdout.read(int(f["bytes"]))
        return json.loads(body)

    def ask(self, line):
        self.send(line)
        return self.read()

    def close(self):
        try:
            self.send("QUIT\n")
        except BrokenPipeError:
            pass
        self.p.stdin.close()
        rc = self.p.wait(timeout=60)
        self.p.stdout.close()
        self.p.stderr.close()
        return rc


def once(line, sleighhome=SLEIGH):
    w = Worker(sleighhome)
    try:
        return w.ask(line)
    finally:
        w.close()


def wait_file(path, secs=20):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(path):
            return open(path).read()
        time.sleep(0.002)
    raise AssertionError("barrier %s never reached" % path)


def strip_volatile(j):
    j = json.loads(json.dumps(j))
    for k in VOLATILE_TOP:
        j.pop(k, None)
    j["request"].pop("id", None)
    j["request"].pop("elf", None)
    j["request"].pop("function_map", None)
    j["image"].pop("path", None)
    j["function"]["function_map"].pop("path", None)
    j["producer"].pop("spec_snapshot_dir", None)
    return j


# ---- independent ELF reading -------------------------------------------------

def loads(data):
    phoff, = struct.unpack_from("<Q", data, 32)
    phnum, = struct.unpack_from("<H", data, 56)
    segs = []
    for i in range(phnum):
        t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", data, phoff + 56 * i)
        if t == 1:
            segs.append((va, fsz, msz, off, fl))
    return segs


def file_bytes(segs, data, addr, n, full=None):
    """File bytes at addr; full (the whole instruction length) must lie in
    the file-backed part of one PF_X segment."""
    full = n if full is None else full
    for va, fsz, msz, off, fl in segs:
        if fl & 1 and va <= addr and addr + full <= va + fsz:
            return data[off + addr - va: off + addr - va + n]
    return None


_objdump = {}


def objdump(path):
    if path not in _objdump:
        out = subprocess.run(["objdump", "-d", "-w", "--no-show-raw-insn", path], stdout=subprocess.PIPE,
                             check=True, timeout=60).stdout.decode()
        starts, calls = set(), {}
        for line in out.splitlines():
            m = re.match(r"^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
            if m:
                a = int(m.group(1), 16)
                starts.add(a)
                if m.group(2) == "call":
                    t = re.match(r"([0-9a-f]+) <([^>]+)>", m.group(3))
                    if t:
                        calls[a] = (int(t.group(1), 16), t.group(2))
        _objdump[path] = (starts, calls)
    return _objdump[path]


def cite(j, path):
    """Every reported instruction's bytes must be the file's bytes at that
    address and every instruction start must be an objdump instruction start."""
    data = open(path, "rb").read()
    assert j["image"]["sha256"] == sha(data), "image.sha256 is not the hash of the analysed file"
    segs = loads(data)
    starts, _ = objdump(path)
    n = 0
    for ins in j["instructions"]:
        if "error" in ins:
            continue
        a, ln = int(ins["addr"], 16), ins["length"]
        fb = file_bytes(segs, data, a, min(ln, 32), ln)
        assert fb is not None, "instruction %s is not file-backed executable bytes" % ins["addr"]
        assert fb.hex() == ins["bytes"], "bytes differ at %s: file %s export %s" % (ins["addr"], fb.hex(), ins["bytes"])
        assert a in starts, "instruction %s is not an objdump instruction start" % ins["addr"]
        n += 1
    return n


def validate(path):
    p = subprocess.run([sys.executable, VALIDATE, path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    assert p.returncode == 0, p.stdout.decode()[-500:]


def test(name):
    def deco(fn):
        rec = {"name": name}
        try:
            rec.update(fn() or {})
            rec["outcome"] = "pass"
        except AssertionError as e:
            rec["outcome"] = "fail"
            rec["error"] = str(e)[:2000]
        except Exception as e:
            rec["outcome"] = "fail"
            rec["error"] = "%s: %s" % (type(e).__name__, str(e)[:2000])
        print("%s %s %s" % (rec["outcome"].upper(), name, rec.get("error", "")), flush=True)
        results.append(rec)
        return fn
    return deco


def save(j, name):
    d = os.path.join(SCRATCH, "exports")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name + ".json")
    with open(p, "w") as f:
        json.dump(j, f)
    return p


# ---- corpus --------------------------------------------------------------------

CORPUS = {}


@test("corpus_export_validate_cite")
def _():
    w = Worker()
    count = cited = 0
    levels = {}
    try:
        for b in BUILDS:
            for variant in ("", ".stripped", ".stripped-map"):
                path = os.path.join(FIX, b + (".stripped" if variant else ""))
                extra = "\tfunction_map=%s" % os.path.join(FIX, b + ".oracle") if variant == ".stripped-map" else ""
                for fn in FUNCS:
                    rid = "%s%s.%s" % (b, variant, fn)
                    j = w.ask(request(rid, path, fn, b, extra))
                    assert j["status"] == "ok", (rid, j.get("error"))
                    validate(save(j, rid))
                    cited += cite(j, path)
                    CORPUS[rid] = j
                    levels[j["qualification"]["level"]] = levels.get(j["qualification"]["level"], 0) + 1
                    count += 1
    finally:
        assert w.close() == 0
    # mapped data reads stay available: switch tables are read from the
    # non-executable .rodata segment of the same snapshot
    tables = sorted(k for k, j in CORPUS.items() if k.endswith(".fx_switch") and j["jump_tables"])
    assert tables, "no switch table recovered anywhere in the corpus"
    for k in tables:
        assert all(t["targets"] for t in CORPUS[k]["jump_tables"]), k
    return dict(exports=count, instructions_cited=cited, qualification_levels=levels, switch_tables=tables)


@test("noreturn_import_stops_flow")
def _():
    """main calls __stack_chk_fail as its last in-range instruction in some
    builds (objdump oracle).  With imports the worker must not flow past it;
    without imports any flow past it must be flagged unreliable."""
    checked = []
    w = Worker()
    try:
        for b in BUILDS:
            path = os.path.join(FIX, b)
            e, s = oracle(b)["main"]
            _, calls = objdump(path)
            data = open(path, "rb").read()
            starts = sorted(objdump(path)[0])
            for a, (t, name) in calls.items():
                if not (e <= a < e + s) or not name.startswith("__stack_chk_fail"):
                    continue
                fall = starts[starts.index(a) + 1]
                last = fall >= e + s
                with_imports = CORPUS.get("%s.main" % b) or w.ask(request(b + ".main", path, "main", b))
                addrs = {int(i["addr"], 16) for i in with_imports["instructions"]}
                stk = [c for c in with_imports["calls"] if c.get("target_name") == "__stack_chk_fail"]
                assert stk and int(stk[0]["target"], 16) == t, "%s: call to __stack_chk_fail not named" % b
                imp = [i for i in with_imports["imports"] if i["name"] == "__stack_chk_fail"]
                assert imp and imp[0]["noreturn"] and int(imp[0]["stub"], 16) == t, "%s: import record" % b
                if last:
                    assert fall not in addrs, "%s: flow continued past noreturn __stack_chk_fail" % b
                    codes = {r["code"] for r in with_imports["qualification"]["reasons"]}
                    assert "flow_past_unknown_noreturn_candidate" not in codes, codes
                no_imp = w.ask(request(b + ".main-noimp", path, "main", b, "\timports=0"))
                naddrs = {int(i["addr"], 16) for i in no_imp["instructions"]}
                ncodes = {r["code"] for r in no_imp["qualification"]["reasons"]}
                flowed = last and fall in naddrs
                if flowed:
                    assert "flow_past_unknown_noreturn_candidate" in ncodes and no_imp["qualification"]["level"] == "unreliable", \
                        "%s: flow past unknown callee not qualified (%s)" % (b, ncodes)
                checked.append(dict(build=b, call=hex(a), last_in_range=last, flowed_without_imports=flowed))
    finally:
        w.close()
    assert len(checked) >= 3, "expected __stack_chk_fail calls in main for most builds: %s" % checked
    assert sum(c["flowed_without_imports"] for c in checked) >= 1, "regression input lost its failure mode"
    return dict(cases=checked)


@test("stripped_O2_without_map_is_qualified_or_correct")
def _():
    out = []
    for cc in ("gcc", "clang"):
        b = "fx-%s-O2" % cc
        add = oracle(b)["fx_add"][0]
        _, calls = objdump(os.path.join(FIX, b + ".stripped"))
        e, s = oracle(b)["fx_calls"]
        truth = any(e <= a < e + s and t == add for a, (t, _) in calls.items())
        assert truth, "objdump: %s fx_calls does not call fx_add directly" % b
        nomap = CORPUS["%s.stripped.fx_calls" % b]
        withmap = CORPUS["%s.stripped-map.fx_calls" % b]
        has = lambda j: any(c.get("target") and int(c["target"], 16) == add for c in j["calls"])
        assert has(withmap), "%s: function_map export lost the direct call" % b
        assert has(nomap) or nomap["qualification"]["level"] == "unreliable", \
            "%s: wrong stripped export not marked unreliable" % b
        assert nomap["qualification"]["function_starts"]["symbols"] == "absent"
        out.append(dict(build=b, nomap_correct=has(nomap), nomap_level=nomap["qualification"]["level"]))
    return dict(cases=out)


# ---- identity -------------------------------------------------------------------

def copy(src, name):
    p = os.path.join(SCRATCH, name)
    shutil.copyfile(src, p)
    return p


BASE_ELF = None


@test("determinism_and_identity_rule")
def _():
    global BASE_ELF
    BASE_ELF = copy(os.path.join(FIX, "fx-gcc-O2"), "base.elf")
    fmap = copy(os.path.join(FIX, "fx-gcc-O2.oracle"), "base.map")
    line = request("d1", BASE_ELF, "fx_switch", "fx-gcc-O2", "\tfunction_map=" + fmap)
    a = once(line)
    b = once(line)
    w = Worker()
    try:
        c = w.ask(line)
        d = w.ask(line.replace("id=d1", "id=d2"))
    finally:
        w.close()
    for x in (a, b, c, d):
        assert x["status"] == "ok", x.get("error")
    ids = {x["artifact_id"] for x in (a, b, c, d)}
    assert len(ids) == 1, ids
    sa = json.dumps(strip_volatile(a), sort_keys=True)
    for x in (b, c, d):
        assert json.dumps(strip_volatile(x), sort_keys=True) == sa, "non-volatile fields differ between identical runs"
    other = copy(BASE_ELF, "same-bytes-other-path.elf")
    e = once(line.replace(BASE_ELF, other))
    assert e["artifact_id"] == a["artifact_id"], "artifact identity depends on the path"
    return dict(artifact_id=a["artifact_id"], runs=5)


def touch_xml(path, comment):
    """insert an XML comment after the declaration: still valid, different bytes"""
    os.chmod(path, 0o644)
    text = open(path).read()
    at = text.index("?>") + 2 if text.startswith("<?xml") else 0
    open(path, "w").write(text[:at] + "\n<!-- %s -->" % comment + text[at:])


def mutated_sleighhome(name, rel, append):
    root = os.path.join(SCRATCH, name)
    if os.path.exists(root):
        shutil.rmtree(root)
    shutil.copytree(os.path.join(SLEIGH, "Ghidra", "Processors", "x86", "data", "languages"),
                    os.path.join(root, "Ghidra", "Processors", "x86", "data", "languages"),
                    ignore=shutil.ignore_patterns("*.sinc", "*.slaspec", "*.dwarf", "*.opinion", "*.info", "*.gdis", "old"))
    if rel:
        touch_xml(os.path.join(root, "Ghidra", "Processors", "x86", "data", "languages", rel), append)
    return root


@test("each_semantic_input_changes_identity")
def _():
    base = request("s0", BASE_ELF, "fx_loop", "fx-gcc-O2")
    j0 = once(base)
    assert j0["status"] == "ok"
    ids = {"baseline": j0["artifact_id"]}
    # one byte of .comment (not code) changed in a copy of the image
    data = bytearray(open(BASE_ELF, "rb").read())
    idx = data.find(b"GCC: (GNU)")
    assert idx > 0
    data[idx] ^= 0x20
    elf2 = os.path.join(SCRATCH, "comment-byte.elf")
    open(elf2, "wb").write(data)
    fmap = copy(os.path.join(FIX, "fx-gcc-O2.oracle"), "sens.map")
    fmap2 = os.path.join(SCRATCH, "sens2.map")
    open(fmap2, "w").write(open(fmap).read() + "extra_fn 0x401000 0x4\n")
    variants = {
        "image_byte": base.replace(BASE_ELF, elf2),
        "function_map": base.rstrip("\n") + "\tfunction_map=%s\n" % fmap,
        "function_map_line": base.rstrip("\n") + "\tfunction_map=%s\n" % fmap2,
        "cspec_id": base.rstrip("\n") + "\tcspec=windows\n",
        "symbols": base.rstrip("\n") + "\tsymbols=0\n",
        "imports": base.rstrip("\n") + "\timports=0\n",
        "bounds": base.rstrip("\n") + "\tbounds=strict\n",
        "size": base.replace("\tsize=0x43", "\tsize=0x42"),
        "name": base.replace("name=fx_loop", "name=fx_loop2"),
        "entry": request("s1", BASE_ELF, "fx_calls", "fx-gcc-O2"),
    }
    for k, line in variants.items():
        j = once(line)
        assert j["status"] == "ok", (k, j.get("error"))
        ids[k] = j["artifact_id"]
    # specification changes: the selected cspec, and an unrelated cspec
    sh1 = mutated_sleighhome("sh-cspec", "x86-64-gcc.cspec", "semantic input changed")
    sh2 = mutated_sleighhome("sh-other", "x86-64-win.cspec", "unrelated spec changed")
    sh0 = mutated_sleighhome("sh-same", None, None)
    j1, j2, j3 = once(base, sh1), once(base, sh2), once(base, sh0)
    assert j3["artifact_id"] == j0["artifact_id"], "an identical specification copy changed identity"
    assert j1["language"]["cspec_sha256"] != j0["language"]["cspec_sha256"]
    assert j2["language"]["cspec_sha256"] == j0["language"]["cspec_sha256"]
    assert j2["language"]["spec_set_sha256"] != j0["language"]["spec_set_sha256"]
    ids["selected_cspec_bytes"] = j1["artifact_id"]
    ids["unrelated_spec_bytes"] = j2["artifact_id"]
    vals = list(ids.values())
    assert len(set(vals)) == len(vals), "identity collision: %s" % ids
    return dict(variants=sorted(ids))


# ---- races ------------------------------------------------------------------------

def race(name, fn, setup_line, barrier_key, mutate):
    """Start a request that stops at a worker barrier, mutate, release."""
    bar = os.path.join(SCRATCH, "bar-" + name)
    for s in (".ready", ".go"):
        if os.path.exists(bar + s):
            os.unlink(bar + s)
    w = Worker()
    try:
        w.send(setup_line.rstrip("\n") + "\t%s=%s\n" % (barrier_key, bar))
        wait_file(bar + ".ready")
        mutate()
        open(bar + ".go", "w").close()
        j = w.read()
    finally:
        rc = w.close()
    assert rc == 0, rc
    return j


@test("race_elf_rename_and_inplace_after_snapshot")
def _():
    out = {}
    pristine = open(os.path.join(FIX, "fx-gcc-O2"), "rb").read()
    other = open(os.path.join(FIX, "fx-clang-O2"), "rb").read()
    ref = once(request("r0", copy(os.path.join(FIX, "fx-gcc-O2"), "ref.elf"), "fx_switch", "fx-gcc-O2"))
    for mode in ("rename", "inplace", "truncate"):
        target = os.path.join(SCRATCH, "race-%s.elf" % mode)
        open(target, "wb").write(pristine)

        def mutate():
            if mode == "rename":
                tmp = target + ".new"
                open(tmp, "wb").write(other)
                os.rename(tmp, target)
            elif mode == "inplace":
                with open(target, "r+b") as f:
                    f.seek(0x1000)
                    f.write(b"\xcc" * 0x800)
            else:
                open(target, "wb").close()
        j = race("elf-" + mode, None, request("r-" + mode, target, "fx_switch", "fx-gcc-O2"), "test_barrier", mutate)
        assert j["status"] == "ok", j.get("error")
        assert j["image"]["sha256"] == sha(pristine), "analysis not bound to the frozen bytes"
        assert j["artifact_id"] == ref["artifact_id"], "frozen analysis differs from the reference"
        segs = loads(pristine)
        for ins in j["instructions"]:
            fb = file_bytes(segs, pristine, int(ins["addr"], 16), min(ins["length"], 32))
            assert fb is not None and fb.hex() == ins["bytes"], "instruction bytes not from the snapshot"
        out[mode] = "frozen"
    return out


@test("race_elf_mutation_during_read_rejected")
def _():
    pristine = open(os.path.join(FIX, "fx-gcc-O2"), "rb").read()
    out = {}
    for mode in ("inplace", "rename"):
        target = os.path.join(SCRATCH, "midread-%s.elf" % mode)
        open(target, "wb").write(pristine)

        def mutate():
            if mode == "inplace":
                with open(target, "r+b") as f:
                    f.seek(len(pristine) - 64)
                    f.write(b"\x00" * 16)
            else:
                tmp = target + ".new"
                open(tmp, "wb").write(pristine[::-1])
                os.rename(tmp, target)
        j = race("mid-" + mode, None, request("m-" + mode, target, "fx_switch", "fx-gcc-O2"), "test_read_barrier", mutate)
        if j["status"] == "ok":
            assert j["image"]["sha256"] == sha(pristine), "mixed identity after mid-read %s" % mode
            out[mode] = "frozen"
        else:
            assert j["error"]["code"] == "input_unstable", j["error"]
            out[mode] = "rejected_input_unstable"
    assert out["inplace"] == "rejected_input_unstable", out
    return out


@test("race_function_map_after_snapshot")
def _():
    elf = copy(os.path.join(FIX, "fx-gcc-O2.stripped"), "fm.elf")
    fmap = copy(os.path.join(FIX, "fx-gcc-O2.oracle"), "race.map")
    orig = open(fmap, "rb").read()
    line = request("f1", elf, "fx_calls", "fx-gcc-O2", "\tfunction_map=" + fmap)
    ref = once(line)

    def mutate():
        tmp = fmap + ".new"
        open(tmp, "w").write("bogus 0x401000 0x10\n")
        os.rename(tmp, fmap)
    j = race("fmap", None, line, "test_barrier", mutate)
    assert j["status"] == "ok", j.get("error")
    assert j["function"]["function_map"]["sha256"] == sha(orig)
    assert j["artifact_id"] == ref["artifact_id"]
    return dict(result="frozen")


@test("race_spec_source_and_private_snapshot")
def _():
    sh = mutated_sleighhome("sh-race", None, None)
    line = request("p1", BASE_ELF, "fx_switch", "fx-gcc-O2")
    ref = once(line, sh)
    cspec = os.path.join(sh, "Ghidra", "Processors", "x86", "data", "languages", "x86-64-gcc.cspec")
    bar = os.path.join(SCRATCH, "bar-spec")
    for s in (".ready", ".go"):
        if os.path.exists(bar + s):
            os.unlink(bar + s)
    # (1) the source spec changes after the worker's snapshot: frozen
    w = Worker(sh, ["--test-spec-barrier", bar])
    try:
        snapdir = wait_file(bar + ".ready")
        touch_xml(cspec, "changed after snapshot")
        open(bar + ".go", "w").close()
        j = w.ask(line)
        assert j["status"] == "ok", j.get("error")
        assert j["artifact_id"] == ref["artifact_id"], "source spec change leaked into a running worker"
        # (2) the private snapshot is modified between requests: rejected, worker exits
        snapped = os.path.join(snapdir, "Ghidra", "Processors", "x86", "data", "languages", "x86-64-gcc.cspec")
        touch_xml(snapped, "tampered")
        k = w.ask(line.replace("id=p1", "id=p2"))
        assert k["status"] == "error" and k["error"]["code"] == "spec_snapshot_modified", k.get("error")
    finally:
        rc = w.close()
    assert rc == 3, "worker must exit after a modified snapshot (rc %s)" % rc
    after = once(line, sh)
    assert after["artifact_id"] != ref["artifact_id"], "changed source spec did not change a new worker's identity"
    return dict(source_change="frozen_in_running_worker", private_change="rejected_and_worker_exited")


# ---- malformed inputs --------------------------------------------------------------

@test("malformed_and_unmapped_inputs")
def _():
    # the review's 120-byte image
    ident = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
    hdr = struct.pack("<16sHHIQQQIHHHHHH", ident, 2, 62, 1, 0x400000, 64, 0, 0, 64, 56, 1, 64, 0, 0)
    ph = struct.pack("<IIQQQQQQ", 1, 5, 4096, 0x400000, 0x400000, 16, 16, 4096)
    past = os.path.join(SCRATCH, "past-eof.elf")
    open(past, "wb").write(hdr + ph)
    w = Worker()
    codes = {}
    try:
        def ask(rid, line):
            j = w.ask(line)
            assert j["status"] == "error", (rid, j["status"])
            codes[rid] = j["error"]["code"]
        ask("past_eof", "DECOMPILE\tid=a\telf=%s\tentry=0x400000\n" % past)
        e, s = oracle("fx-gcc-O2")["main"]
        fx = os.path.join(FIX, "fx-gcc-O2")
        ask("rodata_entry", "DECOMPILE\tid=b\telf=%s\tentry=0x400000\n" % fx)
        ask("range_out", "DECOMPILE\tid=c\telf=%s\tentry=0x%x\tsize=0x100000\n" % (fx, e))
        ask("missing", "DECOMPILE\tid=d\telf=%s/nope\tentry=0x%x\n" % (SCRATCH, e))
        ask("directory", "DECOMPILE\tid=e\telf=%s\tentry=0x%x\n" % (SCRATCH, e))
        ask("bad_field", "DECOMPILE\tid=f\telf=%s\tentry=0x%x\tbogus=1\n" % (fx, e))
    finally:
        assert w.close() == 0
    want = {"past_eof": "malformed_elf", "rodata_entry": "entry_unmapped", "range_out": "range_unmapped",
            "missing": "io_error", "directory": "io_error", "bad_field": "bad_request"}
    assert codes == want, codes
    empty = os.path.join(SCRATCH, "empty-sleighhome")
    os.makedirs(empty, exist_ok=True)
    j = once(request("g", os.path.join(FIX, "fx-gcc-O2"), "main", "fx-gcc-O2"), empty)
    assert j["status"] == "error" and j["error"]["code"] == "spec_snapshot", j.get("error")
    return dict(codes=codes)


leftover = os.listdir(TMP)
results.append({"name": "no_private_snapshot_dirs_left", "outcome": "pass" if not leftover else "fail",
                "error": "" if not leftover else str(leftover)})
fails = [r for r in results if r["outcome"] != "pass"]
with open(OUT, "w") as f:
    json.dump({"suite": "ghx_worker", "tests": results, "passed": len(results) - len(fails), "failed": len(fails)},
              f, indent=1)
print("worker tests: %d passed, %d failed" % (len(results) - len(fails), len(fails)))
sys.exit(1 if fails else 0)
