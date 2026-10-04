#!/usr/bin/env python3
"""Run the T04 profiling workloads with bounded, explicit parameters.

    tests/workloads/run.py presets     baseline and impaired runs; needs no tools
    tests/workloads/run.py attribute   can perf/strace evidence name each known cause?
    tests/workloads/run.py overhead    cost and event loss of the available tools
    tests/workloads/run.py all

Build first with tests/workloads/build.sh. Every run is a few seconds, uses at
most 13 threads, and writes only under .work/workloads-<timestamp>/. Nothing
here needs root, changes kernel settings, or installs anything; `attribute` and
`overhead` use perf and strace as an unprivileged user and say what they could
not do.
"""
import collections
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "out")
FRAMELOOP = os.path.join(OUT, "frameloop")
REQSERVER = os.path.join(OUT, "reqserver")
CAUSES = ["none", "cpu", "lock", "job", "alloc", "io"]
FRAMES = ["--frames", "300"]  # 5 s at the 60 Hz pace
SERVER = {
    "baseline": ["--workers", "4", "--rate", "4000", "--work", "100000", "--hold", "2000", "--shards", "16"],
    "queue-pressure": ["--workers", "2", "--rate", "8000", "--work", "400000", "--hold", "2000", "--shards", "16"],
    "lock-contention": ["--workers", "8", "--rate", "4000", "--work", "20000", "--hold", "150000", "--shards", "1"],
    "baseline-socket": ["--workers", "4", "--rate", "4000", "--work", "100000", "--hold", "2000", "--shards", "16", "--transport", "socket"],
}
RECORD = ["perf", "record", "-q", "-k", "CLOCK_MONOTONIC", "--call-graph", "fp", "--switch-events"]
TIMEOUT = 90  # hard bound per run, far above the expected few seconds


def run(args, prefix=(), log=None):
    """Runs a workload, optionally under a tool, and returns its JSON summary."""
    done = subprocess.run([*prefix, *args], capture_output=True, text=True, timeout=TIMEOUT, cwd=WORK)
    if log:
        with open(os.path.join(WORK, log), "w") as f:
            f.write(done.stderr)
    start = done.stdout.find('{"workload"')
    if done.returncode != 0 or start < 0:
        raise RuntimeError(f"{' '.join(args)} failed ({done.returncode}): {done.stderr[-400:]}")
    return json.loads(done.stdout[start:])


def table(headers, rows):
    print("| " + " | ".join(headers) + " |")
    print("| " + " | ".join("---" for _ in headers) + " |")
    for row in rows:
        print("| " + " | ".join(str(cell) for cell in row) + " |")
    print()


def presets():
    """Baseline and deliberately impaired runs, as measured by the programs themselves."""
    results = {"frameloop": {}, "reqserver": {}}
    rows = []
    for cause in CAUSES:
        r = run([FRAMELOOP, "--stall", cause, *FRAMES])
        results["frameloop"][cause] = r
        stalls = r["stalls"]
        mean = lambda key: round(sum(s[key] for s in stalls) / len(stalls) / 1000, 1) if stalls else "-"
        rows.append([cause, r["work_us"]["p50"] / 1000, r["work_us"]["max"] / 1000, r["over_budget"], r["over_budget_not_injected"], mean("update_us"), mean("render_us"), mean("wait_us"), r["rusage"]["minor_faults"], r["rusage"]["voluntary_switches"]])
    print("frameloop: 300 frames, 4 workers, 16 jobs per frame, 16.667 ms pace and budget, seed 1\n")
    table(["stall", "work p50 ms", "work max ms", "frames over budget", "of those not injected", "stalled update ms", "stalled render ms", "stalled wait ms", "minor faults", "voluntary switches"], rows)
    rows = []
    for name, args in SERVER.items():
        r = run([REQSERVER, *args])
        results["reqserver"][name] = r
        share = lambda key: f"{r[key]['share']:.0%}"
        rows.append([name, r["sent"], r["dropped"], r["throughput"], r["latency_us"]["p50"], r["latency_us"]["p99"], share("queue_wait_us"), share("lock_wait_us"), share("service_us"), r["max_queue_depth"]])
    print("reqserver: 4 s, 4 open-loop clients, Poisson arrivals, seed 1\n")
    table(["preset", "sent", "dropped", "req/s", "latency p50 us", "latency p99 us", "queue wait", "lock wait", "service", "max queue depth"], rows)
    return results


