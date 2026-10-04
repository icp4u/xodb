# T12: Android and remote Linux debugging boundary

Status: native-executable device research started by Codex (2026-10-02); broader
protocol research remains unassigned. [Pixel probe and next steps](../ANDROID_NATIVE_PLAN.md). The [first Linux SSH/TCP remote GUI](../REMOTE_DEBUGGING.md)
is now integrated; use it as the implementation baseline. Android, serial,
interoperability and reconnect research remain open.

## Goal and ownership

Prepare an evidence-backed design for the user's eventual Android-first remote
debugging goal, plus serial/network connections to any Linux host. This task does
not authorize installing a daemon, opening a listener on the workstation network,
accessing an Android device, or selecting a new production protocol.

Own only:

- `docs/research/remote-debugging.md`
- `docs/research/remote-debugging/`
- `tests/repros/remote-protocol/`

Read TODO.md, linux-ai-debugger-agents.md, MILESTONES.md, target/model/MCP boundaries
and existing generation/scope contracts. Keep production and shared docs unchanged.

## Deliverables

- Compare an xodb-owned target service, GDB Remote Serial Protocol interoperability,
  and LLDB-related building blocks using current primary documentation and license
  provenance. Explain what can be reused versus adapted; no commercial purchases.
- Android deployment/access matrix: app debuggability, same-user/root restrictions,
  SELinux, ptrace/perf availability, NDK debug information, AArch64 registers/CFI,
  software/hardware breakpoints, module identity and source transfer. Distinguish
  documented requirements from facts verified on a device. Do not claim device
  validation when no device was authorized/provided.
- Serial/net transport framing, negotiated architecture/features, message limits,
  backpressure, authentication, interruptions, disconnect/reconnect and stale stop
  identity. The host must not assume x86 registers or local target addresses.
- A proposed minimal loopback-only/fake-transport prototype for tests, with bounded
  message decoding and deliberate partial/out-of-order/disconnect cases. No real
  target service integration is needed for this research packet.
- A small ordered implementation plan and explicit questions that genuinely need
  user decisions. Include concrete alternatives, costs and uncertainty rather than
  asking for approval before preparing the design.

Follow normal backups and repo-local artifacts. No system/network configuration,
package installs or external remote writes. Use bugme before host resource work;
all automatic graphics remain private. Record where external local/remote LLMs
could help investigation while keeping target control and scope enforcement in
xodb's deterministic model.
