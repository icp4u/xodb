"""External stopped-process CPython stacks for xodb.logical-frames v1, draft C05-1.

Spawns an owned CPython workload, stops the whole process with SIGSTOP, waits
until every task is in stopped state, reads all Python thread stacks with the
CPython 3.14 stdlib reader _remote_debugging.RemoteUnwinder (process_vm_readv,
layout from the target's _Py_DebugOffsets), then resumes with SIGCONT.
Nothing is executed inside the target and no code is injected.

Version/layout gates, before any memory read:
  1. the target's executable and libpython must be byte-identical to the
     reader's own (SHA-256), unless --skip-build-check;
  2. the _Py_DebugOffsets header (cookie "xdebugpy" + PY_VERSION_HEX) found at
     the _PyRuntime symbol in the target's ELF file must carry the reader's
     sys.hexversion, unless --skip-version-check.
RemoteUnwinder performs its own runtime cookie/version validation as well.

usage: py_remote_snapshot.py --target-python EXE --workload SCRIPT --out OUT.jsonl
         [--snapshots N] [--period-ms M] [--seconds S] [--skip-build-check] [--skip-version-check]
Prints a JSON summary; exit 0 ok, 3 gate failure, 1 other failure.
"""
import argparse
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import time

FORMAT, DRAFT = "xodb.logical-frames", "C05-1"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def mapped(pid, prefix):
    with open("/proc/%d/maps" % pid) as f:
        for line in f:
            p = line.split()
            if len(p) > 5 and os.path.basename(p[5]).startswith(prefix):
                return p[5]
    return None


