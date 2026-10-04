#!/usr/bin/env python3
"""Differential check of src/binary/elf.zig against llvm-readelf.

    tests/fixtures/elf/compare.py [FILE...]

With no arguments it checks every fixture in tests/fixtures/elf/out/ (run
build.sh first), a few installed system binaries, and the load bias of the
runnable fixtures against the addresses those processes report themselves.

Values are compared, not text: both tools emit JSON. Lookup results are
checked against a second implementation of the documented rules, written here
over llvm-readelf's symbols. Build products and caches stay in the workdir.
"""
import bisect
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
OUT = os.path.join(HERE, "out")
DUMP = os.path.join(ROOT, ".work", "elf", "elfdump")
MASK = (1 << 64) - 1
ADDRESS_TYPES = {0, 1, 2, 10}  # NOTYPE, OBJECT, FUNC, GNU_IFUNC
BIND_RANK = {1: 0, 10: 0, 2: 1, 0: 2}  # GLOBAL, GNU_UNIQUE, WEAK, LOCAL
SYSTEM = ["/usr/lib/libc.so.6", "/usr/lib/ld-linux-x86-64.so.2", "/usr/lib/libstdc++.so.6", "/usr/bin/ld", os.path.join(ROOT, "zig-out", "bin", "xodb")]
RUNNABLE = {"gcc-exec": "libfix.so", "gcc-pie": "libfix.so", "clang-pie": "libfix.so", "clang-lld-pie": "libfix-lld.so"}
REJECTED = {"reject-rel.o", "reject-i386", "reject-ppc64be", "reject-aarch64"}

failures = []


def fail(path, message):
    failures.append(f"{os.path.basename(path)}: {message}")


def build_dump():
    env = dict(os.environ)
    os.makedirs(os.path.join(ROOT, ".work", "tmp"), exist_ok=True)
    os.makedirs(os.path.dirname(DUMP), exist_ok=True)
    env["TMPDIR"] = os.path.join(ROOT, ".work", "tmp")
    env["ZIG_GLOBAL_CACHE_DIR"] = os.path.join(ROOT, ".cache", "zig-global")
    env["ZIG_LOCAL_CACHE_DIR"] = os.path.join(ROOT, ".zig-cache")
    subprocess.run(["zig", "build-exe", "-OReleaseSafe", "--dep", "elf", "-Mroot=tests/fixtures/elf/elfdump.zig", "-Melf=src/binary/elf.zig", "-femit-bin=.work/elf/elfdump"], cwd=ROOT, env=env, check=True)


def ours(path, *extra):
    run = subprocess.run([DUMP, path, *extra], capture_output=True)
    if run.returncode != 0:
        raise RuntimeError(f"elfdump failed on {path}: {run.stderr.decode(errors='replace')}")
    return json.loads(run.stdout.decode("utf-8", "surrogateescape"))


def reference(path):
    run = subprocess.run(["llvm-readelf", "--elf-output-style=JSON", "-h", "-l", "-S", "-s", "--dyn-syms", path], capture_output=True)
    return json.loads(run.stdout.decode("utf-8", "surrogateescape"))[0]


def count(text):
    # llvm-readelf prints an escaped count as "0 (66031)".
    text = str(text)
    return int(text[text.index("(") + 1 : text.index(")")]) if "(" in text else int(text)


def placement(section):
    name, value = section["Name"], section["Value"]
    if value == 0 and name == "Undefined":
        return "undefined"
    if value == 0xFFF1 and name == "Absolute":
        return "absolute"
    if value == 0xFFF2 and name == "Common":
        return "common"
    if 0xFF00 <= value <= 0xFFFF and name.startswith(("Processor Specific", "Operating System Specific", "Reserved")):
        return f"reserved:{value}"
    return value


def reference_symbols(ref, key, table):
    symbols = []
    for index, entry in enumerate(ref.get(key, [])):
        s = entry["Symbol"]
        symbols.append({"table": table, "index": index, "name": s["Name"]["Name"], "value": s["Value"], "size": s["Size"], "bind": s["Binding"]["Value"], "type": s["Type"]["Value"], "visibility": s["Other"]["Value"] & 3, "placement": placement(s["Section"])})
    return symbols