HEADER = re.compile(r"^\s*(\S+)\s+(\d+)\s+(\d+\.\d+):\s+(.*)$")


def perf_script(data):
    """Yields (comm, tid, seconds, event, [symbols innermost first]) from a perf.data file.

    --no-inline keeps one line per physical frame; with inline expansion perf shows a
    GCC clone such as stall_cpu_hot_path.isra.0 as "stall_cpu_hot_path (inlined)".
    """
    text = subprocess.run(["perf", "script", "-i", data, "--ns", "--no-inline", "-F", "comm,tid,time,event,ip,sym", "--show-switch-events"], capture_output=True, text=True, cwd=WORK).stdout
    current = None
    for line in text.splitlines():
        match = HEADER.match(line)
        if match:
            if current:
                yield current
            comm, tid, seconds, rest = match.groups()
            if rest.startswith("PERF_RECORD_SWITCH"):
                event = "switch-out" if " OUT" in rest else "switch-in"
            else:
                event = rest.split(":")[0].split("/")[0]
            current = (comm, int(tid), float(seconds), event, [])
        elif current and line.strip():
            parts = line.split()
            current[4].append(parts[1].split(".")[0] if len(parts) > 1 else "?")  # drop GCC clone suffixes such as .isra.0
    if current:
        yield current


def blame(stack):
    """The function a sample is charged to: a stall_* frame if present, else the innermost frame above the shared work loop."""
    for symbol in stack:
        if symbol.startswith("stall_"):
            return symbol
    for symbol in stack:
        if symbol not in ("burn", "[unknown]"):
            return symbol
    return "?"


def perf_stats(data):
    text = subprocess.run(["perf", "report", "-i", data, "--stats"], capture_output=True, text=True, cwd=WORK).stdout
    find = lambda name: sum(int(n) for n in re.findall(rf"^\s*{name}[^:]*:\s+(\d+)", text, re.M)[:1])
    return {"samples": find("SAMPLE events"), "switches": find("SWITCH events"), "lost": find("LOST events"), "lost_samples": find("LOST_SAMPLES events"), "bytes": os.path.getsize(os.path.join(WORK, data))}


def off_cpu(events, tid, windows):
    """Fraction of the windows that thread `tid` spent switched out."""
    out_at, blocked = None, 0.0
    for _, event_tid, t, event, _ in events:
        if event_tid != tid:
            continue
        if event == "switch-out":
            out_at = t
        elif event == "switch-in" and out_at is not None:
            for start, end in windows:
                blocked += max(0.0, min(end, t) - max(start, out_at))
            out_at = None
    total = sum(end - start for start, end in windows)
    return blocked / total if total else 0.0


