#!/usr/bin/env python3
"""ghx_worker instruction-admission and function-map regressions (C01-R3/R4, GPLv3).

usage: boundary_tests.py WORKER SLEIGHHOME SCRATCH OUT.json [VALIDATE]

Every input is a small synthetic x86-64 ELF written by this script.  The
oracle is the ELF itself, parsed here: an exported instruction is acceptable
only if all of its bytes are file bytes of one PF_X PT_LOAD and equal the
exported bytes.  Cases come from the C01-R2 review (truncated suffix, strict
span, non-executable destination, empty/incomplete/malformed maps) plus
truncation at every byte of representative instructions, exact-end success,
one-byte-short strict bounds, segment gaps, unmapped and memory-only
destinations, mapped read-only data reads, and map duplicate/range records.
A refusal (error) or an explicit unreliable qualification naming the refused
address are the honest outcomes; status=ok/complete with such bytes fails.
Tests named r4_* come from the C01-R3 review (N1-N6): undecodable truncation,
a refusal hidden as "undecoded", function maps without an entry record,
non-canonical map hex, the schema/contract gate and the strict one-byte-short
error code.  Tests named r5_* come from the C01-R4 review (R4-1..R4-3): the
exact "<owner>.cold" suffix, declared-extent conflicts, and validate --map.
"""
import json
import os
import re
import struct
import subprocess
import sys

WORKER, SLEIGH, SCRATCH, OUT = sys.argv[1:5]
VALIDATE = sys.argv[5] if len(sys.argv) > 5 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ghx_validate.py")
os.umask(0o022)
os.makedirs(SCRATCH, exist_ok=True)
os.chmod(SCRATCH, 0o755)
TMP = os.path.join(SCRATCH, "tmp")
os.makedirs(TMP, exist_ok=True)
ENV = dict(os.environ, TMPDIR=TMP)
BASE = 0x401000
R, W, X = 4, 2, 1
results = []


def elf(name, segments):
    """segments: (vaddr, flags, payload, extra_memsz); one page each."""
    out = bytearray(0x1000 * (len(segments) + 1))
    struct.pack_into('<16sHHIQQQIHHHHHH', out, 0, b'\x7fELF\x02\x01\x01' + b'\0' * 9,
                     2, 62, 1, BASE, 64, 0, 0, 64, 56, len(segments), 64, 0, 0)
    off = 0
    for i, (va, flags, payload, extra) in enumerate(segments):
        off = 0x1000 * (i + 1)
        struct.pack_into('<IIQQQQQQ', out, 64 + 56 * i, 1, flags, off, va, va, len(payload),
                         len(payload) + extra, 0x1000)
        out[off:off + len(payload)] = payload
    out = out[:off + len(segments[-1][2])]
    path = os.path.join(SCRATCH, name + ".elf")
    with open(path, "wb") as f:
        f.write(out)
    return path, segments


def ask(lines):
    p = subprocess.run([WORKER, "--sleighhome", SLEIGH], input=("".join(lines) + "QUIT\n").encode(),
                       capture_output=True, env=ENV, timeout=60)
    out, docs = p.stdout, []
    while out:
        hdr, _, out = out.partition(b"\n")
        n = int(dict(kv.split("=", 1) for kv in hdr.decode().split("\t")[1:])["bytes"])
        docs.append(json.loads(out[:n]))
        out = out[n:]
    assert p.returncode == 0, "worker exit %d: %s" % (p.returncode, p.stderr[-400:])
    return docs


def req(rid, path, entry=BASE, size=None, extra=""):
    s = "\tsize=0x%x" % size if size is not None else ""
    return "DECOMPILE\tid=%s\telf=%s\tentry=0x%x%s\tname=t_entry\timports=0%s\n" % (rid, path, entry, s, extra)


def one(rid, path, **kw):
    return ask([req(rid, path, **kw)])[0]


def file_exec_bytes(segs, addr, n):
    for va, flags, payload, _ in segs:
        if flags & X and va <= addr and addr + n <= va + len(payload):
            return payload[addr - va:addr - va + n]
    return None


def cite(j, segs):
    """Every exported instruction with bytes must be real PF_X file bytes."""
    bad = []
    for i in j.get("instructions", []):
        if "bytes" not in i:
            continue
        a, n = int(i["addr"], 16), i["length"]
        real = file_exec_bytes(segs, a, n)
        if real is None or real.hex() != i["bytes"]:
            bad.append((i["addr"], n, i["bytes"]))
    assert not bad, "fabricated or non-executable instruction evidence: %s" % bad


def reasons(j):
    return {(r["code"], r.get("addr")) for r in j["qualification"]["reasons"]}


