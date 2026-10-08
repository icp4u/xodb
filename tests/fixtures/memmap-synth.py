#!/usr/bin/env python3
"""Synthetic memory maps for the Memory map panel and `xodb --memdefrag`.

Adds a "memory_map" object (schema xodb-memdefrag/1) to every frame of an
overview replay, or writes bare maps with --bare. Every address, name, path
and count is invented. Scenarios:

  process   a 1 GiB THP-eligible arena whose coverage rises frame by frame; the
            last frame has page-state changes, fresh collapses and one split;
            also heap, swap, a file mapping, a reserved gap, an unmovable PFN
            mapping and a range the scan budget did not reach (unknown)
  fallback  the same layout through plain pagemap flags: page size unknown
            and the coverage denominator unknown (hatched, never 0 %)
  system    no process: free memory by buddy block size, kcompactd active
  exited    the process exited: an explicit state, no map (not "unavailable")

usage: memmap-synth.py BASE.jsonl OUT.jsonl [--scenario NAME] [--frames N]
       memmap-synth.py --bare OUT.jsonl [--scenario NAME] [--frames N]
"""
import argparse
import json

MIB = 1 << 20
CELL = 2 * MIB
PRESENT, SWAPPED, FILE, HUGE = 1, 2, 4, 8
SCAN_KNOWN = 1 | 2 | 4 | 8 | 32 | 128 | 256
FLAGS_KNOWN = 1 | 2 | 4 | 64 | 128
PID, START = 3100, 100 + 3100 * 7  # the synthetic "browser" row in overview-synth.py


def vmas_layout():
    v = []
    def add(start, size, perms, kind, path=None, eligible=False, rss=None, swap=0, tag=""):
        v.append(dict(start=start, end=start + size, perms=perms, kind=kind, path=path, thp_eligible=eligible,
                      rss=rss, anon_huge=0, swap=swap, locked=0, tag=tag))
    base = 0x555555400000
    add(base, 8 * MIB, "r-xp", "file", "/usr/lib/browser/browser", rss=6 * MIB, tag="text")
    add(base + 8 * MIB, 2 * MIB, "rw-p", "anon", None, rss=2 * MIB, tag="data")
    add(base + 16 * MIB, 96 * MIB, "rw-p", "heap", "[heap]", eligible=True, rss=80 * MIB, swap=8 * MIB, tag="heap")
    arena = 0x7f3a00000000
    add(arena, 1024 * MIB, "rw-p", "anon", None, eligible=True, rss=1024 * MIB, tag="arena")
    add(arena + 1024 * MIB, 256 * MIB, "rw-s", "file", "/home/demo/secret-cache.db", rss=150 * MIB, tag="cache")
    add(arena + 1280 * MIB, 512 * MIB, "---p", "anon", None, rss=0, tag="reserved")
    add(arena + 1792 * MIB, 4 * MIB, "rw-s", "special", "/dev/dri/renderD128", rss=4 * MIB, tag="pfn")
    add(arena + 1800 * MIB, 128 * MIB, "rw-p", "anon", None, eligible=True, rss=None, tag="unscanned")
    libs = arena + 2048 * MIB
    for k in range(6):
        add(libs + k * 720 * 1024, 720 * 1024, "r-xp" if k % 2 else "r--p", "file", f"/usr/lib/libexample{k}.so.1", rss=512 * 1024, tag="lib")
    add(0x7ffd40000000, 8 * MIB, "rw-p", "stack", "[stack]", rss=3 * MIB, tag="stack")
    add(0x7ffd40a00000, 16 * 1024, "r--p", "pseudo", "[vvar]", rss=0, tag="vvar")
    add(0x7ffd40a04000, 8 * 1024, "r-xp", "pseudo", "[vdso]", rss=8 * 1024, tag="vdso")
    return v