def elf_symbol_bytes(path, symbol, size):
    """Read `size` initialised bytes of a dynamic or static symbol from an ELF64 LE file."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not ELF64 little-endian")
    shoff, = struct.unpack_from("<Q", data, 40)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    for symtab_type in (11, 2):  # SHT_DYNSYM, SHT_SYMTAB
        for name, kind, flags, addr, off, sz, link, info, align, entsize in sections:
            if kind != symtab_type:
                continue
            strtab = sections[link]
            for i in range(sz // entsize):
                st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, off + i * entsize)
                start = strtab[4] + st_name
                if data[start:data.index(b"\0", start)] != symbol.encode():
                    continue
                sec = sections[st_shndx]
                if sec[1] == 8:  # SHT_NOBITS: zero-initialised, no file bytes
                    raise ValueError("%s is in .bss" % symbol)
                file_off = sec[4] + (st_value - sec[3])
                return data[file_off:file_off + size]
    raise ValueError("symbol %s not found" % symbol)


def debug_offsets_header(path):
    raw = elf_symbol_bytes(path, "_PyRuntime", 16)
    return raw[:8], struct.unpack_from("<Q", raw, 8)[0]


def hexversion_text(v):
    level = {0xA: "a", 0xB: "b", 0xC: "rc", 0xF: ""}[(v >> 4) & 0xF]
    serial = v & 0xF
    return "%d.%d.%d%s" % (v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, level + (str(serial) if level else ""))


def task_states(pid):
    states = {}
    for tid in os.listdir("/proc/%d/task" % pid):
        try:
            with open("/proc/%d/task/%s/stat" % (pid, tid)) as f:
                s = f.read()
            states[int(tid)] = s[s.rindex(")") + 2]
        except (OSError, ValueError):
            pass
    return states


def comm(pid, tid):
    try:
        with open("/proc/%d/task/%d/comm" % (pid, tid)) as f:
            return f.read().rstrip("\n")
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-python", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--snapshots", type=int, default=20)
    ap.add_argument("--period-ms", type=float, default=50)
    ap.add_argument("--seconds", type=float, default=4)
    ap.add_argument("--skip-build-check", action="store_true")
    ap.add_argument("--skip-version-check", action="store_true")
    a = ap.parse_args()
    summary = {"reader": sys.executable, "reader_version": sys.version, "target_python": a.target_python,
               "gates": {}, "snapshots": [], "cleanup": {}}
    meta = a.out + ".target-meta.json"
    target = subprocess.Popen([a.target_python, "-B", a.workload, os.devnull, meta, str(a.seconds), "5", "--no-export"],
                              stdin=subprocess.DEVNULL)
    pid = target.pid
    summary["target_pid"] = pid
    stopped = False
    rc = 1
    try:
        # Readiness from kernel-visible state only: the four named worker tasks exist.
        want = {"py-fib", "py-nested", "py-qsort", "py-raiser"}
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            names = {comm(pid, t) for t in task_states(pid)}
            if want <= names:
                break
            time.sleep(0.01)
        else:
            raise RuntimeError("target workers did not appear")
        exe = os.path.realpath("/proc/%d/exe" % pid)
        lib = mapped(pid, "libpython")
        own_exe = os.path.realpath("/proc/self/exe")
        own_lib = mapped(os.getpid(), "libpython")
        ident = {"target_exe": exe, "target_exe_sha256": sha256_file("/proc/%d/exe" % pid),
                 "target_lib": lib, "target_lib_sha256": sha256_file(lib) if lib else None,
                 "reader_exe": own_exe, "reader_exe_sha256": sha256_file(own_exe),
                 "reader_lib": own_lib, "reader_lib_sha256": sha256_file(own_lib) if own_lib else None}
        build_ok = (ident["target_exe_sha256"] == ident["reader_exe_sha256"]
                    and ident["target_lib_sha256"] == ident["reader_lib_sha256"])
        summary["gates"]["build"] = dict(ident, ok=build_ok, skipped=a.skip_build_check)
        runtime_image = lib or exe
        cookie, version = debug_offsets_header(runtime_image)
        version_ok = cookie == b"xdebugpy" and version == sys.hexversion
        summary["gates"]["debug_offsets"] = {"image": runtime_image, "cookie": cookie.decode("latin-1"),
                                             "target_version_hex": "0x%08x" % version,
                                             "reader_version_hex": "0x%08x" % sys.hexversion,
                                             "ok": version_ok, "skipped": a.skip_version_check}
        if (not build_ok and not a.skip_build_check) or (not version_ok and not a.skip_version_check):
            summary["result"] = "gate_failed"
            rc = 3
            return rc
        import _remote_debugging
        with open("/proc/%d/stat" % pid) as f:
            st = f.read()
        start_ticks = st[st.rindex(")") + 2:].split()[19]
        with open("/proc/sys/kernel/random/boot_id") as f:
            boot_id = f.read().strip()
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmdline = [x.decode("utf-8", "replace") for x in f.read().split(b"\0")[:-1]]
        records = []
        codes, functions, threads = {}, {}, {}

        def code_id(path):
            if path not in codes:
                codes[path] = "c%d" % (len(codes) + 1)
                rec = {"type": "code", "id": codes[path], "path": path}
                if path.startswith("<"):
                    rec.update(kind="builtin" if path.startswith("<frozen") else "generated", sha256=None, bytes=None,
                               unavailable="no source file")
                else:
                    try:
                        rec.update(kind="source_file", sha256=sha256_file(path), bytes=os.path.getsize(path),
                                   x_identity_note="file read by the reader at snapshot time; not proof of target bytecode")
                    except OSError as e:
                        rec.update(kind="unknown", sha256=None, bytes=None, unavailable="unreadable: %s" % e.strerror)
                records.append(rec)
            return codes[path]

        def function_id(name, path):
            key = (name, path)
            if key not in functions:
                functions[key] = "f%d" % (len(functions) + 1)
                records.append({"type": "function", "id": functions[key], "name": name.rsplit(".", 1)[-1],
                                "qualified": name, "code": code_id(path), "first_line": None,
                                "frame_kind": "interpreter", "runtime_id": None})
            return functions[key]

        def thread_id(tid, name):
            key = (tid, name)
            if key not in threads:
                threads[key] = "t%d" % (len(threads) + 1)
                records.append({"type": "thread", "id": threads[key], "language_id": None, "name": name,
                                "os_tid": tid,
                                "os_tid_source": "RemoteUnwinder thread_id, present in /proc/PID/task while stopped",
                                "x_name_source": "kernel comm (CPython sets it from Thread.name; 15 bytes)"})
            return threads[key]

        unwinder = _remote_debugging.RemoteUnwinder(pid, all_threads=True)
        seq = stacks = 0
        for n in range(a.snapshots):
            time.sleep(a.period_ms / 1000)
            if target.poll() is not None:
                break
            t_request = time.monotonic_ns()
            os.kill(pid, signal.SIGSTOP)
            stopped = True
            deadline = time.monotonic() + 2
            while True:
                states = task_states(pid)
                if states and all(s in "Tt" for s in states.values()):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("target did not reach group stop: %r" % states)
                time.sleep(0.0002)
            t_stopped = time.monotonic_ns()
            error = None
            try:
                trace = unwinder.get_stack_trace()
            except Exception as e:  # reader failure is evidence, not a crash
                trace, error = None, "%s: %s" % (type(e).__name__, e)
            t_read = time.monotonic_ns()
            tasks = {tid: comm(pid, tid) for tid in states}
            os.kill(pid, signal.SIGCONT)
            stopped = False
            t_resumed = time.monotonic_ns()
            seq += 1
            snap = {"seq": seq, "stop_wait_ns": t_stopped - t_request, "read_ns": t_read - t_stopped,
                    "stopped_ns": t_resumed - t_request, "error": error,
                    "threads": len(trace) if trace else 0, "tasks": len(tasks)}
            summary["snapshots"].append(snap)
            items = []
            for info in trace or []:
                tid, frames = info.thread_id, info.frame_info
                if tid not in tasks:
                    snap.setdefault("unverified_tids", []).append(tid)
                items.append((tid, frames))
            records.append({"type": "acquisition", "seq": seq, "start_ns": str(t_stopped), "end_ns": str(t_read),
                            "stacks": len(items), "x_stop_requested_ns": str(t_request), "x_resumed_ns": str(t_resumed)})
            if error:
                records.append({"type": "loss", "reason": "remote_unwinder_error: " + error[:200], "count": "1",
                                "acquisition": seq})
            for tid, frames in items:
                t = thread_id(tid, tasks.get(tid))
                out = []
                for fr in frames:
                    fid = function_id(fr.funcname, fr.filename)
                    f = {"function": fid, "kind": "interpreter", "line": fr.lineno if fr.lineno > 0 else None,
                         "provenance": "external_read"}
                    if f["line"] is None:
                        f["reason"] = "reader reported line %d" % fr.lineno
                    out.append(f)
                stacks += 1
                records.append({"type": "stack", "id": "s%d" % stacks, "acquisition": seq, "thread": t,
                                "start_ns": str(t_stopped), "end_ns": str(t_read), "trigger": "external_timer",
                                "weight": "1", "state": "partial", "omitted": None,
                                "reason": "CPython 3.14 RemoteUnwinder stops at a C-stack entry frame (e.g. "
                                          "Context.run in threading); outer frames may be absent",
                                "frames": out})
        header = {
            "type": "header", "format": FORMAT, "version": 1, "draft": DRAFT,
            "producer": {"name": "xodb-lframes-cpython-remote", "version": "1", "kind": "external_reader",
                         "sha256": sha256_file(os.path.abspath(__file__))},
            "source_kind": "stopped_snapshot",
            "runtime": {"language": "python", "implementation": "cpython", "version": hexversion_text(version),
                        "build": None,
                        "executable": {"path": exe, "sha256": ident["target_exe_sha256"], "gnu_build_id": None},
                        "library": {"path": lib, "sha256": ident["target_lib_sha256"], "gnu_build_id": None} if lib else None},
            "process": {"pid": pid, "start_ticks": start_ticks, "boot_id": boot_id},
            "clock": {"domain": "CLOCK_MONOTONIC", "unit": "ns"},
            "command": cmdline,
            "collection": {"method": "SIGSTOP group-stop, then _remote_debugging.RemoteUnwinder(pid, all_threads=True)"
                                     ".get_stack_trace() (process_vm_readv), then SIGCONT",
                           "trigger": "external timer in the reader process",
                           "interval_ns": str(int(a.period_ms * 1e6)), "atomicity": "process_stopped",
                           "notes": "All target tasks were in stopped state for the whole read, so memory was not "
                                    "changing (no shared-memory writers in this fixture). A thread may be stopped "
                                    "mid frame push; reader errors are recorded as loss. Times are the reader's "
                                    "CLOCK_MONOTONIC on the same host (same boot_id). The workload ran without any "
                                    "cooperating exporter."},
            "frame_order": "innermost_first", "weight_unit": "observation",
            "weight_semantics": "one stack per thread per stopped snapshot; not CPU time",
            "x_debug_offsets": summary["gates"]["debug_offsets"],
        }
        records.insert(0, header)
        records.append({"type": "end", "records": len(records), "acquisitions": seq, "stacks": stacks, "status": "complete"})
        with open(a.out, "w", encoding="utf-8") as f:
            for r in records:
                f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
        summary["result"] = "ok"
        summary["stacks"] = stacks
        rc = 0
        return rc
    except Exception as e:
        summary["result"] = "error"
        summary["error"] = "%s: %s" % (type(e).__name__, e)
        return 1
    finally:
        if stopped:
            os.kill(pid, signal.SIGCONT)
        if target.poll() is None:
            if summary.get("result") != "ok":
                target.kill()
        try:
            summary["cleanup"]["target_exit"] = target.wait(timeout=30)
        except subprocess.TimeoutExpired:
            target.kill()
            summary["cleanup"]["target_exit"] = target.wait()
        summary["cleanup"]["target_reaped"] = True
        summary["cleanup"]["resumed_if_stopped"] = True
        try:
            summary["target_meta"] = json.load(open(meta))
            os.unlink(meta)
        except (OSError, ValueError):
            pass
        print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    sys.exit(main())