def same_name(reference_name, name, table):
    # llvm-readelf appends @VERSION to dynamic symbols; the string table holds the bare name.
    return reference_name == name or (table == "dynsym" and reference_name.split("@")[0] == name)


class Lookup:
    """The rules documented on findSymbol and symbolAt, over llvm-readelf's symbols."""

    def __init__(self, symbols, sections):
        self.symbols = symbols
        self.sections = sections
        order = {"symtab": 0, "dynsym": 1}
        self.rank = lambda s: (0 if s["type"] != 0 else 1, BIND_RANK.get(s["bind"], 3), order[s["table"]], s["index"])
        addressable = sorted((s for s in symbols if isinstance(s["placement"], int) and s["type"] in ADDRESS_TYPES), key=lambda s: s["value"])
        self.sized = [s for s in addressable if s["size"]]
        self.sized_values = [s["value"] for s in self.sized]
        self.labels = [s for s in addressable if not s["size"]]
        self.label_values = [s["value"] for s in self.labels]
        self.max_size = max((s["size"] for s in self.sized), default=0)
        self.by_name = {}
        for s in symbols:
            if s["placement"] != "undefined" and s["index"] != 0:
                self.by_name.setdefault(s["name"].split("@")[0] if s["table"] == "dynsym" else s["name"], []).append(s)

    def find(self, name):
        candidates = self.by_name.get(name, [])
        return min(candidates, key=lambda s: self.rank(s)[1:]) if candidates else None

    def at(self, address):
        containing = []
        i = bisect.bisect_right(self.sized_values, address) - 1
        barrier = self.sized_values[i] if i >= 0 else None
        while i >= 0 and address - self.sized_values[i] < self.max_size:
            s = self.sized[i]
            if address - s["value"] < s["size"]:
                if containing and s["value"] < containing[0]["value"]:
                    break
                containing.append(s)
            i -= 1
        if containing:
            return min(containing, key=self.rank)
        i = bisect.bisect_right(self.label_values, address) - 1
        if i < 0:
            return None
        nearest = self.label_values[i]
        label = min((s for s in self.labels[bisect.bisect_left(self.label_values, nearest) : i + 1]), key=self.rank)
        if address != nearest:
            if barrier is not None and barrier >= nearest:
                return None
            if label["placement"] >= len(self.sections):
                return None
            section = self.sections[label["placement"]]
            if not section["Address"] <= address < section["Address"] + section["Size"]:
                return None
        return label


def check_hit(path, what, hit, expected, expected_offset):
    got = None if hit is None else (hit["table"], hit["index"], hit["offset"])
    want = None if expected is None else (expected["table"], expected["index"], expected_offset)
    if got != want:
        fail(path, f"{what}: got {got}, expected {want}")


