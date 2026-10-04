# Allocation tracing capability check

Prepared 2026-10-02. **Approved host run completed 2026-10-03: passed.**
[Results and limits](research/allocation-probe-host-20261003.md).
No production privilege workflow adopted yet.

The first isolated task-scoped perf uprobe attempt returned `EACCES` as the
ordinary workstation user, with `perf_event_paranoid=1`. That is a permission
result, not a finding that the kernel cannot collect allocator events.
Current upstream `perf_uprobe_event_init` explicitly checks `CAP_SYS_ADMIN`;
this differs from the `CAP_PERFMON` check for kprobes. Verify the actual host
before choosing a production path.
[Linux implementation](https://github.com/torvalds/linux/blob/master/kernel/events/core.c).

## Prepared experiment

```sh
sudo -n timeout --signal=TERM --kill-after=1 8s \
  .work/allocation-probe-20261002T234343993830/probe
```

The probe source and build log are in that same ignored directory. It forks
one owned child and observes three calls to its own allocation wrapper. Entry
and return events share a per-task perf ring, `inherit` is off, and saved x86
registers supply sizes and return pointers. It verifies three entries and three
returns, closes both descriptors and reaps its child. Its internal deadline is
three seconds, with the outer deadline as a second bound.

It does not attach to other applications, write tracefs, change sysctls, install
capabilities, access guests/devices, or write outside the checkout. The temporary
privileged execution is the only additional authorization requested. A successful
probe would establish only this mechanism on an owned fixture, not allocator
coverage, tolerable overhead, or a suitable privilege model for the GUI.

## Short critical review

Perf uprobes could collect allocator entry/return evidence without stopping the
whole debugger for every call. A shared ring solves entry/return ordering for
one thread. Multi-thread lifetime reconstruction, loss, nested allocator calls,
realloc edge cases and custom allocators still need separate treatment.

The privilege requirement is a material cost. Running the GUI as root is not
an adopted design. A small privileged collector/helper, explicitly configured
trace events, or slower ordinary debugger hooks are alternatives to evaluate.
The experiment chooses none of them and leaves host policy unchanged.