def strace_blocking(args, main_only=True, slower_than=0.005):
    """Time in blocking syscalls longer than `slower_than` seconds, by the nearest workload function on the stack."""
    path = os.path.join(WORK, "strace.txt")
    subprocess.run(["strace", "-f", "-k", "-T", "-e", "trace=futex,read,nanosleep,clock_nanosleep", "-o", path, *args], capture_output=True, timeout=TIMEOUT, cwd=WORK)
    slow = collections.Counter()
    main_pid, pending, call_of = None, None, {}
    for line in open(path, errors="replace"):
        if line.startswith(" > "):
            if pending:
                match = re.search(r"\(([\w.]+)\+0x", line)
                if match and "/out/" in line:
                    slow[(pending[0], match.group(1).split(".")[0])] += pending[1]
                    pending = None
            continue
        pending = None
        match = re.match(r"^(\d+)\s+(.*)$", line)
        if not match:
            continue
        pid, rest = int(match.group(1)), match.group(2)
        main_pid = main_pid or pid
        started = re.match(r"^(\w+)\(", rest)
        if started:
            call_of[pid] = started.group(1)
        duration = re.search(r"<(\d+\.\d+)>\s*$", rest)
        if duration and float(duration.group(1)) > slower_than and (pid == main_pid or not main_only):
            name = call_of.get(pid, "?")
            if name != "clock_nanosleep":  # frame pacing, not a stall
                pending = (name, float(duration.group(1)))
    if slower_than == 0:  # whole-run view: shares, because strace stretches the run
        total = sum(slow.values()) or 1
        return [f"{call} from {symbol}: {seconds / total:.0%}" for (call, symbol), seconds in slow.most_common(3)]
    return [f"{call} from {symbol}: {seconds * 1000:.0f} ms" for (call, symbol), seconds in slow.most_common(2)]


