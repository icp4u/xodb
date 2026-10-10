# Descriptor path treemap

**LIVE SYSCALL TRACING · ~11% host syscall overhead · E to stop.**
The overview treemap starts tracing by default, like the graph and galaxy.
Permission failures fall back to polling with a visible reason. For the full
view, run with existing process/tracing access:

```sh
sudo -E xodb --overview --panel treemap
```

Press **B** from another overview panel. Click a tile to zoom, **Backspace** to
move up, **Esc** for root, and **+/-** to show more/fewer tiles (8–256).
**L** opens one explicitly sampled holder's Files table. It does not claim that
all descriptors with that path refer to one inode. **P** freezes the view and
stops tracing; **E** switches to polling; **X** permanently redacts paths for
this run. Leaving the pane also stops its tracing demand. Blue tiles have
unmeasured IO, green tiles have measurements but no current activity, and warm
tiles have sampled throughput. Cumulative syscall bytes remain available in MCP
after tracing stops; offset progress is reported separately.

The panel and observer use the same C path aggregator, with 4,096 nodes, 1 MiB
copied names and 32 components per path. Arrays grow with demand. The GUI rebuilds
at most twice per second and displays the snapshot age. Selection follows the
selected node's exact component chain (raw name bytes plus the separate
synthetic-bucket namespace) across refreshes, not its displayed spelling. Empty
components are dropped, as POSIX path resolution does (`//x/` groups as `/x`);
the kernel never reports them, so every displayed spelling names one node. If the
chain vanishes or becomes capped, selection returns to root with a notice. Trees
are built from a copy taken under the publication lock, after releasing it, so a
large rebuild never delays the syscall stream's drain.

`get_fd_treemap` is an observer MCP tool. It requests polling only; reading it
never starts, renews or stops tracing. `{}` returns root plus up to 16 tiles.
`{"node": 12, "sequence": 34, "limit": 32}` requests a node from that exact poll;
a changed sequence refuses with `FdSnapshotChanged`. Use the IDs returned by
your own query. `limit` is 1–32; an Other tile has no node/path and counts every
omitted entry. This is a bounded projection, not a complete pathname listing.
`metric` and `coverage` distinguish measured zero, unavailable IO, stale data,
unexpanded handles and scan omissions. `system_flow` carries tracing cost, CPU
coverage, unmatched bytes and loss. `sample_holder` identifies one process and
fd for drill-in. Non-root node IDs require a sequence.

`path_hex` preserves exact captured bytes. The readable `path` is null for
non-UTF-8 strings or names longer than 512 bytes, keeping replies bounded even
when JSON escaping expands every byte. Redaction removes both forms. Synthetic
bucket labels carry a separate `namespace_kind`; they are not filesystem paths.
The GUI escapes control/non-ASCII bytes, and clips long labels.

Tile area represents **descriptor count**, including duplicate handles. It never
represents allocated disk space or unique inode count. Equal path spellings may
refer to different files or mount namespaces; hardlink aliases may have different
spellings. Grouping paths does not assert file identity. Only the existing C
PID/start/fd/device/inode/kind join attaches sampled syscall-byte counters.
Those associations do not prove the kernel file selected by a concurrent fdget.

Absolute regular-file, directory and device paths form a component tree. Other
kinds, including pipes, sockets and memfd, have explicitly labelled buckets.
Unavailable or malformed paths stay counted in unavailable-path buckets. Paths
are kept literally: repeated separators, dot components and the observed deleted
suffix are neither resolved nor removed. Synthetic buckets have a distinct
namespace even if a real filename has the same spelling. Path bytes are raw;
presentation consumers must escape them and honor redaction.

Every node retains direct, unexpanded and total metrics. A directory can have
both an open descriptor of its own and children; layout gives its direct handles
a separate tile so their area is not lost. Stale descriptors, stale names,
deleted handles, unknown names and unexpanded descendants stay explicitly
counted. A stale path never receives newly joined event bytes. A known measured
zero has a nonzero measurement count; unavailable IO has none. Seekable offset
progress, read bytes and write bytes are separate fields, never substitutes.
Stopped flow keeps cumulative sampled counters but contributes no live rate.
Stream/count flags and status remain available to show incomplete coverage.

The builder accepts at most 16,384 processes and 262,144 descriptors. Options
bound nodes (16–65,536), copied text (256 bytes–8 MiB) and path components (1–32).
Path text is limited to 4,096 bytes. Allocation grows with demand. If a node,
text or depth limit prevents expansion, the descriptor and its metrics join the
nearest represented ancestor's explicit unexpanded bucket. No input descriptor
disappears. The source-fd-to-node map identifies these cases with an overflow bit.
A cap is not a claim to have retained every pathname.

`xrt_fdtreemap_layout` projects one directory level into at most 1,024 tiles.
It keeps the largest entries and combines any remainder in an explicit Other
item with a hidden-item count. C sorts and partitions the weights into normalized,
non-overlapping rectangles. The renderer only scales/draws the returned tiles.
Byte totals and finite rates saturate with a flag instead of wrapping or becoming
infinity. Malformed numeric rates and contradictory duplicate active flow rows
are refused.

Fast component checks:

```sh
scripts/build test-fdtreemap test-fdtreemap-owner test-fdflow-graph -Doptimize=ReleaseSafe -j2
```

The synthetic oracle checks exact values, path/identity distinctions, direct plus
child area, stale/unknown/zero states, capacity, malformed input, saturation,
geometry and a 100,000-descriptor/1,000-process workload. Checks stay active with
NDEBUG. The test executable's `--wrong-oracle` expects three handles where there
are two and must abort. `tests/runtime-fdtreemap-fuzz.c` belongs to the periodic
lane; successful builds must conserve every descriptor and projected metric.

Fast private GUI/MCP check (use an empty, short work directory):

```sh
python3 tests/fdtreemap-gui.py --work-dir .work/treemap
```

The test starts its own fixture and scopes all descriptor/tracing collection to
that PID. `--wrong-oracle` plants an incorrect handle count and must fail.
`--live` is a periodic positive syscall-byte check requiring existing tracing
permission. Neither test changes system policy.

The owner regression uses fake capture and an owned child to prove flow demand
binds its descriptors even without topology demand. The previous owner fails
this oracle; polling-only observers still do not request capture.
