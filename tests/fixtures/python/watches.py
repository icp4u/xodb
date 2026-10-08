"""Owned stopped-watch fixture; the oracle runs only in this cooperating program."""
import gc
import json
import struct
import sys
import xodb_named


def describe(value):
    kind = type(value)
    if value is None:
        return {"kind": 0, "sample": ""}
    if kind is bool:
        return {"kind": 1, "sample": bytes([value]).hex()}
    if kind is int:
        magnitude = abs(value)
        raw = bytes([1 if not magnitude else 2 if value < 0 else 0])
        while magnitude:
            raw += struct.pack("<I", magnitude & ((1 << 30) - 1))
            magnitude >>= 30
        return {"kind": 2, "sample": raw.hex()}
    if kind is float:
        return {"kind": 3, "sample": struct.pack("<d", value).hex()}
    if kind is str:
        return {"kind": 4, "sample": value.encode("utf-32-le", errors="surrogatepass").hex()}
    if kind is bytes:
        return {"kind": 5, "sample": value.hex()}
    return {"reason": "PythonWatchValueUnsupported"}


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
    print(json.dumps({"label": label, "frames": frames}), flush=True)
    xodb_named.snapshot(pairs)


def grow(depth):
    if depth:
        grow(depth - 1)
    else:
        probe("deep")


def outer():
    captured = 73
    def watched(reuse=False):
        nonlocal captured
        x, cell_local = 7, 9
        text, blob = "a" * 300 + "x", b"\0" + b"a" * 300 + b"x"
        huge, object_value = "z" * 1025, []
        number = 1 << 1200
        zero = 0.0
        nan = struct.unpack("<d", bytes.fromhex("010000000000f87f"))[0]
        deleted = 1
        del deleted
        def hold():
            return cell_local
        if reuse:
            probe("reuse")
            return
        probe("initial")
        x, captured, cell_local = 8, 74, 10
        text, blob = text[:-1] + "y", blob[:-1] + b"y"
        number += 7
        zero = -0.0
        nan = struct.unpack("<d", bytes.fromhex("020000000000f87f"))[0]
        gc.collect()
        probe("changed")
        probe("equal")
        del x
        probe("unbound")
        x, huge, object_value, deleted = None, "small", False, 42
        probe("recovered")
        grow(12)
        assert hold() == 10
    watched()
    probe("retired")
    iterator = generator()
    next(iterator)
    probe("generator-suspended")
    next(iterator)
    iterator.close()
    probe("generator-closed")
    watched(True)
    co = coroutine()
    co.send(None)
    probe("coroutine-suspended")
    try:
        co.send(None)
    except StopIteration:
        pass
    probe("coroutine-closed")


def generator():
    value = 42
    probe("generator-first")
    yield value
    value = 43
    probe("generator-resumed")
    yield value


class Pause:
    def __await__(self):
        yield None


async def coroutine():
    value = 51
    probe("coroutine-first")
    await Pause()
    value = 52
    probe("coroutine-resumed")


print("ready", flush=True)
assert sys.stdin.readline().strip() == "go"
outer()