def page_state(vma, k, t, frames, scenario):
    """Bytes of one 2 MiB cell (index k inside the VMA) at frame t."""
    tag = vma["tag"]
    last = t == frames - 1
    if tag == "arena":
        huge_cells = min(512, 64 + int(448 * t / max(1, frames - 1)) - (8 if last else 0))
        huge = k < huge_cells or (last and k in range(huge_cells, huge_cells + 8))
        if last and k == 37:
            huge = False  # the forced split
        present = k < 470 or (last and k < 500)
        if not present:
            return dict(present=0, huge=0, file=0, swapped=0)
        return dict(present=CELL, huge=CELL if huge else 0, file=0, swapped=0)
    if tag == "heap":
        if 40 <= k < 44:  # read-faulted onto the huge zero page: HUGE|ZERO, not THP
            return dict(present=CELL, huge=0, file=0, swapped=0, zero=CELL)
        if k >= 44:
            return dict(present=0, huge=0, file=0, swapped=CELL)
        return dict(present=CELL, huge=CELL if k % 9 == 0 else 0, file=0, swapped=0)
    if tag == "cache":
        on = (k * 37 + (11 if last else 0)) % 100 < 60  # the last poll faults some pages in and drops others
        return dict(present=CELL if on else 0, huge=0, file=CELL if on else 0, swapped=0)
    if tag == "pfn":
        return dict(present=CELL, huge=0, file=0, swapped=0)
    if tag == "stack":
        return dict(present=CELL if k >= 2 else 0, huge=0, file=0, swapped=0)
    if tag in ("text", "lib"):
        return dict(present=CELL if k % 3 != 2 else 0, huge=0, file=CELL if k % 3 != 2 else 0, swapped=0)
    return dict(present=CELL, huge=0, file=0, swapped=0)