def compare(path, probes):
    ref = reference(path)
    got = ours(path, "--probes", str(probes))
    name = os.path.basename(path)
    header = ref["ElfHeader"]
    if "error" in got:
        ident = header["Ident"]
        file_type = int(header["Type"].split("(")[1].rstrip(")"), 16)
        why = "UnsupportedClass" if ident["Class"]["Value"] != 2 else "UnsupportedEncoding" if ident["DataEncoding"]["Value"] != 1 else "UnsupportedMachine" if header["Machine"]["Value"] != 62 else "UnsupportedType" if file_type not in (2, 3) else None
        if got["error"] != why:
            fail(path, f"rejected with {got['error']}, llvm-readelf implies {why}")
        elif name not in REJECTED and path.startswith(OUT):
            fail(path, f"unexpectedly rejected with {got['error']}")
        return f"rejected ({got['error']}), consistent with llvm-readelf"
    if name in REJECTED:
        fail(path, "expected rejection")

    h = got["header"]
    pairs = [
        ("type", {"executable": 2, "shared": 3}[h["type"]], int(header["Type"].split("(")[1].rstrip(")"), 16)),
        ("machine", h["machine"], header["Machine"]["Value"]),
        ("os_abi", h["os_abi"], header["Ident"]["OS/ABI"]["Value"]),
        ("abi_version", h["abi_version"], header["Ident"]["ABIVersion"]),
        ("entry", h["entry"], header["Entry"]),
        ("flags", h["flags"], header["Flags"]["Value"]),
        ("segment_table_offset", h["segment_table_offset"], header["ProgramHeaderOffset"]),
        ("segment_count", h["segment_count"], count(header["ProgramHeaderCount"])),
        ("section_table_offset", h["section_table_offset"], header["SectionHeaderOffset"]),
        ("section_count", h["section_count"], count(header["SectionHeaderCount"])),
        ("section_name_index", h["section_name_index"], count(header["StringTableSectionIndex"])),
    ]
    for field, mine, theirs in pairs:
        if mine != theirs:
            fail(path, f"header {field}: {mine} != {theirs}")

    segments = [p["ProgramHeader"] for p in ref.get("ProgramHeaders", [])]
    if len(segments) != len(got["segments"]):
        fail(path, f"segment count {len(got['segments'])} != {len(segments)}")
    for i, (mine, theirs) in enumerate(zip(got["segments"], segments)):
        want = {"type": theirs["Type"]["Value"], "flags": theirs["Flags"]["Value"], "offset": theirs["Offset"], "vaddr": theirs["VirtualAddress"], "paddr": theirs["PhysicalAddress"], "file_size": theirs["FileSize"], "mem_size": theirs["MemSize"], "alignment": theirs["Alignment"]}
        if mine != want:
            fail(path, f"segment {i}: {mine} != {want}")

    sections = [s["Section"] for s in ref.get("Sections", [])]
    if len(sections) != len(got["sections"]):
        fail(path, f"section count {len(got['sections'])} != {len(sections)}")
    for i, (mine, theirs) in enumerate(zip(got["sections"], sections)):
        want = {"name": theirs["Name"]["Name"], "type": theirs["Type"]["Value"], "flags": theirs["Flags"]["Value"], "addr": theirs["Address"], "offset": theirs["Offset"], "size": theirs["Size"], "link": theirs["Link"], "info": theirs["Info"], "alignment": theirs["AddressAlignment"], "entry_size": theirs["EntrySize"]}
        if mine != want:
            fail(path, f"section {i}: {mine} != {want}")

    if not sections:
        # Known gap: llvm-readelf recovers .dynsym from PT_DYNAMIC; this reader needs the section table.
        if got["symtab"] is not None or got["dynsym"] is not None:
            fail(path, "symbols reported without a section table")
        return f"{len(segments)} segments, no section table (symbols not compared)"

    symbols = reference_symbols(ref, "Symbols", "symtab") + reference_symbols(ref, "DynamicSymbols", "dynsym")
    compared = 0
    for table in ("symtab", "dynsym"):
        theirs = [s for s in symbols if s["table"] == table]
        mine = got[table] or []
        if len(mine) != len(theirs):
            fail(path, f"{table}: {len(mine)} entries != {len(theirs)}")
        for i, (m, t) in enumerate(zip(mine, theirs)):
            compared += 1
            # llvm-readelf shows an unnamed STT_SECTION symbol under its section's name.
            section_symbol = t["type"] == 3 and m["name"] == "" and isinstance(t["placement"], int) and t["name"] == sections[t["placement"]]["Name"]["Name"]
            if not same_name(t["name"], m["name"], table) and not section_symbol:
                fail(path, f"{table}[{i}] name {m['name']!r} != {t['name']!r}")
            for field in ("value", "size", "bind", "type", "visibility", "placement"):
                if m[field] != t[field]:
                    fail(path, f"{table}[{i}] {m['name']} {field}: {m[field]} != {t[field]}")
            if m["has_address"] != (isinstance(t["placement"], int) and t["type"] in ADDRESS_TYPES):
                fail(path, f"{table}[{i}] {m['name']} has_address: {m['has_address']}")

    lookup = Lookup(symbols, sections)
    for probe in got["by_name"]:
        check_hit(path, f"findSymbol({probe['name']!r})", probe["hit"], lookup.find(probe["name"]) if probe["name"] else None, 0)
    for probe in got["by_address"]:
        expected = lookup.at(probe["address"])
        check_hit(path, f"symbolAt({probe['address']:#x})", probe["hit"], expected, 0 if expected is None else probe["address"] - expected["value"])
    return f"{len(segments)} segments, {len(sections)} sections, {compared} symbols, {len(got['by_name'])} name and {len(got['by_address'])} address lookups agree"


