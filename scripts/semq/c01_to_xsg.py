#!/usr/bin/env python3
"""Explicit adapter: C01 xodb.ghidra.function_graph 0.4.x JSON -> xsg v1.

Only 0.4.x (C01-R4) exports are converted, the same versions
tools/ghx/ghx_validate.py admits.  Earlier exports are refused: 0.1.x and
0.2.x predate instruction admission (an R2 export can carry padding or data
bytes as code), and 0.3.x counted any accepted function-map record as
function-start evidence.  The artifact identity and producer qualification
are copied into the xsg `qualification` line and every xsq result repeats
them.  Copying is not admission: run tools/ghx/ghx_validate.py --image on
saved or external exports before converting them.  Read-only ranges come
from the export's own PT_LOAD table, or from --elf after checking its SHA-256.

The C01 file is read only and never modified; its SHA-256 is recorded in the
xsg `source` line so a derivation can be reproduced from the saved input.
Every mapping decision that is not a pure renaming is listed in ADAPTER.md and
emitted as a `#` comment in the output. Unknown constructs fail loudly.
"""
import argparse
import hashlib
import json
import os
import struct
import sys

ADAPTER_VERSION = "0.3.0"

# Ghidra's native get_opname() returns SLEIGH placeholder spellings for four
# opcodes and short names for float conversions (opcodes.cc). Map them to the
# canonical p-code names used by xsg. Unknown names are passed through and
# become barriers in the engine (never no-ops).
NATIVE_OPCODE_ALIASES = {
    "BUILD": "MULTIEQUAL",
    "DELAY_SLOT": "INDIRECT",
    "LABEL": "PTRADD",
    "CROSSBUILD": "PTRSUB",
    "INT2FLOAT": "FLOAT_INT2FLOAT",
    "FLOAT2FLOAT": "FLOAT_FLOAT2FLOAT",
    "TRUNC": "FLOAT_TRUNC",
    "CEIL": "FLOAT_CEIL",
    "FLOOR": "FLOAT_FLOOR",
    "ROUND": "FLOAT_ROUND",
}

# Stack-pointer register names per processor. Ghidra marks the spacebase input
# internally (Varnode::isSpacebase) but C01 0.1.0 does not export that flag,
# so the adapter infers it and labels the inference (spacebase_heuristic).
STACK_POINTERS = {"x86": {"RSP", "ESP", "SP"}, "AARCH64": {"sp"}, "68000": {"SP", "A7"}}

SPACE_CLASSES = {"constant": "constant", "internal": "unique", "spacebase": "stack",
                 "join": "join", "fspec": "other", "iop": "other"}


class AdapterError(Exception):
    pass


def num(ident, prefix):
    if not isinstance(ident, str) or not ident.startswith(prefix):
        raise AdapterError("bad id %r (want %s<n>)" % (ident, prefix))
    text = ident[len(prefix):]
    if not text.isdigit() or int(text) >= 0xffffffff:
        raise AdapterError("bad id %r" % ident)
    return int(text)


def hexval(text, what):
    if not isinstance(text, str) or not text.startswith("0x"):
        raise AdapterError("%s: expected canonical hex string, got %r" % (what, text))
    value = int(text, 16)
    if value >> 64:
        raise AdapterError("%s: exceeds 64 bits" % what)
    return value


def token(text):
    out = []
    for ch in str(text):
        out.append(ch if 0x21 <= ord(ch) <= 0x7e and ch not in '"\\#=' else "_")
    return "".join(out) or "_"


def readonly_ranges(elf_path, expected_sha256):
    data = open(elf_path, "rb").read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise AdapterError("--elf sha256 %s does not match export image %s" % (actual, expected_sha256))
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise AdapterError("--elf: only ELF64 little-endian is supported")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3a)
    if shentsize != 64 or shoff + shnum * 64 > len(data):
        raise AdapterError("--elf: bad section header table")
    ranges = []
    for i in range(shnum):
        _, kind, flags, addr, _, size = struct.unpack_from("<IIQQQQ", data, shoff + i * 64)
        SHF_WRITE, SHF_ALLOC = 1, 2
        if kind != 8 and flags & SHF_ALLOC and not flags & SHF_WRITE and size and addr:
            ranges.append((addr, addr + size))  # NOBITS (8) has no file bytes
    return sorted(ranges)