def build_cells(vmas, t, frames, scenario):
    cells, nxt = [], 0
    known = FLAGS_KNOWN if scenario == "fallback" else SCAN_KNOWN
    for i, v in enumerate(vmas):
        first = v["start"] - v["start"] % CELL
        stop = -(-v["end"] // CELL) * CELL
        if first < nxt:
            first = nxt
        if first >= stop:
            continue
        if nxt and first > nxt:
            if (first - nxt) // CELL <= 4:
                for a in range(nxt, first, CELL):
                    cells.append(dict(start=a, end=a + CELL))
            else:
                cells.append(dict(start=nxt, end=first, gap=first - nxt))
        if v["rss"] == 0 and (stop - first) // CELL > 64:
            cells.append(dict(start=first, end=stop, vma=i, gap=stop - first, mapped=stop - first))
            nxt = stop
            continue
        for a in range(first, stop, CELL):
            # Which VMAs intersect this cell; the first owns it.
            inter = [(j, w) for j, w in enumerate(vmas) if w["start"] < a + CELL and w["end"] > a]
            owner = inter[0][0]
            mapped = sum(min(w["end"], a + CELL) - max(w["start"], a) for _, w in inter)
            cell = dict(start=a, end=a + CELL, vma=owner, mapped=mapped)
            w = vmas[owner]
            if w["tag"] == "unscanned":
                cell.update(observed=0, known=0)
            else:
                k = (a - w["start"]) // CELL if a >= w["start"] else 0
                st = page_state(w, k, t, frames, scenario)
                scale = mapped / CELL
                for key in ("present", "huge", "file", "swapped", "zero"):
                    cell[key] = int(st.get(key, 0) * scale)
                if scenario == "fallback":
                    cell["huge"] = 0
                cell["observed"] = mapped
                cell["known"] = known
                prev = page_state(w, k, t - 1, frames, scenario) if t > 0 else None
                if prev is not None:
                    cell["change_known"] = PRESENT | SWAPPED | FILE
                    flips = 0
                    for bit, key in ((PRESENT, "present"), (SWAPPED, "swapped"), (FILE, "file")):
                        if bool(prev[key]) != bool(st[key]):
                            flips |= bit
                    cell["changed"] = flips
                    if scenario != "fallback" and w["kind"] in ("anon", "heap"):
                        cell["pmd_known"] = True
                        if st["huge"] and not prev["huge"]:
                            cell["collapsed"] = mapped
                        if prev["huge"] and not st["huge"]:
                            cell["split"] = mapped
                cell["special"] = w["kind"] == "special"
            cells.append(cell)
        nxt = stop
    return cells


def system(t, frames, scenario):
    last = t == frames - 1
    grow = t / max(1, frames - 1)
    normal = [41000, 22000, 9800, 4100, 1500, 620, 240, 96, 40, int(18 + 60 * grow), int(4 + 120 * grow)]
    zones = [dict(node=0, name="DMA", blocks=[0, 1, 1, 0, 2, 1, 1, 1, 0, 1, 3]),
             dict(node=0, name="DMA32", blocks=[3200, 1800, 900, 420, 200, 90, 40, 18, 9, 6, 120]),
             dict(node=0, name="Normal", blocks=normal)]
    names = ["thp_fault_alloc", "thp_fault_fallback", "thp_collapse_alloc", "thp_collapse_alloc_failed", "thp_split_page",
             "thp_split_pmd", "thp_deferred_split_page", "compact_stall", "compact_fail", "compact_success",
             "compact_migrate_scanned", "compact_free_scanned", "compact_daemon_wake", "compact_daemon_migrate_scanned", "pgmigrate_success"]
    deltas = dict.fromkeys(names, 0)
    if scenario == "system" and last:
        deltas.update(compact_daemon_wake=1, compact_daemon_migrate_scanned=4096, compact_migrate_scanned=4096, compact_success=3, pgmigrate_success=2210)
    elif last:
        deltas.update(thp_collapse_alloc=8, thp_split_pmd=1, thp_fault_alloc=12)
    else:
        deltas.update(thp_fault_alloc=24 if t % 2 else 0, thp_collapse_alloc=3 if t % 3 == 0 else 0)
    counters = [dict(name=n, value=10000 + 97 * t + i, delta=None if t == 0 else deltas[n]) for i, n in enumerate(names)]
    settings = [dict(name="enabled", value="[always] madvise never"), dict(name="defrag", value="always defer defer+madvise [madvise] never"),
                dict(name="khugepaged/pages_collapsed", value=str(4000 + 8 * t)), dict(name="khugepaged/pages_to_scan", value="4096")]
    ok = dict(state="ok", reason="ok")
    return dict(buddy=ok, vmstat=ok, thp=ok, page_size=4096, interval_ns=0 if t == 0 else 1000000000, cpu_ns=310000,
                zones=zones, counters=counters, settings=settings)


def memory_map(t, frames, scenario):
    sys_ = system(t, frames, scenario)
    out = dict(schema="xodb-memdefrag/1", sequence=1000 + t, sampled_ns=5_000_000_000 + t * 1_000_000_000,
               redacted=False, cell_bytes=CELL, worker_cpu_ns=2_000_000 + t * 2_400_000, system=sys_,
               # An expensive 4 KiB-heavy map refreshes slower than 1 Hz (cost-limited).
               refresh_ns=1_000_000_000 if scenario == "system" else 5_200_000_000, system_refresh_ns=1_000_000_000, cost_limited=scenario != "system", system_cost_limited=False)
    if scenario == "system":
        return out
    if scenario == "exited":
        out["process"] = dict(pid=PID, start_ticks=START, name="browser", maps=dict(state="exited", reason="process exited"),
                              pages=dict(state="exited", reason="process exited"), backend="none", page_size=4096)
        return out
    vmas = vmas_layout()
    cells = build_cells(vmas, t, frames, scenario)
    by_vma = {}
    for c in cells:
        if "vma" in c and c.get("gap", 0) == 0:
            by_vma[c["vma"]] = by_vma.get(c["vma"], 0) + c.get("huge", 0)
    eligible = [i for i, v in enumerate(vmas) if v["thp_eligible"] and v["tag"] != "unscanned"]
    numerator = sum(by_vma.get(i, 0) for i in eligible)
    denominator = sum(vmas[i]["end"] - vmas[i]["start"] for i in eligible) + (128 * MIB)
    for i, v in enumerate(vmas):
        v["anon_huge"] = by_vma.get(i, 0) if v["kind"] in ("anon", "heap") else 0
        v.pop("tag")
    fallback = scenario == "fallback"
    out["process"] = dict(
        pid=PID, start_ticks=START, name="browser", maps=dict(state="ok", reason="ok"),
        pages=dict(state="partial", reason="page scan budget reached"),
        backend="pagemap_flags" if fallback else "pagemap_scan", page_size=4096, pmd_size=CELL,
        coverage_numerator=None if fallback else numerator, coverage_denominator=None if fallback else denominator,
        rss=1400 * MIB, anon_huge=None if fallback else numerator, swap=8 * MIB, mapped_bytes=sum(v["end"] - v["start"] for v in vmas),
        scanned_bytes=sum(c.get("observed", 0) for c in cells), scan_cpu_ns=4_200_000, interval_ns=0 if t == 0 else 1_000_000_000,
        vma_count=len(vmas))
    out["vmas"] = vmas
    out["cells"] = cells
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--scenario", default="process", choices=["process", "fallback", "system", "exited"])
    ap.add_argument("--frames", type=int, default=0, help="bare maps to write (default: one per base frame, or 12)")
    ap.add_argument("--bare", action="store_true")
    a = ap.parse_args()
    if a.bare:
        frames = a.frames or 12
        with open(a.paths[0], "w") as f:
            for t in range(frames):
                f.write(json.dumps(memory_map(t, frames, a.scenario)) + "\n")
        return
    base, out = a.paths
    lines = [l for l in open(base) if l.strip()]
    frames = len(lines)
    with open(out, "w") as f:
        for t, line in enumerate(lines):
            frame = json.loads(line)
            frame["memory_map"] = memory_map(t, frames, a.scenario)
            f.write(json.dumps(frame) + "\n")


if __name__ == "__main__":
    main()