def attribute():
    """For each known cause: what unprivileged perf and strace evidence shows inside the stalled frames."""
    results = {}
    rows = []
    for cause in CAUSES[1:]:
        data, frames_csv = f"frameloop-{cause}.data", f"frameloop-{cause}.csv"
        truth = run([FRAMELOOP, "--stall", cause, *FRAMES, "--csv", frames_csv], prefix=[*RECORD, "-e", "cycles/freq=4000/u", "-e", "page-faults/period=1/u", "-o", data, "--"])
        frames = list(csv.DictReader(open(os.path.join(WORK, frames_csv))))
        span = lambda f: (int(f["start_us"]) / 1e6, (int(f["start_us"]) + int(f["work_us"])) / 1e6)
        stalled = [span(f) for f in frames if f["injected"] == "1"]
        normal = [span(f) for f in frames if f["injected"] == "0"]
        inside = lambda t, windows: any(start <= t <= end for start, end in windows)
        events = list(perf_script(data))
        main_tid = next(tid for comm, tid, _, _, _ in events if comm == "main")
        cycles = {"stalled": collections.Counter(), "normal": collections.Counter()}
        faults = collections.Counter()
        for comm, tid, t, event, stack in events:
            thread = "main" if tid == main_tid else "worker" if comm.startswith("worker") else comm
            if event == "cycles":
                kind = "stalled" if inside(t, stalled) else "normal" if inside(t, normal) else None
                if kind:
                    cycles[kind][(thread, blame(stack))] += 1
            elif event == "page-faults" and inside(t, stalled):
                faults[(thread, blame(stack))] += 1
        # Samples per second of window time, stalled frames minus normal frames: what is extra during a stall.
        seconds = {"stalled": sum(e - s for s, e in stalled), "normal": sum(e - s for s, e in normal)}
        excess = {key: cycles["stalled"][key] / seconds["stalled"] - cycles["normal"][key] / seconds["normal"] for key in cycles["stalled"]}
        top = max(excess, key=excess.get) if excess else None
        top_text = f"{top[1]} on {top[0]} (+{excess[top]:.0f}/s)" if top and excess[top] > 400 else "none"
        fault_top = faults.most_common(1)
        fault_text = f"{fault_top[0][0][1]}: {fault_top[0][1]}" if fault_top and fault_top[0][1] > 1000 else "few"
        blocked = off_cpu(events, main_tid, stalled)
        blocking = strace_blocking([FRAMELOOP, "--stall", cause, "--frames", "170"]) if cause in ("lock", "job", "io") else []
        named = truth["ground_truth"]["symbol"] in (top_text + fault_text + " ".join(blocking))
        results[cause] = {"truth": truth["ground_truth"], "excess_cycles": top_text, "page_faults": fault_text, "main_off_cpu": round(blocked, 2), "blocking_calls": blocking, "truth_symbol_named": named, "perf": perf_stats(data)}
        rows.append([cause, truth["ground_truth"]["symbol"], top_text, fault_text, f"{blocked:.0%}", "; ".join(blocking) or "not run", "yes" if named else "NO"])
    print("frameloop: evidence inside the injected stall frames (perf record cycles:u at 4 kHz, page faults, switch events; strace -k for blocking calls)\n")
    table(["stall", "known cause", "extra on-CPU samples", "page-fault samples", "main thread off-CPU", "slow syscalls on main (strace)", "cause named"], rows)

    rows = []
    for name in ("baseline", "queue-pressure", "lock-contention"):
        data = f"reqserver-{name}.data"
        truth = run([REQSERVER, *SERVER[name]], prefix=[*RECORD, "-e", "cycles/freq=4000/u", "-o", data, "--"])
        events = list(perf_script(data))
        workers = sorted({tid for comm, tid, _, _, _ in events if comm.startswith("worker")})
        times = [t for comm, _, t, _, _ in events if comm.startswith("client")]
        window = [(min(times), max(times))] if times else []
        busy = [1 - off_cpu(events, tid, window) for tid in workers]
        symbols = collections.Counter(blame(stack) for comm, _, _, event, stack in events if event == "cycles" and comm.startswith("worker"))
        total = sum(symbols.values()) or 1
        top = ", ".join(f"{symbol} {count / total:.0%}" for symbol, count in symbols.most_common(2))
        futex = subprocess.run(["strace", "-f", "-c", "-e", "trace=futex", "-o", os.path.join(WORK, "futex.txt"), REQSERVER, *SERVER[name]], capture_output=True, text=True, timeout=TIMEOUT, cwd=WORK)
        calls = re.search(r"^\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(?:\d+\s+)?futex", open(os.path.join(WORK, "futex.txt")).read(), re.M)
        traced = json.loads(futex.stdout[futex.stdout.find('{"workload"'):]) if '{"workload"' in futex.stdout else {"completed": 0}
        per_request = int(calls.group(1)) / traced["completed"] if calls and traced["completed"] else float("nan")
        # Where threads block, by call site: waiting for work (take) or waiting for a lock (update_shared).
        blocked = strace_blocking([REQSERVER, *SERVER[name], "--seconds", "2"], main_only=False, slower_than=0)
        share = lambda key: f"{truth[key]['share']:.0%}"
        results[name] = {"truth": {k: truth[k] for k in ("latency_us", "queue_wait_us", "lock_wait_us", "service_us", "dropped", "throughput")}, "worker_on_cpu": [round(b, 2) for b in busy], "top_symbols": top, "futex_per_request": round(per_request, 2), "blocked_by_call_site": blocked, "perf": perf_stats(data)}
        rows.append([name, f"{share('queue_wait_us')} / {share('lock_wait_us')} / {share('service_us')}", truth["dropped"], f"{sum(busy) / len(busy):.0%}" if busy else "-", top, f"{per_request:.1f}", "; ".join(blocked) or "none"])
    print("reqserver: the program's own latency split beside what perf and strace see from outside\n")
    table(["preset", "queue / lock / service share (ground truth)", "dropped", "mean worker on-CPU", "worker on-CPU samples", "futex calls per request", "share of blocked time by call site (strace -k)"], rows)
    return results


