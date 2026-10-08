"""Owned f_locals oracle: no oracle operation is performed by xodb."""
import json
import os
import sys
import xodb_named


def describe(value):
    kind = type(value).__name__
    result = {"address": id(value), "type": kind}
    if type(value) is int:
        result["display"] = "int " + str(value)
    elif value is None or type(value) is bool:
        result["display"] = repr(value)
    elif type(value) is str:
        result["display"] = "str " + repr(value)
    elif type(value) in (list, tuple, dict):
        result["count"] = len(value)
    return result


def probe(label):
    pairs, frames = [], []
    frame = sys._getframe(1)
    while frame:
        if frame.f_code.co_filename == __file__ and frame.f_code.co_flags & 1:
            bindings = dict(frame.f_locals)
            pairs.append((frame, bindings))
            frames.append({"code": id(frame.f_code), "name": frame.f_code.co_qualname,
                           "bindings": {name: describe(value) for name, value in bindings.items()}})
        frame = frame.f_back
    if os.environ.get("XODB_PYTHON_NAMED_EXPORT"):
        print(json.dumps({"label": label, "frames": frames}), flush=True)
    xodb_named.snapshot(pairs)


def recursive(depth, payload, *, flag=True):
    local = depth + 100
    deleted = -1
    del deleted
    if depth:
        recursive(depth - 1, payload, flag=flag)
    else:
        probe("recursion")
    return local


def outer(seed):
    captured = seed + 40
    unbound = 12
    def inner(argument, *args, keyword=9, **kwargs):
        nonlocal captured
        captured += 1
        α = 17
        cell_local = 18
        def use_cell():
            return cell_local
        probe("closure")
        return argument, args, keyword, kwargs, captured, α, use_cell
    def empty_cell():
        probe("empty-cell")
        return unbound
    del unbound
    inner(3, 4, 5, keyword=6, supplied=7)
    try:
        empty_cell()
    except NameError:
        pass


def generator(base):
    local = base + 7
    probe("generator-first")
    yield local
    local += 1
    probe("generator-resumed")
    yield local


async def coroutine(base):
    local = base + 8
    probe("coroutine")
    return local


def callback(value):
    text = "owned"
    probe("mixed-lua-python" if value == 49 else "native-callback")
    return value, text


def main():
    recursive(3, [1, 2, 3])
    outer(2)
    iterator = generator(10)
    next(iterator)
    next(iterator)
    co = coroutine(20)
    try:
        co.send(None)
    except StopIteration:
        pass
    sorted([3], key=callback)
    if hasattr(xodb_named, "lua_call"):
        xodb_named.lua_call(callback)
    xodb_named.finished()


if os.environ.get("XODB_PYTHON_NAMED_READY"):
    print("ready", flush=True)
    assert sys.stdin.readline().strip() == "go"
main()