def live(name, library):
    """Run a fixture and compare its own addresses with link address + load bias."""
    path = os.path.join(OUT, name)
    run = subprocess.run([path, "maps"], capture_output=True, text=True)
    reported = {"sym": {}, "libsym": {}}
    lowest = {}
    for line in run.stdout.splitlines():
        fields = line.split()
        if fields[0] in reported:
            reported[fields[0]][fields[1]] = int(fields[2], 16)
        elif fields[0] == "map" and len(fields) >= 7:
            start = int(fields[1].split("-")[0], 16)
            file = os.path.realpath(fields[6])
            if file not in lowest or start < lowest[file][0]:
                lowest[file] = (start, int(fields[3], 16))
    checked = 0
    for file, kind in ((path, "sym"), (os.path.join(OUT, library), "libsym")):
        if os.path.realpath(file) not in lowest or not reported[kind]:
            fail(file, f"live: no mapping or no reported addresses (exit {run.returncode})")
            continue
        start, offset = lowest[os.path.realpath(file)]
        got = ours(file, "--mapping", f"{start:x}", f"{offset:x}")
        bias = got["load_bias"]
        if not isinstance(bias, int):
            fail(file, f"live: loadBias returned {bias}")
            continue
        hits = {p["name"]: p["hit"] for p in got["by_name"]}
        at = {p["address"]: p["hit"] for p in got["by_address"]}
        for symbol, runtime in reported[kind].items():
            hit = hits.get(symbol)
            if hit is None:
                fail(file, f"live: {symbol} not found")
                continue
            link = got[hit["table"]][hit["index"]]["value"]
            if (link + bias) & MASK != runtime:
                fail(file, f"live: {symbol} link {link:#x} + bias {bias:#x} != runtime {runtime:#x}")
            back = at.get((runtime - bias) & MASK)
            if back is None or got[back["table"]][back["index"]]["name"] != symbol:
                fail(file, f"live: runtime {runtime:#x} did not resolve back to {symbol}")
            checked += 1
        if got["header"]["type"] == "executable" and bias != 0:
            fail(file, f"live: ET_EXEC bias {bias:#x}")
        print(f"  live {os.path.basename(file)}: bias {bias:#x}, {len(reported[kind])} runtime addresses match")
    return checked


def main():
    build_dump()
    paths = sys.argv[1:]
    default = not paths
    if default:
        if not os.path.isdir(OUT):
            sys.exit("no fixtures: run tests/fixtures/elf/build.sh first")
        paths = sorted(os.path.join(OUT, f) for f in os.listdir(OUT) if f not in ("VERSIONS", "many.c"))
        paths += [p for p in SYSTEM if os.path.exists(p)]
    for path in paths:
        before = len(failures)
        summary = compare(path, 400 if os.path.getsize(path) > (1 << 20) else 1 << 30)
        print(f"{'ok  ' if len(failures) == before else 'FAIL'} {os.path.relpath(path, ROOT) if path.startswith(ROOT) else path}: {summary}")
    if default:
        for name, library in RUNNABLE.items():
            live(name, library)
    for failure in failures[:50]:
        print("FAIL", failure)
    if failures:
        sys.exit(f"{len(failures)} mismatches")
    print("all comparisons agree")


if __name__ == "__main__":
    main()
