# Owned CPython fixture for tests/python-language.py and tests/python-gui.py.
# Prints "ready" once its dict store site is warm (specialized to call
# _PyDict_SetItem_Take2 where that symbol exists and is not inlined), then
# waits for "go" on stdin before the mode runs. Every store also calls
# os.getpid(), so libc getpid is a stop that fires with any CPython build.
# Lines marked "# @name" are located by the tests; keep each marker unique.
import os
import sys
import threading
import time


def store(table, key, value):
    table[key] = value  # @store
    os.getpid()  # @hit


class Plain:
    pass


class Text(str):
    pass


CLEARED = {"gone": 1}
CLEARED.clear()

CASES = [
    ("none", None),
    ("true", True),
    ("small", 42),
    ("negative", -7),
    ("big", -(2**100) - 5),
    ("float", 3.25),
    ("ascii", "hello"),
    ("latin1", "héllo"),
    ("ucs2", "λ x"),
    ("ucs4", "\U0001f600"),
    ("long", "x" * 300),
    ("bytes", b"raw\x00bytes"),
    ("list", [1, "two", 3.0, None]),
    ("tuple", ("t", 1)),
    ("dict", {"answer": 42}),
    ("empty", {}),
    ("cleared", CLEARED),
    ("plain", Plain()),
    ("type", int),
    ("subclass", Text("sub")),
]


def values(table):
    for key, value in CASES:
        store(table, key, value)  # @values


def c(table):
    store(table, "answer", [1, 2, 3])  # @c


def b(table):
    c(table)  # @b


def a(table):
    b(table)  # @a


def gen(table):
    while True:
        store(table, "gen", 1)  # @gen
        yield


def consume(table):
    for _ in gen(table):  # @consume
        pass


async def coro(table):
    store(table, "coro", 1)  # @coro


def drive(table):
    co = coro(table)
    try:
        co.send(None)  # @drive
    except StopIteration:
        pass


def sorted3(table):
    # Two C-level sorted() calls: three interpreter-loop activations.
    return sorted([1], key=lambda x: sorted([2], key=lambda y: store(table, "sorted", y)))  # @sorted3


def deep_inner(table):
    sorted([1], key=lambda x: deep(table, 200))  # @deepinner


def deep(table, n):
    if n:
        return deep(table, n - 1)  # @deep
    store(table, "deep", n)  # @deepstore


def worker(table):
    while True:
        store(table, "worker", 1)  # @worker


def wait_main():
    time.sleep(60)  # @sleep


SUB = '''
import os
def store(table, key, value):
    table[key] = value
    os.getpid()
def run():
    table = {}
    while True:
        store(table, "sub", 1)  # @subrun
run()
'''


def subinterp(interp):
    interp.exec(SUB)  # @subexec


mode = sys.argv[1]
table = {}
for i in range(200):
    store(table, "warm", i)
sys.setrecursionlimit(20000)
if mode == "subinterp":
    from concurrent import interpreters
    interp = interpreters.create()
print("ready", flush=True)
assert sys.stdin.readline() == "go\n"
if mode == "values":
    values(table)
elif mode == "nested":
    a(table)  # @module
elif mode == "generator":
    consume(table)
elif mode == "coroutine":
    drive(table)
elif mode == "sorted3":
    sorted3(table)
elif mode == "deepinner":
    deep_inner(table)
elif mode == "deep300":
    deep(table, 300)
elif mode == "deep5000":
    deep(table, 5000)
elif mode == "threads":
    threading.Thread(target=worker, args=(table,), daemon=True).start()
    wait_main()
elif mode == "subinterp":
    subinterp(interp)
time.sleep(60)
