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
- [ ] Skinnable, flexible display: fonts/scaling, control treatments, pane arrangement and saved layouts.
- [x] Initial AArch64 hardware data watchpoints, write investigations and remote GUI controls ([evidence/limits](docs/research/arm64-watchpoints/integration.md)).
- [ ] AArch64 feature coverage: precise multi-watch attribution, modern ARM validation, profiling, native GUI and remaining debugger gaps.
- [ ] Investigate debugging additional architectures and the hardware/emulation needed to validate them.
- [ ] Serial and kernel debugging on much more varied targets: speak the GDB remote serial protocol as a client (gdbserver, QEMU/emulator stubs, kgdb over serial or network, OpenOCD/JTAG probes, bare-metal and RTOS stubs). Treat a stub as another target backend beside ptrace and the C agent, with honest capability discovery (qSupported, target.xml register descriptions, no-ack, non-stop) and explicit gaps where a stub cannot provide what ptrace does.
- [ ] Periodic agent reassessment of unmet wants: what useful workflows are missing from both the implementation and the plan?

Scope and review cadence: [future work](docs/MILESTONES.md#future-display-and-architecture-work).
