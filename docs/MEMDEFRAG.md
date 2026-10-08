# Memory defrag views

`xodb --memdefrag` is a terminal twin of the overview's
[Memory map panel](OVERVIEW.md#memory-map-defrag-views): an MS-DOS 6 DEFRAG /
Norton Speed Disk screen of one process's memory. Each map cell is 2 MiB of
virtual address space; the status box shows THP coverage as **% complete**,
the refresh period (with *cost-limited* when the observer slowed an expensive
map) and the system-wide activity from vmstat deltas.

```
xodb --memdefrag --pid PID [--start-ticks N] [--theme dos|plain] [--redact]
xodb --memdefrag --once | --json [--samples N] [--stream] [--ansi]
xodb --memdefrag --replay FILE --once
```

Without `--pid` the map shows system free memory by buddy block size: cells
in blocks of 2 MiB or more versus smaller ones. These are counts, not physical
positions (a physical map needs privilege).

| Glyph | Meaning |
| --- | --- |
| `█` light cyan | THP, PMD-mapped ("optimized") |
| `▓` cyan / light cyan | 4 KiB anonymous / partly huge |
| `▓` yellow | file-backed or shared |
| `▓` grey | swapped out |
| `░` light blue | mapped, not present |
| `░` black | unmapped gap; `≈` a compressed gap or never-resident VMA |
| `■` red | unmovable (VM_IO / VM_PFNMAP) |
| `▒` on grey | unknown: not observed |
| `r` `W` blinking on green | page states changed between the last two snapshots |
| `█` white | collapsed into a huge page this snapshot |
| `▓` red on red | split from a huge page this snapshot |

A dark-grey ground means part of the cell was not observed, or the page size
is unknown (plain pagemap fallback). Keys: arrows move the cursor, PgUp/PgDn
scroll, **+/-** zoom toward 4 KiB cells, **o** select a process, **g**
legend, **t** plain/colour, **p** pause, **q** quit. `--json` prints the map in
the replay schema; `--stream` prints every publication as one line, which
`--replay` (and the overview's `--replay`, inside a frame's `memory_map`)
draws again.

## Try it

```
cc -O2 -o ~/tmp/mdf tests/memdefrag-fixture.c
~/tmp/mdf            # 1 GiB, 4 KiB pages, MADV_HUGEPAGE; prints its pid
xodb --memdefrag --pid PID --redact      # in a second terminal
```

Type `collapse` into the fixture four times (each MADV_COLLAPSEs a quarter;
ENOMEM means the kernel had no free huge page at that moment) and `split`
once (an mprotect of one page). The fixture changes no system settings.
