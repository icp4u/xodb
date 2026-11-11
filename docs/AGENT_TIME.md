# Agent work-log flames

`xodb --agent-time` is a read-only window for local agent transcripts. It never
attaches a debugger, runs a recorded command, reads credential files, or contacts
a provider. Python 3 (standard library only) is required to import transcripts;
the adapter is embedded in the executable. Saved work-log archives need no
Python interpreter.

```
xodb --agent-time
xodb --agent-time --agent-kind codex --agent-log session.jsonl
xodb --agent-time --agent-kind claude --agent-log session.jsonl --redact
xodb --agent-time --agent-kind grok --agent-log events.jsonl
```

Use **W** to switch between elapsed activity and token burn, click a frame to
select it, **Z** or Enter to focus, Backspace to go out, **X** to reset, and **/**
to search. Search captures text until Enter or Escape; **Q** quits outside it.
The graph uses the same weighted call tree as CPU profiles. **L** switches to
the chronological chart; **B** returns to the session browser.

With no file argument, the browser discovers Codex sessions under
`$CODEX_HOME/sessions` (default `~/.codex/sessions`), Claude sessions under
`~/.claude/projects`, and Grok sessions under `~/.grok/sessions`. Newest file
activity comes first. Initial title/project/date reads are bounded; exact
duration, tokens and turns populate asynchronously, one session at a time.
`?` means not indexed or unavailable, never zero. Enter opens the selected row;
Up/Down selects, **A** cycles agents, **P** edits the project filter, **D** edits
an inclusive UTC date range (`2026-01-01..2026-12-31`), and **/** searches titles
and projects. A single date means "since"; **X** clears filters. Enter/Escape
ends text editing, so typed shortcut letters do not trigger commands.

The browser keeps a private numeric index under
`$XDG_CACHE_HOME/xodb/agent-time/index-v1` (default `~/.cache/xodb/...`). Warm
entries supply duration, tokens and turns without reparsing the transcript or
building flames. Titles and projects are read from bounded source chunks,
not stored in the cache. Cache keys hash source paths; entries contain only
numeric totals and a source fingerprint that includes a hash of the adapter
source, so any adapter change invalidates old entries. Each entry is
private (0600), at most 4 KiB, and the cache retains at most 10,000 entries.
It never writes to agent directories.

Source identity, size and nanosecond timestamps invalidate entries; Claude
child/meta files and Grok history/usage sidecars participate too. A source that
changes during indexing remains usable but is not cached. Corrupt/version-old
entries are misses; cache write failures show **cache unavailable** without
preventing session inspection. The header reports cache hits for this launch.

Merged coordinates represent aggregate weight, not chronology. In the time
chart, x is recorded elapsed time and overlapping activities occupy separate
rows. Token usage appears at its recorded timestamp: marker height is log
token count, not generation time. Select a marker for its exact count; **Z**
focuses the selected interval (or a narrow window around a token marker), and
Backspace resets the time extent. Scroll to reach child-session rows.

## Fleet, tasks, cache and live updates

In the browser, **F** combines up to the 32 newest sessions matching the agent,
project and search filters. **D** supplies the UTC window; unlike individual
browser rows (filtered by start date), fleet selection includes sessions whose
activity overlaps it, including children continuing after the parent stopped.
Intervals are clipped to the window and token events charged only when their
recorded time lies inside it. The upper date includes that whole day. Missing
timestamps cannot be placed more accurately than the adapter's recorded turn
fallback. Unindexed sessions are considered conservatively, then checked on
the worker; narrow the filters if the newest-32 cap excludes older matches.
Session roots occupy separate lanes, never invented parent/child links.
The title reports sessions without usage; omitted/failed imports are counted.

In a flame view, **P** toggles inferred task-packet grouping. A turn's first
packet-shaped label with a digit (for example `A33-M1` or `KG2`) in its filtered
prompt is the grouping key, else the first digit-free one (`KG-HANG`); technical
tokens (`UTF-8`, `X11`, `F8`, `ARM64`) and all-caps phrases (`READ-ONLY`) are not
labels. A turn naming two packets is grouped under the first; no inbox is read. This is a heuristic, not an authoritative
task tracker. Missing labels stay **unlabelled**. Grok prompts are associated
through exact history/event tool-call IDs; tool-free turns are not guessed.
Task work excludes user/resume waiting; task tokens retain their recorded turn.
Tasks sit above agents, so the same packet label combines work across providers.
**L** returns to the session chronology; **P** returns to task flames.