def validate(j, name):
    path = os.path.join(SCRATCH, name + ".json")
    with open(path, "w") as f:
        json.dump(j, f)
    p = subprocess.run([sys.executable, VALIDATE, path], capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, "validator: %s" % p.stdout.strip()


def test(name):
    def deco(fn):
        rec = {"name": name}
        try:
            rec.update(fn() or {})
            rec["outcome"] = "pass"
        except AssertionError as e:
            rec["outcome"] = "fail"
            rec["error"] = str(e)[:2000]
        except Exception as e:  # a harness failure is a failure, never a skip
            rec["outcome"] = "fail"
            rec["error"] = "%s: %s" % (type(e).__name__, e)
        print("%s %s %s" % (rec["outcome"].upper(), name, rec.get("error", "")))
        results.append(rec)
        return fn
    return deco


def refused_at_entry(j, why):
    assert j["status"] == "error", "status %s level %s insns %s" % (
        j["status"], j.get("qualification", {}).get("level"),
        [(i["addr"], i.get("bytes")) for i in j.get("instructions", [])])
    assert j["error"]["code"] == "instruction_refused" and why in j["error"]["message"], j["error"]


def refused_on_path(j, segs, addr, why):
    assert j["status"] == "ok", j.get("error")
    cite(j, segs)
    assert j["qualification"]["level"] == "unreliable", j["qualification"]
    assert ("instruction_refused_" + why, "0x%x" % addr) in reasons(j), reasons(j)
    ins = {i["addr"]: i for i in j["instructions"]}
    assert ins.get("0x%x" % addr, {}).get("admission") == "refused", ins.get("0x%x" % addr)
    validate(j, "v-%x-%s" % (addr, why))


# representative multi-byte instructions (ret imm16, call rel32, lea, mov imm64)
INSNS = {"ret_imm16": bytes.fromhex("c20400"), "call_rel32": bytes.fromhex("e800000000"),
         "lea_rip": bytes.fromhex("488d0500000000"), "mov_imm64": bytes.fromhex("48b81122334455667788")}


@test("review1_truncated_ret_suffix_refused")
def _():
    p, segs = elf("trunc-ret", [(BASE, R | X, b"\xc2", 0)])
    refused_at_entry(one("a", p, size=1, extra="\tbounds=strict"), "not_file_backed_executable")


@test("truncation_at_every_byte_entry_and_second_insn")
def _():
    n = 0
    for name, ins in INSNS.items():
        for k in range(1, len(ins)):
            p, segs = elf("t-%s-%d" % (name, k), [(BASE, R | X, ins[:k], 0)])
            refused_at_entry(one("e", p), "not_file_backed_executable")
            p, segs = elf("t2-%s-%d" % (name, k), [(BASE, R | X, b"\x90" + ins[:k], 0)])
            refused_on_path(one("s", p), segs, BASE + 1, "not_file_backed_executable")
            n += 2
    return dict(cases=n)


@test("exact_segment_end_succeeds")
def _():
    out = []
    for body in (b"\xc3", b"\x90\xc3", INSNS["ret_imm16"], b"\x90" + INSNS["ret_imm16"]):
        p, segs = elf("exact-%s" % body.hex(), [(BASE, R | X, body, 0)])
        j = one("x", p, size=len(body), extra="\tbounds=strict")
        assert j["status"] == "ok", j.get("error")
        cite(j, segs)
        assert j["qualification"]["level"] == "qualified", j["qualification"]  # stripped, no map
        assert {r[0] for r in reasons(j)} == {"stripped_without_function_starts"}, reasons(j)
        last = max(j["instructions"], key=lambda i: int(i["addr"], 16))
        assert int(last["addr"], 16) + last["length"] == BASE + len(body) and last["admission"] == "admitted", last
        validate(j, "exact-%s" % body.hex())
        out.append(body.hex())
    return dict(bodies=out)


@test("review2_strict_span_one_byte_short")
def _():
    p, segs = elf("complete-ret", [(BASE, R | X, INSNS["ret_imm16"], 0)])
    refused_at_entry(one("a", p, size=1, extra="\tbounds=strict"), "outside_strict_bounds")
    refused_at_entry(one("b", p, size=2, extra="\tbounds=strict"), "outside_strict_bounds")
    j = one("c", p, size=3, extra="\tbounds=strict")
    assert j["status"] == "ok" and j["function"]["instructions_crossing_declared_bounds"] == [], j.get("error")
    p, segs = elf("nop-ret", [(BASE, R | X, b"\x90" + INSNS["ret_imm16"], 0)])
    refused_on_path(one("d", p, size=3, extra="\tbounds=strict"), segs, BASE + 1, "outside_strict_bounds")
    j = one("e", p, size=4, extra="\tbounds=strict")
    assert j["status"] == "ok" and j["qualification"]["level"] == "qualified", j.get("error")


@test("advisory_bounds_report_span_crossing")
def _():
    p, segs = elf("adv-nop-ret", [(BASE, R | X, b"\x90" + INSNS["ret_imm16"], 0)])
    j = one("a", p, size=2)
    assert j["status"] == "ok", j.get("error")
    cite(j, segs)
    assert j["function"]["instructions_crossing_declared_bounds"] == ["insn:0x%x" % (BASE + 1)], j["function"]
    assert ("instruction_crosses_declared_bounds", "0x%x" % (BASE + 1)) in reasons(j), reasons(j)
    validate(j, "adv-cross")
    # entry+size overflow is refused before analysis
    j = ask(["DECOMPILE\tid=o\telf=%s\tentry=0xffffffffffffffff\tsize=0x2\n" % p])[0]
    assert j["status"] == "error" and j["error"]["code"] == "bad_request", j.get("error")


@test("segment_gap_truncated_insn_refused")
def _():
    # seg1 ends after a 2-byte prefix of mov imm64; seg2 (exec) starts one page later
    p, segs = elf("gap", [(BASE, R | X, b"\x90" + INSNS["mov_imm64"][:2], 0),
                          (BASE + 0x1000, R | X, INSNS["mov_imm64"][2:] + b"\xc3", 0)])
    refused_on_path(one("g", p), segs, BASE + 1, "not_file_backed_executable")


@test("review3_nonexec_destination_refused")
def _():
    p, segs = elf("branch-nonexec", [(BASE, R | X, b"\xe9\xfb\x0f\x00\x00", 0), (BASE + 0x1000, R | W, b"\xc3", 0)])
    refused_on_path(one("n", p), segs, BASE + 0x1000, "not_file_backed_executable")


@test("unmapped_destination_refused")
def _():
    p, segs = elf("branch-unmapped", [(BASE, R | X, b"\xe9\xfb\x0f\x00\x00", 0)])
    refused_on_path(one("u", p), segs, BASE + 0x1000, "not_file_backed_executable")


@test("memory_only_tail_refused")
def _():
    # executable segment: file holds one nop; the next bytes exist only as memsz zeros
    p, segs = elf("bss-tail", [(BASE, R | X, b"\x90", 64)])
    refused_on_path(one("m", p), segs, BASE + 1, "not_file_backed_executable")
    # a branch into the tail is refused the same way
    p, segs = elf("bss-branch", [(BASE, R | X, b"\xeb\x10", 64)])
    refused_on_path(one("b", p), segs, BASE + 0x12, "not_file_backed_executable")


@test("load_from_nonexec_segment_still_analysed")
def _():
    # mov eax,[0x402000]; ret -- 0x402000 is a read-only, non-executable data
    # segment: the access is data, not instruction flow, and stays analysable.
    # (Jump-table reads from .rodata are covered by worker_tests' corpus.)
    p, segs = elf("rodata-read", [(BASE, R | X, bytes.fromhex("8b042500204000c3"), 0),
                                  (BASE + 0x1000, R, struct.pack("<I", 0x2a), 0)])
    j = one("r", p, size=8)
    assert j["status"] == "ok", j.get("error")
    cite(j, segs)
    assert [i["admission"] for i in j["instructions"]] == ["admitted", "admitted"], j["instructions"]
    assert {r[0] for r in reasons(j)} == {"stripped_without_function_starts"}, reasons(j)
    assert any(v["space"] == "ram" and v["offset"] == "0x402000" for v in j["high_pcode"]["varnodes"]), \
        "the data location 0x402000 is not represented"
    validate(j, "rodata")


def map_case(name, text, ret):
    path = os.path.join(SCRATCH, name + ".map")
    with open(path, "w") as f:
        f.write(text)
    return one(name, ret, size=1, extra="\tfunction_map=%s" % path)


@test("review4_function_map_qualification")
def _():
    ret, segs = elf("ret", [(BASE, R | X, b"\xc3", 0)])
    none = one("none", ret, size=1)
    assert none["qualification"]["level"] == "qualified", none["qualification"]
    out = {}
    j = map_case("empty", "", ret)
    assert j["status"] == "ok" and j["qualification"]["level"] == none["qualification"]["level"], j["qualification"]
    assert {r[0] for r in reasons(j)} == {"stripped_without_function_starts"}, reasons(j)
    fm = j["function"]["function_map"]
    assert fm["supplied"] is True and fm["used"] is False and fm["entries_accepted"] == 0, fm
    assert j["qualification"]["function_starts"]["function_map"] == "supplied_unused"
    validate(j, "map-empty")
    out["empty"] = j["qualification"]["level"]
    for name, text, kind in (("incomplete", "t_entry 0x401000\n", "truncated 1"),
                             ("malformed", "bad nope 0x1\n", "malformed 1"),
                             ("extra-field", "t_entry 0x401000 0x1 junk\n", "malformed 1"),
                             ("trailing-partial", "t_entry 0x401000 0x1\nother 0x401000", "truncated 1"),
                             ("duplicate", "t_entry 0x401000 0x1\nalias 0x401000 0x1\n", "duplicate 1"),
                             ("zero-size", "t_entry 0x401000 0x0\n", "range 1"),
                             ("past-segment", "t_entry 0x401000 0x2\n", "range 1"),
                             ("unmapped", "far 0x500000 0x1\n", "range 1")):
        j = map_case(name, text, ret)
        assert j["status"] == "error" and j["error"]["code"] == "function_map" and kind in j["error"]["message"], \
            (name, j.get("error"), j.get("qualification"))
        out[name] = "refused"
    j = map_case("valid", "# comment\n\nt_entry 0x401000 0x1\n", ret)
    assert j["status"] == "ok" and j["qualification"]["level"] == "complete", j["qualification"]
    fm = j["function"]["function_map"]
    assert fm["used"] is True and fm["entries_accepted"] == 1 and fm["records"] == 1, fm
    validate(j, "map-valid")
    out["valid"] = "complete"
    return dict(outcomes=out)


def validator_says(j, name, image=None):
    path = os.path.join(SCRATCH, name + ".json")
    with open(path, "w") as f:
        json.dump(j, f)
    args = [sys.executable, VALIDATE] + (["--image", image] if image else []) + [path]
    p = subprocess.run(args, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout.strip()


@test("validator_rejects_forged_instruction_evidence")
def _():
    """Saved-export admission recomputes what it can; copied fields are not trusted."""
    import copy
    out = {}
    p, segs = elf("v-nonexec", [(BASE, R | X, b"\xe9\xfb\x0f\x00\x00", 0), (BASE + 0x1000, R | W, b"\xc3", 0)])
    base = one("v", p)
    assert base["status"] == "ok" and validator_says(base, "v-ok", p)[0] == 0
    # R2-style claim: the RW byte as admitted code, graph complete
    j = copy.deepcopy(base)
    for i in j["instructions"]:
        if i["addr"] == "0x402000":
            i.update(admission="admitted", length=1, bytes="c3", mnemonic="RET", operands="", raw_pcode=[], high_ops=[])
            i.pop("error", None), i.pop("refusal_reason", None)
    j["instruction_admission"]["refused"] = []
    j["qualification"]["reasons"] = [r for r in j["qualification"]["reasons"] if not r["code"].startswith("instruction_refused")]
    j["qualification"]["level"] = "qualified" if j["qualification"]["reasons"] else "complete"
    rc, msg = validator_says(j, "v-forged-nonexec")
    assert rc != 0 and "not file-backed executable" in msg, msg
    out["nonexec_as_code"] = msg[-80:]
    # fabricated suffix: a 3-byte RET over a 1-byte segment
    p2, segs2 = elf("v-exact", [(BASE, R | X, INSNS["ret_imm16"], 0)])
    ok = one("w", p2, size=3, extra="\tbounds=strict")
    j = copy.deepcopy(ok)
    j["image"]["load_segments"][0]["filesz"] = "0x1"
    rc, msg = validator_says(j, "v-forged-suffix")
    assert rc != 0 and "not file-backed executable" in msg, msg
    out["fabricated_suffix"] = msg[-80:]
    # bytes that are not the image's bytes (only --image can see this)
    j = copy.deepcopy(ok)
    j["instructions"][0]["bytes"] = "c20500"
    assert validator_says(j, "v-forged-bytes")[0] == 0, "without --image the forged bytes are undetectable"
    rc, msg = validator_says(j, "v-forged-bytes-img", p2)
    assert rc != 0 and "not the image's executable file bytes" in msg, msg
    out["forged_bytes_with_image"] = msg[-80:]
    # strict bounds: an admitted span past the declared end
    j = copy.deepcopy(ok)
    j["function"]["declared_size"] = "0x1"
    rc, msg = validator_says(j, "v-forged-strict")
    assert rc != 0, msg
    out["strict_span"] = msg[-80:]
    # function map: claimed use without accepted records
    ret, _ = elf("v-ret", [(BASE, R | X, b"\xc3", 0)])
    mp = os.path.join(SCRATCH, "v-empty.map")
    open(mp, "w").close()
    j = one("m", ret, size=1, extra="\tfunction_map=%s" % mp)
    assert validator_says(j, "v-map-ok")[0] == 0
    j["function"]["function_map"]["used"] = True
    rc, msg = validator_says(j, "v-forged-map")
    assert rc != 0 and "function_map.used" in msg, msg
    j = one("m2", ret, size=1, extra="\tfunction_map=%s" % mp)
    j["qualification"]["reasons"] = []
    j["qualification"]["level"] = "complete"
    rc, msg = validator_says(j, "v-forged-stripped")
    assert rc != 0 and "stripped_without_function_starts" in msg, msg
    out["map_upgrade"] = msg[-80:]
    # pre-admission exports are refused outright
    j = copy.deepcopy(ok)
    j["schema_version"] = "0.2.0"
    rc, msg = validator_says(j, "v-schema-0.2")
    assert rc != 0 and "predates instruction admission" in msg, msg
    return dict(rejections=out)


# ---- C01-R4: C01-R3 review findings N1-N6 --------------------------------

def forge_hidden_refusal(j):
    """F3: relabel a refused instruction 'undecoded', drop its refusal and reason."""
    import copy
    f = copy.deepcopy(j)
    for i in f["instructions"]:
        if i.get("admission") == "refused":
            i["admission"] = "undecoded"
            i.pop("refusal_reason", None)
    f["instruction_admission"]["refused"] = []
    f["qualification"]["reasons"] = [r for r in f["qualification"]["reasons"] if not r["code"].startswith("instruction_refused_")]
    lv = {"complete": 0, "qualified": 1, "unreliable": 2}
    f["qualification"]["level"] = max((r["level"] for r in f["qualification"]["reasons"]), key=lv.get, default="complete")
    return f


@test("r4_n1_undecodable_truncation_refused")
def _():
    # U1: a truncated 3-byte VEX instruction whose zero-padded window does not decode
    p, segs = elf("u1-vex-trunc", [(BASE, R | X, b"\xc5\xf8", 0)])
    refused_at_entry(one("u1", p), "undecodable_at_segment_end")
    # U3 (after a jcc) and A12 (after a nop): later on the path -> cut, unreliable
    p, segs = elf("u3-vex-trunc-after-jcc", [(BASE, R | X, bytes.fromhex("85c07401c3c5f8"), 0)])
    refused_on_path(one("u3", p), segs, BASE + 5, "undecodable_at_segment_end")
    p, segs = elf("a12-trunc-vex2-short", [(BASE, R | X, b"\x90\xc5\xf8", 0)])
    refused_on_path(one("a12", p), segs, BASE + 1, "undecodable_at_segment_end")
    # policy: undecodable file-backed bytes with a fully real window stay an
    # explicit qualified halt (instruction_undecoded), not a refusal
    p, segs = elf("u4-invalid-in-segment", [(BASE, R | X, b"\x90\xd6" + b"\xc3" * 16, 0)])
    j = one("u4", p)
    assert j["status"] == "ok", j.get("error")
    cite(j, segs)
    ins = {i["addr"]: i for i in j["instructions"]}
    assert ins.get("0x%x" % (BASE + 1), {}).get("admission") == "undecoded", ins
    assert ("instruction_undecoded", "0x%x" % (BASE + 1)) in reasons(j), reasons(j)
    assert j["qualification"]["level"] == "qualified", j["qualification"]
    validate(j, "u4")


@test("r4_n2_validator_rejects_refusal_hidden_as_undecoded")
def _():
    p, segs = elf("f3-nonexec", [(BASE, R | X, b"\xe9\xfb\x0f\x00\x00", 0), (BASE + 0x1000, R | W, b"\xc3", 0)])
    j = one("f3", p)
    assert j["status"] == "ok" and validator_says(j, "f3-honest", p)[0] == 0
    f = forge_hidden_refusal(j)
    out = {}
    for name, img in (("noimage", None), ("image", p)):
        rc, msg = validator_says(f, "f3-forged-" + name, img)
        assert rc != 0 and "start is not" in msg, (name, msg)
        out[name] = msg[-100:]
    # F3b: also rewrite the export's segment flags and add the undecoded
    # reason, so only the image itself can tell; --image anywhere on the line
    g = forge_hidden_refusal(j)
    for s in g["image"]["load_segments"]:
        s["flags"] = "r-x"
    g["qualification"]["reasons"].append({"code": "instruction_undecoded", "level": "qualified", "detail": "forged", "addr": "0x402000"})
    g["qualification"]["level"] = "qualified" if g["qualification"]["level"] == "complete" else g["qualification"]["level"]
    assert validator_says(g, "f3b-forged")[0] == 0, "F3b should only be detectable with --image"
    rc, msg = validator_says(g, "f3b-forged-image", p)
    assert rc != 0 and "start is not the image's" in msg, msg
    path = os.path.join(SCRATCH, "f3b-forged-image.json")
    r = subprocess.run([sys.executable, VALIDATE, path, "--image", p], capture_output=True, text=True, timeout=60)
    assert r.returncode != 0 and "start is not the image's" in r.stdout, r.stdout
    out["image_after_file"] = r.stdout.strip()[-100:]
    # declared limit (contract): length/mnemonic/p-code are not re-derived
    import copy
    p2, _ = elf("f1-ret3", [(BASE, R | X, INSNS["ret_imm16"], 0)])
    g = copy.deepcopy(one("f1", p2))
    g["instructions"][0].update(length=1, bytes="c2")
    out["F1_length_prefix_undetectable"] = validator_says(g, "f1-forged", p2)[0] == 0
    return dict(rejections=out)


def validator_ok(j, name, image):
    rc, msg = validator_says(j, name, image)
    assert rc == 0, msg


def mcase(name, path, text, **kw):
    mp = os.path.join(SCRATCH, name + ".map")
    with open(mp, "w") as f:
        f.write(text)
    return one(name, path, extra="\tfunction_map=%s" % mp, **kw)


@test("r4_n3_function_map_needs_entry_record")
def _():
    # M-tailcall: A 0x401000 jmp B; B 0x401010 mov eax,42; ret; C 0x401020 ret; no symtab
    code = bytearray(b"\x90" * 0x30)
    code[0:5] = b"\xe9" + struct.pack("<i", 0x10 - 5)
    code[0x10:0x16] = b"\xb8\x2a\x00\x00\x00\xc3"
    code[0x20] = 0xc3
    p, segs = elf("m-tailcall", [(BASE, R | X, bytes(code), 0)])
    out = {}
    for name, text in (("unrelated", "C 0x401020 0x1\n"), ("relevant", "B 0x401010 0x6\n")):
        j = mcase("m-" + name, p, text)
        assert j["status"] == "ok", j.get("error")
        fm = j["function"]["function_map"]
        assert fm["used"] is False and fm["entry_size"] is None and fm["entries_accepted"] == 1, fm
        assert j["qualification"]["function_starts"]["function_map"] == "supplied_unused"
        assert ("stripped_without_function_starts", None) in reasons(j), reasons(j)
        assert j["qualification"]["level"] != "complete", j["qualification"]
        validator_ok(j, "m-" + name, p)
        out[name] = j["qualification"]["level"]
    # entry record only: B is absorbed, which leaves the record's extent
    j = mcase("m-entry", p, "A 0x401000 0x5\n")
    fm = j["function"]["function_map"]
    assert j["status"] == "ok" and fm["used"] is True and fm["entry_size"] == "0x5", (j.get("error"), fm)
    assert ("stripped_without_function_starts", None) not in reasons(j), reasons(j)
    assert ("flow_outside_function_map_bounds", "0x401010") in reasons(j), reasons(j)
    assert j["qualification"]["level"] == "qualified", j["qualification"]
    validator_ok(j, "m-entry", p)
    out["entry"] = j["qualification"]["level"]
    # entry + callee records: the jmp is a tail call, nothing absorbed
    j = mcase("m-both", p, "A 0x401000 0x5\nB 0x401010 0x6\n")
    assert [i["addr"] for i in j["instructions"]] == ["0x401000"], j["instructions"]
    assert {r[0] for r in reasons(j)} >= {"tail_call_inferred"} and not {r[0] for r in reasons(j)} & {
        "stripped_without_function_starts", "flow_outside_function_map_bounds", "flow_reaches_other_function_start"}, reasons(j)
    validator_ok(j, "m-both", p)
    # fall-through into the start of another accepted record
    p2, _ = elf("m-fallthrough", [(BASE, R | X, b"\x90\x90\xc3", 0)])
    j = mcase("m-fall", p2, "A 0x401000 0x2\nB 0x401002 0x1\n")
    assert ("flow_reaches_other_function_start", "0x401002") in reasons(j), reasons(j)
    assert ("flow_outside_function_map_bounds", "0x401002") in reasons(j), reasons(j)
    assert j["qualification"]["level"] == "qualified", j["qualification"]
    validator_ok(j, "m-fall", p2)
    # forged: claim the extent reason away -> recomputed by the validator
    j["qualification"]["reasons"] = [r for r in j["qualification"]["reasons"] if r["code"] != "flow_outside_function_map_bounds"]
    rc, msg = validator_says(j, "m-fall-forged")
    assert rc != 0 and "function-map extent" in msg, msg
    return dict(levels=out)


@test("r4_n4_function_map_rejects_noncanonical_hex")
def _():
    ret, _ = elf("n4-ret", [(BASE, R | X, b"\xc3", 0)])
    out = {}
    for name, text in (("upper-prefix", "t_entry 0X401000 0x1\n"), ("leading-zero", "t_entry 0x0401000 0x1\n"),
                       ("size-leading-zero", "t_entry 0x401000 0x01\n"), ("upper-digit", "t_entry 0x401000 0xA\n")):
        j = map_case("n4-" + name, text, ret)
        assert j["status"] == "error" and j["error"]["code"] == "function_map" and \
            "noncanonical 1" in j["error"]["message"] and "non-canonical hex" in j["error"]["message"], (name, j.get("error"))
        out[name] = "refused"
    # the duplicate-by-spelling case is non-canonical first, not a duplicate
    j = map_case("n4-dup-spelling", "t_entry 0x401000 0x1\nalias 0x0401000 0x1\n", ret)
    assert j["status"] == "error" and "noncanonical 1" in j["error"]["message"] and "duplicate 0" in j["error"]["message"], j.get("error")
    return dict(outcomes=out)


@test("r4_n5_schema_and_contract_gate")
def _():
    p, segs = elf("n5-ret", [(BASE, R | X, b"\xc3", 0)])
    j = one("n5", p, size=1)
    contract = re.search(r"^CONTRACT = '(.*)'$", open(VALIDATE).read(), re.M).group(1)
    assert j["status"] == "ok" and j["schema_version"].startswith("0.4.") and j["contract"] == contract, \
        (j.get("schema_version"), j.get("contract"), contract)
    import copy
    for v in ("0.2.0", "0.3.0"):
        g = copy.deepcopy(j)
        g["schema_version"] = v
        rc, msg = validator_says(g, "n5-" + v)
        assert rc != 0 and "not admitted" in msg, msg


@test("r4_n6_strict_one_byte_short_is_bounds_exceeded")
def _():
    p, segs = elf("b2-strict-short", [(BASE, R | X, bytes.fromhex("90b801000000c3"), 0)])
    j = one("b2", p, size=6, extra="\tbounds=strict")
    assert j["status"] == "error" and j["error"]["code"] == "bounds_exceeded", j.get("error")
    assert "0x401006" in j["error"]["message"], j["error"]
    j = one("b2-ok", p, size=7, extra="\tbounds=strict")
    assert j["status"] == "ok", j.get("error")


# ---- C01-R5: C01-R4 review notes R4-1..R4-3 --------------------------------
def tc_image(name, jcc=False):
    """A 0x401000: jmp (or test; jz; ret) to B 0x401010: mov eax,42; ret.  No symtab."""
    code = bytearray(b"\x90" * 0x30)
    if jcc:
        code[0:8] = b"\x85\xc0\x0f\x84" + struct.pack("<i", 0x10 - 8)
        code[8] = 0xc3
    else:
        code[0:5] = b"\xe9" + struct.pack("<i", 0x10 - 5)
    code[0x10:0x16] = b"\xb8\x2a\x00\x00\x00\xc3"
    return elf(name, [(BASE, R | X, bytes(code), 0)])[0]


def validator_map(j, name, mp, image=None):
    path = os.path.join(SCRATCH, name + ".json")
    with open(path, "w") as f:
        json.dump(j, f)
    p = subprocess.run([sys.executable, VALIDATE, "--map", mp] + (["--image", image] if image else []) + [path],
                       capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout.strip()


@test("r5_r41_cold_exemption_is_exact_owner_suffix")
def _():
    p = tc_image("r41-jmp")
    pj = tc_image("r41-jcc", jcc=True)
    out = {}
    # another function named like a fragment: a tail call, never absorbed
    for name, text in (("B.cold", "A 0x401000 0x20\nB.cold 0x401010 0x6\n"),
                       ("coldstart", "A 0x401000 0x20\nfoo.coldstart 0x401010 0x6\n"),
                       ("A.colder", "A 0x401000 0x5\nA.colder 0x401010 0x6\n"),
                       ("A.cold.x", "A 0x401000 0x5\nA.cold.x 0x401010 0x6\n")):
        j = mcase("r41-" + name, p, text)
        assert j["status"] == "ok", j.get("error")
        assert [i["addr"] for i in j["instructions"]] == ["0x401000"], (name, [i["addr"] for i in j["instructions"]])
        assert ("tail_call_inferred", "0x401000") in reasons(j) and j["qualification"]["level"] != "complete", (name, reasons(j))
        validator_ok(j, "r41-" + name, p)
        out[name] = j["qualification"]["level"]
    j = mcase("r41-jcc-B.cold", pj, "A 0x401000 0x20\nB.cold 0x401010 0x6\n")
    assert {("conditional_tail_call_unmodelled", "0x401002"), ("flow_reaches_other_function_start", "0x401010")} <= reasons(j), reasons(j)
    assert j["qualification"]["level"] == "unreliable", j["qualification"]
    validator_ok(j, "r41-jcc-B.cold", pj)
    out["jcc-B.cold"] = j["qualification"]["level"]
    # the owner's own fragment: flowed as part of the function, reported as leaving the record
    for name in ("A.cold", "A.cold.1"):
        j = mcase("r41-own-" + name, p, "A 0x401000 0x5\n%s 0x401010 0x6\n" % name)
        rs = {r[0] for r in reasons(j)}
        assert "0x401010" in [i["addr"] for i in j["instructions"]], j["instructions"]
        assert "flow_outside_function_map_bounds" in rs and not rs & {"tail_call_inferred", "flow_reaches_other_function_start"}, (name, rs)
        validator_ok(j, "r41-own-" + name, p)
        out["own-" + name] = j["qualification"]["level"]
    return dict(levels=out)


@test("r5_r42_declared_extent_conflict_and_unreached")
def _():
    p = tc_image("r42")
    out = {}
    # the requested size and the entry record disagree
    j = mcase("r42-conflict", p, "A 0x401000 0x5\n", size=0x20)
    assert ("declared_extent_conflict", None) in reasons(j) and j["qualification"]["level"] != "complete", reasons(j)
    validator_ok(j, "r42-conflict", p)
    j["qualification"]["reasons"] = [r for r in j["qualification"]["reasons"] if r["code"] != "declared_extent_conflict"]
    rc, msg = validator_says(j, "r42-conflict-forged")
    assert rc != 0 and "declared_extent_conflict" in msg, msg
    out["conflict"] = "qualified"
    # an overbroad entry record (B absorbed, no record for B): its tail is unreached
    j = mcase("r42-overbroad", p, "A 0x401000 0x20\n")
    assert ("declared_extent_unreached", "0x40101f") in reasons(j) and j["qualification"]["level"] == "qualified", reasons(j)
    validator_ok(j, "r42-overbroad", p)
    j["qualification"]["reasons"] = [r for r in j["qualification"]["reasons"] if r["code"] != "declared_extent_unreached"]
    j["qualification"]["level"] = "complete" if not j["qualification"]["reasons"] else j["qualification"]["level"]
    rc, msg = validator_says(j, "r42-overbroad-forged")
    assert rc != 0 and "declared_extent_unreached" in msg, msg
    # the same with a requested size and no map
    j = one("r42-size", p, size=0x20)
    assert ("declared_extent_unreached", "0x40101f") in reasons(j), reasons(j)
    validator_ok(j, "r42-size", p)
    # agreeing, exact extents: no new reason
    j = mcase("r42-exact", p, "A 0x401000 0x5\nB 0x401010 0x6\n", size=0x5)
    assert not {r[0] for r in reasons(j)} & {"declared_extent_conflict", "declared_extent_unreached"}, reasons(j)
    validator_ok(j, "r42-exact", p)
    # stated limit: an extent overbroad exactly to the end of absorbed code is not detectable
    j = mcase("r42-limit", p, "A 0x401000 0x16\n")
    out["limit_exact_overbroad_level"] = j["qualification"]["level"]
    return dict(outcomes=out)


@test("r5_r43_validate_map_rederives_map_claims")
def _():
    p = tc_image("r43-jcc", jcc=True)
    mp = os.path.join(SCRATCH, "r43.map")
    with open(mp, "w") as f:
        f.write("A 0x401000 0x9\nB 0x401010 0x6\n")
    j = one("r43", p, extra="\tfunction_map=%s" % mp)
    assert ("flow_reaches_other_function_start", "0x401010") in reasons(j), reasons(j)
    rc, msg = validator_map(j, "r43-honest", mp, p)
    assert rc == 0, msg
    import copy
    out = {}
    # producer-asserted claims: undetectable without --map, rejected with it
    g = copy.deepcopy(j)
    g["qualification"]["reasons"] = [r for r in g["qualification"]["reasons"] if r["code"] != "flow_reaches_other_function_start"]
    assert validator_says(g, "r43-other-forged")[0] == 0
    rc, msg = validator_map(g, "r43-other-forged", mp)
    assert rc != 0 and "flow_reaches_other_function_start" in msg, msg
    out["other_start_dropped"] = msg[-80:]
    # F6: a map-less stripped export rewritten to claim a map that the caller does not hold
    q = tc_image("r43-jmp")
    base = one("r43-nomap", q)
    g = copy.deepcopy(base)
    forged = b"A 0x401000 0x16\n"
    sha = __import__("hashlib").sha256(forged).hexdigest()
    g["function"]["function_map"].update({"supplied": True, "used": True, "entry_size": "0x16", "path": "x.map", "sha256": sha,
                                          "records": 1, "entries_accepted": 1, "entries_added": 1,
                                          "entries_already_known": 0, "entries_rejected": 0})
    g["qualification"]["function_starts"]["function_map"] = "used"
    g["qualification"]["reasons"] = [r for r in g["qualification"]["reasons"] if r["code"] != "stripped_without_function_starts"]
    lv = {"complete": 0, "qualified": 1, "unreliable": 2}
    g["qualification"]["level"] = max((r["level"] for r in g["qualification"]["reasons"]), key=lv.get, default="complete")
    g["identity"]["basis"] = g["identity"]["basis"].replace("function_map_sha256=none", "function_map_sha256=" + sha)
    g["artifact_id"] = "fg2-" + __import__("hashlib").sha256(g["identity"]["basis"].encode()).hexdigest()
    assert validator_says(g, "r43-f6", q)[0] == 0, "F6 is producer-asserted without --map"
    trusted = os.path.join(SCRATCH, "r43-trusted.map")
    with open(trusted, "w") as f:
        f.write("A 0x401000 0x5\n")
    rc, msg = validator_map(g, "r43-f6", trusted, q)
    assert rc != 0 and "sha256" in msg, msg
    out["f6_other_map"] = msg[-80:]
    # entry_size forged against the matching map
    g = copy.deepcopy(j)
    g["function"]["function_map"]["entry_size"] = "0x8"
    rc, msg = validator_map(g, "r43-esize", mp)
    assert rc != 0, msg
    out["entry_size_forged"] = msg[-80:]
    return dict(rejections=out)


leftover = os.listdir(TMP)
results.append({"name": "no_private_snapshot_dirs_left", "outcome": "pass" if not leftover else "fail",
                "error": "" if not leftover else str(leftover)})
fails = [r for r in results if r["outcome"] != "pass"]
with open(OUT, "w") as f:
    json.dump({"suite": "ghx_boundaries", "tests": results, "passed": len(results) - len(fails),
               "failed": len(fails)}, f, indent=1)
print("boundary tests: %d passed, %d failed" % (len(results) - len(fails), len(fails)))
sys.exit(1 if fails else 0)