def overhead():
    """What each available tool costs these workloads, and whether it lost events."""
    tools = [
        ("none (1)", [], None), ("none (2)", [], None), ("none (3)", [], None),
        ("perf stat", ["perf", "stat", "-o", "stat.txt", "--"], None),
        ("perf record 1 kHz fp", ["perf", "record", "-q", "-e", "cycles/freq=1000/u", "--call-graph", "fp", "-o", "o.data", "--"], "o.data"),
        ("perf record 4 kHz fp", ["perf", "record", "-q", "-e", "cycles/freq=4000/u", "--call-graph", "fp", "-o", "o.data", "--"], "o.data"),
        ("perf record 20 kHz fp", ["perf", "record", "-q", "-e", "cycles/freq=20000/u", "--call-graph", "fp", "-o", "o.data", "--"], "o.data"),
        ("perf record 4 kHz dwarf", ["perf", "record", "-q", "-e", "cycles/freq=4000/u", "--call-graph", "dwarf", "-o", "o.data", "--"], "o.data"),
        ("perf record 4 kHz fp + switch events", ["perf", "record", "-q", "-e", "cycles/freq=4000/u", "--call-graph", "fp", "--switch-events", "-o", "o.data", "--"], "o.data"),
        ("strace -f -c", ["strace", "-f", "-c", "-o", "strace-c.txt"], None),
        ("strace -f -k futex,read", ["strace", "-f", "-k", "-T", "-e", "trace=futex,read", "-o", "strace-k.txt"], None),
    ]
    results, rows = [], []
    for label, prefix, data in tools:
        frame = run([FRAMELOOP, "--stall", "none", "--frames", "240"], prefix=prefix, log="tool.err")
        frame_stats = perf_stats(data) if data else {}
        server = run([REQSERVER, *SERVER["queue-pressure"], "--seconds", "3"], prefix=prefix, log="tool.err")
        server_stats = perf_stats(data) if data else {}
        calm = run([REQSERVER, *SERVER["baseline"], "--seconds", "3"], prefix=prefix, log="tool.err")
        results.append({"tool": label, "frame_work_us": frame["work_us"], "saturated_throughput": server["throughput"], "baseline_latency_us": calm["latency_us"], "frameloop_perf": frame_stats, "reqserver_perf": server_stats})
        lost = frame_stats.get("lost", 0) + frame_stats.get("lost_samples", 0) + server_stats.get("lost", 0) + server_stats.get("lost_samples", 0) if data else "-"
        rows.append([label, frame["work_us"]["p50"], frame["work_us"]["p99"], server["throughput"], calm["latency_us"]["p50"], calm["latency_us"]["p99"], frame_stats.get("samples", "-"), f"{frame_stats['bytes'] / 1e6:.1f}" if data else "-", lost])
    print("tool cost: frameloop work time (240 frames, no stall), reqserver throughput when saturated (queue-pressure), reqserver latency when calm (baseline)\n")
    table(["tool", "frame work p50 us", "frame work p99 us", "saturated req/s", "calm latency p50 us", "calm latency p99 us", "frameloop samples", "frameloop perf.data MB", "lost events"], rows)
    return results


def main():
    global WORK
    mode = sys.argv[1] if len(sys.argv) > 1 else "presets"
    if mode not in ("presets", "attribute", "overhead", "all"):
        sys.exit(__doc__)
    if not (os.path.exists(FRAMELOOP) and os.path.exists(REQSERVER)):
        sys.exit("build first: tests/workloads/build.sh")
    if mode != "presets":
        for tool in ("perf", "strace"):
            if not shutil.which(tool):
                sys.exit(f"{tool} is not installed; `presets` needs no tools")
    WORK = os.path.join(ROOT, ".work", "workloads-" + datetime.now().strftime("%Y%m%dT%H%M%S"))
    os.makedirs(WORK)
    started = time.monotonic()
    results = {"mode": mode, "started": datetime.now().isoformat(timespec="seconds")}
    if mode in ("presets", "all"):
        results["presets"] = presets()
    if mode in ("attribute", "all"):
        results["attribute"] = attribute()
    if mode in ("overhead", "all"):
        results["overhead"] = overhead()
    with open(os.path.join(WORK, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    print(f"{time.monotonic() - started:.0f} s; artifacts in {os.path.relpath(WORK, ROOT)}")


if __name__ == "__main__":
    main()
