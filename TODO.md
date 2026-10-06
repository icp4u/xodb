## xodb - a modern graphical debugger for native linux. The hugs and kisses debugger.

guiding principles:
- graphical, fast, flashy
- a debugger but also an IDA, profiler, etc
- AI native design, MCP interfaces built for agent control and analysis
- linux native in all ways, capture all the wins we can get with tight kernel integration. We can use linux-only extensions and kernel module components are on the table
- We can be portable where it makes sense and we DEFINITELY want to be portable to non-x86 architectures
- Leverage AI for pattern and protocol analysis
- align with omarchy design styles and vibes
- eventual goal: remote debugging with a particular eye toward android but also serial/net to any linux host
- future feature: Lua scriptability with debugger bindings such as `dbg.eval()`, configurable behavior and limits, and possible MCP access

see linux-ai-debugger-agents.md for an ai summary of a discussion fleshing out this concept

## Future tasks

- [x] Initial startup themes: semantic colors, presets and explicit loading ([workflow](docs/THEMES.md)).
- [ ] Live watch expressions that re-evaluate in the selected frame at every stop (like gdb `display`), next to today's pinned investigation watches.
- [ ] Clipboard in text fields: Ctrl+V and middle-click (primary selection) paste, then copy.
- [ ] Skinnable, flexible display: fonts/scaling, control treatments, pane arrangement and saved layouts.
- [x] Initial AArch64 hardware data watchpoints, write investigations and remote GUI controls ([evidence/limits](docs/research/arm64-watchpoints/integration.md)).
- [ ] AArch64 feature coverage: precise multi-watch attribution, modern ARM validation, profiling, native GUI and remaining debugger gaps.
- [ ] Investigate debugging additional architectures and the hardware/emulation needed to validate them.
- [ ] Mixed-language logical stacks: processes hosting several interpreters (PL/Perl and PL/Python in one server, embedded Perl and Ruby, Perl multiplicity, Python sub-interpreters, Ruby ractors). Show each runtime's logical segment anchored to its native interpreter-loop frame from the same stop, so interleaving comes from evidence rather than timestamps; extend the logical-frame format with a runtime instance and a native↔logical bridge record.
- [ ] Nice-to-have: some macOS functionality (Apple silicon). Likely order: open saved archives/profiles and drive a remote Linux target from a macOS GUI (Cocoa window, Vulkan via MoltenVK); then debug macOS processes through Apple's `debugserver`, which speaks the GDB remote protocol below, rather than a native Mach/ptrace backend (code signing, entitlements and SIP apply).
- [ ] Serial and kernel debugging on much more varied targets: speak the GDB remote serial protocol as a client (gdbserver, QEMU/emulator stubs, kgdb over serial or network, OpenOCD/JTAG probes, bare-metal and RTOS stubs). Treat a stub as another target backend beside ptrace and the C agent, with honest capability discovery (qSupported, target.xml register descriptions, no-ack, non-stop) and explicit gaps where a stub cannot provide what ptrace does.
- [ ] Periodic agent reassessment of unmet wants: what useful workflows are missing from both the implementation and the plan?

Scope and review cadence: [future work](docs/MILESTONES.md#future-display-and-architecture-work).