**C** enables token weights and overlays cache-read share. The green bar portion
(or timeline marker color) is cached input divided by fresh input + cached input
+ cache write. Output and reasoning are excluded from that denominator. Selected
frames show the exact numerator and denominator; zero input is shown as 0/0,
not a measured cache hit rate. This is input-token reuse, not money saved.

**T** toggles live tailing for a single transcript (not archives or fleets).
Starting live releases the previous view before loading the first live snapshot,
avoiding two large views in memory at once. An explicit loading view replaces
the graph during startup; weight/layout/search choices survive. If startup fails,
the error is shown and polling retries. **T** off before the first live view
arrives cancels/reaps the helper and reloads the log offline; **B** and **Q**
cancel without starting that reload.
An owned helper checks source/sidecar fingerprints about two seconds after each
completed refresh; unchanged files are not parsed. While live mode is enabled,
it retains normalized decoder checkpoints in memory and consumes only appended
complete JSONL records. Pending tool calls and usage accumulators survive refresh;
a partial final line waits for its newline. Codex, Claude (including child logs),
and Grok events/history use this path. Grok's replaceable `usage.json` snapshot
is still reread within its 64 MiB limit. No transcript checkpoint is written to disk.

New child files preserve existing decoder checkpoints and only their new bytes
are parsed. Unchanged sibling documents are referenced in the wire update, even
when a new child sorts before them. Removal, rotation, truncation or same-size
edits rebuild the checkpoint. Appends check bounded prefix/tail guards; edits confined to the
middle of an old prefix while also appending are outside the append-log contract.
At the normal span/token/turn ceilings or 150,000 retained decoder keys across
the selected tree, the helper drops its checkpoints and falls back to full
imports until live mode is restarted. Snapshots remain bounded to 64 MiB and
each native request has a 120-second deadline. The first/rebuilt snapshot is sent
in full; subsequent appends send generation-checked row splices and changed child
metadata. Unchanged native rows and child sessions are shared immutably between
views, without retaining a chain of old snapshot arenas. The helper keeps row
fingerprints, not the full previous encoded reply. A malformed or out-of-sequence
update restarts the helper on the next poll. After live startup completes, the
last complete live view stays visible during
refresh or failure, with live status in the header. Replacement preserves flame
selection/focus by identity, falling back to the deepest surviving ancestor in
the root-most 32 levels. The chronological chart keeps its absolute zoom interval;
**Backspace** or **X** returns to the full range. A missing chart selection falls
back to the first span. Weight/layout/search choices survive. **B** pauses polling;
**T** off and **Q** cancel and reap the worker. No clock-based activity is
invented between records. Flame projection still processes the complete normalized
snapshot; checkpoint-limit fallback can also make refresh expensive;
leave live mode off when inspecting historical data. Browser discovery remains
a snapshot; reopen the window to discover new sessions.

With `--log=profile=debug` (or `XODB_LOG=profile=debug`), the log gets bounded
JSON `agent-time view` records after input and snapshot publication: layout,
selected/zoomed frame labels and time range, so tests can check focus retention
without OCR. Labels can be turn titles (prompt text) and command summaries, so
they are off at the default level, and with `--redact` each label is a stable
hash instead of text. No transcript body or full command is logged.

## What the weights mean

Tool time is the interval from recorded call to result. Grok's explicit
`duration_ms` is used when present. Parallel calls overlap: their sum is
agent-time, not elapsed wall time. Gaps within a turn are labelled **model
(inferred)** and include transport, orchestration and unrecorded work, not just
generation. Gaps between finished turns and subsequent prompts are **waiting
for user**. Open turns end at the last recorded timestamp, not the current
clock; unfinished calls are counted and excluded from exact tool totals.
Claude's completed `SubagentHandback` ends work even without an `end_turn`.
A subsequent metadata resume starts a new turn; the intervening interval is
**waiting for resume**, excluded from agent-seconds. This follows explicit
records, not a long-gap threshold: an hours-long active tool remains work.
Waiting spans retain their boundary record IDs for reconciliation.

