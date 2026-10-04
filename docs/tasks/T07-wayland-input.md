# T07: keyboard input and cursor integration prototype

Status: ready for Claude after T04. Codex owns the active UI and Wayland adapter.

## Goal and owned files

Address T05's raw-keycode, dropped-event, repeat and cursor findings with a
small adapter and a tested integration patch. Preserve the current application
controls; this task does not add a command palette or text editor.
Own only:

- `src/platform/input.zig` (new input adapter)
- `tests/repros/input/`
- `docs/research/input.md`
- `docs/research/input/` (integration patches and small retained captures)

Do not directly modify `src/platform/wayland.zig`, `src/c.zig`, `src/main.zig`,
`src/ui/`, shared build files, or T04 files from this task. Read their current
versions and record hashes for any patch. Back up every existing owned file.

## Deliverables

- A Zig 0.16 input adapter using installed libxkbcommon in the standalone test
  harness. Consume the compositor keymap/modifier state; close received keymap
  FDs and release mapped storage, keymaps and xkb state on all paths.
- A bounded ordered event queue. Keep physical key identity, translated keysym,
  Unicode text and modifiers distinct. Preserve several key events in one
  dispatch; explicitly count/report queue overflow. Include press/release.
- Compositor repeat settings and monotonic repeat scheduling. Cancel repeat on
  release, keyboard leave, keymap replacement and seat removal. Avoid burst
  floods after long pauses. Propose which commands may repeat: execution,
  detach, watch, scope and quit must not repeat automatically.
- Document a policy for logical letter shortcuts versus function keys and
  physical bindings. Distinguish Ctrl/Alt shortcuts from text, allow composing
  characters, and test a second installed layout. A policy that changes current
  shortcut behavior needs coordinator/user review before adoption.
- A proposed patch to connect the queue to existing workspace actions without
  losing clicks or keys. Keep application/session control on the owning thread.
- A proposed cursor-shape integration for ordinary and divider-hover cursors,
  with clean registry/seat/pointer teardown. Use installed protocol definitions;
  state behavior when the compositor does not advertise that protocol.
- List exact build/dependency changes for integration. The standalone prototype
  may link installed libxkbcommon; adding it to the application remains a
  coordinator decision. Do not install packages or change system input settings.

## Acceptance

Pure tests should cover ordered multi-event delivery, modifiers, non-US text,
composition, queue capacity, repeat cancellation and deterministic timer inputs.
Use private headless Sway plus test-only virtual keyboard/pointer input for the
integration prototype. Never inject events into the interactive session.

Demonstrate that Space/F5/F6, F10/F11, F8, W, Tab, J/K, D and Q remain operable;
show that holding an execution key does not repeatedly resume/stop the target.
Verify seat removal/keymap replacement frees resources and resets modifiers.
Capture failures as well as successes; do not report cursor appearance as
visually verified if the test compositor hides it.

Use a scratch copy and separate compiler caches for any proposed shared-file
patch.  The current UI styling has been integrated and render-failure recovery
changed `main.zig`; work from a fresh snapshot rather than T05's old one.

## Handoff

Return adapter API, exact commands/results, integration patch, upstream API
references/provenance, dependency/license notes, and remaining limitations.
Record where an LLM could help analyze input traces or GUI captures, keeping
physical/logical/text events and injected test actions distinguishable.
