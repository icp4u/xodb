"""Cooperating in-process CPython exporter for xodb.logical-frames v1, draft C05-1.

This is COOPERATING INSTRUMENTATION: the observed program imports this module
and runs a sampler thread inside its own interpreter. Stacks come from
sys._current_frames() (all threads in one call while the sampler holds the GIL)
and from exception tracebacks. It is not external or noninvasive sampling.
Interpreter frames never carry native PCs. Native transitions are only shown
where the program itself declares them with native_region() and are labelled
"cooperative_annotation".
"""
import hashlib
import json
import os
import platform
import sys
import threading
import time

FORMAT = "xodb.logical-frames"
DRAFT = "C05-1"
PRODUCER = "xodb-lframes-cpython"
PRODUCER_VERSION = "1"
_ELF_NOTE_GNU_BUILD_ID = 3


def file_sha256(path, limit=1 << 30):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            n += len(b)
            if n > limit:
                raise OSError("file exceeds hashing limit")
            h.update(b)
    return h.hexdigest(), n


def gnu_build_id(path):
    """Return the NT_GNU_BUILD_ID of a 64-bit little-endian ELF file, or None."""
    import struct
    try:
        with open(path, "rb") as f:
            ident = f.read(64)
            if len(ident) < 64 or ident[:4] != b"\x7fELF" or ident[4] != 2 or ident[5] != 1:
                return None
            phoff, = struct.unpack_from("<Q", ident, 32)
            phentsize, phnum = struct.unpack_from("<HH", ident, 54)
            for i in range(min(phnum, 256)):
                f.seek(phoff + i * phentsize)
                ph = f.read(56)
                p_type, = struct.unpack_from("<I", ph, 0)
                if p_type != 4:  # PT_NOTE
                    continue
                offset, = struct.unpack_from("<Q", ph, 8)
                size, = struct.unpack_from("<Q", ph, 32)
                f.seek(offset)
                notes = f.read(min(size, 1 << 16))
                at = 0
                while at + 12 <= len(notes):
                    namesz, descsz, kind = struct.unpack_from("<III", notes, at)
                    name_at = at + 12
                    desc_at = name_at + ((namesz + 3) & ~3)
                    if kind == _ELF_NOTE_GNU_BUILD_ID and notes[name_at:name_at + namesz] == b"GNU\0":
                        return notes[desc_at:desc_at + descsz].hex()
                    at = desc_at + ((descsz + 3) & ~3)
    except OSError:
        return None
    return None


def image_identity(path):
    if path is None:
        return {"path": None, "sha256": None, "gnu_build_id": None, "unavailable": "not mapped"}
    try:
        digest, _ = file_sha256(path)
        return {"path": path, "sha256": digest, "gnu_build_id": gnu_build_id(path)}
    except OSError as e:
        return {"path": path, "sha256": None, "gnu_build_id": None, "unavailable": "unreadable: %s" % e.strerror}


def mapped_paths():
    paths = []
    try:
        with open("/proc/self/maps") as f:
            for line in f:
                parts = line.split()
                if len(parts) > 5 and parts[5].startswith("/") and parts[5] not in paths:
                    paths.append(parts[5])
    except OSError:
        pass
    return paths


def process_identity():
    pid = os.getpid()
    out = {"pid": pid, "start_ticks": None, "boot_id": None}
    try:
        with open("/proc/self/stat") as f:
            stat = f.read()
        out["start_ticks"] = stat[stat.rindex(")") + 2:].split()[19]
        with open("/proc/sys/kernel/random/boot_id") as f:
            out["boot_id"] = f.read().strip()
    except (OSError, ValueError, IndexError) as e:
        out["unavailable"] = "proc identity unreadable: %s" % e
    return out


def os_thread_comm(tid):
    try:
        with open("/proc/self/task/%d/comm" % tid) as f:
            return f.read().rstrip("\n")
    except OSError:
        return None


