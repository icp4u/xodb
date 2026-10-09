# Function observations and saved investigations

xodb can record individual native function calls, retain their raw argument and
return register words, and compare fast and slow calls. Linux x86-64 SysV is the
initial supported ABI. The C runtime collects both local and C-agent events;
the host pairs and analyzes the retained evidence.

Capture is headless (CLI and MCP). A saved `.xoi` can also be browsed in the GUI;
see [Browsing a saved investigation](#browsing-a-saved-investigation). Existing
**P** CPU sampling and `.xoc` profile comparisons continue to work independently.

## One-command capture

From the checkout, after `./scripts/build -Doptimize=ReleaseSafe`:

```sh
xodb --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper" \
  --observe-recipe examples/observation.recipe.json \
  --observation-out example-01.xoi \
  -- "$PWD/zig-out/bin/xodb-observation-fixture"

xodb --open-observation example-01.xoi
xodb --open-observation example-01.xoi --observation-threshold-ns 1000000
xodb --browse-observation example-01.xoi
```

Use a new output filename each time. `--open-observation` prints JSON;
`--browse-observation` opens the same archive in the GUI ([keys](#browsing-a-saved-investigation)). The JSON
contains capture status, cohort counts, duration distributions and raw-record citations.
The fixture deliberately alternates short calls and an 8 ms wait: expect sixteen
complete calls, eight on either side of the recipe's 4 ms threshold. It tests
classification; it is not an optimization benchmark.

The recipe implies headless operation. It runs to `observation_ready`, prepares
the probes while stopped, resumes, then stops capture at `observation_done`.
After saving, xodb kills its owned target or detaches an attached target. Target
output goes to stderr. A duration or record limit can leave an incomplete final
call; its duration stays unknown. Unexpected stops, signals and scope changes
produce an explicit outcome; interrupted runs return failure after saving
available evidence when collection had started.

`--allocation-helper` is the existing explicit uprobe helper option, shared by
allocation and generic function capture. It permits the helper's `sudo -n`
invocation to open probes for the selected target. Omit it when the process
already has sufficient perf permissions. Neither command installs a helper or
changes system policy. A remote C agent needs a matching build and a helper path
on its own machine; add the usual `--runtime-agent` / `--runtime-ssh` options.

## Ruby example

This finite workload alternates a small and a large array. Capture its native
`rb_ary_each` calls after Ruby reaches `ruby_run_node`:

```sh
xodb --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper" \
  --observe-recipe examples/ruby-observation.recipe.json \
  --observation-out ruby-01.xoi \
  -- /opt/debug/bin/ruby -e '
    small = (1..120).to_a
    large = (1..100_000).to_a
    result = 0
    20.times do |i|
      values = i.even? ? small : large
      values.each do |v|
        result = ((result * 1664525 + v * 1013904223) ^ (result >> 13)) & 0xffffffff
        v.to_s.reverse.to_i
      end
    end'

xodb --open-observation ruby-01.xoi
xodb --open-observation ruby-01.xoi --mcp
```

Use a Ruby build containing those native symbols; change `/opt/debug/bin/ruby`
to its path. The recipe selects the thread reaching `ruby_run_node`, observes
`rb_ary_each`, and stops at process exit or its five-second limit. Twenty
complete calls are expected for this workload when it finishes within the limit.
The 4 ms split should separate the small and large loops on this host; measured
durations depend on the machine and Ruby build, and the threshold can be changed
when reopening the same archive.

The first argument word is the raw Ruby `VALUE` passed to the native function.
Its hex patterns can distinguish the two arrays in this program. xodb does not
decode array contents or Ruby types from that word, and captured native stacks
are not Ruby logical frames. This example demonstrates call observation and
input-dependent latency, not an optimized implementation of the workload.

## Perl example

The same shape works for Perl. This workload sorts a small and a large array in
turn. Capture its native `Perl_pp_sort` calls after Perl reaches `perl_run`:

```sh
xodb --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper" \
  --observe-recipe examples/perl-observation.recipe.json \
  --observation-out perl-01.xoi \
  -- /opt/debug/bin/perl -e '
    my @small = map { ($_ * 7919) % 1000 } 1..120;
    my @large = map { ($_ * 7919) % 100_003 } 1..100_000;
    my $total = 0;
    for my $i (0..19) {
        my @sorted = sort { $a <=> $b } ($i % 2 ? @large : @small);
        $total += $sorted[0];
    }'

xodb --open-observation perl-01.xoi
```

Use a Perl build whose `libperl.so` keeps its symbol table and DWARF; change
`/opt/debug/bin/perl` to its path. `Perl_pp_sort` is a local symbol of
`libperl.so` and runs once per `sort` op. A numeric `sort { $a <=> $b }` does
not go through the exported `Perl_sortsv_flags`, so observe the op itself.
Twenty complete calls are expected: on the reference host the ten small sorts
take about 5 µs and the ten large ones about 4 ms, so the recipe's 1 ms split
separates them with margin. Durations depend on the machine and Perl build. In a threaded Perl the first argument word
is the interpreter pointer (`my_perl`), not a Perl value. Captured native stacks
are not Perl logical frames.

`scripts/demo-perl` is the interactive counterpart of the Ruby and CPython
demos. It runs `examples/perl-demo.pl`, where nested subs keep storing `42` at
index 3, and stops in `Perl_av_store` and then `Perl_av_delete`. At the first
stop, **E** `val` shows `undef`, the new element `av_store` is about to insert:
Perl assigns 42 only after the call returns, so stale bits are not shown as a
value. **E** `av` shows `AV (3 slots)`. At the `Perl_av_delete` stop,
`av->sv_u.svu_array[3]` shows `IV 42`. Agents can read the Perl stack beside the
native one with `get_language_stack` (`main::store_answer` → `main::tick` →
`main`, with file and line).

## Recipes

```json
{
  "version": 1,
  "start": "observation_ready",
  "functions": ["observed_work"],
  "stop": "observation_done",
  "duration_ms": 10000,
  "record_limit": 32768,
  "memory_limit": 67108864,
  "callstacks": true,
  "threshold_ns": 4000000,
  "threads": "selected"
}
```

`start` and `stop` are optional phase symbols. A finite positive duration is
required. Choose phases outside the observed function; software breakpoints on
an observed entry conflict with its uprobe. Function names must resolve exactly
and uniquely in one executable mapping. IFUNC resolvers and interior addresses
are rejected. `selected` captures the thread reaching the start phase;
`all_stopped` selects every held thread, at most 32. New threads are not enrolled.

Defaults are 10 seconds, 32,768 records and 64 MiB of retained host allocations.
Each entry and return is a record. Requests allow at most sixteen functions and
six raw integer argument words per entry. Preparation reads a verified mapped
ELF, bounded to 128 MiB. Recipes are bounded to 64 KiB and reject unknown fields.
Start-phase waits, preparation and cleanup have separate bounded deadlines.

## What the evidence means

An invocation has stable call and raw-record ordinals, a process/session/image
identity, stable debugger thread identity, function location, entry time,
optional return time, optional captured stack, and an explicit pairing reason.
Only validated pairs get a wall-duration value. Recursion is paired per thread
using function identity and normalized entry/return stack position.

The six words are DI, SI, DX, CX, R8 and R9; the return word is AX. The original
sampled registers and optional entry stack bytes are retained separately. These
are **untyped words**, including unused registers when a function has fewer
arguments. Pointer contents, floating-point/vector/aggregate arguments and
arguments passed on the stack are not inferred. MCP renders address/register
words as hex strings, and duration sums as decimal strings to preserve precision.
Kernel callchain PCs are raw evidence, not a claim of validated symbolic frames.

Missing records, throttling, stack switches, mismatched nesting and reversed
timestamps invalidate pairing in the affected thread. Later raw events remain
visible as incomplete evidence. Exec, mapping and process-scope boundaries stop
collection. No successful return is invented for a longjmp, tail alias, missing
entry or stopped capture.

Fast means duration **strictly below** the threshold; slow means greater than or
equal. Summaries include complete/incomplete/filtered denominators, nearest-rank
p50/p90/p99, exact word-value distributions, omitted-value counts and example
call IDs. Comparisons operate on ended captures and run on cancellable workers.
Wall duration includes waiting, scheduling and probe overhead; it is not CPU cost.

## Saved `.xoi` investigations

`.xoi` is a separate versioned invocation-evidence container. `.xoc` remains the
CPU/allocation profile archive described in [PROFILE_COMPARISON.md](PROFILE_COMPARISON.md).
An `.xoi` contains its recipe and selected cohort filter when available, exact
function/thread/file identities, clock provenance, raw records, call citations,
termination/loss information and pairing algorithm version. It does not need
the original executable or working directory to reopen and compare.

The container has a SHA-256 checksum. Opening validates metadata and reproduces
pairing from raw records, checking every saved call citation. Unsupported
versions fail explicitly; saved paths are labels and are never opened. Files
are capped at 64 MiB and decoding at 256 MiB. A default-sized full-stack fixture
uses about 25.3 MB on disk and 133 MB during decoding; larger live captures can
exceed the file limit and report a save error.

The checksum verifies container bytes; it does not authenticate a producer or
hash the original executable. File identities record device, inode, size and
timestamps, alongside verified function offsets. Full executable content hashes
are not yet retained.

Save/open work runs off the owner thread. Saving publishes a complete new file
atomically without replacing an existing destination. Completion means actual
publication, not merely accepting the request. Durability sync is not requested.
Cancellation after publication does not remove the published file.

## Browsing a saved investigation

```sh
xodb --browse-observation example-01.xoi
xodb --browse-observation example-01.xoi --observation-threshold-ns 1000000
```

`--browse-observation` opens the archive on the same worker and validation as
`--open-observation` and shows the invocation browser. `--open-observation` itself
stays headless. The browser starts one comparison, at the given threshold, the
archive's saved threshold or 4 ms. Rows are drawn only for the visible window;
scrolling and selection never start analysis.

- The header shows capture identity, record/call counts, stop/finish reasons,
  lost events, throttles, rejections, the first gap and whether an unread suffix
  is possible.
- The cohort summary shows the comparison ID and threshold (`fast < T <= slow`),
  total/matched/filtered/filter-unavailable denominators, complete and incomplete
  counts by reason, p50/p90/p99, min/max and the sum of inclusive wall durations
  (nested or parallel calls overlap). Clicking a DI example selects its call.
- **Tab** cycles All calls, Slow, Fast, Incomplete and Raw records. **J/K**,
  arrows, **PgUp/PgDn**, Home/End and the wheel move; clicking selects a row.
- The call detail shows its thread, wall duration or incomplete reason, raw
  entry/return/parent citations, the six untyped argument words (or "not
  captured"), the AX word and the raw entry callchain PCs. **E** and **R** open the
  cited raw record, **P** the parent call, **C** (or Enter) returns from a record
  to the call citing it, **Backspace** returns to the previous list. Missing
  entries and returns are reported, never inferred.
- **]** and **[** double or halve the threshold; **T** types it in nanoseconds.
  Recomputation uses the same Session operation and busy rule as MCP
  `compare_observation`; a running comparison is not replaced. **Esc** cancels
  a running open or comparison, otherwise it closes the browser like **N**. **N**
  in the main view reopens it with the same selection. **Shift+Q** quits.

With `--session-socket`, agents read the same immutable capture. An agent's
`compare_observation` still needs the controller lease; the human GUI does not.
The browser follows the latest comparison, including one started by an agent,
and keeps its selected call. **F8** grants or revokes agent control from inside
the browser. `--observation-threshold-ns` is not accepted together with
`--mcp` or `--session-socket`; use **T** there. A corrupt or unsupported archive
shows its error and no evidence.

Durations are entry-to-return wall time, not CPU time or causal cost. Argument
and return words are raw registers, not typed or language-level values; PCs are
not logical frames.

## MCP workflow

For a live target, start xodb with `--headless --mcp --agent-scope control` and
the target/helper options. In a GUI session, **F8** grants/revokes agent control.

1. Stop at a workload phase. Read `get_session` for its generation and stable
   thread IDs, and select an executable mapping containing the desired functions.
2. Call `start_observation` with `generation`, `tids`, `mapping_address` as hex,
   and `functions` as an array of exact names. Poll `get_observation` until
   `state` is `collecting`; preparation failures include a diagnostic.
3. Continue. Stop with `stop_observation`, passing the current generation and
   the observation's `session_id` / `capture_id`, or let its limit end it.
4. Page `get_observation_calls` and `get_observation_records` with that identity.
   Pages are immutable once collection ends. `compare_observation` starts a job;
   use `get_observation_comparison` to obtain the result. Filters include stable
   thread ID, function ID, an entry-time window, an exact argument word or return.
5. `save_observation` takes `generation`, the capture identity and a new `path`.
   Poll `get_observation_archive` with its returned `id` to confirm publication.

For offline inspection:

```sh
xodb --open-observation example-01.xoi --mcp
```

Read tools use the recorded capture identity, which differs from the new host
session's identity. `get_observation` reports both through the normal MCP process
envelope. Offline captures cannot start collectors.

`associate_observation` joins ended native captures from the same process/image
to complete call intervals. Supply the observation identity and threshold, plus
`profile_id` / `profile_revision` (`include_cpu`, `include_syscalls`) and/or
`allocation_id` / `allocation_revision`. Poll/page `get_observation_associations`;
`stream_id` also pages the retained normalized source records. Reports distinguish
unique matches, overlapping calls, outside calls, boundary crossings and unusable
time/identity. Remote timestamps carry conversion uncertainty and unmeasured
drift. Association counts are samples/events, not inferred CPU time, bytes or
causality. Source loss and excluded metadata are reported separately. Saving after a successful association also retains its normalized CPU points,
syscall intervals and allocation sample events, source capture/revision IDs,
original ordinals, producer/clock proofs, uncertainty and derived result. Raw
citations refer to those normalized records. Full CPU stacks, syscall payloads
and allocation arguments are not bundled by this feature. An association is
still temporal evidence, not causal attribution.

## Coherent stopped inspections

`start_inspection` takes a required generation and TID, an optional frame, and
bounded `registers`, `stack`, `locals`, `expressions` and `memory` requests.
Poll `get_inspection` with its returned `id`; each item has an ordinal and either
data or a diagnostic. Memory pages retain a validity mask and `?` bytes for
unreadable addresses. All traced threads must be held. This does not make shared
memory atomic against unobserved processes or devices.

One item advances per owner poll. A generation/image/thread change fails pending
work and preserves its completed prefix; completed items never read from the
new target state. `cancel_inspection` retains that prefix; `release_inspection`
frees it. Eight jobs of at most 4 MiB of tracked Zig allocations are retained per
process session. Local DWARF-library work can still take time within an item.
These inspections live until explicitly released or the session closes.

This API provides retained context and fewer client requests for some workflows,
not a measured latency improvement. The sixteen-item fixture used fourteen
requests versus sixteen legacy reads, with larger replies and higher latency.

## Checks

```sh
./scripts/build test -Doptimize=ReleaseSafe
python3 tests/inspections.py
python3 tests/inspection-lifecycle.py
python3 tests/observations-live.py --helper "$PWD/zig-out/bin/xodb-allocation-helper"
python3 tests/observation-recipes.py --helper "$PWD/zig-out/bin/xodb-allocation-helper"
python3 tests/observation-associations.py --helper "$PWD/zig-out/bin/xodb-allocation-helper"
python3 tests/invocations-gui.py
```

`tests/invocations-gui.py` needs no helper: it writes owned synthetic `.xoi`
files and drives the browser in a private headless Sway. Use a short checkout
or `XODB_TEST_TMPDIR` so the compositor socket path fits. `python3
tests/invocations-gui.py --fixture demo.xoi` only writes its demonstration file.

Set `XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent` for the agent variants.
`scripts/release-check host --uprobes` includes those function suites and
explicitly enables the built helper for the owned fixtures. The release runner
snapshots tracked source, so new files must be added before that snapshot gate.


## Save and reopen associated evidence

For a complete owned capture/save/reopen example:

```sh
python3 tests/observation-associations.py
# The test prints the generated archive path, then deletes its owned target/input.
xodb --open-observation path-from-test/associated.xoi
xodb --open-observation path-from-test/associated.xoi --mcp
```

Use the test's explicit `--helper` option only for a helper already approved on
this host. Set `XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent` to exercise the same
capture through the local C agent. These are headless commands; no hotkeys are
needed. The live example needs the existing CPU/syscall/allocation collector
permissions. Offline reopening needs none of those collection privileges.

In your own MCP investigation, start the observation and selected profile or
allocation collectors while the target is held, run the interesting interval,
then stop all collectors. Wait for completed evidence, call
`associate_observation` with the recorded capture identity, source IDs/revisions
and threshold, and wait for `get_observation_associations` to finish. Only then
call `save_observation` with `generation`, `session_id`, `capture_id` and a fresh
`path`; poll `get_observation_archive` until publication completes. Closing the
target or replacing the original source profile cannot alter the saved snapshot.
Saving while analysis is running returns `ObservationAssociationsBusy`
immediately. After failed or cancelled offline reanalysis, saving retains the
original saved association snapshot and reports `associations_fallback_reason`.
Without an earlier saved snapshot, saving publishes an invocation-only version-1
archive; status reports `associations_saved: false` and
`associations_omitted_reason`. Replacement during save returns
`ObservationArchiveBusy` immediately while the worker pins its completed source.

Views borrow slices from the completed job. Consumers hold IDs and re-look up on
the Session owner thread on each use; never retain slices across capture or job
replacement. A replaced job ID returns `StaleObservationAssociations`. Status
includes `association_algorithm`, `payload_version` (the input archive version;
null for live evidence), `would_save_as` (2, subject to save limits),
`analysis_origin` (live,
restored or reanalysed), per-source counts/loss and `rows_truncated` /
`calls_truncated` with omitted counts. These result-list limits do not truncate
the retained source streams.

On reopening, `get_observation` includes `association_id`. Use it with
`get_observation_associations` to page results. Add `stream_id` (1 CPU, 2 syscalls,
3 allocation) to page retained source records. `start` is an array offset;
`ordinal` is the original source ordinal and can contain gaps where allocation
metadata was excluded. For example, use `stream_id: 3, start: 1, limit: 1` to see
the second retained allocation event, whose original ordinal need not be 1.

For offline reanalysis, call `associate_observation` with the recorded
`session_id`, `capture_id` and a new `threshold_ns` or existing filter fields.
Omit live profile/allocation IDs, revisions and include flags. It uses exactly the
retained streams. Source paging is passive; replacing/cancelling the analysis
retains the existing controller lease classification in a shared session. CLI
output includes `associations` status and `association_result` in addition to the
invocation comparison. `--observation-threshold-ns` changes the invocation
comparison; use MCP to select a different association threshold.

Invocation-only archives retain payload version 1 and omit the new field.
Archives with associated evidence use payload version 2 and
`xodb-temporal-association-v1` inside the unchanged digest envelope. Existing
version-1 archives remain readable; older readers reject the new association
field as `UnknownField`. With the current algorithm, opening replays pairing and
association classification and checks saved results/citations. An unknown
association algorithm keeps invocation and normalized source evidence readable;
status is `unsupported_algorithm`, labels the saved algorithm, and exposes no
current derived result. Explicit offline reanalysis uses the current algorithm.
Identity and clock contradictions are rejected for every algorithm.
It never follows recorded executable/source paths. Source loss diagnostics remain
reported claims about acquisition; absent records are not reconstructed.

Limits remain 64 MiB per file and 256 MiB for decode allocations. A normalized
snapshot has at most three streams and 262,144 aggregate records, with a 64 MiB
owner budget. Live analysis retains its separate 1,048,576-record ceiling and
64 MiB job budget; records too large for that budget return
`ObservationAssociationMemoryLimit`. Saving more than 262,144 source records
returns `ObservationAssociationRecordLimit` without discarding the live result.
The snapshot record ceiling is reachable even with the largest interval records;
independent file and byte limits can still reject large invocation sets. Budget
denials return `ObservationAssociationMemoryLimit`, not `OutOfMemory`, and saving
checks that a snapshot fits its reader's owner budget. Stream and record arrays
are counted before typed decoding; other semantic checks run after bounded
allocation. Allocations are charged before they occur. These
budgets are separate from the invocation capture's configured memory budget;
opening temporarily holds decoded evidence, the new capture, its snapshot and
its analysis job together. Cancellation either leaves a fully published file or
no published file; publication refuses overwrite and does not promise power-loss
durability.
