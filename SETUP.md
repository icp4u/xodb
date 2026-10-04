# Workstation setup

xodb supports the x86-64 GUI and an initial ARM64 headless backend.
Run xodb as your normal user. Use sudo for granular root steps.

> **Security:** These host-wide changes relax tracing isolation and can expose
> sensitive process/kernel data to local users. Optional `ptrace_scope=0` also
> lets same-user software inspect or modify other dumpable processes. Use a
> trusted development machine and protect capture files.
> [Kernel perf security](https://docs.kernel.org/admin-guide/perf-security.html),
> [Yama/ptrace security](https://docs.kernel.org/admin-guide/LSM/Yama.html).

## Build and run

Install Zig **0.16 or newer** (no exact version pin; see the README for the tested
baseline), a C compiler, `pkg-config`, `wayland-scanner`, `glslc`,
and the development files for Wayland/wayland-protocols, libxkbcommon, Vulkan,
FreeType, HarfBuzz, Capstone and elfutils libdw/libelf. The GUI needs a Wayland
session, a working Vulkan driver and DejaVu Sans Mono (or `--font FILE`).
[Dependency details](docs/DEPENDENCIES.md).

From the checkout:

```sh
pkg-config --print-errors --exists wayland-client xkbcommon vulkan freetype2 harfbuzz capstone libdw
./scripts/build -Doptimize=ReleaseSafe
./zig-out/bin/xodb -- ./zig-out/bin/xodb-m1-fixture
```

Build targets with `-g` for source information; `-fno-omit-frame-pointer` helps
recorded CPU callchains. See the [debugging demo](README.md#try-m1) and
[profiling demo](docs/PROFILING.md#try-the-demo). Headless MCP can be built without the GUI dependencies:

```sh
pkg-config --print-errors --exists capstone libdw
./scripts/build -Dgui=false -Doptimize=ReleaseSafe
./zig-out/bin/xodb --mcp -- ./zig-out/bin/xodb-m1-fixture
```

The headless build needs Zig, libc development files, Capstone and libdw/libelf.
It defaults to headless mode and requires `--mcp`. The normal GUI build also
continues to accept runtime `--headless --mcp`.

## Optional allocation tracing

Linux x86-64 allocation capture uses task-scoped perf uprobes. This workstation
requires elevated permission to create them even with perf_event_paranoid=1.
Use the explicit short-lived helper workflow in [ALLOCATIONS.md](docs/ALLOCATIONS.md);
keep xodb itself under your normal account. No additional global settings are
required by that workflow. Do not install broad sudoers permission for a helper
writable by an untrusted account.

## Check the current tracing policy

Record the current values and mount options before changing anything:

```sh
id
sysctl kernel.perf_event_paranoid
sysctl kernel.yama.ptrace_scope
findmnt -t tracefs
ulimit -n
ulimit -l
sysctl kernel.perf_event_mlock_kb
```

A missing `kernel.yama.ptrace_scope` means that interface is unavailable in this
environment; no tracefs output means no tracefs mount was found.

| Feature | Configuration on the tested workstation |
| --- | --- |
| Debug launch / attach | Ptrace access to the target; independent of perf settings |
| Current user-CPU sampling and scheduling | Works with `perf_event_paranoid=2`; no tracefs mount needed |
| Experimental T17 syscall timing | Readable tracefs event IDs/formats, plus `perf_event_paranoid=1` (or CAP_PERFMON for the collector) |

T17 is still a prototype. Configuring the host does not add a syscall capture
button to xodb. [Configured evaluation and measurements](docs/T17_CONFIGURED_RERUN.md).

## Enable task-scoped syscall tracing

This is the tested ordinary-user configuration. Setting paranoid to **1** allows
per-process kernel profiling while retaining the restriction on unprivileged
system-wide perf. It applies to every local user, not just xodb. It does not
permit every raw tracepoint; the task-scoped `raw_syscalls` events below worked
on this kernel. [Perf permission levels](https://docs.kernel.org/admin-guide/perf-security.html#unprivileged-users).

### Mount tracefs for a trusted group

Use your private user group or a dedicated trusted tracing group. Check `id`
above: a shared primary group grants access to its other members too. In a
normal-user shell, obtain the numeric GID (substitute your chosen group's GID
if needed):

```sh
xodb_trace_gid="$(id -g)"
```

If `/sys/kernel/tracing` is not already mounted:

```sh
sudo mount -t tracefs \
    -o "nosuid,nodev,noexec,gid=$xodb_trace_gid,mode=750" \
    tracefs /sys/kernel/tracing
```

For an existing tracefs mount, first check whether the verification commands
below already work. If its access policy needs changing, review its current
options and use the same group/mode in that mount's configuration; do not stack
another mount over it or unmount another tool's active tracing filesystem.
The tested fresh mount gave the group read access to event metadata and kept
control-file writes with root. Group access can also expose other tracing data;
it is not a restriction on which events perf itself permits.
[Tracefs documentation](https://docs.kernel.org/trace/ftrace.html).

To persist the mount, print the entry, then add or update **one** matching entry
in `/etc/fstab` (use the numeric GID, not a literal shell variable):

```sh
printf 'tracefs /sys/kernel/tracing tracefs nosuid,nodev,noexec,gid=%s,mode=750,nofail 0 0\n' "$xodb_trace_gid"
sudoedit /etc/fstab
sudo findmnt --verify
```

If your init system already manages this mount elsewhere, update that existing
configuration instead of adding a second owner.

### Set perf permissions

After the backup above, create/update the drop-in and apply it immediately:

```sh
printf '%s\n' 'kernel.perf_event_paranoid = 1' | sudo tee /etc/sysctl.d/90-xodb-perf.conf
sudo sysctl -p /etc/sysctl.d/90-xodb-perf.conf
```

Check for conflicting settings in other sysctl files if the value changes back.
Verify the effective settings again after reboot on your distribution.

A process-local **CAP_PERFMON** collector also passed T17 with paranoid left at
2. This is an alternative for administrators who want to retain the host-wide
policy; it grants broader perf access to that process. A packaged privilege
helper is not implemented. The guide does not require running the GUI as root
or granting permanent capabilities to the xodb executable.

### Verify as your normal user

```sh
findmnt -no TARGET,FSTYPE,OPTIONS /sys/kernel/tracing
sysctl kernel.perf_event_paranoid
cat /sys/kernel/tracing/events/raw_syscalls/sys_enter/id
cat /sys/kernel/tracing/events/raw_syscalls/sys_exit/id
cat /sys/kernel/tracing/events/raw_syscalls/sys_enter/format
cat /sys/kernel/tracing/events/raw_syscalls/sys_exit/format
```

Expect paranoid **1** and readable, nonzero IDs with matching format files.
IDs vary by boot. Reading metadata checks setup; a successful collector run
checks actual perf access. The [T17 rerun instructions](docs/T17_CONFIGURED_RERUN.md#reproducible-configured-experiment)
exercise owned CPU/wait/copy fixtures, including ordinary-user collection.

## If attaching by PID is denied

Start with a process owned by your user. Under Yama's common `ptrace_scope=1`
policy, launching a target under xodb usually works while attaching to an
unrelated existing process requires the target's cooperation or extra privilege.
If you deliberately want ordinary same-user attach across applications, the
optional live setting is:

```sh
sudo sysctl -w kernel.yama.ptrace_scope=0
```

Record its old value first. To persist this choice, back up any existing
`/etc/sysctl.d/90-xodb-ptrace.conf`, then place
`kernel.yama.ptrace_scope = 0` in that file. UID/dumpability and other security
checks still apply. CAP_PERFMON does not grant general debugger ptrace access.
[Ptrace policies](https://docs.kernel.org/admin-guide/LSM/Yama.html#ptrace-scope).

## Other failures and undo

- **Missing event files:** check tracefs is mounted and the kernel provides the
  syscall tracepoints. A permissions change cannot add missing kernel support.
- **`EACCES` / `EPERM`:** inspect xodb's stderr for the failed syscall. Perf,
  ptrace, sandbox and other kernel security policies are separate checks.
- **Descriptor or locked-memory limits:** use fewer selected threads first;
  inspect `ulimit -n`, `ulimit -l`, and `perf_event_mlock_kb` before choosing
  larger limits. A permission fix does not remove resource limits.
- **Few CPU samples during copying/waiting:** current flames sample user CPU.
  Kernel work and blocked time are absent; see [profiling limits](docs/PROFILING.md#few-or-no-samples).

## Remote connections

[Remote GUI setup](docs/REMOTE_DEBUGGING.md) cover SSH and
`--listen` / `--connect` over TCP. The target host needs its own native headless
xodb and normal debugger permissions. SSH uses your existing authentication and
host-key setup, without agent forwarding. Plain TCP has no authentication or
encryption: only expose it on a trusted LAN with an appropriate scope. No
listener, service or firewall configuration is installed automatically.
