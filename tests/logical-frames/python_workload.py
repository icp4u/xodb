"""Owned CPython workload for logical-frame export (draft C05-1).

Threads: py-fib (recursion), py-nested (fixed nesting, blocks in sleep),
py-qsort (libc qsort calling a Python comparator: a real native transition,
declared by cooperative annotation), py-raiser (recursive raise, caught and
exported). Usage: python_workload.py OUT.jsonl META.json [seconds] [interval_ms] [--no-export]
"""
import ctypes
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "logical-frames"))
import xodb_lframes  # noqa: E402

out_path, meta_path = sys.argv[1], sys.argv[2]
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
interval_ms = float(sys.argv[4]) if len(sys.argv) > 4 else 5.0
export = "--no-export" not in sys.argv
stop = threading.Event()
counts = {}
exporter = xodb_lframes.Exporter(out_path, interval_s=interval_ms / 1000.0) if export else None


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


def fib_worker():
    n = 0
    while not stop.is_set():
        fib(16)
        n += 1
    counts["py-fib"] = n


def nested_d():
    time.sleep(0.003)


def nested_c():
    nested_d()


def nested_b():
    nested_c()


def nested_a():
    nested_b()


def nested_worker():
    n = 0
    while not stop.is_set():
        nested_a()
        n += 1
    counts["py-nested"] = n


libc = ctypes.CDLL(None)
CMP = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int))


def compare_work(x, y):
    # Enough interpreter work that samples can land inside the callback.
    spin = 0
    for i in range(40):
        spin += i
    return (x > y) - (x < y)


emit_from_callback = threading.Event()


def compare(a, b):
    if emit_from_callback.is_set():
        # Cooperative emit from inside the native qsort's callback.
        emit_from_callback.clear()
        exporter.emit_here("explicit")
    return compare_work(a[0], b[0])


comparator = CMP(compare)


def sort_with_qsort(values):
    array = (ctypes.c_int * len(values))(*values)
    if exporter:
        with exporter.native_region("libc.so.6:qsort"):
            libc.qsort(array, len(values), ctypes.sizeof(ctypes.c_int), comparator)
    else:
        libc.qsort(array, len(values), ctypes.sizeof(ctypes.c_int), comparator)
    return list(array)


def qsort_worker():
    n = 0
    values = [(i * 7919) % 1009 for i in range(400)]
    while not stop.is_set():
        if exporter:
            emit_from_callback.set()
        assert sort_with_qsort(values) == sorted(values)
        n += 1
    counts["py-qsort"] = n


def raise_at_depth(depth):
    if depth == 0:
        raise ValueError("fixture failure at depth 0")
    raise_at_depth(depth - 1)


def raiser_worker():
    n = 0
    while not stop.is_set():
        try:
            raise_at_depth(5)
        except ValueError as e:
            if exporter:
                exporter.emit_exception(e)
        n += 1
        stop.wait(0.05)
    counts["py-raiser"] = n


def explicit_leaf():
    if exporter:
        exporter.emit_here("explicit")


def explicit_mid():
    explicit_leaf()


def explicit_top():
    explicit_mid()


workers = [threading.Thread(target=f, name=name) for name, f in (
    ("py-fib", fib_worker), ("py-nested", nested_worker), ("py-qsort", qsort_worker), ("py-raiser", raiser_worker))]
started = time.monotonic_ns()
if exporter:
    exporter.start()
for t in workers:
    t.start()
explicit_top()
time.sleep(seconds)
stop.set()
for t in workers:
    t.join()
elapsed = time.monotonic_ns() - started
stats = exporter.stop() if exporter else None
with open(meta_path, "w") as f:
    json.dump({"runtime": sys.version, "executable": sys.executable, "pid": os.getpid(), "seconds": seconds,
               "interval_ms": interval_ms, "export": export, "elapsed_ns": elapsed, "iterations": counts,
               "exporter": stats, "native_ids": {t.name: t.native_id for t in workers}}, f, indent=1)
