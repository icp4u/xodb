# ARM64: first headless demo

2026-10-01. The user chose **headless first, GUI next**. The native Linux backend
now runs on Jetty through the same Session and stdio MCP used on x86-64.

## Try it on Jetty

```sh
ssh -t jetty 'cd ~/git/xodb-arm64-demo-20261001-r3 && python3 -B tests/arm64-demo.py --pause'
```

Omit `--pause` for the automated version. The demo launches its own fixture,
stops at `change_value`, shows ARM registers and a four-frame stack, evaluates
`item->value + amount` as `12`, steps the assignment and observes the change
from `7` to `12`. Closing the client kills and reaps the owned fixture.

A machine client can launch the actual MCP endpoint with:

```sh
ssh -T -o ForwardAgent=no jetty 'cd ~/git/xodb-arm64-demo-20261001-r3 && exec ./zig-out/bin/xodb --mcp --agent-scope control -- ./zig-out/bin/xodb-m1-fixture'
```

Use `--attach PID` in place of `-- PROGRAM` to attach. An attached target is
preserved on client shutdown. `observe`, `control` and `mutate` scopes retain
their existing meanings; register/memory writes require `mutate`.
SSH carries stdio to xodb running on Jetty. A workstation GUI connection to a
remote target now works through the [SSH/TCP remote GUI](REMOTE_DEBUGGING.md).

## Build strategy

Jetty is an AArch64 Jetson running Ubuntu 18.04.6, Linux `4.9.337-tegra`, glibc
2.27, libdw/libelf 0.170 and Capstone 3.0.4. No Zig is installed there. The first
xodb build is cross-compiled on the workstation and **executed natively** on
Jetty. The local GCC 7.5 on Jetty also built independent O0/O2 fixtures.

From this workstation:

```sh
./scripts/build-jetty
```

The helper reads Jetty's installed development headers/libraries over SSH,
creates a new local `.work/jetty-build-*` directory and builds with Zig 0.16:
`-Dgui=false -Dtarget=aarch64-linux.4.9-gnu.2.27 -Doptimize=ReleaseSafe`.
It prints the output path and retains the host snapshot, dependency archive,
command and build log. It does not install or deploy anything. Explicit Linux
and glibc target versions avoid assuming Zig's newer target defaults.

On a native ARM64 machine with Zig and the development libraries installed:

```sh
./scripts/build -Dgui=false -Doptimize=ReleaseSafe
./zig-out/bin/xodb --mcp -- ./zig-out/bin/xodb-m1-fixture
python3 -B tests/arm64-native.py
```

`-Dgui=false` removes Wayland, Vulkan, xkbcommon, FreeType, HarfBuzz, protocol
and shader generation from the build. libc, Capstone and libdw/libelf remain.
The normal x86 GUI build remains the default. Jetty's Vulkan runtime is present;
its missing GUI development files and untested compositor/driver path are
separate from this headless result.

## What is covered

| Area | Native evidence / current limit |
| --- | --- |
| Process control | Launch/exec, continue, interrupt, owned multithread cleanup and owned-fixture attach/detach |
| Registers | GETREGSET/SETREGSET; X0–X30, SP, PC, PSTATE; named MCP reads/writes and `$pc` expressions |
| Software breakpoints | Four-byte BRK, exact stop PC, instruction restoration/rearming, unaligned rejection and overlapping memory access |
| Stepping | Instruction step, source step and source step-over |
| Symbols/source/locals | ARM64 ELF, DWARF 4, pointers/structs and basic expressions |
| Unwinding | CFI uses ARM LR column 30, SP 31 and PC 32; separate breakpoint and caller-PC rules |
| Optimized fixture | GCC O2 without frame pointers unwinds; `next=12`; `amount` is explicitly unavailable (`EntryValueUnavailable`), also unavailable in installed GDB |
| Hardware watches | Up to four aligned 1/2/4/8-byte write/read-write watches; MCP investigations and remote GUI controls; native lifecycle/completion tests pass ([semantics/evidence](research/arm64-watchpoints/integration.md)); hardware execution breakpoints remain unsupported |
| Profiling | Explicit `ProfilingUnsupportedArchitecture`; T18 integration and capture ABI work remain |
| Archives | Existing x86 format retained; incompatible ELF assets are rejected even if their content hash matches |
| GUI / remote protocol | Workstation GUI controls native ARM64 over SSH or TCP ([demo](REMOTE_DEBUGGING.md)); GUI rendering on Jetty remains pending |

Jetty's libdw predates `dwarf_get_units`; its adapter uses `dwarf_next_unit` for
DWARF 4 and explicitly rejects newer unit versions. Newer libdw keeps the
existing DWARF 4/5 path. Signal-frame unwinding, PAC/tag handling, SIMD/SVE state,
32-bit compatibility targets and general optimized entry-value reconstruction
are outside this first native slice. Native target and ELF ISA checks prevent
interpreting another machine's register or debug layout as the current target.
The complete Zig suite is verified on x86; ARM validation currently uses the
native MCP harness, not a claim that every x86 fixture/test has been ported.

## Critical assessment and next work

This gets a real debugger demo onto available hardware without waiting for the
old Jetson graphics stack or a native Zig installation. It reuses the production
lifecycle and scope machinery, and the native checks cover actual register,
breakpoint and memory behavior rather than accepting cross-compilation alone.
Keeping x86 archives unchanged avoids claiming an untested ARM capture format.

The evidence is still small C fixtures on one older ARM64 kernel. Jetty's old
libdw and its lack of modern ARM features leave important coverage for the M1
Omarchy machine. The workstation remote GUI is now verified over SSH and TCP.
Claude is handling cross-platform/ARM GUI builds next. Data watchpoints now work
through MCP and the remote GUI. Precise multi-watch attribution, modern ARM
watch validation, corrected sampled register/stack collection, an explicit ARM archive
ABI and modern compiler/optimized-language coverage remain independent follow-ups. T19's delivered GUI expression
panel is queued for its separate review.

[Logs, source/binary hashes and native checks](research/arm64-demo/README.md).
