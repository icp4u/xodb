# GDScript stacks in a Godot 4 or Redot game

Run `REDOT=/path/to/engine scripts/demo-redot`, press **Space** to stop in
the game's next `OS.delay_msec()` call, then choose the **GDScript** tab. It
lists the script call stack of the selected thread, innermost first, each
row with its script as a project path and the current line:

```
Script stack: 4 levels
complete
leaf  [native #1]
res://worker.gd:16
step  [native #5]
res://worker.gd:12
plan  [native #9]
res://main.gd:20
_process  [native #13]
res://main.gd:16
```

Each script level is paired with the engine's native frame that is running
it (`native #5` is frame 5 of the C/C++ stack, a `GDScriptFunction::call`).
Selecting a level selects that native frame, and selecting such a native
frame offers its level; the selection is shared with MCP
(`select_language_frame`, `select_native_frame`). A long script path is shown
by its end (`...mies/boss.gd:120`) so that the line number stays visible; MCP
always has the whole path.

In another terminal `scripts/demo-redot stack` prints the same as text, and
the native stack with each call frame labelled:

```
GDScript on thread 20838: 4 levels, complete
  leaf      res://worker.gd:16   <- native #1 GDScriptFunction::call
  step      res://worker.gd:12   <- native #5 GDScriptFunction::call
  plan      res://main.gd:20   <- native #9 GDScriptFunction::call
  _process  res://main.gd:16   <- native #13 GDScriptFunction::call
Native stack, with the script level each GDScriptFunction::call frame is running:
  #0  CoreBind::OS::delay_msec
  #1  GDScriptFunction::call   <= leaf res://worker.gd:16
  #2  GDScriptInstance::callp
  ...
```

Agents ask `get_language_stack` with `language` `gdscript`. Each frame has
`name`, `file`, `line`, the address of its call record, the script instance
and its object id, and `native_binding` (the native frame's index, pc and
symbol).

xodb attaches to a game that was started normally. It does not use the
engine's remote debugger, runs no code in the game and writes nothing to it,
so it also works on a game that hangs in a script loop.

## What is needed

| Need | Why | Otherwise |
| --- | --- | --- |
| A debug-enabled engine: an editor build or a `template_debug` export template | Only these keep the script call stack | `GDScriptCallStackNotTracked` |
| DWARF in that engine binary (`debug_symbols=yes` when building it) | Every offset is read from the binary's own type descriptions | `GDScriptDwarfUnavailable` |
| Its symbol table | The engine is recognised by `GDScriptLanguage::singleton` and the thread-local `GDScriptLanguage::_call_stack` | No GDScript tab; `GDScriptRuntimeUnavailable` |
| Room for the image: `--image-limit` and `--image-total-limit` | An engine with DWARF is about 1 to 1.5 GB; the defaults are 256 MiB an image | `GDScriptImageBudgetExceeded`, with the values to rerun with ([large images](LARGE_IMAGES.md)) |
| x86-64 Linux, the engine as the main executable | The call stack is found through the thread pointer and the executable's static thread-local block | `GDScriptArchitectureUnsupported`, `GDScriptRuntimeUnavailable` |

`scripts/demo-redot` works the two image options out from the engine's size.
By hand:

```
xodb --image-limit 1600M --image-total-limit 4G --attach PID
```

Reading a 1.4 GB engine costs about that much memory in xodb once, and about
a second for the first stack: the image is copied, and its type descriptions
are searched for eight types. Later stops reuse both.

## How it is read

The engine keeps, per thread, a linked list of call records
(`GDScriptLanguage::CallLevel`), one for each script function that is
running. Each record is a local variable of the native function that runs
that script function (`GDScriptFunction::call`), so it lies in that native
frame's part of the stack. The list head and its length are thread-local
variables of the engine executable.

1. **The engine** is the main executable, by the kernel's record of its
   program headers. Its build ID in memory must equal the file's.
2. **Layouts** come from the binary's DWARF, by type name, from every
   compilation unit: `GDScriptLanguage::CallLevel`, `GDScriptFunction`,
   `GDScript`, `GDScriptInstance`, `GDScriptLanguage`, `StringName::_Data`,
   `StringName`, `String`. Every unit that defines a type must agree. Nothing
   comes from a version table: editor and template builds of one engine
   version place these members differently.
