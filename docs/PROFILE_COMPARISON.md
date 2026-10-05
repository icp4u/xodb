# CPU archive comparison

For individual function arguments, return words and fast/slow call durations,
see [function observations](OBSERVATIONS.md). Its headless recipe runner produces
`.xoi` invocation investigations; the `.xoc` workflow below compares CPU samples.

## Capture before and after

An `.xoc` is a native xodb capture archive. `--capture-out FILE` chooses where
to save it **when xodb closes**; it does not start sampling. Other documentation
uses `.xcap` for the same format. `--profile-out` produces Speedscope JSON,
which this comparison workflow does not accept.

These examples use local Linux x86-64 CPU sampling.

```sh
xodb --capture-out before.xoc --break main -- ./my-program arg1 arg2
```

In the GUI:

1. Press **Space** to run to `main` (or choose another workload-entry symbol
   with `--break`). This lets the initial libraries load before sampling.
2. Press **P** to start CPU sampling and open the flame view. The program
   stays stopped.
3. Press **Space** to run the program. Exercise the workload you want to measure.
4. While collection is running, press **P** to stop sampling. The program keeps
   running. If the program exited or the capture stopped automatically, skip
   this step: pressing **P** then would attempt a new capture.
5. Press **Q** to close xodb and wait for it to return to the terminal.
   `before.xoc` is now saved. Closing xodb ends a program it launched.

Rebuild or change the workload, then repeat the same steps with a new filename:

```sh
xodb --capture-out after.xoc --break main -- ./my-program arg1 arg2
```

Keep the executable at the same path between builds so recorded module paths
can match. Use comparable workload phases and sampling settings. Defaults are
99 Hz and a 60-second capture deadline, including time paused; see
[capture settings](PREFERENCES.md). A new capture replaces the previous one in
that session, and shutdown saves the latest one. Choose unused output filenames:
existing files are never overwritten.

To capture an already running process instead:

```sh
xodb --capture-out before.xoc --attach PID
```

Attach pauses the process: start at step 2 (**P**, **Space**, workload, **P**
while collecting, **Q**). Closing xodb detaches and preserves an attached
process. If sampling cannot start, check the status line and
[tracing permissions](../SETUP.md).

### Short intervals and repeated breakpoints

CPU sampling needs time executing on a CPU. A short run from one breakpoint
hit to the next can yield zero samples at the default 99 Hz, even though the
debugger spent much longer handling the stops. Prefer a one-time workload checkpoint.

Alternatively, disable that breakpoint after reaching the intended phase:
return to the source workspace with **F** if viewing flames, press **B**, select
the breakpoint, press **Space** to disable it, then **Esc** to close the manager.
With no capture running, use **P**, **Space**, a few seconds of work, **P**,
**Q**. If a capture is already collecting, just resume with **Space**. Skip the
stop-collection **P** if collection has already stopped automatically.

## Open and compare

You can inspect either saved capture on its own:

```sh
xodb --open-capture before.xoc
```

Or open the before/after pair:

```sh
xodb --compare-capture before.xoc --open-capture after.xoc
```

The comparison opens first. **F** toggles function rankings and differential
flames, **V** switches between comparison and the ordinary after-capture view,
and **Backspace** resets flame zoom. Click a flame to zoom; arrows, J/K and the
wheel scroll. **Esc** cancels unfinished comparison work and closes the view.

Rankings sort by absolute self-share change. Before/after percentages use each
capture's included sample count; the delta is in percentage points. Inclusive
function counts count a recursive function only once per ancestry path. Raw
counts, loss, partial stacks and unverified samples remain available. A change
in sample share does not establish an elapsed-time regression or speedup.

Flame color encodes the inclusive share change. Width is the sum of the larger
before/after share for each leaf path, quantized to one part in a billion. Thus
width is a comparison layout weight, not an elapsed-time unit. Thread roots are
aggregated rather than matching unrelated TIDs between runs.

Matching uses the exact recorded module path and symbol name when that name
identifies one observed symbol per module in each run. Address changes due to
ASLR do not change that match. Multiple homonymous observed symbols, truncated
names and unresolved leaf PCs remain separate. A match is a name-based
comparison, not a claim of binary or source equivalence. Moved modules with
different recorded paths do not match automatically. When both archive hashes
are identical, recorded frame identities also match unresolved PCs, so comparing
an archive with itself yields zero changes even for unknown sample leaves.

Unknown caller ancestry is grouped under **[unresolved callers grouped]** in the
flames, allowing known descendants to align without asserting that unresolved
PCs denote the same function. The flat rows retain their separate unknown PCs.
The existing partial-stack markers remain visible. These paths describe the
recorded subset of ancestry.

This first version compares whole native CPU archives using recorded labels.
It does not read old target memory, open source/ELF assets, or alter the primary
capture's filters. Different event types, empty captures, graph-cap overflow
and malformed archives fail explicitly. Imported profiles, allocation archives,
reanalysis and independent selected-range filters are not supported yet.

The cancellable comparison worker has a 128 MiB graph/analysis allocation
budget and at most 16,384 output nodes. Input archives are limited to 256 MiB
and decoded one at a time with the archive codec's 512 MiB budget. These bounds
are additional to the ordinary after-capture view's resources.

MCP `get_profile_comparison` is read-only. Poll `pending`, then page with
`view: "functions"` or `"flames"`, `start` and `limit` (1–256). The response
includes both archive hashes, raw counters, share deltas and explicit matching
and width semantics. Opening the pair is an explicit startup action.

Validation: normalization at unequal sample counts, recursive inclusive counts,
ASLR/TID changes, ambiguous names, unresolved ancestry, cancellation and
allocation failures have deterministic tests. `tests/comparison.py --gui`
captures two owned workloads with deliberately exchanged hot functions, removes
the executable, and checks the production archive/GUI/MCP path. The observed
shift was about 90 percentage points; comparing an archive with itself returned
zero deltas. 
