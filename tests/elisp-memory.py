"""Run by GDB; the shared C reader executes in the debugger, never the target."""
import ctypes as C
import json
import os
from pathlib import Path
import re
import time
import traceback
import gdb


class Field(C.Structure):
    _fields_ = [("offset", C.c_uint32), ("size", C.c_uint32)]


source = Path(__file__).resolve().parents[1] / "src/language"
field_count = (source / "elisp_fields.inc").read_text().count("XEL_FIELD(")
type_count = (source / "elisp_types.inc").read_text().count("XEL_TYPE(")
global_names = re.findall(r'XEL_GLOBAL\((\w+),', (source / "elisp_globals.inc").read_text())

class Layout(C.Structure):
    _fields_ = [("fields", Field * field_count), ("sizes", C.c_uint32 * type_count),
                ("build_id", C.c_uint8 * 64), ("build_id_len", C.c_uint8)]


Read = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.c_void_p, C.c_size_t)


class Reader(C.Structure):
    _fields_ = [("context", C.c_void_p), ("read", Read), ("reads", C.c_size_t),
                ("bytes", C.c_size_t), ("error", C.c_char_p)]


class Context(C.Structure):
    _fields_ = [("lispsym", C.c_uint64), ("globals", C.c_uint64 * len(global_names))]


class Frame(C.Structure):
    _fields_ = [("record", C.c_uint64), ("function", C.c_uint64), ("args", C.c_uint64),
                ("depth", C.c_uint64), ("nargs", C.c_int64), ("name", C.c_char * 192),
                ("name_reason", C.c_char_p), ("kind_reason", C.c_char_p), ("active_function", C.c_uint64), ("native_frame", C.c_size_t),
                ("execution_kind", C.c_uint32), ("kind_basis", C.c_char_p)]


class Control(C.Structure):
    _fields_ = [("record", C.c_uint64), ("depth", C.c_uint64), ("kind", C.c_uint32),
                ("runtime_kind", C.c_uint32), ("frame", C.c_size_t), ("reason", C.c_char_p)]


