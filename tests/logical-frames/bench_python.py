"""Fixed-work overhead benchmark: one worker computes fib(N) K times.
usage: bench_python.py OUT.jsonl INTERVAL_MS(0=no exporter) N K -> prints JSON."""
import json, os, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "logical-frames"))
import xodb_lframes
out, interval, n, k = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def fib(x):
    return x if x < 2 else fib(x - 1) + fib(x - 2)
exporter = xodb_lframes.Exporter(out, interval_s=interval / 1000) if interval > 0 else None
if exporter:
    exporter.start()
result = {}
def work():
    t0, c0 = time.monotonic_ns(), time.thread_time_ns()
    for _ in range(k):
        fib(n)
    result.update(wall_ns=time.monotonic_ns() - t0, worker_cpu_ns=time.thread_time_ns() - c0)
t = threading.Thread(target=work, name="bench-worker")
p0 = time.process_time_ns()
t.start(); t.join()
stats = exporter.stop() if exporter else None
print(json.dumps(dict(result, process_cpu_ns=time.process_time_ns() - p0, interval_ms=interval, exporter=stats)))
