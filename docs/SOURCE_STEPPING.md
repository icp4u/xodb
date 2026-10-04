# Source stepping

F11 / MCP `step_source` enters calls. F10 / `step_over` steps over them.
Source stepping stops when the source file or line changes, or another stop
requires attention. Breakpoints, watchpoints and signals remain visible.

On Linux x86-64, a target with one live thread can batch straight-line
instructions on the current source line. The planner examines at most 256 bytes
and 64 decoded instructions per resume. It places a temporary breakpoint before
a control-flow instruction, a different/unknown source line, or the end of the
bounded block. Calls, branches, traps, syscalls and existing probes remain
boundaries. Failure to plan or place a breakpoint uses instruction stepping.

Targets with multiple live threads, shared address spaces or another native
architecture keep the instruction path. Batching does not resume otherwise
stopped peer threads. Blocks can still be interrupted by hardware watchpoints,
signals and user breakpoints; temporary probes are cleaned up by the existing
stop/cancellation path.

The 10,000-resume safeguard remains (`SourceStepResumeLimit`). This now counts
bounded block resumes as well as instruction steps. Long straight-line source
lines can exceed 10,000 instructions without exhausting it. Loops and branches
can still reach the safeguard; this is not a full control-flow range-stepper.

`get_session` reports `source_step_resumes` and
`source_step_planned_instructions` for the most recent source-step operation.
The latter counts instructions covered by planned batches, not a retired
instruction count: an intervening stop may interrupt a planned block.

`tests/source-blocks.py --baseline PATH` checks an owned 1,024-NOP line against
an earlier binary, a 12,000-NOP line, a user breakpoint inside a block, a hardware
watchpoint, an explicit trap and the multithread fallback. On the development
host the short line fell from 2.31 seconds to 45 milliseconds (17 resumes); the
long line completed in 0.46 seconds (191 resumes). These are headless fixture
measurements, not general stepping-speed guarantees. Existing source-call,
C++ value, stripped-debug and restart tests also pass.
