# KGDB remote

`--gdb-remote` accepts three endpoint forms.

- `tcp:HOST:PORT` and the older `HOST:PORT` form. Brackets still mark an IPv6 host.
- `unix:ABS_PATH` is a stream socket. The path is absolute.
- `serial:ABS_PATH[,BAUD][,break]` is a raw 8N1 line. The baud is one of 9600, 19200, 38400, 57600, 115200, and 230400. 460800 and 921600 are accepted when the host defines them. The default is 115200. `break` sends a line break and then the byte `g` before the handshake.

A stub that does not offer `qXfer:features:read+` is treated as a kernel stub. The `g` packet length selects a built-in register layout:

- 156 bytes: x86-64 (`rax` through `rip`, then `eflags`, `cs`, `ss`, `ds`, `es`)
- 788 bytes: aarch64 (`x0` through `x30`, `sp`, `pc`, `pstate`, then the vector bank)
- 548 bytes: loongarch64 (`r0` through `r31`, `orig_a0`, `pc`, `badv`, then the floating-point bank)

Any other length is refused. The client does not guess.

Threads are tasks plus per-CPU shadow ids. The wire id is kept for packets. A negative shadow id is shown locally as a distinct positive id so snapshots can name it. Names come from `qThreadExtraInfo`.

Continue sends `Hc0` and then `c`. Step sends `Hc` of the stopped CPU and then `s`. Stepping another CPU is refused. The client never sends a kill packet. Detach sends `D` and resumes the kernel.

kgdboc ignores the `0x03` interrupt byte while the kernel runs. On a `serial:` tty, interrupt sends a line break and then `g` (SysRq-G). On `unix:` and `tcp:` endpoints interrupt is refused with `UnsupportedControl`; enter the debugger from the target instead (`echo g > /proc/sysrq-trigger`, or the lab's `kl-console RUN_DIR send kgdb`). For the same reason, closing xodb or detaching while such a kernel runs cannot remove xodb's breakpoints. xodb prints a warning, and the next hit stops the kernel with no debugger attached. Enter the debugger and detach to remove them.

Real kgdb differs from gdbserver in ways the client handles:

- the thread list ends with an empty reply, not `l`;
- task names are the 16-byte `comm`, padded with NUL bytes;
- on x86-64 a breakpoint stop reports the address after `int3`, and the client rewinds the PC onto the breakpoint;
- x86-64 kgdb does not bound `m` requests to its 1024-byte buffer, so reads stay at 511 bytes per packet;
- each stop refreshes every thread and its name: about 6 seconds per stop for 66 tasks at 9600 baud, 0.4 seconds over the lab socket. More than 1024 tasks is refused with `TooManyThreads`.

Launch, attach, restart, follow, process files, libraries, and hardware watchpoints are refused. Software breakpoints use `Z0`. A later milestone can read a vmcore through the same kernel view; this client does not open one.

`XODB_KGDB_ENDPOINT` may name a `tcp:`, `unix:`, or `serial:` endpoint. The kgdb-stub test opens it when the variable is set and otherwise prints a skip line. The synthetic stub still runs.