class Stack(C.Structure):
    _fields_ = [("thread", C.c_uint64), ("first", C.c_uint64), ("top", C.c_uint64),
                ("count", C.c_size_t), ("control_count", C.c_size_t), ("frames", Frame * 128),
                ("controls", Control * 256), ("reason", C.c_char_p), ("classification_reason", C.c_char_p)]


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    check(gdb.parameter("may-call-functions") is False, "target calls must be disabled")
    lib = C.CDLL(os.environ["XODB_ELISP_READER"])
    lib.probe_size.argtypes = [C.c_char_p]
    lib.probe_size.restype = C.c_size_t
    for typ in (Layout, Reader, Context, Frame, Control, Stack):
        check(lib.probe_size(("xel_" + typ.__name__.lower()).encode()) == C.sizeof(typ),
              "ctypes/C ABI drift: " + typ.__name__)
    lib.probe_layout.argtypes = [C.c_char_p, C.POINTER(Layout)]
    lib.probe_layout.restype = C.c_char_p
    layout = Layout()
    why = lib.probe_layout(gdb.current_progspace().filename.encode(), C.byref(layout))
    check(why is None, "layout: " + str(why))
    # Independent GDB type traversal corroborates every offset, width and size.
    source = Path(__file__).resolve().parents[1] / "src/language"
    type_rows = re.findall(r'XEL_TYPE\((\w+), "([^"]+)"\)', (source / "elisp_types.inc").read_text())
    types = {key: gdb.lookup_type(("union " if key in ("SPEC", "MAIN") else "struct ") + name)
             for key, name in type_rows}
    for i, (key, _) in enumerate(type_rows):
        check(layout.sizes[i] == types[key].sizeof, "layout type size: " + key)
    field_rows = re.findall(r'XEL_FIELD\((\w+), (\w+), "([^"]+)", (\w+), (\d+)\)',
                            (source / "elisp_fields.inc").read_text())
    for i, (key, owner, path, kind, width) in enumerate(field_rows):
        typ = types[owner]
        bits = 0
        for part in path.split("."):
            field = next(f for f in typ.strip_typedefs().fields() if f.name == part)
            bits += field.bitpos
            typ = field.type
        check(bits % 8 == (1 if kind == "REDIRECT" else 0) and layout.fields[i].offset == bits // 8, "field offset: " + key)
        width = int(width) or typ.sizeof
        check(layout.fields[i].size == int(width), "field width: " + key)
        check(field.bitsize == (2 if kind == "REDIRECT" else 8) if kind in ("BIT8", "REDIRECT") else typ.sizeof == int(width), "GDB width: " + key)

    @Read
    def read(_, address, output, count):
        try:
            C.memmove(output, bytes(gdb.selected_inferior().read_memory(address, count)), count)
            return 0
        except gdb.error:
            return -1

    word = lambda v: int(v.cast(gdb.lookup_type("uintptr_t")))
    def address(name):
        text = gdb.execute("info address " + name, to_string=True)
        match = re.search(r"at address (0x[0-9a-f]+)", text)
        check(match is not None, "global address unavailable: " + text)
        return int(match[1], 16)
    context = Context(word(gdb.parse_and_eval("&lispsym")), (C.c_uint64 * len(global_names))(
        *[address(n) for n in global_names]))
    reader = Reader(None, read, 0, 0, None)
    stack = Stack()
    lib.xel_stack_main.argtypes = [C.POINTER(Layout), C.POINTER(Reader), C.POINTER(Context),
                                  C.c_uint64, C.c_uint64, C.c_int32, C.c_int32, C.POINTER(Stack)]
    lib.xel_stack_main.restype = None
    def rss_bytes():
        return int(Path("/proc/self/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    rss_before = rss_bytes()
    cpu_before = time.process_time_ns()
    os.write(2, b"ELISP_READER_BEGIN\n")
    lib.xel_stack_main(C.byref(layout), C.byref(reader), C.byref(context),
                       address("current_thread"), address("main_thread"),
                       gdb.selected_inferior().pid, gdb.selected_thread().ptid[1], C.byref(stack))
    cpu_ns = time.process_time_ns() - cpu_before
    rss_after = rss_bytes()
    os.write(2, b"ELISP_READER_END\n")
    check(stack.reason is None, "stack: " + str(stack.reason))
    rows = [{"name": f.name.decode(), "nargs": f.nargs} for f in stack.frames[:stack.count]]
    start = next(i for i, f in enumerate(rows) if f["name"] == "xodb-elisp-mark")
    oracle = json.loads(Path(os.environ["XODB_ELISP_ORACLE"]).read_text())
    if os.environ.get("XODB_ELISP_WRONG_ORACLE"):
        oracle["frames"][0]["nargs"] += 1
    check(rows[start:] == oracle["frames"], "full stable stack mismatch: " + repr((rows[start:], oracle["frames"])))
    check(all(f.kind_reason == b"ElispFrameKindUnproved" for f in stack.frames[:stack.count]),
          "unproved activation was classified")
    if os.environ.get("XODB_ELISP_REDEFINE"):
        check(oracle["current-definition"] == ("bytecode" if oracle["mode"] == "interpreted" else "interpreted") and oracle["current-definition"] != oracle["mode"],
              "redefinition probe did not observe the changed definition")
    controls = []
    for c in stack.controls[:stack.control_count]:
        typ = types["SPEC" if c.kind == 0 else "HANDLER"]
        record = gdb.Value(c.record).cast(typ.pointer()).dereference()
        tag = int(record["kind" if c.kind == 0 else "type"])
        check(tag == c.runtime_kind, "control kind mismatch")
        if c.kind == 0:
            check(tag <= 6 and c.depth == (c.record - stack.first) // types["SPEC"].sizeof,
                  "unwind depth mismatch")
        elif tag < 4:
            check(c.depth * types["SPEC"].sizeof == int(record["pdlcount"]["bytes"]),
                  "handler depth mismatch")
        controls.append({"kind": c.kind, "tag": c.runtime_kind, "depth": c.depth,
                         "frame": None if c.frame == C.c_size_t(-1).value else c.frame})
    check(any(c["kind"] == 0 for c in controls), "owned unwind was not observed")
    check(any(c["kind"] == 1 and c["tag"] == 1 for c in controls), "owned condition-case was not observed")
    result = {"status": "pass", "rows": rows, "stable_rows_compared": len(rows) - start,
              "controls": controls, "reads": reader.reads, "bytes": reader.bytes,
              "build_id": bytes(layout.build_id[:layout.build_id_len]).hex(),
              "mode": oracle["mode"], "redefined": bool(os.environ.get("XODB_ELISP_REDEFINE")),
              "target_calls": False, "activation_kinds": "unproved",
              "observer_cpu_ns": cpu_ns, "observer_rss_before": rss_before, "observer_rss_after": rss_after,
              "result_capacity_bytes": C.sizeof(Stack), "measurement": "GDB-hosted C reader with Python read callback"}
    Path(os.environ["XODB_ELISP_RESULT"]).write_text(json.dumps(result, indent=2) + "\n")
    print("elisp C reader:", result["mode"], "PASS", result["stable_rows_compared"], "stable frames")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        gdb.execute("quit 1")