class Exporter:
    def __init__(self, path, interval_s=0.005, max_depth=512, source_root=None):
        self.path = path
        self.interval_ns = int(interval_s * 1e9)
        self.max_depth = max_depth
        self.source_root = source_root
        self.lock = threading.Lock()
        self.out = open(path, "w", encoding="utf-8", newline="\n")
        self.records = 0
        self.seq = 0
        self.stacks = 0
        self.codes = {}        # filename -> code id
        self.functions = {}    # id(code) -> (code object, function id); strong refs prevent id reuse
        self.threads = {}      # (thread object id or ident, native id) -> (thread object, thread id)
        self.regions = {}      # thread ident -> list of (label, depth)
        self.stop_event = threading.Event()
        self.sampler = None
        self.cost_ns = 0
        self.annotations_dropped = 0
        self.lost_ticks = 0
        self._header()

    # -- records ---------------------------------------------------------
    def _write(self, record):
        self.out.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.records += 1

    def _header(self):
        exe = os.path.realpath("/proc/self/exe")
        library = next((p for p in mapped_paths() if os.path.basename(p).startswith("libpython")), None)
        clock = time.get_clock_info("monotonic")
        with open(os.path.abspath(__file__), "rb") as f:
            producer_sha = hashlib.sha256(f.read()).hexdigest()
        self._write({
            "type": "header", "format": FORMAT, "version": 1, "draft": DRAFT,
            "producer": {"name": PRODUCER, "version": PRODUCER_VERSION, "kind": "cooperating_in_process",
                         "sha256": producer_sha},
            "source_kind": "cooperative_sample",
            "runtime": {"language": "python", "implementation": sys.implementation.name,
                        "version": platform.python_version(),
                        "build": "%s; %s; %s" % (" ".join(platform.python_build()), platform.python_compiler(),
                                                 "gil" if getattr(sys, "_is_gil_enabled", lambda: True)() else "free-threaded"),
                        "executable": image_identity(exe), "library": image_identity(library) if library else None},
            "process": process_identity(),
            "clock": {"domain": "CLOCK_MONOTONIC", "unit": "ns"} if "CLOCK_MONOTONIC" in clock.implementation else None,
            "command": list(getattr(sys, "orig_argv", sys.argv)),
            "collection": {
                "method": "sys._current_frames+frame.f_back walk; exception tracebacks; explicit emits",
                "trigger": "timer thread (threading.Event.wait); also exception and explicit",
                "interval_ns": str(self.interval_ns),
                "atomicity": "all_threads_one_call",
                "notes": ("frames for all threads are captured in one sys._current_frames call under the GIL; the "
                          "f_back/f_lineno walk happens afterwards and a thread may advance if the GIL is released "
                          "during the walk, so each stack is valid somewhere inside its [start_ns,end_ns] window. "
                          "The exporter's own sampler thread is excluded. Exception stacks describe the raise site "
                          "(traceback) plus the catching frame's callers at emit time."),
            },
            "frame_order": "innermost_first",
            "weight_unit": "observation",
            "weight_semantics": "one stack observation per acquisition per thread; not CPU time",
            "x_clock_info": str(clock),
        })

    def _code(self, filename):
        cid = self.codes.get(filename)
        if cid is not None:
            return cid
        cid = "c%d" % (len(self.codes) + 1)
        self.codes[filename] = cid
        rec = {"type": "code", "id": cid, "path": filename}
        if filename.startswith("<frozen "):
            rec.update(kind="builtin", sha256=None, bytes=None, unavailable="frozen module; no source file")
        elif filename.startswith("<"):
            rec.update(kind="generated", sha256=None, bytes=None, unavailable="no file for %s" % filename)
        else:
            try:
                digest, size = file_sha256(filename)
                rec.update(kind="source_file", sha256=digest, bytes=size,
                           x_hashed_at_ns=str(time.monotonic_ns()),
                           x_identity_note="file content at first observation; not proof of loaded bytecode")
            except OSError as e:
                rec.update(kind="unknown", sha256=None, bytes=None, unavailable="unreadable: %s" % e.strerror)
        self._write(rec)
        return cid

    def _function(self, code):
        entry = self.functions.get(id(code))
        if entry is not None and entry[0] is code:
            return entry[1]
        fid = "f%d" % (len(self.functions) + 1)
        self.functions[id(code)] = (code, fid)
        self._write({"type": "function", "id": fid, "name": code.co_name,
                     "qualified": getattr(code, "co_qualname", code.co_name),
                     "code": self._code(code.co_filename), "first_line": code.co_firstlineno,
                     "frame_kind": "interpreter", "runtime_id": "cpython:code@0x%x" % id(code),
                     "x_co_code_sha256": hashlib.sha256(code.co_code).hexdigest()})
        return fid

    def _thread(self, ident, thread):
        native = getattr(thread, "native_id", None) if thread is not None else None
        key = (id(thread) if thread is not None else ident, native)
        entry = self.threads.get(key)
        if entry is not None:
            return entry[1]
        tid = "t%d" % (len(self.threads) + 1)
        self.threads[key] = (thread, tid)
        rec = {"type": "thread", "id": tid, "language_id": "ident:%d" % ident,
               "name": thread.name if thread is not None else None}
        if native:
            rec.update(os_tid=native, os_tid_source="threading.Thread.native_id",
                       x_os_comm=os_thread_comm(native))
        else:
            rec.update(os_tid=None, os_tid_reason="no threading.Thread object for this ident at acquisition"
                       if thread is None else "native_id unavailable")
        self._write(rec)
        return tid

    def _frames(self, frame, ident=None, regions=None):
        frames = []
        f = frame
        while f is not None and len(frames) < self.max_depth:
            fid = self._function(f.f_code)
            line = f.f_lineno
            rec = {"function": fid, "kind": "interpreter", "line": line, "provenance": "runtime"}
            if line is None:
                rec["reason"] = "no line number for the current instruction"
            frames.append(rec)
            f = f.f_back
        omitted = 0
        while f is not None and omitted < 1 << 20:
            omitted += 1
            f = f.f_back
        if regions:
            if frame.f_code in _REGION_CODES:
                # Blocked entering/leaving a region: the declaration is in flux.
                self.annotations_dropped += 1
            else:
                frames = self._annotate(frames, len(frames) + omitted, regions)
        return frames, omitted

    def _annotate(self, frames, depth, regions):
        # regions record the caller depth (outermost = 1) of each native call;
        # shallower markers are inserted first so indices stay in original order.
        captured = len(frames)
        for label, entry_depth in sorted(regions, key=lambda r: r[1]):
            index = depth - entry_depth
            if entry_depth > depth or index > captured:
                self.annotations_dropped += 1
                continue
            marker = {"function": None, "kind": "native_transition", "line": None,
                      "provenance": "cooperative_annotation", "label": label,
                      "reason": "program-declared native call; native frames not observed"}
            frames.insert(index, marker)
        return frames

    def _stack(self, seq, tid, start, end, trigger, frames, omitted, exception=None):
        self.stacks += 1
        rec = {"type": "stack", "id": "s%d" % self.stacks, "acquisition": seq, "thread": tid,
               "start_ns": str(start), "end_ns": str(end), "trigger": trigger, "weight": "1",
               "state": "truncated" if omitted else "complete", "omitted": str(omitted) if omitted else None,
               "reason": "max_depth %d reached" % self.max_depth if omitted else None,
               "exception": exception, "frames": frames}
        self._write(rec)

    # -- acquisition paths ---------------------------------------------------
    def sample(self):
        me = threading.get_ident()
        with self.lock:
            regions = {k: list(v) for k, v in self.regions.items()}
            start = time.monotonic_ns()
            snapshot = sys._current_frames()
            by_ident = {t.ident: t for t in threading.enumerate()}
            items = []
            for ident, frame in snapshot.items():
                if ident == me:
                    continue
                items.append((ident, self._frames(frame, ident, regions.get(ident))))
            del snapshot
            end = time.monotonic_ns()
            self.seq += 1
            self._write({"type": "acquisition", "seq": self.seq, "start_ns": str(start), "end_ns": str(end),
                         "stacks": len(items)})
            for ident, (frames, omitted) in items:
                tid = self._thread(ident, by_ident.get(ident))
                self._stack(self.seq, tid, start, end, "timer", frames, omitted)
            self.cost_ns += end - start

    def emit_here(self, trigger="explicit"):
        """Cooperatively emit the caller's own stack (exporter frame excluded)."""
        with self.lock:
            start = time.monotonic_ns()
            frames, omitted = self._frames(sys._getframe(1), regions=self.regions.get(threading.get_ident()))
            end = time.monotonic_ns()
            self.seq += 1
            self._write({"type": "acquisition", "seq": self.seq, "start_ns": str(start), "end_ns": str(end),
                         "stacks": 1})
            t = threading.current_thread()
            self._stack(self.seq, self._thread(t.ident, t), start, end, trigger, frames, omitted)

    def emit_exception(self, exc):
        """Emit the raise-site stack of a caught exception from the current thread."""
        with self.lock:
            start = time.monotonic_ns()
            tb = exc.__traceback__
            inner = []
            while tb is not None and len(inner) < self.max_depth:
                fid = self._function(tb.tb_frame.f_code)
                inner.append({"function": fid, "kind": "interpreter", "line": tb.tb_lineno, "provenance": "runtime"})
                tb = tb.tb_next
            inner.reverse()
            outer, omitted = self._frames(exc.__traceback__.tb_frame.f_back) if exc.__traceback__ else ([], 0)
            frames = (inner + outer)[:self.max_depth]
            omitted += len(inner) + len(outer) - len(frames)
            end = time.monotonic_ns()
            self.seq += 1
            self._write({"type": "acquisition", "seq": self.seq, "start_ns": str(start), "end_ns": str(end),
                         "stacks": 1})
            t = threading.current_thread()
            self._stack(self.seq, self._thread(t.ident, t), start, end, "exception", frames, omitted,
                        {"type": type(exc).__module__ + "." + type(exc).__qualname__, "message": str(exc)[:512]})

    # -- cooperative native annotation ---------------------------------------
    class _Region:
        def __init__(self, exporter, label):
            self.exporter, self.label = exporter, label

        def __enter__(self):
            depth = 0
            f = sys._getframe(1)
            while f is not None:
                depth += 1
                f = f.f_back
            e = self.exporter
            with e.lock:
                e.regions.setdefault(threading.get_ident(), []).append((self.label, depth))
            return self

        def __exit__(self, *exc):
            e = self.exporter
            with e.lock:
                stack = e.regions.get(threading.get_ident())
                stack.pop()
                if not stack:
                    del e.regions[threading.get_ident()]
            return False

    def native_region(self, label):
        return Exporter._Region(self, label)

    # -- lifecycle -------------------------------------------------------------
    def _run(self):
        threading.current_thread().name = "xodb-lframes-sampler"
        next_tick = time.monotonic_ns() + self.interval_ns
        while not self.stop_event.wait(max(0, next_tick - time.monotonic_ns()) / 1e9):
            self.sample()
            now = time.monotonic_ns()
            next_tick += self.interval_ns
            missed = (now - next_tick) // self.interval_ns if now > next_tick else 0
            if missed:
                # Late by whole intervals: those ticks are skipped, not sampled late.
                next_tick += missed * self.interval_ns
                self.lost_ticks += missed
                with self.lock:
                    self._write({"type": "loss", "reason": "timer_overrun", "count": str(missed),
                                 "acquisition": self.seq})

    def start(self):
        self.sampler = threading.Thread(target=self._run, name="xodb-lframes-sampler", daemon=True)
        self.sampler.start()

    def stop(self, status="complete"):
        self.stop_event.set()
        if self.sampler is not None:
            self.sampler.join()
        with self.lock:
            self._write({"type": "end", "records": self.records, "acquisitions": self.seq, "stacks": self.stacks,
                         "status": status})
            self.out.close()
        return {"acquisitions": self.seq, "stacks": self.stacks, "records": self.records,
                "sampling_cost_ns": self.cost_ns, "lost_ticks": self.lost_ticks,
                "annotations_dropped": self.annotations_dropped}


_REGION_CODES = (Exporter._Region.__enter__.__code__, Exporter._Region.__exit__.__code__)
