# Function observations and saved investigations

xodb can record individual native function calls, retain their raw argument and
return register words, and compare fast and slow calls. Linux x86-64 SysV is the
initial supported ABI. The C runtime collects both local and C-agent events;
the host pairs and analyzes the retained evidence.

The first interface is the headless CLI and MCP. There is no function-observation
GUI panel or new keyboard shortcut yet. Existing **P** CPU sampling and `.xoc`
profile comparisons continue to work independently.

## One-command capture

From the checkout, after `./scripts/build -Doptimize=ReleaseSafe`:

```sh
xodb --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper" \
  --observe-recipe examples/observation.recipe.json \
  --observation-out example-01.xoi \
  -- "$PWD/zig-out/bin/xodb-observation-fixture"

xodb --open-observation example-01.xoi
xodb --open-observation example-01.xoi --observation-threshold-ns 1000000
```

Use a new output filename each time. The commands print JSON containing capture
status, cohort counts, duration distributions and raw-record citations.
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
Twenty complete calls are expected, and the 4 ms split should separate the
small and large sorts on this host. In a threaded Perl the first argument word
is the interpreter pointer (`my_perl`), not a Perl value. Captured native stacks
are not Perl logical frames.

`scripts/demo-perl` is the interactive counterpart of the Ruby and CPython
demos. It attaches to a loop that stores `42` at index 3 and breaks on
`Perl_av_store`. With DWARF, the frame's expressions `key` and
`val->sv_u.svu_iv` show **3** and **42**; `av` and `val` are the raw `AV *` and
`SV *` arguments.

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
causality. Source loss and excluded metadata are reported separately. These joins
currently require ended live-session sources; `.xoi` does not bundle the separate
CPU/allocation streams or association result.

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
```

Set `XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent` for the agent variants.
`scripts/release-check host --uprobes` includes those function suites and
explicitly enables the built helper for the owned fixtures. The release runner
snapshots tracked source, so new files must be added before that snapshot gate.