Token frames distinguish fresh input, cached input, cache write, output and
reasoning. Cached input is a subset of Codex input, and reasoning is a subset
of output; neither is added twice. Codex cumulative usage is differenced;
duplicate usage telemetry is not charged again. Claude streamed message
records are deduplicated by message id, and the cache-creation breakdown is
not charged on top of cache-creation total. Grok usage comes from the session's
`usage.json` (per-turn model-call totals, same subset rules as Codex). A log
without recorded usage shows **unavailable**, not zero; context-window
occupancy is not token burn.

Claude child transcripts next to the parent are read and associated with the
recorded child id or `.meta.json` tool-use id. Metadata parent-agent ids place
nested workers under their actual parent; descriptive worker names are shown.
Forked workers replay their spawner's history under the same message and tool
ids; each id is charged once, to the earlier transcript (counted as copied).
When metadata explicitly marks a fork and identifies its parent call, copied
model/wait intervals before that call are clipped too. Raw session extents and
unique usage/tool records remain intact; the removed prefix duration is counted.
A child without an explicit association goes under
**unlinked subagent**, never a guessed tool. Agent-time and token flames include
children; parent wall duration does not grow merely because tools overlap.

## Labels, privacy and saved views

Shell commands are tokenized, never evaluated. Setup prefixes and common
wrappers are stripped; build/test/gate subcommands survive. Pipelines and
chains select the principal operation. Inline scripts get a line count and
an inferred purpose, not their bodies. Labels are deterministic and limited
to 60 characters, grouped below a command-class frame. Selecting a command
shows its longer safe summary. Known credential arguments are suppressed even without
`--redact`; labels are summaries, not a safe way to publish arbitrary prompts.
With `--redact`, displayed and exported strings pass through xodb's shared
redaction policy. Review exports before publishing.

```
xodb --agent-time --agent-kind codex --agent-log session.jsonl \
  --redact --agent-time-out work.agent-time.json
xodb --agent-time --agent-kind archive --agent-log work.agent-time.json
```

Exports contain normalized labels, spans, usage and diagnostics, not transcript
bodies or tool results. The destination must be new; an existing file is never
overwritten. Archives retain both weights, so reopening can switch between them.

## Coverage and limits

Imports stream one JSON line at a time on a worker. Limits are 16 MiB per line,
20,000 turns, 150,000 activity spans and 150,000 usage rows shared across the
parent and children (shared across fleet roots too), 256 child files per root,
and 64 MiB of normalized helper output.
Counts show malformed syntax, unknown records, unfinished calls and omitted
data. Flame nodes are bounded by the existing 8,192-node graph; excluded weight
is displayed separately. The chart caps each weight at 300,000 marks and
parallel activity at 64 lanes per session; draw-limit omissions are explicit.
Discovery caps the catalog at 10,000 sessions. Limits are ceilings, not up-front allocations.

Model-price tables are not implemented. Formats drift; unknown
records remain visible in diagnostics rather than being treated as understood.

## Independent accounting check

`src/profile/agent_time_oracle.py` reads raw records without importing the
adapter. It independently checks per-file logged tokens, paired tool IDs and
intervals, Claude resume-boundary IDs, and raw session extent. It reads only the
named log and known Grok usage/history sidecars, prints aggregate results (no
paths/prompts/commands/IDs), and exits nonzero on mismatch or unreadable input.

```
python3 src/profile/agent_time.py --agent codex --file session.jsonl > normalized.json
python3 src/profile/agent_time_oracle.py --agent codex --file session.jsonl --normalized normalized.json
```

Use `claude` or `grok` for the other formats; omit `--normalized` for raw totals.
It compares **own** totals, not the subagent-tree rollup. Check child transcripts
individually; cross-file fork ownership and inferred model durations are outside
this oracle. Imports that reached normalization limits are not declared equal.
The registered synthetic corpus includes deliberately wrong totals and IDs that
must fail, so agreement is not just conservation inside one implementation.

## Live equivalence check

`tests/agent-time-equivalence.py` drives the real `--live` helper and applies
its frames through the app's own delta state (compiled from
`src/profile/agent_time_replay.zig`, test-only). After every applied frame the
document must equal a full reparse of the complete lines it has consumed, with
every counter kept: Codex/Claude/Grok growth, partial lines (split UTF-8 too),
malformed and oversize lines, streamed usage, new, inserted, nested and forked
children, truncation, rotation and child removal. Lost, duplicated and stale
frames must be rejected, and the published document read back unchanged. `--mirror SESSION.jsonl` runs the same check
against a private copy of a live Claude session, appending only the bytes it gains.
