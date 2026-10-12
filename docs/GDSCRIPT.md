# GDScript stacks and values in a Godot 4 or Redot game

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

Selecting a level also lists its **named locals**: parameters and local
variables, then `self` and the members of its script, each with a preview of
its value. [Values](#values) below has the walkthrough.

xodb attaches to a game that was started normally. It does not use the
engine's remote debugger, runs no code in the game and writes nothing to it,
so it also works on a game that hangs in a script loop.

## Values

Run `REDOT=/path/to/engine scripts/demo-redot values`. This game has a player
with an inventory, a target and a child node; every frame runs
`_process` → `act` → `swing` → `take_hit`, which sleeps in `OS.delay_msec()`.
Press **Space**, choose the **GDScript** tab, and click **swing**. **NAMED
LOCALS** then shows the level you clicked (scroll the list for the rest):

```
weapon = Dictionary(3) {"damage": 12, "tags": Array(2) ["sharp", "steel"], "reach": 1.5}
parameter
power = 3.0
parameter
damage = 12
local
tags = Array(2) ["sharp", "steel"]
local
aim = (6.5, -9.0)
local
self = Player:<Node2D#28823257355> /root/Arena/Player (res://player.gd)
context
title = "Aria"
member
hp = 90
member
...
inventory = Dictionary(4) {"sword": Dictionary(3) {"damage": 12, "tags": Array(2), "reach": 1.5}, "potions": Array(3) [3, 5, 8], "gold": 250, 7: "lucky"}
member
hand = Hand:<Node2D#28840034572> /root/Arena/Player/Hand
member
target = Dummy:<Node2D#28856811789> /root/Arena/Dummy (res://dummy.gd)
member
```

Press **E**, type a path and press **Return** to read one value:

| Type | Shows |
| --- | --- |
| `inventory["sword"].damage` | `12` |
| `inventory.potions[-1]` | `8` (a negative index counts from the end) |
| `target.armor` | `3`, a member of another object's script |
| `velocity.x` | `3.25` |
| `hand` | `Hand:<Node2D#...> /root/Arena/Player/Hand` |

Click **_process** for one value of every Variant type (the members of the
`Arena` node). In a second terminal `scripts/demo-redot locals` prints every
level as text, and `scripts/demo-redot locals 1` one level:

```
#1 swing  res://player.gd:36
    parameter weapon = Dictionary(3) {"damage": 12, "tags": Array(2) ["sharp", "steel"], "reach": 1.5}
                  "damage": 12
                  "tags": Array(2) ["sharp", "steel"]
                  "reach": 1.5
    parameter power = 3.0
    local     damage = 12
    ...
    member    hp = 90
```

Agents use `get_language_locals` (`language` `gdscript`, the `segment` and
`frame` of a level from `get_language_stack`, `start` and `limit` to page) and
`evaluate_language_expression` with the same paths. Each row has the name, its
`scope` (`parameter`, `local`, `context` for `self`, `member`), and a `value`
with `type`, `display`, `count`, and the first `children` (key, type, display)
of a container or of an object's script. `slot_address` is where the Variant
is stored in the game, and `address` an object's own address.

### What a value looks like

| Variant type | Example |
| --- | --- |
| `Nil`, `bool`, `int`, `float` | `null`, `true`, `-42`, `2.5`, `3.0` |
| `String`, `StringName`, `NodePath` | `"héllo wörld"`, `&"beta_name"`, `^"/root/Arena/Player:position:x"` |
| `Vector2`, `Vector2i`, `Vector3`, `Vector3i`, `Vector4`, `Vector4i` | `(3.25, -4.5)`, `(7, -9)`, `(1.0, 2.0, 0.5)` |
| `Rect2`, `Rect2i`, `Plane`, `Quaternion`, `Color` | `[P: (1.0, 2.0), S: (30.0, 40.0)]`, `[N: (0.0, 1.0, 0.0), D: 2.5]`, `(0, 0, 0, 1)`, `(1.0, 0.5, 0.25, 1.0)` |
| `Transform2D`, `AABB`, `Basis`, `Transform3D`, `Projection` | `[X: (1.0, 0.0), Y: (0.0, 1.0), O: (5.0, 6.0)]`, as the engine prints them |
| `Array` | `Array(7) [4, 1.5, "alpha", (3.25, -4.5), Array(2) [1, Array(1)], Dictionary(1) {"a": 1}, null]` |
| `Dictionary` | `Dictionary(4) {"k_int": 4, "k_str": "alpha", 7: 2.5, &"k_name": (1, 2)}`, in insertion order |
| `PackedByteArray` ... `PackedVector4Array` | `PackedInt32Array(3) [10, 20, -30]` |
| `Object` | `Player:<Node2D#28823257355> /root/Arena/Player (res://player.gd)`: node name, class, instance id, path in the scene tree, script. `<RefCounted#-9223372009>`, `<null>`, `<Freed Object#...>` |
| `Callable`, `Signal`, `RID` | `Callable(noted on #28806480138)`, `Callable(custom)`, `Signal(tree_exiting on #28806480138)`, `RID(77)` |

A container's line shows its size and its first eight elements; a container
inside it shows its first four, and one inside that only its size. A row
carries the first 12 children (an expression's result 32); an index or key
reaches any element (`v_big[57]`). Strings are cut at 96 characters with `…`,
and `count` then has the full length.

### Paths

An expression is a name, then up to eight steps. The name is a parameter or
local of the level (the innermost declaration wins), `self`, or a member.

| Step | On | Means |
| --- | --- | --- |
| `[2]`, `[-1]` | `Array`, packed arrays | Element by index |
| `["key"]`, `.key` | `Dictionary` | The pair whose key is that `String` or `StringName` |
| `[7]` | `Dictionary` | The pair whose key is that `int` (or the equal `float`) |
| `.member`, `["member"]` | `Object` with a GDScript | A member of its script instance |
| `.x .y .z .w`, `.r .g .b .a`, `.position .size` | vectors, `Quaternion`, `Color`, `Rect2` | One component |

Nothing is evaluated: there are no operators, calls, properties of engine
classes (`position`, `name`) or getters. A step that finds nothing answers
with no rows and a reason: `GDScriptNameNotFound`, `GDScriptKeyNotFound`,
`GDScriptIndexOutOfRange`, `GDScriptMemberNotFound`,
`GDScriptObjectHasNoScript`, `GDScriptObjectNull`, `GDScriptObjectFreed`,
`GDScriptPathNotContainer`, `GDScriptPathNeedsIndex`,
`GDScriptPathNotIndexable`. Text that is not a path is refused
(`GDScriptExpressionUnsupported`). A dictionary is searched pair by pair, up
to 262,144 pairs (`GDScriptDictionaryScanLimit`).

### Local names

The engine records the names of local variables only when it was told to:
with the project setting `debug/settings/gdscript/always_track_local_variables`
(the demo project sets it), or when its own debugger was attached while the
script was compiled. Otherwise the view says `GDScriptLocalNamesNotTracked`
and still shows every value: parameters keep their names (they are also in the
function's signature), other slots that hold something are listed as
`stack[6]`, `stack[7]` (locals and the engine's temporaries; it does not keep
which), and `self` and the members are unaffected.

### How values are read

- **The level's stack.** A call record points at the function's array of
  Variants: slot 0 is `self`, the arguments start at slot 3, locals and
  temporaries follow. Names come from the function's debug records, replayed
  up to the current line by the engine's own rule.
- **Members.** The script instance holds a vector of Variants; the script's
  member table maps each name to its index (base classes first).
- **Layouts.** As for the stack, every offset and size comes from the binary's
  DWARF: `Variant` and its `Type` enumerators, `Variant::ObjData`,
  `ArrayPrivate`, `DictionaryPrivate`, the hash map element types, the debug
  record list, `PropertyInfo`, `Object`, `Node`, `NodePath`, a packed-array
  holder, `Callable` and `Signal`. A type this build does not have, or that
  two units define differently, turns off only what needs it, with a reason
  (`GDScriptArrayLayoutUnavailable`, `GDScriptDictionaryLayoutUnavailable`,
  `GDScriptPackedArrayLayoutUnavailable`, `GDScriptObjectLayoutUnavailable`,
  `GDScriptMemberLayoutUnavailable`, `GDScriptNodePathLayoutUnavailable`);
  without `Variant` itself there are no values
  (`GDScriptValueLayoutUnavailable`). The stack does not depend on any of them.
- **Objects.** A Variant remembers an object's id and address. The object is
  described only if it still carries that id (`GDScriptObjectFreed`
  otherwise). Its class and whether it is a `Node` come from the C++ type
  information its vtable points at; its script instance is trusted only when
  its vtable is `GDScriptInstance`'s.
- **Bounds.** One page of locals makes at most 16,384 reads and one expression
  1,048,576 (`GDScriptReadLimit`); a level's first 1,024 stack slots and 2,048
  members are read (`GDScriptMemberLimit` says when there are more); element counts come from the containers' own headers and
  are checked before use.

Measured on the demo with a 1.4 GB `template_debug` engine: a page of locals
costs 17 to 26 ms and 340 to 530 reads (about 8 to 12 KB); an expression 2 to
4 ms. The first request after a stop also reads the stack (about 75 ms).

## What is needed

| Need | Why | Otherwise |
| --- | --- | --- |
| A debug-enabled engine: an editor build or a `template_debug` export template | Only these keep the script call stack | `GDScriptCallStackNotTracked` |
| DWARF in that engine binary (`debug_symbols=yes` when building it) | Every offset is read from the binary's own type descriptions | `GDScriptDwarfUnavailable` |
| Its symbol table | The engine is recognised by `GDScriptLanguage::singleton` and the thread-local `GDScriptLanguage::_call_stack` | No GDScript tab; `GDScriptRuntimeUnavailable` |
| Room for the image: `--image-limit` and `--image-total-limit` | An engine with DWARF is about 1 to 1.5 GB; the defaults are 1 GiB an image and 4 GiB in all | `GDScriptImageBudgetExceeded`, with the values to rerun with ([large images](LARGE_IMAGES.md)) |
| x86-64 Linux, the engine as the main executable | The call stack is found through the thread pointer and the executable's static thread-local block | `GDScriptArchitectureUnsupported`, `GDScriptRuntimeUnavailable` |

`scripts/demo-redot` works the two image options out from the engine's size.
By hand:

```
xodb --image-limit 1600M --image-total-limit 4G --attach PID
```

Reading a 1.4 GB engine costs about that much memory in xodb once, and about
a second for the first stack: the image is copied, and its type descriptions
are searched for the stack's eight types and the value reader's twenty. Later
stops reuse both.

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

## Engine scene tree and object inspector

`REDOT=/path/to/engine scripts/demo-redot scene` starts an owned game with
the engine debugger enabled. Press **U** for the scene tree and inspector.
Click a node (or use arrows) to see its script and properties, including
engine properties such as a Node2D's `position`. **Tab** changes keyboard
focus, the wheel scrolls either pane, **P** shows properties, **S** shows
Signal-valued properties, **R** refreshes, and **U** or **Esc** closes.

The header says **ENGINE DEBUGGER PROTOCOL / cooperative**: these are retained
snapshots reported by the running engine. This view needs a responsive debug
engine, but no DWARF. Pausing the native target leaves its last snapshot
visible; requests stay pending until it runs again. The memory-based script
stack and values described above remain available independently.

For an existing project, launch xodb with:

```sh
xodb --redot-debugger -- /path/to/engine --path /path/to/project
```

xodb supplies `--remote-debug` with a loopback ephemeral port, accepts one
peer, and checks its announced PID against the owned launch. Do not supply a
second `--remote-debug` option. The engine protocol has no authentication;
the PID check is a consistency check, not protection against another local
process impersonating the engine. Only scene and inspection requests are
sent; no property setters, evaluation or method-call commands are exposed.
The engine itself handles inspection, which can invoke a project's property
getters. Arbitrary attach, remote-agent sessions, and automatic reconnect or
restart are not supported yet; restart this xodb launch to reconnect.

The launch starts stopped like any other: **Continue** it, and the tree fills
in once the game is running. Helper programs the engine starts on the way
(Redot runs `xdg-user-dir`) are released on their own. The `scene` demo does
the Continue for you and leaves unexpected signals or breakpoints stopped for
inspection. Packed arrays show their length and first eight elements, and a
property preview is cut at about 500 bytes.

MCP observers can use `get_redot_scene_tree` (`start`, `limit`, `refresh`) and
`inspect_redot_object` (`object_id`, `refresh`). Poll a pending answer until
the engine responds. IDs are decimal strings to preserve all 64 bits. Each
answer names its source and revision. Property values are bounded previews,
not expandable memory paths. Selection is shared between observers; an
answer is returned only for the requested object ID.

The tested Redot 26.2 / Godot 4.5 protocol does not enumerate declared signals
or connections. The signals pane shows only properties whose value is a
Signal (for example the demo Arena's `v_signal = tree_exiting`), and states
that limitation. Signal connection graphs remain future work.

## Limits

- **Debug-enabled builds only.** A release export template does not track
  script calls unless the project sets
  `debug/settings/gdscript/always_track_call_stacks`, and has no DWARF unless
  it was built with it.
- **Memory values are read, not evaluated.** No expressions with operators or calls,
  no properties of engine classes (a node's `position` is not a script member)
  and no writes. Local names need the engine to have recorded them
  ([above](#local-names)).
- **Engines built with double precision** (`precision=double`) have a larger
  Variant; values are refused there (`GDScriptValueLayoutUnavailable`) by the
  size check alone. No such build was tried.
- **A freed object** is recognised by its id no longer being in its memory.
  The engine's own object table is not consulted.
- **Language watches** (**W**) do not cover GDScript yet; a hardware
  watchpoint on a row's `slot_address` plus 8 does (`set_watchpoint`).
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