def convert(doc, source_sha256, elf=None):
    if doc.get("schema") != "xodb.ghidra.function_graph":
        raise AdapterError("not an xodb.ghidra.function_graph export")
    version = str(doc.get("schema_version", ""))
    if not version.startswith("0.4."):
        raise AdapterError("unsupported schema_version %s (adapter reads 0.4.x only; earlier exports "
                           "predate instruction admission or the entry-record function-map rule)" % version)
    if doc.get("status") != "ok":
        raise AdapterError("export status is %r, not ok" % doc.get("status"))
    image, lang, func = doc["image"], doc["language"], doc["function"]
    high = doc["high_pcode"]
    if high.get("kind") != "decompiler_final_ssa":
        raise AdapterError("high_pcode.kind %r is not decompiler_final_ssa" % high.get("kind"))
    notes = []
    out = ["xsg 1",
           "# adapter c01_to_xsg %s from %s %s artifact %s" % (
               ADAPTER_VERSION, doc["schema"], version, doc.get("artifact_id")),
           "# producer %s %s ghidra %s java=%s" % (
               doc["producer"].get("kind"), doc["producer"].get("worker_version"),
               doc["producer"].get("ghidra_commit"), doc["producer"].get("java"))]
    out.append("image sha256=%s build_id=%s name=%s" % (
        token(image["sha256"]), token(image.get("gnu_build_id") or "unknown"),
        token(os.path.basename(image.get("path") or "unknown"))))
    spaces = {}
    ram_bytes = None
    for s in doc["address_spaces"]:
        cls = SPACE_CLASSES.get(s["type"])
        if s["type"] == "processor":
            cls = {"ram": "ram", "register": "register"}.get(s["name"], "other")
            if s.get("default_code"):
                ram_bytes = s["addr_size"]
        if cls is None:
            raise AdapterError("unknown address space type %r" % s["type"])
        spaces[s["name"]] = (s["index"], cls)
    if not ram_bytes:
        raise AdapterError("no default code space")
    out.append("spec language=%s compiler=%s addr_bytes=%d" % (
        token(lang["id"]), token(lang["compiler_spec"]), ram_bytes))
    out.append("producer xsq-c01-adapter %s" % ADAPTER_VERSION)
    out.append("source kind=c01-function-graph-%s sha256=%s" % (token(version), source_sha256))
    q = doc.get("qualification")
    if q:
        codes = sorted({r["code"] for r in q.get("reasons", [])})
        line = "qualification level=%s" % token(q["level"])
        if codes:
            line += " reasons=%s" % token(",".join(codes))
        out.append(line + " artifact=%s" % token(doc.get("artifact_id") or "unknown"))
    else:
        out.append("qualification level=unknown artifact=%s" % token(doc.get("artifact_id") or "unknown"))
    for name, (index, cls) in sorted(spaces.items(), key=lambda kv: kv[1][0]):
        out.append("space %d %s %s" % (index, token(name), cls))
    elf_ranges = readonly_ranges(elf, image["sha256"]) if elf else None  # always hash-checked
    if image.get("load_segments") is not None:
        for seg in image["load_segments"]:
            low, size = hexval(seg["vaddr"], "segment"), hexval(seg["memsz"], "segment")
            if "w" not in seg["flags"] and size:
                out.append("readonly 0x%x 0x%x" % (low, low + size))
        notes.append("readonly ranges from the export's non-writable PT_LOAD segments")
    elif elf:
        for low, high_addr in elf_ranges:
            out.append("readonly 0x%x 0x%x" % (low, high_addr))
        notes.append("readonly ranges from ELF section headers (non-writable SHF_ALLOC)")

    entry = hexval(func["entry"], "function.entry")
    if not any(hexval(b["start"], b["id"]) == entry for b in doc["blocks"]):
        # e.g. Ghidra "Possible PIC construction ... Changing call to branch":
        # the graph no longer describes code starting at the requested entry.
        raise AdapterError("no block starts at function entry 0x%x; decompiler warnings: %s" % (
            entry, "; ".join(w.get("text", "") for w in func.get("warnings", []))[:600]))
    outside = func.get("instructions_outside_declared_bounds") or []
    if outside:
        notes.append("%d instructions outside declared bounds (bounds_policy=%s); "
                     "results may cite them" % (len(outside), func.get("bounds_policy")))
    out.append("function 1 %s entry=0x%x" % (token(func.get("name") or "unnamed"), entry))
    ops = {op["id"]: op for op in high["ops"]}
    blocks = {b["id"]: b for b in doc["blocks"]}
    op_block = {}
    for b in doc["blocks"]:
        out.append("block %d 0x%x" % (num(b["id"], "bb:"), hexval(b["start"], b["id"])))
        for seq, op_id in enumerate(b["ops"]):
            if op_id in op_block:
                raise AdapterError("op %s listed in two blocks" % op_id)
            if op_id not in ops:
                raise AdapterError("block %s lists unknown op %s" % (b["id"], op_id))
            op_block[op_id] = (b["id"], seq)
    # Edges in each target's pred[] order: MULTIEQUAL input i belongs to pred i.
    used = {b["id"]: [False] * len(b["succ"]) for b in doc["blocks"]}
    for b in doc["blocks"]:
        for p in b["pred"]:
            if p not in blocks:
                raise AdapterError("block %s has unknown predecessor %s" % (b["id"], p))
            slot = None
            for k, s in enumerate(blocks[p]["succ"]):
                if s["to"] == b["id"] and not used[p][k]:
                    slot = k
                    break
            if slot is None:
                raise AdapterError("pred %s -> %s has no matching succ entry" % (p, b["id"]))
            used[p][slot] = True
            s = blocks[p]["succ"][slot]
            last = ops[blocks[p]["ops"][-1]]["opcode"] if blocks[p]["ops"] else None
            kind = {"true_out": "true", "false_out": "false", "switch": "switch",
                    "flow": "fall"}.get(s["kind"])
            if s["kind"] == "unconditional":
                kind = "jump" if last == "BRANCH" else "fall"
            if kind is None:
                raise AdapterError("unknown edge kind %r" % s["kind"])
            out.append("edge %d %d %s" % (num(p, "bb:"), num(b["id"], "bb:"), kind))
    for p, flags in used.items():
        if not all(flags):
            raise AdapterError("block %s has a succ entry without matching pred" % p)

    params = {}
    for prm in func.get("prototype", {}).get("params", []):
        key = (prm.get("storage_space"), prm.get("storage_offset"))
        params.setdefault(key, prm["index"])
    stack_regs = STACK_POINTERS.get(lang.get("processor"), set())
    flipped = 0
    for v in high["varnodes"]:
        space = v["space"]
        if space not in spaces:
            raise AdapterError("varnode %s in unknown space %s" % (v["id"], space))
        index, cls = spaces[space]
        flags = set(v.get("flags", []))
        attrs = []
        offset = hexval(v["offset"], v["id"])
        if v.get("offset_encoding") == "reference_elided":
            if space == "iop":
                continue  # INDIRECT op reference: emitted as @op on the INDIRECT
            if space == "fspec":
                attrs.append("annotation")
        if "input" in flags:
            attrs.append("input")
            pidx = params.get((space, v["offset"]))
            if pidx is not None:
                attrs.append("param=%d" % pidx)
            if "spacebase" in flags:
                attrs.append("spacebase")  # exported by C01-R2 from Varnode::isSpacebase
            elif v.get("register") in stack_regs:
                attrs.append("spacebase_heuristic")
                notes.append("%s (%s) marked frame base by register-name heuristic" % (
                    v["id"], v.get("register")))
        if "annotation" in flags and "annotation" not in attrs:
            attrs.append("annotation")
        if "addrtied" in flags:
            attrs.append("addrtied")
        if "persist" in flags:
            attrs.append("persist")
        if ("free" in flags and cls != "constant" and "annotation" not in attrs and
                "input" not in flags):
            raise AdapterError("free non-constant varnode %s has no def and no input flag" % v["id"])
        name = v.get("register")
        if name:
            attrs.append("name=%s" % token(name))
        attrs.append("origin=%s" % token(v["id"]))
        out.append("vn %d %d 0x%x %d %s" % (num(v["id"], "vn:"), index, offset, v["size"],
                                             " ".join(attrs)))
    vns = {v["id"]: v for v in high["varnodes"]}
    for op in high["ops"]:
        if op["id"] not in op_block:
            raise AdapterError("op %s is in no block" % op["id"])
        block, seq = op_block[op["id"]]
        opcode = NATIVE_OPCODE_ALIASES.get(op["opcode"], op["opcode"])
        if opcode == "CBRANCH" and op.get("boolean_flip"):
            flipped += 1
        ins = []
        for k, ref in enumerate(op["in"]):
            v = vns.get(ref)
            if v is None:
                raise AdapterError("op %s reads unknown varnode %s" % (op["id"], ref))
            if v["space"] == "iop":
                if "ref_op" not in v:
                    raise AdapterError("iop varnode %s has no ref_op" % ref)
                ins.append("@%d" % num(v["ref_op"], "op:"))
            else:
                ins.append(str(num(ref, "vn:")))
        outv = str(num(op["out"], "vn:")) if op.get("out") else "-"
        out.append("op %d %d 0x%x %d %s %s %s origin=%s" % (
            num(op["id"], "op:"), num(block, "bb:"), hexval(op["pc"], op["id"]), seq,
            token(opcode), outv, " ".join(ins), token(op["id"])))
    for c in doc.get("calls", []):
        target = "unknown" if c.get("target") is None else "0x%x" % hexval(c["target"], "call")
        line = "call %d target=%s" % (num(c["op"], "op:"), target)
        if c.get("target_name"):
            line += " name=%s" % token(c["target_name"])
        out.append(line)
    if flipped:
        notes.append("%d CBRANCH with boolean_flip: edge true/false follow Ghidra "
                     "getTrueOut/getFalseOut, i.e. the raw condition value" % flipped)
    for n in notes:
        out.insert(3, "# note: " + n)
    out.append("end")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="C01 function_graph JSON (read only)")
    ap.add_argument("output", help="xsg file to write")
    ap.add_argument("--elf", help="image file, verified against image.sha256, for read-only ranges")
    args = ap.parse_args()
    raw = open(args.input, "rb").read()
    sha = hashlib.sha256(raw).hexdigest()
    try:
        text = convert(json.loads(raw), sha, args.elf)
    except (AdapterError, KeyError, TypeError, ValueError) as e:
        print("c01_to_xsg: %s: %s: %s" % (args.input, type(e).__name__, e), file=sys.stderr)
        return 1
    tmp = args.output + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, args.output)
    print("%s %s -> %s" % (sha, args.input, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
