# Short demo walkthroughs

## Emacs: Lisp and C at the same stop

Run `./scripts/demo-emacs` with a supported debug Emacs 31.1. Press **Space**,
select **Elisp**, then **xodb-demo-checkpoint**: its label is `"item"`.
Select the nearby **let** and scroll the bindings pane to find title
`"Profile delta"` and points `2`. The next **Space** shows `"Cache budget"`
and `3`; the next reaches `"render"`, with total `5` and dynamic stage
`"render"`. One more reaches the handled `"error"` case. The C argument link
lets you inspect the native caller beside those Lisp frames.

The demo transforms JSON into an Org-style outline using `cl-defun`, a lexical
lambda and `condition-case`. **Space** continues; **Shift+Q** quits. See the
[Emacs walkthrough](ELISP.md#try-the-demo) for executable overrides and current
limits, or the [Guide's demo table](GUIDE.md#try-it) for other runtimes.

## Redot / Godot: script state of a running game

```sh
REDOT=path/to/redot.linuxbsd.template_debug.x86_64 scripts/demo-redot values
```

The engine must be a debug-enabled build with DWARF. The launcher starts a
small headless game (a player, a target, an inventory) and attaches to it.

1. **Space** stops in the script's `OS.delay_msec()`; **Tab** to **GDScript**.
   The tab lists `take_hit` ← `swing` ← `act` ← `_process` with `res://`
   path:line, each over its native `GDScriptFunction::call` frame.
2. Click **swing**. **NAMED LOCALS** shows `weapon = Dictionary(3) {"damage":
   12, "tags": Array(2) ["sharp", "steel"], "reach": 1.5}`, `power = 3.0`,
   `damage = 12`, `tags`, `aim = (6.5, -9.0)`, then `self` and the player's
   members: `inventory`, `velocity`, `hand` (a child node, with its scene-tree
   path) and `target` (another scripted node).
3. **E**, `inventory["sword"].damage`, **Return**: `12`. Try `target.armor`,
   `velocity.x`, `inventory.potions[-1]`.
4. Click **_process**: the `Arena` node's members are one value of every
   Variant type, shown as the engine itself prints them.
5. In a second terminal, `scripts/demo-redot locals` prints all four levels as
   text, and `scripts/demo-redot stack` the script stack with the labelled
   native stack.

Nothing runs in the game and nothing is written to it; the game was started
without the engine's debugger. See [GDScript](GDSCRIPT.md#values) for value
formats, paths, what local names need, and limits.

## Memory: defrag to Gibson

Start `xodb --overview --look win95` for the classic desktop. Select an owned
process on **Processes**, then press **m** to see its memory map. **t** cycles
Win95, DOS, modern, deep and Gibson looks.

For the neon memory city, run:

```sh
xodb --overview --panel memory_map --look gibson --memmap-pid PID
```

The camera slowly orbits and dollies through the sampled VMAs. **WASD** moves,
drag or arrow keys orbit, and the wheel zooms. **F** toggles the flythrough;
**R** resets it. Hold movement, arrow or zoom keys for smooth motion; keys
combine, and focus loss stops movement immediately. Automatic orbit pauses
after five idle seconds and resumes on the next interaction. Click a tower to read its block details. **H** switches height
between present, THP-backed and swapped bytes; **C** switches backing and
district colours. **G** opens the encoding legend; **O** chooses a process.
Use `--redact` to hide process names, paths and floating district labels.

Cyan towers contain measured THP backing, magenta means known small pages,
amber file backing and red swap. Wire cages mark unmeasured heights. A
measured zero is a flat footprint; a partial height counts only observed
bytes. Tower movement and collapse flashes follow page samples. The replay
mode uses the same observations and can demonstrate these transitions without
collecting a live process.
