# Dependencies

xodb uses installed system libraries and generates Wayland bindings at build time.
The UI adapts RAD Debugger rectangle shading and visual conventions; its MIT
notice is retained in [licenses/RAD-Debugger-MIT.txt](licenses/RAD-Debugger-MIT.txt).
No LLVM implementation code is included.
The project license has not yet been selected.

Preserve applicable notices if dependencies or
protocol-generated files are bundled for distribution.

| Component | Package license label | Use |
| --- | --- | --- |
| Wayland | MIT | Native window and input |
| wayland-protocols | MIT | Generated xdg-shell, cursor-shape and tablet interface bindings |
| libxkbcommon |  MIT | Compositor keymap, logical keys, modifiers and compose |
| Vulkan headers |  Apache-2.0 OR MIT | Vulkan API declarations |
| Vulkan loader | Apache-2.0 | Driver dispatch |
| FreeType | FTL OR GPL-2.0-or-later | Glyph rasterization |
| HarfBuzz | MIT | Text shaping |
| elfutils libdw/libelf | Headers: LGPL-3.0-or-later OR GPL-2.0-or-later | M1 DWARF and CFI decoding; dynamically linked |
| Capstone | BSD-3-Clause | x86-64/AArch64 instruction decoding |
| DejaVu fonts | custom | Default installed font; not bundled |
| wlr-protocols | MIT | Private pointer protocol used only by GUI tests |

Build tools: Zig, `pkg-config`, `wayland-scanner`, `glslc`, and a C compiler.
The executable also uses the system C runtime for Linux process and event APIs.
GUI tests additionally use Python 3, Sway, `swaymsg`, and `grim`.

Implementation references:

- [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
  and the installed Zig standard library for build and process APIs.
- [Linux ptrace manual](https://man7.org/linux/man-pages/man2/ptrace.2.html)
  for seized tracees, interrupt, clone events, and lifecycle behavior.
- [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
  and [tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
  for framing, inspection tools, and structured results.
- [Vulkan swapchain semaphore reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
  for presentation synchronization. Render-finished semaphores belong to
  swapchain images; vertex/atlas writes wait for the preceding submission fence.

## M1 decoder decision and provenance

The user approved libdw for M1 on 2026-09-30 after T01/T02 completed.
`pkg-config libdw` supplies `-ldw -lelf`. Installed headers
`/usr/include/elfutils/libdw.h` and `/usr/include/libelf.h` state the dual license
recorded above; this row records those header notices rather than substituting
the distribution's broader elfutils package label.

`src/debug/info.zig` is an original adapter using those installed APIs. It opens
libdw on the same mapped bytes owned by the T01/session module, keeps runtime
load bias explicit, and uses the xodb location evaluator for target reads.
No libdwfl module/session ownership or remote debug-file service is used.
`.eh_frame` is preferred, with `.debug_frame` as a fallback. No third-party
implementation was copied. T01's provenance is in [research/elf.md](research/elf.md);
T02's comparison and normalized contract are in [research/dwarf.md](research/dwarf.md).

M1 tests additionally require GCC/G++, Clang/Clang++, LLD, binutils,
`llvm-objcopy`, `llvm-readelf`, `llvm-dwarfdump`, and GDB. These are test oracles
and fixture builders, not runtime debugger backends.

## T05 visual integration

The user approved Claude's visual patch on 2026-09-30. Rectangle shading in
`src/render/ui.frag` and the semantic colors/widget conventions in
`src/ui/style.zig` adapt RAD Debugger. Attribution is in
the source; the upstream Epic Games Tools copyright and MIT notice are retained
in `docs/licenses/RAD-Debugger-MIT.txt`. See
[Claude's review](research/ui-review.md) for exact upstream paths and measured
tradeoffs. This adds no runtime dependency.


## T07 input integration

The user reviewed the T07 policy and deferred both shortcut fallbacks. The
application dynamically links installed libxkbcommon; input follows only the
active layout. `wayland-scanner` generates cursor-shape bindings from
`staging/cursor-shape/cursor-shape-v1.xml` and the referenced tablet interfaces
from `stable/tablet/tablet-v2.xml`. These are existing wayland-protocols build
inputs; no package was installed. The source API references and original test
provenance are in [research/input.md](research/input.md).

The integrated private-display runner also uses the test-only virtual keyboard
protocol installed with wayland-debug-cli-git, plus ImageMagick for capture
comparisons. Neither is a runtime application dependency. The exact protocol
path remains workstation-specific in `tests/helpers/input.py`.

## T06 CPU sampling integration

Sampling uses installed Linux perf UAPI headers and syscalls; no library, daemon,
package, sysctl or paid tool was added. Grok's collector/decoder provenance and
Linux-syscall-note references are in [research/perf-collector.md](research/perf-collector.md).
The shared capture, call tree and native flame view are original xodb code.
ELF/libdw and Capstone supply the existing symbol/source/assembly services.


## Portable profiling export

The exporter is original Zig code implementing the published
[Speedscope format](https://github.com/jlfwong/speedscope/wiki/Importing-from-custom-sources).
No Speedscope implementation is linked or copied. No runtime dependency was added.
The optional schema check used `jsonschema==4.25.1` (MIT) in an isolated 
virtual environment. Its dependencies and cache stay inside the workdir; nothing
was installed into system Python. Schema validation is optional for the live
regression script and is not part of the application build.


## Basic language value views

The Rust/Zig adapters are original code over installed libdw. No layout or
visualizer implementation was copied. The optional language fixture tests use
installed rustc and Zig (LLVM/native backends); these add no runtime
dependency. Tests preserve unsupported optimized locations.

## Jetty headless build (2026-10-01)

The native ARM64 demo dynamically links Jetty's installed Capstone 3.0.4 and
elfutils libdw/libelf 0.170, using glibc 2.27. No dependency package or system
configuration was changed. `scripts/build-jetty` copies headers and shared
objects into an ignored local build directory for cross-linking; no third-party
implementation is vendored in the repository. The older libdw iterator path
supports the demo's DWARF 4 and reports newer unit versions as unsupported.
`-Dgui=false` omits the GUI libraries and generated graphics inputs entirely.
See [ARM64 evidence and limits](ARM64.md).


## Android headless build (2026-10-02)

`scripts/build-android` uses the installed NDK and checksum-pinned upstream
elfutils 0.193 / Capstone 5.0.6 source archives. These libraries are linked
statically; Bionic and zlib remain Android system dependencies. The build keeps
source archives, modified and original files, objects, manifests and upstream
license notices together under `.work/`. Its libdw subset excludes libdwfl and
command-line tools; optional non-zlib compression is disabled. No AOSP/Termux
implementation is copied. [Build details and redistribution boundary](research/android-native-build.md).

## APK mappings and explicit debug companions

The user adopted this workflow on 2026-10-02. `src/binary/apk.zig` is an original
bounded ZIP32 metadata reader using PKWARE field definitions; it adds no library
or decompressor. `src/binary/debug_files.zig` pairs explicit GNU-build-ID-matched
ELFs with the existing libdw adapter. Runtime CFI remains tied to the actual
mapped ELF. [Usage](DEBUG_SYMBOLS.md) and [provenance](research/android-symbols.md).
