# KGDB remote

## Kernel target panel and MCP

With `--vmlinux` and a KGDB, vmcore or live kcore target, **F7** opens a read-only
overlay. It is closed by default and leaves the existing layout unchanged.
**1–4** or **Tab** selects Tasks, CPUs, Modules or Waits; arrows, Page Up/Down
and the wheel scroll. **Esc** or **F7** closes it. The frame thread renders a
copied owner publication; it never walks target memory. Closing the panel stops
requesting inventory rows. F8's existing emergency agent-scope control remains
available; other debugger hotkeys do not leak through the open overlay.

MCP `get_kernel_target` reads the same model, with `section`, `start`, `limit`
(1–128, default 32), optional stopped `generation`, and `process_id`.
The result has `rows`, `total`, `next`, `generation`, `reason`, `truncated` and
`limits`. Carry the generation and next index when paging; `StaleSnapshot`
means start again. Ordinary targets refuse `KernelTargetRequired`. Running
kernels return empty rows with `TargetRunning`. No new attach, control or host
procfs access is implied. `get_kernel_stacks` is the separate host census. A task row's `tid` is the debugger thread for that task: a core's published thread, or on a live stub the thread whose id is the pid; it is null when the debugger has no thread for the task (for example an idle swapper). In the `--connect` remote GUI, F7 remains Instruction step; this overlay uses F7 only in the main workspace.

| Section | Rows |
| --- | --- |
| `tasks` | Kernel PID, debugger TID (zero if not mapped), name, raw state bits or null, CPU or null, task address as hex |
| `cpus` | CPU indices supported by a task's CPU assignment or a matched current task; current address (null if unavailable), resolved PID/name where known. Uninitialized possible-CPU slots are omitted. Online/offline state is not established. |
| `modules` | Loaded kernel images and separate `load_failure` entries with reason/detail, including `KernelModuleUnverified`; an unverified loaded object appears in both |
| `waits` | Waiting PID/name, up to four `hops`, and `end` (`complete`, `truncated` or `cycle`); each hop preserves lock address/kind, owner, CPU, reader and unknown-owner flags |