3. **The list head** of a thread is at its thread pointer (`fs_base`, now
   listed by `get_registers` with `gs_base`) minus the executable's
   thread-local block, plus the variable's offset in it.
4. **The walk** follows `prev` from the head. It reads at most one record more
   than the engine's own count and limit allow (1,025 at most), and stops at a
   record that is outside the thread's stack, misaligned, or not above the one
   before it.
5. **Each level** gives the function's name, its script (the function's
   `source`, which is what the engine's own `get_stack()` reports), and the
   current line, which is a local of the same native frame.
6. **The pairing** puts each record in the native frame whose stack range
   holds it. That frame must be `GDScriptFunction::call`, and deeper levels
   must be in outer frames.

A segment is `complete` only when all of this holds: the list ends, its
length equals the engine's count, and, when the whole native stack was
unwound, the number of native `GDScriptFunction::call` frames equals the
number of levels. Otherwise it is `partial` with a reason, and the frames
that were proved are still shown:

| Reason | Meaning |
| --- | --- |
| `GDScriptCallStackSizeMismatch`, `GDScriptCallStackSizeInvalid` | The list and the engine's count disagree |
| `GDScriptCallLevelOutsideStack`, `GDScriptCallLevelOrder`, `GDScriptCallLevelUnreadable` | A record is not where a live record can be |
| `GDScriptNativeFrameCountMismatch`, `GDScriptNativeFrameNotFound`, `GDScriptNativeJoinInconsistent` | Levels and native frames do not pair one to one |
| `GDScriptFunctionInvalid`, `GDScriptStringInvalid`, `GDScriptStringUnreadable`, `GDScriptLineUnavailable`, `GDScriptLineOutsideFrame` | One level's name, script or line could not be proved; the others are unaffected |

Two moments are expected and are not errors. The engine links a record just
before it fills and counts it, and counts it out just before unlinking it: a
stop in between shows one more record than the count. That level is marked
`GDScriptCallLevelInTransition` (`top_in_transition`), and the stack stays
`complete`. And a stop in the first or last instructions of
`GDScriptFunction::call` has a native frame with no record yet
(`native_call_frame_without_level`).

A thread that runs no script has an empty list: `in_script` is false and the
tab says "Not in script code".

Strings are read with the same care. An engine `String` is a pointer to
UTF-32 text with its length stored before it. The length must be plausible
and must lead to the terminator, and every element must be a Unicode code
point, or the string is refused rather than shown. At most 1,024 characters
are kept; control characters are shown as `?`.

## Limits

- **Debug-enabled builds only.** A release export template does not track
  script calls unless the project sets
  `debug/settings/gdscript/always_track_call_stacks`, and has no DWARF unless
  it was built with it.
- **Stack only.** Local variables, members and values are not shown yet. When
  they are, local *names* will need the engine to have recorded them: it does
  so only with `debug/settings/gdscript/always_track_local_variables`, or when
  its own debugger was attached while the script was compiled.
- **Suspended coroutines are not shown.** A function waiting in `await` is not
  on the thread's list until it resumes.
- **A script stack overflow** leaves native frames without records; the
  segment is `partial` (`GDScriptNativeFrameCountMismatch`).
- **Up to 64 levels are listed** (`truncated` says when there are more), and
  the native stack is unwound for 64 frames: deeper levels are listed without
  a native frame.
- **C# scripts and GDExtension code** appear as native frames only.
- **Engine version.** Proved on Redot 26.2 (Godot 4.5) editor and
  `template_debug` builds made with GCC. Other 4.x engines work when they keep
  the call stack the same way; one that does not is refused with
  `GDScriptLayoutUnsupported`, never read with guessed offsets. The engine's
  version number is not read: the tab shows the build ID.
- **Live processes only.** A core file is refused
  (`GDScriptModuleIdentityUnavailable`).
- **Remote targets** (the runtime agent) keep the fixed 256 MiB bound for
  whole-file transfers, so an engine with DWARF is refused there.

Runtime-agent sessions retain the fixed 256 MiB image-transfer limit, even
when `--image-limit` is larger. An engine above that limit reports
`GDScriptImageBudgetExceeded`; its unavailable tab cannot be selected. The
large-engine stack and frame-pairing oracle runs natively; the agent GUI
oracle checks this refusal and unchanged target state.