The bounded view retains at most 4096 tasks, 4096 CPU slots, 576 module rows and
256 waiting tasks. The underlying task/module reader can report its own limit
or missing-layout reason. Null state/CPU and unknown owners remain unknown.
Names and module paths obey `--redact`. `atomic_snapshot: false` is conservative
for every target: live `/proc/kcore` is changing memory, not a coherent stop;
even a paused kernel's view is a bounded inventory rather than a completeness
claim. The x86_64 [lab demo](DEMOS.md#kernel-target-and-two-hop-waits) covers
KGDB, ELF guest dumps and live kcore without accessing the host kernel.

## Target transport and kernel awareness

`--gdb-remote` accepts three endpoint forms.

- `tcp:HOST:PORT` and the older `HOST:PORT` form. Brackets still mark an IPv6 host.
- `unix:ABS_PATH` is a stream socket. The path is absolute.
- `serial:ABS_PATH[,BAUD][,break]` is a raw 8N1 line. The baud is one of 9600, 19200, 38400, 57600, 115200, and 230400. 460800 and 921600 are accepted when the host defines them. The default is 115200. `break` sends a line break and then the byte `g` before the handshake.

A stub that does not offer `qXfer:features:read+` is treated as a kernel stub. The `g` packet length selects a built-in register layout:

- 156 bytes: x86-64 (`rax` through `rip`, then `eflags`, `cs`, `ss`, `ds`, `es`)
- 788 bytes: aarch64 (`x0` through `x30`, `sp`, `pc`, `cpsr`, then the vector bank)
- 548 bytes: loongarch64 (`r0` through `r31`, `orig_a0`, `pc`, `badv`, then the floating-point bank)

Any other length is refused. The client does not guess.

Threads are tasks plus per-CPU shadow ids. The wire id is kept for packets. A negative shadow id is shown locally as a distinct positive id so snapshots can name it. A name is read with `qThreadExtraInfo` when a view asks for that thread. Every stop lists threads again (a few packets), so a task that started or exited, such as a module kthread after a reload, is current.

Continue sends `Hc0` and then `c`. Step sends `Hc` of the stopped CPU and then `s`. Stepping another CPU is refused. The client never sends a kill packet. Detach sends `D` and resumes the kernel.

kgdboc ignores the `0x03` interrupt byte while the kernel runs. On a `serial:` tty, interrupt sends a line break and then `g` (SysRq-G). On `unix:` and `tcp:` endpoints interrupt is refused with `UnsupportedControl`; enter the debugger from the target instead (`echo g > /proc/sysrq-trigger`, or the lab's `kl-console RUN_DIR send kgdb`). Closing xodb or detaching while such a kernel runs cannot remove xodb's breakpoints. xodb prints a warning, and the next hit stops the kernel with no debugger attached. Enter the debugger and detach to remove them. SysRq-G over a real serial line is untested end to end.

Real kgdb differs from gdbserver. The client keeps those differences in one quirks table, filled when the stub offers no target description:

- the thread list ends with an empty reply, not `l`;
- task names are the 16-byte `comm`, padded with NUL bytes;
- on x86-64 a breakpoint stop reports the address after `int3`, and the client rewinds the PC onto the breakpoint;
- reads stay at 511 bytes per packet;
- a thread list longer than the client's table is capped, later tasks are not shown, and the connection stays up;
- a failed link still attempts one detach packet so the kernel is not left stopped.

The session snapshot's `gdb_remote` object has `kernel` set for this stub.

`--core FILE` with `--vmlinux FILE` opens a kdump vmcore, or an ELF guest dump whose load segments already name guest virtual addresses, through this same kernel view. Each kdump crash note becomes one CPU thread, using the same local per-CPU id as a live stub, because idle notes repeat pid 0. A guest dump that has no VMCOREINFO note keeps the note pids. VMCOREINFO supplies the page-table root and whether the guest is using five-level paging. A virtual address that misses every load segment is translated with that page table, including large pages, and read from the segment that owns the physical page. A kdump file's load segments cover kernel text and the direct map, so module memory and vmalloc stacks take the walk. A guest dump that already includes those ranges reads them from the load segments. The slide is still measured from `linux_banner`. There is no output-size limit and no stub. QEMU's paged `dump-guest-memory` writes 8 in `e_ehsize`; that field is ignored, as readelf and GDB do. x86-64 and arm64 cores open; the task walk adds sleeping tasks beyond the crash-note CPUs. An arm64 QEMU paging dump (`dump-guest-memory -p`) records physical addresses and no VMCOREINFO note. Its kernel image is found by the banner and the image's own `kimage_voffset`, which gives the slide; the kernel's VMCOREINFO page with a matching `KERNELOFFSET` then supplies the page tables. Its CPU notes are named by position, and a CPU's current task is that note's thread. `tests/kernel-target-lab.py --arm64 --core` checks this. ORC module frames use the module's table, and report `KernelModuleOrcUnavailable` when it is unavailable rather than following a stale frame pointer.

Launch, attach, restart, follow, process files, and libraries are refused. Software breakpoints use `Z0`. Write and access hardware watches use `Z2` and `Z4`. An empty reply from the stub is a refusal. Execute watches are refused by this client.

`--vmlinux FILE` with `--gdb-remote` loads that fixed ELF, its symbols, and its ORC tables, and measures the KASLR slide. The slide is zero when `linux_banner` is at its link address. Otherwise each stopped program counter nominates image offsets on the machine's alignment step, and the offset whose `linux_banner` matches is the slide. x86-64 and aarch64 use a 2 MiB step. Other machines use 64 KiB. Two matches are refused. A missing `linux_banner` is refused. A GNU build id is checked at the slid address. `--exe` stays a fixed-address image and does not measure a slide. A VMCOREINFO `KERNELOFFSET` nominates a slide the same way when it is a multiple of that step and `linux_banner` matches at the slid address.

`--modules DIR` names a directory of kernel objects. The client walks the kernel module list and loads each live object's text when the file name and, when the kernel publishes one, the build id match. A missing object, a differing build id, or symbols that disagree with the kernel's own table is a note, and that object is not loaded. A refused object is listed by `list_modules` under `load_failures` as `kernel/NAME.ko` with `KernelModuleSymbolsDiffer` or `KernelModuleSymbolTableUnreadable`. A kernel that publishes no module symbol table loads the object as `KernelModuleUnverified`, with that detail, rather than refusing it or passing it silently. AArch64 mapping symbols (`$x`, `$d`) are not compared. DWARF supplies struct offsets. BTF is used only when DWARF is absent. A sleeping x86 task whose program counter is zero is unwound from its saved thread state. An arm64 kernel return is stripped with the PAC mask published by the image. A kernel-looking pointer without that mask stops the walk. The arm64 and loongarch64 images are ET_DYN at a fixed kernel address and are accepted. A kernel that relocates by copying (LoongArch) leaves its loaded image at the link address; a slid banner match wins over it. Per-CPU symbols use the stopped task's CPU, or a supplied cpu when the symbol is per-CPU. Task labels show `pid`, `state` and `cpu` (from `thread_info.cpu`). The module list is read once per stop. Task names are read when a label or a stack asks for them.

A loaded module's allocatable sections are placed the way the kernel lays them out, so a module data symbol has a runtime address. Module code on an ORC kernel, including LoongArch, unwinds from the module's ORC table; a missing or terminal entry stops the walk. On a frame-pointer kernel the walk uses the frame pointer, and a stop at the first instruction of a function keeps the caller. Task names are read when a label or a stack asks for them. Hardware watches are accepted by x86 kgdb in the KVM lab but did not fire, for stock GDB either. In a core, a CPU thread is named after that CPU's current task: `current_task` where the kernel has it, otherwise the only running task on that CPU; a guest dump without VMCOREINFO names its notes by position. A CPU's current task is not published a second time as a sleeping task. A stub that offers a target description still uses this kernel view when `--vmlinux` is set. Its own threads stay the CPU threads: each is named for the CPU whose per-CPU base matches `gs_base`, or whose kernel stack contains that thread's stack pointer. A task that is not current on one of those CPUs is shown beside them and unwound from saved thread state. Continue and step still address the stub's own threads. An idle task that is absent from the task list is read from the per-CPU current pointer and names that CPU's thread. An image with no per-CPU current_task symbol uses the runqueue's current task pointer instead.

QEMU's own gdbstub (`qemu-system-* -gdb unix:PATH,server=on,wait=off`, or `-s`) is such a stub. It stops every vCPU, including one spinning with interrupts off, so a hang needs no NMI or KGDB entry:

```sh
xodb --gdb-remote unix:PATH --vmlinux vmlinux --modules DIR
```

The vCPU threads carry the task labels and wait chains; the KASLR slide is measured from the target. In `get_kernel_target`, a task's `tid` is its debugger thread: the CPU thread for a CPU's current task, the published thread for a sleeping task, or null. Continue, step, and register reads on a task thread are refused with `KernelTaskNotCpu` ("kernel task is not a CPU thread"). Task threads are rebuilt at each stop; leaving a stop drops them without thread-exit events. Without `--vmlinux` the stub shows only its vCPU threads, as before. `tests/kernel-target-lab.py --gdbstub` (and `--gdbstub --gui`) checks this against the lab.

An aarch64 vmcore opens through the same view, with 34 general registers from its crash note. The page walk follows the note's address size, including a 52-bit kernel whose top index is four bits. The PAC mask from the note is applied to arm64 return addresses. A core walks the task list once. Each task that is not current on a crash-note CPU becomes a labelled thread, and a zero program counter is unwound from saved thread state, so a mutex waiter shows mutex_lock. A per-CPU symbol takes an optional cpu; without it the stopped CPU is used. The panicking CPU's frame in `__crash_kexec` or `crash_kexec` continues with the image's DWARF call frame when the kernel unwind stops. Page-table reads use an index of load segments ordered by physical address.

A task in uninterruptible sleep, other than an idle task, is checked for a mutex or rwsem waiter. The lock is the embedded wait list when the type has one. Otherwise the task's `blocked_on` pointer, or a kernel pointer on that task's stack, is accepted when the lock's first waiter is that task. The owner field names the holder and its low three bits are flags. When that holder is a CPU's current task, the waiter's label names the lock and the holder, who spins on CPU <n>. The holder's own label says it spins on that CPU holding the lock, and does not repeat the waiter's sentence. The same walk runs for a vmcore, a live stop, and a core whose every load segment is a kernel virtual address. A live kcore is that kind of core: open it with `--core` and `--vmlinux`. The open is read-only, and a core target refuses memory writes. A core that also has a low load segment is unchanged. An rwsem whose owner word has the reader bit set is reported as held by readers; the last reader recorded there is not named as its owner. A wait list is followed for at most 64 nodes, so a corrupt or circular list gives no edge. With `--vmlinux`, thread labels are rebuilt at every stop, so CPU, state and wait sentences describe the current stop. A chain longer than a thread label ends with ", ..". A live `/proc/kcore` (root) has a register note only for the reading CPU: another CPU's current task is still listed, and its stack is refused with `KernelTaskRunning` rather than unwound from stale saved state. Without root the open fails with `CoreFileUnavailable`. On a guest whose CPU spins with interrupts off, pin the reader to another CPU (`taskset`), and use at least three CPUs, or the reader can stall behind the spinning one. A label puts its own thread's wait first and what it holds after it, so the order of the task walk never decides which part a 128-byte label keeps.

A lock whose owner word is empty, names the waiter, or names an address that is not in the walked task list is reported as owned by an unknown task. A `blocked_on` address that is not a mutex or rwsem waiter of that task is reported as an unknown lock. A label follows the owner chain for at most four edges, so one sentence can name A waiting on B who waits on C. The walk stops when the bound is reached, the next owner is unknown, or an owner is repeated.

`XODB_KGDB_ENDPOINT` may name a `tcp:`, `unix:`, or `serial:` endpoint. The kgdb-stub test opens it when the variable is set and otherwise prints a skip line. The synthetic stub still runs.

A thread label is 128 bytes, so its wait sentence keeps one hop. `list_threads` and `get_session` publish `wait_chain` on that label: up to four hops, each with the lock, its kind, the owner, and the owner's CPU when that owner is running. The owner is null when the holder is unknown or the lock is held by readers. The chain stops early when an owner repeats, the lock is held by readers, or the owner is not itself waiting. A thread that is not waiting has `wait_chain` null. The label name is unchanged. `wait_chain_truncated` is true when more hops follow the fourth, and `wait_chain_cycle` when an owner repeats; both are null when there is no chain. An unknown owner is `unknown_owner: true`. Module symbols come from the `.ko` files given with `--modules`. A kernel without CONFIG_STACKTRACE_BUILD_ID stores no module build id, so each object is checked against the module's own kallsyms instead (see `--modules` above).
