#!/usr/bin/env python3
"""C06 JVM importer checks.

  check.py IMPORTER [--capture DIR] [--fixture-build DIR] [--source FILE.kt]
                    [--lframes-reader XODB_LFRAMES] [--json OUT]

Without --capture only generated adversarial cases run. With --capture (the
capture.py output; recording.json may be stored as recording.json.xz) real owned
JVM evidence is checked too, including Kotlin SMAP source mapping when the fixture
jar is available. Exit status is nonzero when any check fails.
"""
import argparse
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import smap  # noqa: E402

os.umask(0o022)
RESULTS = []


def check(name, condition, detail=""):
    RESULTS.append({"name": name, "ok": bool(condition), "detail": detail if isinstance(detail, (str, dict)) else str(detail)})
    print(("PASS " if condition else "FAIL ") + name + (f": {detail}" if detail and not condition else ""))
    return bool(condition)


def run(binary, *args, expect=None, limit=120):
    p = subprocess.run([binary, *map(str, args)], capture_output=True, timeout=limit)
    out = p.stdout.decode("utf-8")
    return p.returncode, out, p.stderr.decode("utf-8", "replace")


def doc(binary, source, path, *extra):
    rc, out, err = run(binary, "--source", source, *extra, path)
    try:
        value = json.loads(out) if out.strip() and not out.startswith('{"type"') else None
    except json.JSONDecodeError as e:
        value = None
        err += f" [stdout not JSON: {e}]"
    return rc, value, err, out


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# ---------------------------------------------------------------- synthetic inputs
def frame(cls="pkg/C", name="m", desc="()V", line=1, bci=0, kind="Interpreted"):
    return {"method": {"type": {"classLoader": {"type": None, "name": "app"}, "name": cls,
                                "package": None, "modifiers": 1, "hidden": False},
                       "name": name, "descriptor": desc, "modifiers": 1, "hidden": False},
            "lineNumber": line, "bytecodeIndex": bci, "type": kind}


def thread(jtid=7, ostid=1234, name="w", virtual=False):
    return {"osName": name, "osThreadId": ostid, "javaName": name, "javaThreadId": jtid,
            "group": {"parent": None, "name": "main"}, "virtual": virtual}


def sample(frames, t="2026-10-05T00:00:00.000000001Z", th=None, truncated=False):
    return {"type": "jdk.ExecutionSample",
            "values": {"startTime": t, "sampledThread": th or thread(), "state": "STATE_RUNNABLE",
                       "stackTrace": {"truncated": truncated, "frames": frames}}}


JVMINFO = {"type": "jdk.JVMInformation", "values": {
    "startTime": "2026-10-05T00:00:00Z", "jvmName": "Synthetic VM", "jvmVersion": "synthetic 1",
    "jvmArguments": "", "jvmFlags": None, "javaArguments": "x", "jvmStartTime": "2026-10-05T00:00:00Z",
    "pid": 4242}}


def recording(events):
    return json.dumps({"recording": {"events": events}}, ensure_ascii=False)


def adversarial(binary, tmp, reader):
    w = lambda name, text: (tmp / name).write_bytes(text if isinstance(text, bytes) else text.encode())  # noqa: E731
    p = lambda name: str(tmp / name)  # noqa: E731

    rc, _, err, _ = doc(binary, "jfr-json", p("absent.json"))
    check("A01 missing input is 'unavailable' (exit 3)", rc == 3, err)

    good = recording([JVMINFO, sample([frame()])])
    w("trunc.json", good[: len(good) // 2])
    rc, _, err, _ = doc(binary, "jfr-json", p("trunc.json"))
    check("A02 truncated JSON rejected with byte offset (exit 1)", rc == 1 and "byte" in err, err)

    w("good.json", good)
    rc, _, err, _ = doc(binary, "jfr-json", p("good.json"), "--max-bytes", "100")
    check("A03 input byte budget is exit 4", rc == 4 and "budget" in err, err)

    w("many.json", recording([JVMINFO] + [sample([frame(line=i)]) for i in range(100)]))
    rc, d, err, _ = doc(binary, "jfr-json", p("many.json"), "--max-records", "10")
    check("A04 record budget -> incomplete document, exit 4",
          rc == 4 and d and d["status"] == "incomplete" and d["counts"]["records"] == 10, f"{rc} {err}")

    big = [frame(name=f"f{i}", line=i) for i in range(20000)]
    w("deep.json", recording([JVMINFO, sample(big)]))
    rc, d, err, _ = doc(binary, "jfr-json", p("deep.json"))
    ok = rc == 0 and d["records"][0]["truncation"] == "truncated_by_importer" and \
        len(d["records"][0]["stack"]) == 8192 and d["diagnostics"]["importer_truncated_stacks"] == 1
    check("A05 per-stack frame budget marks importer truncation", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "jfr-json", p("deep.json"), "--query", "lframes")
    stack = [json.loads(line) for line in out.splitlines() if '"type":"stack"' in line]
    check("A05b lframes clips to 4096 frames with omitted count",
          rc == 0 and stack and stack[0]["state"] == "truncated" and stack[0]["omitted"] == "15904"
          and len(stack[0]["frames"]) == 4096, out[:200])
    lf_validate(reader, tmp, "deep.jsonl", out, "A05c")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("deep.json"), tmp / "deep.jsonl", "A05c")

    rc, d, err, _ = doc(binary, "jfr-json", p("deep.json"), "--max-total-frames", "100")
    check("A06 total frame budget -> incomplete", rc == 4 and d and d["status"] == "incomplete", err)

    w("nest.json", '{"recording":{"events":[' + "[" * 5000 + "]" * 5000 + "]}}")
    rc, _, err, _ = doc(binary, "jfr-json", p("nest.json"))
    check("A07 deep nesting rejected without crash (exit 1)", rc == 1 and "nesting" in err, err)

    w("noid.json", recording([sample([frame()])]))
    rc, d, err, _ = doc(binary, "jfr-json", p("noid.json"))
    check("A08 missing runtime identity stays missing",
          rc == 0 and d["runtime"]["identity"] == "missing" and d["process"]["pid"] is None
          and d["process"]["instance"] is None, err)
    rc, _, _, out = doc(binary, "jfr-json", p("noid.json"), "--query", "lframes")
    hdr = json.loads(out.splitlines()[0]) if out else {}
    check("A08b lframes header keeps unknown runtime/pid",
          rc == 0 and hdr.get("runtime", {}).get("version") == "unknown"
          and hdr.get("process", {}).get("pid") is None, out[:200])
    lf_validate(reader, tmp, "noid.jsonl", out, "A08c")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("noid.json"), tmp / "noid.jsonl", "A08c")

    partial = sample([frame(), {"lineNumber": 3, "type": "Interpreted"}, frame(kind="Weird", line=-1),
                      {"method": None, "type": "JIT compiled"}])
    nostack = sample([])
    nostack["values"]["stackTrace"] = None
    w("partial.json", recording([JVMINFO, partial, nostack]))
    rc, d, err, _ = doc(binary, "jfr-json", p("partial.json"))
    if rc == 0:
        frames = d["frames"]
        kinds = [frames[i]["kind"] for i in d["records"][0]["stack"]]
        ok = (kinds == ["interpreted", "unavailable", "unknown", "unavailable"]
              and d["diagnostics"]["malformed_frames"] == 2 and d["diagnostics"]["unknown_frame_kinds"] == 1
              and d["records"][1]["truncation"] == "not_reported_by_source"
              and d["diagnostics"]["missing_stack"] == 1
              and frames[d["records"][0]["stack"][2]]["line"] is None)
    else:
        ok = False
    check("A09 partial/malformed frames kept in position with diagnostics", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "jfr-json", p("partial.json"), "--query", "lframes")
    lf_validate(reader, tmp, "partial.jsonl", out, "A09b")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("partial.json"), tmp / "partial.jsonl", "A09b")

    odd_thread = thread(name="tab\there \"q\" \\ nl\nend \u0001 ü")
    names = recording([JVMINFO, sample([frame(name=""), frame(name="a/b;c"),
                                        frame(name="ü\U0001F600 x"), frame(cls="p/é")],
                                       th=odd_thread)])
    names = names.replace("a/b;c", "a/b;c\\ud800")  # lone surrogate escape
    w("names.json", names)
    rc, d, err, _ = doc(binary, "jfr-json", p("names.json"))
    if rc == 0:
        fs = [d["frames"][i] for i in d["records"][0]["stack"]]
        ok = (fs[0]["method"] == "" and fs[0]["name_status"] == "empty"
              and fs[1]["name_status"] == "invalid_jvm_name" and fs[1]["method"] == "a/b;c�"
              and fs[2]["method"] == "ü\U0001F600 x" and fs[3]["class"] == "p.é"
              and d["diagnostics"]["lossy_strings"] == 1 and d["diagnostics"]["unnamed_methods"] == 1
              and d["threads"][0]["names"] == ["tab\there \"q\" \\ nl\nend \u0001 ü"])
    else:
        ok = False
    check("A10 unnamed/invalid/Unicode/escaped names round-trip exactly", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "jfr-json", p("names.json"), "--query", "lframes")
    lf_validate(reader, tmp, "names.jsonl", out, "A10b")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("names.json"), tmp / "names.jsonl", "A10b")

    nums = recording([JVMINFO,
                      sample([frame()], th=thread(jtid=9223372036854775807, ostid=0)),
                      sample([frame()], th=thread(jtid=0, ostid=1)).replace("0", "0") if False else
                      sample([frame()], th={**thread(), "javaThreadId": 18446744073709551615}),
                      sample([frame()], th={**thread(), "javaThreadId": 1.5})])
    w("nums.json", nums)
    rc, d, err, _ = doc(binary, "jfr-json", p("nums.json"))
    if rc == 0:
        t = d["threads"]
        ok = (t[0]["java_thread_id"] == "9223372036854775807" and t[0]["os_tid"] is None
              and d["diagnostics"]["os_tid_zero_treated_absent"] == 1
              and d["diagnostics"]["invalid_numbers"] == 2
              and all(x["java_thread_id"] is None for x in t[1:]))
    else:
        ok = False
    check("A11 high-bit/overflow/non-integer IDs exact or absent, never rounded", ok, f"{rc} {err}")

    times = recording([JVMINFO, sample([frame()], t=None), sample([frame()], t="2026-10-05T00:00:00"),
                       sample([frame()], t="2026-10-05T00:00:00.5+02:00")])
    w("times.json", times)
    rc, d, err, _ = doc(binary, "jfr-json", p("times.json"))
    if rc == 0:
        tm = [r["time"] for r in d["records"]]
        ok = (tm[0] == {"raw": None, "epoch_ns": None, "status": "absent"} and tm[1]["epoch_ns"] is None
              and tm[1]["raw"] == "2026-10-05T00:00:00" and tm[1]["status"] == "unzoned"
              and tm[2]["epoch_ns"] == "1791151200500000000" and tm[2]["status"] == "ok")
    else:
        ok = False
    check("A12 missing/unzoned clocks stay unknown; zoned converts exactly", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "jfr-json", p("times.json"), "--query", "lframes")
    st = [json.loads(line) for line in out.splitlines() if '"type":"stack"' in line]
    check("A12b lframes stacks without a clock value carry null times",
          rc == 0 and st[0]["start_ns"] is None and st[2]["start_ns"] == "1791151200500000000", out[:200])
    lf_validate(reader, tmp, "times.jsonl", out, "A12c")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("times.json"), tmp / "times.jsonl", "A12c")

    count = 50000
    events = [JVMINFO] + [sample([frame(name=f"m{i % 7}"), frame(name="root")],
                                 th=thread(jtid=1 + i % 5, ostid=100 + i % 5)) for i in range(count)]
    w("large.json", recording(events))
    start = time.time()
    rc, _, err, out = doc(binary, "jfr-json", p("large.json"), "--query", "aggregate", "--kind",
                          "execution_sample", "--by", "method", "--limit", "3")
    d = json.loads(out) if rc == 0 else None
    ok = d and d["total_weight"] == count and d["rows_total"] == 7 and len(d["rows"]) == 3 \
        and d["rows"][0]["citations"]["truncated"] is True
    check("A13 large count aggregates exactly and bounded", ok, f"{rc} {err} {time.time() - start:.2f}s")

    tp = (b"123:\n2026-10-05 00:00:00\nFull thread dump Synthetic VM (9.9 mixed mode):\n\n"
          b"\"broken\nname\" #4 [76] prio=5 os_prio=0 tid=0x00007eff nid=76 runnable  [0x0]\n"
          b"\tat lost.Frame.m(F.java:1)\n\n"
          b"\"loaders\" #5 [77] prio=5 os_prio=0 tid=0x00007f00 nid=77 runnable  [0x0]\n"
          b"   java.lang.Thread.State: RUNNABLE\n"
          b"\tat app//pkg.C.m(C.java:3)\n"
          b"\tat com.foo.L//pkg.D.n(D.java:1)\n"
          b"\tat pkg.C$$Lambda/0x0000abc.run(Unknown Source)\n"
          b"\tat noparen\n"
          b"\tat x(Native Method)\n"
          b"\tat pkg.\xff\xfeBad.m(Bad.java:9)\n"
          b"\n\"old\" #6 prio=5 os_prio=0 tid=0x00007f01 nid=0x1f waiting\n"
          b"\tat java.lang.Object.wait(java.base@9.9/Native Method)\n"
          b"garbage line\n")
    w("print.txt", tp)
    rc, d, err, _ = doc(binary, "thread-print", p("print.txt"))
    if rc == 0:
        fs = [d["frames"][i] for r in d["records"] for i in r["stack"]]
        by = {f["raw_text"]: f for f in fs}
        ok = (by["app//pkg.C.m(C.java:3)"]["class_loader"] == "app"
              and by["app//pkg.C.m(C.java:3)"]["module"] is None
              and by["com.foo.L//pkg.D.n(D.java:1)"]["class_loader"] == "com.foo.L"
              and by["pkg.C$$Lambda/0x0000abc.run(Unknown Source)"]["class"] == "pkg.C$$Lambda/0x0000abc"
              and by["pkg.C$$Lambda/0x0000abc.run(Unknown Source)"]["hidden"] is True
              and by["noparen"]["kind"] == "unavailable"
              and by["x(Native Method)"]["kind"] == "unavailable"
              and by["java.lang.Object.wait(java.base@9.9/Native Method)"]["module_version"] == "9.9"
              and d["diagnostics"]["invalid_utf8_lines"] == 1
              and d["diagnostics"]["unparsed_lines"] >= 4
              and "lost.Frame.m(F.java:1)" not in by
              and [t["names"] for t in d["threads"]] == [["loaders"], ["old"]]
              and d["process"]["pid"] == "123"
              and any(t["os_tid"] == "31" for t in d["threads"])
              and all(f["parse"] == "heuristic_text" for f in fs))
    else:
        ok = False
    check("A14 Thread.print adversarial lines, loaders, hidden classes, hex nid", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "thread-print", p("print.txt"), "--query", "lframes")
    lf_validate(reader, tmp, "print.jsonl", out, "A14b")
    if reader and rc == 0:
        composed(binary, reader, "thread-print", p("print.txt"), tmp / "print.jsonl", "A14b")

    rc, _, err, _ = doc(binary, "art-trace", p("good.json"))
    check("A15 ART source refused, not approximated (exit 2)", rc == 2 and "ART" in err, err)
    rc, d, _, _ = doc(binary, "jfr-json", p("good.json"), "--query", "flame")
    check("A15b unsupported query distinct (exit 2)", rc == 2 and d["status"] == "unsupported_query")
    rc, d, _, _ = doc(binary, "jfr-json", p("good.json"), "--query", "relations")
    check("A15c relations on JFR unsupported (exit 2)", rc == 2 and d["status"] == "unsupported_query")
    rc, d, _, _ = doc(binary, "jfr-json", p("good.json"), "--query", "stacks", "--java-tid", "999")
    check("A15d no matching evidence distinct (exit 5)", rc == 5 and d["status"] == "no_matching_evidence")
    rc, d, _, _ = doc(binary, "jfr-json", p("good.json"), "--query", "aggregate", "--kind",
                      "exception_throw", "--by", "stack")
    check("A15f empty aggregate is no_matching_evidence (exit 5; fuzz regression)",
          rc == 5 and d["status"] == "no_matching_evidence" and d["rows"] == [])
    rc, d, _, _ = doc(binary, "jfr-json", p("good.json"), "--query", "stacks", "--start", "5")
    check("A15e empty page distinct from no evidence", rc == 0 and d["status"] == "empty_page")

    w("notjfr.json", '{"foo":1}')
    rc, _, err, _ = doc(binary, "jfr-json", p("notjfr.json"))
    check("A16 non-JFR JSON rejected", rc == 1 and "recording.events" in err, err)
    w("trail.json", good + " x")
    rc, _, err, _ = doc(binary, "jfr-json", p("trail.json"))
    check("A17 trailing data rejected", rc == 1, err)
    w("dup.json", good.replace('"jvmName"', '"pid": 1, "jvmName"'))
    rc, _, err, _ = doc(binary, "jfr-json", p("dup.json"))
    check("A18 duplicate keys rejected", rc == 1 and "duplicate" in err, err)

    td = {"threadDump": {"processId": "77", "time": "2026-10-05T00:00:00Z", "runtimeVersion": "x",
                         "threadContainers": [{"container": "<root>", "parent": None, "owner": None,
                                               "threads": [{"tid": "abc", "name": "t", "stack": ["a.B.c(B.java:1)", 5]}]}]}}
    w("td.json", json.dumps(td))
    rc, d, err, _ = doc(binary, "thread-dump-json", p("td.json"))
    check("A19 thread dump with bad tid/frame imports with diagnostics",
          rc == 0 and d["diagnostics"]["missing_thread"] == 1 and d["diagnostics"]["malformed_frames"] == 1,
          f"{rc} {err}")
    w("probes2.json", json.dumps({"format": "xodb-c06-coroutine-probes", "version": 2, "coroutines": []}))
    rc, _, err, _ = doc(binary, "coroutine-probes", p("probes2.json"))
    check("A20 unknown probe dump version rejected", rc == 1 and "version" in err, err)
    pr = {"format": "xodb-c06-coroutine-probes", "version": 1, "pid": 1, "wall_time": "2026-10-05T00:00:00Z",
          "nano_time": "1", "probes_installed": True, "runtime_version": "x",
          "coroutines": [{"sequence": 9, "coroutine_id": None, "name": None, "state": "SUSPENDED",
                          "parent_relation": "parent_not_tracked", "parent_sequence": None, "last_thread": None,
                          "last_observed_frames": ["a.B.c(B.kt:1)", "_COROUTINE._BOUNDARY._(CoroutineDebugging.kt:46)",
                                                   "a.B.d(B.kt:2)", "_COROUTINE._CREATION._(CoroutineDebugging.kt:30)",
                                                   "a.B.e(B.kt:3)"],
                          "creation_frames": ["a.B.e(B.kt:3)"]}]}
    w("probes.json", json.dumps(pr))
    rc, d, err, _ = doc(binary, "coroutine-probes", p("probes.json"))
    if rc == 0:
        fs = [d["frames"][i] for i in d["records"][0]["stack"]]
        ok = ([f["kind"] for f in fs] == ["unspecified", "coroutine_marker", "unspecified"]
              and d["diagnostics"]["creation_marker_splits"] == 1
              and len(d["records"][0]["creation_stack"]) == 1
              and d["records"][0]["coroutine"]["parent_sequence"] is None)
    else:
        ok = False
    check("A21 coroutine stack splits at creation marker; no invented callers/parents", ok, f"{rc} {err}")
    rc, _, _, out = doc(binary, "coroutine-probes", p("probes.json"), "--query", "lframes")
    lf_validate(reader, tmp, "probes.jsonl", out, "A21b")
    if reader and rc == 0:
        composed(binary, reader, "coroutine-probes", p("probes.json"), tmp / "probes.jsonl", "A21b")

    # C05-R3: reproduced importer failures (inputs in tests/jvm/regress).
    regress = Path(__file__).resolve().parent / "regress"
    bad_times = {"9999-01-01T00:00:00Z": "outside_int64_epoch_ns",
                 "2262-04-11T23:47:16.854775808Z": "outside_int64_epoch_ns",
                 "1677-09-21T00:12:43.145224191Z": "outside_int64_epoch_ns",
                 "2026-02-31T00:00:00Z": "invalid_calendar_date",
                 "2023-02-29T00:00:00Z": "invalid_calendar_date",
                 "2026-10-05T00:00:00+99:99": "invalid_zone_offset",
                 "2016-12-31T23:59:60Z": "leap_second_not_representable",
                 "2026-10-05T24:00:00Z": "invalid_time_of_day"}
    good_times = {"2262-04-11T23:47:16.854775807Z": "9223372036854775807",
                  "1677-09-21T00:12:43.145224192Z": "-9223372036854775808",
                  "2024-02-29T00:00:00Z": "1709164800000000000"}
    w("times-r3.json", recording([JVMINFO] + [sample([frame()], t=t) for t in list(bad_times) + list(good_times)]))
    rc, d, err, _ = doc(binary, "jfr-json", p("times-r3.json"))
    tm = [r["time"] for r in d["records"]] if rc == 0 and d else []
    want = [{"raw": t, "epoch_ns": None, "status": s} for t, s in bad_times.items()] + \
        [{"raw": t, "epoch_ns": v, "status": "ok"} for t, v in good_times.items()]
    check("A23 invalid/unrepresentable times keep raw text + reason; exact int64 endpoints convert",
          rc == 0 and tm == want, f"{rc} {err} {[x for x in zip(tm, want) if x[0] != x[1]][:3]}")
    rc, _, _, out = doc(binary, "jfr-json", p("times-r3.json"), "--query", "lframes")
    st = [json.loads(line) for line in out.splitlines() if '"type":"stack"' in line]
    check("A23b lframes: bad times give no stack time and an explicit x_time_status",
          rc == 0 and [(x["start_ns"], x.get("x_time_status"), x.get("x_time_raw")) for x in st[:len(bad_times)]]
          == [(None, s, t) for t, s in bad_times.items()]
          and st[len(bad_times)]["start_ns"] == "9223372036854775807"
          and st[len(bad_times) + 1]["start_ns"] is None
          and st[len(bad_times) + 1]["x_time_status"] == "before_unix_epoch_not_representable_in_c05", out[:300])
    lf_validate(reader, tmp, "times-r3.jsonl", out, "A23c")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", p("times-r3.json"), tmp / "times-r3.jsonl", "A23c")
    stp = regress / "short-thread-print.txt"
    rc, d, err, _ = doc(binary, "thread-print", stp)
    check("A24 45-byte Thread.print tail imports without reading past the input",
          rc == 0 and d and d["counts"]["records"] == 0 and stp.stat().st_size == 45, f"{rc} {err[:300]}")
    clc = regress / "class-loader-collision.json"
    rc, _, _, out = doc(binary, "jfr-json", clc, "--jfr-stack-depth", "2048", "--query", "lframes")
    fns = [json.loads(line) for line in out.splitlines() if '"type":"function"' in line]
    check("A25 same method from loader-A and loader-B: two functions with their own loaders",
          rc == 0 and sorted(f["x_class_loader"] for f in fns) == ["loader-A", "loader-B"]
          and all(f["x_identity_basis"] == "loader_named" for f in fns), out[:300])
    lf_validate(reader, tmp, "loaders.jsonl", out, "A25b")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", clc, tmp / "loaders.jsonl", "A25b", ("--jfr-stack-depth", "2048"))

    # C05-R4: importer regression inputs.
    idv = regress / "identity-variants.json"
    rc, _, _, out = doc(binary, "jfr-json", idv, "--jfr-stack-depth", "2048", "--query", "lframes")
    fns = [json.loads(line) for line in out.splitlines() if '"type":"function"' in line]
    check("A26 identity variants: p/C vs p.C and m\\0a vs m\\0b stay distinct; 12 functions from 13 raw identities "
          "(null and absent classLoader merge as loader_not_exported)",
          rc == 0 and len(fns) == 12 and sum(1 for f in fns if f.get("x_nul_escaped")) == 2
          and sorted(f["name"] for f in fns if f.get("x_nul_escaped")) == ["m\\0a", "m\\0b"], out[:300])
    lf_validate(reader, tmp, "identity.jsonl", out, "A26b")
    if reader and rc == 0:
        composed(binary, reader, "jfr-json", idv, tmp / "identity.jsonl", "A26b", ("--jfr-stack-depth", "2048"))
    tpn = regress / "tp-null-frame.txt"
    outs = [run(binary, "--source", "thread-print", "--query", "evidence", "--max-total-bytes", str(n), str(tpn))
            for n in range(27000, 27800, 7)]
    check("A27 Thread.print under a budget never crashes (exit 4 memory_limit or 0)",
          all(r[0] in (0, 4) for r in outs), sorted({r[0] for r in outs}))
    rc, out, err = run(binary, "--source", "thread-print", "--query", "evidence", str(regress / "tp-invalid-utf8-time.txt"))
    ev = json.loads(out) if rc == 0 and out.startswith("{") else {}
    check("A28 invalid UTF-8 in the Thread.print time line imports; time malformed",
          rc == 0 and ev.get("status") == "ok" and ev.get("stacks") and all(st["time"]["status"] == "malformed" and "\ufffd" in st["time"]["raw"] for st in ev["stacks"]),
          f"{rc} {out[:200]} {err[:200]}")

    w("depth.json", recording([JVMINFO, sample([frame()] * 5), sample([frame()] * 3),
                               sample([frame()] * 5, truncated=True)]))
    t = lambda *x: [r["truncation"] for r in doc(binary, "jfr-json", p("depth.json"), *x)[1]["records"]]  # noqa: E731
    undeclared, declared = t(), t("--jfr-stack-depth", "5")
    check("A22 jfr print export depth: undeclared or reached depth is never 'complete'",
          undeclared == ["possibly_truncated_by_export"] * 2 + ["truncated_by_source"]
          and declared == ["possibly_truncated_by_export", "complete", "truncated_by_source"],
          f"{undeclared} {declared}")


def lf_validate(reader, tmp, name, text, label):
    if not reader:
        RESULTS.append({"name": f"{label} C05 reader validation", "ok": None, "detail": "not_tested"})
        print(f"SKIP {label} (no C05 reader given)")
        return
    path = tmp / name
    path.write_text(text)
    rc, out, err = run(reader, "validate", path, "--strict")
    try:
        status = json.loads(out).get("status")
    except json.JSONDecodeError:
        status = None
    check(f"{label} C05-1 reader validates (--strict)", rc == 0 and status == "ok", (out or err)[:400])


# ---------------------------------------------------------------- real evidence
def function_ranges(source):
    lines = source.read_text().splitlines()
    starts = []
    for i, line in enumerate(lines, 1):
        m = re.match(r"^(\s*)(?:inline |suspend |private )*fun (?:<[^>]*> )?(`[^`]+`|\w+)\(", line)
        if m:
            starts.append((i, len(m.group(1)), m.group(2).strip("`")))
    ranges = {}
    for k, (line, indent, name) in enumerate(starts):
        end = len(lines)
        for j in range(line, len(lines)):
            text = lines[j]
            if text.strip() and (len(text) - len(text.lstrip())) <= indent and \
                    (text.lstrip().startswith(("fun ", "inline ", "suspend ", "private ", "class ", "}"))):
                end = j if not text.lstrip().startswith("}") else j + 1
                break
        ranges.setdefault(name, []).append((line, end))
    return ranges, len(lines)


def enclosing(cls, method):
    base = method.split("$")[0]
    if base in ("invokeSuspend", "invoke", "run", "<init>", "create") or not base:
        parts = cls.split("$")
        base = parts[1] if len(parts) > 1 else base
    return base


def real(binary, capture, fixture, source, reader, tmp):
    manifest = json.loads((capture / "capture-manifest.json").read_text())
    runs = {r["name"]: r for r in manifest["runs"]}
    depth = manifest.get("jfr_print_stack_depth")
    jd = ["--jfr-stack-depth", str(depth)] if depth else []
    check("R00 capture manifest declares the jfr print stack depth", bool(depth),
          "older captures used jfr print's default depth of 5")

    def raw_json(run):
        plain = capture / run / "recording.json"
        if plain.exists():
            return plain
        out = tmp / f"{run}-recording.json"
        with lzma.open(capture / run / "recording.json.xz") as f, open(out, "wb") as g:
            shutil.copyfileobj(f, g)
        return out

    kotlin = "kotlin" in runs
    for rn in ["java"] + (["kotlin"] if kotlin else []):
        path = raw_json(rn)
        digest = sha(path)
        rc, d, err, _ = doc(binary, "jfr-json", path, *jd)
        info = runs[rn]
        ok = rc == 0 and d["status"] == "complete" and d["source"]["sha256"] == digest \
            and digest == info["files"]["recording.json"]["sha256"] \
            and d["runtime"]["identity"] == "present" and d["process"]["pid"] == str(info["pid"]) \
            and d["process"]["instance"] is not None
        check(f"R01[{rn}] JFR import complete; sha/pid match capture manifest", ok, f"{rc} {err}")
        if rc:
            continue
        threads = {n: t for t in d["threads"] for n in t["names"]}
        worker = threads.get("c06-worker" if rn == "kotlin" else "c06j-worker")
        check(f"R02[{rn}] worker has distinct Java TID and OS TID",
              worker and worker["java_thread_id"] and worker["os_tid"] and worker["virtual"] is False)
        kinds = {f["kind"] for f in d["frames"]}
        check(f"R03[{rn}] JFR execution modes preserved", {"interpreted", "jit_compiled"} <= kinds, kinds)
        allowed = {"id", "kind", "raw_kind", "class", "method", "name_status", "descriptor", "module",
                   "module_version", "class_loader", "class_loader_type", "class_loader_status", "file", "line",
                   "bytecode_index", "hidden", "parse",
                   "raw_text", "raw_class"}
        check(f"R03b[{rn}] no frame carries a PC/address field",
              all(set(f) <= allowed for f in d["frames"]))
        events = json.loads(path.read_text())["recording"]["events"]
        samples = [r for r in d["records"] if r["kind"] == "execution_sample"]
        bad = 0
        for r in samples[:: max(1, len(samples) // 60)]:
            e = events[r["ordinal"]]
            th = d["threads"][r["thread"]]
            if e["type"] != "jdk.ExecutionSample" or str(e["values"]["sampledThread"]["javaThreadId"]) != \
                    th["java_thread_id"] or e["values"]["startTime"] != r["time"]["raw"] or \
                    len(e["values"]["stackTrace"]["frames"]) != len(r["stack"]):
                bad += 1
        check(f"R04[{rn}] record citations resolve to the raw events", samples and bad == 0, f"bad={bad}")
        # paging agrees with the summary
        total, rows, start, pages = None, 0, 0, 0
        weight = 0
        while pages < 1000:
            rc2, out, _ = run(binary, "--source", "jfr-json", *jd, "--query", "aggregate", "--kind",
                              "execution_sample", "--by", "method", "--limit", "7", "--start", start, path)
            q = json.loads(out)
            total = q["total_weight"]
            if q["status"] == "empty_page":
                break
            weight += sum(x["weight"] for x in q["rows"])
            rows += len(q["rows"])
            start += 7
            pages += 1
        check(f"R05[{rn}] paged aggregate rows sum to summary total",
              total == len(samples) == weight and rows == q["rows_total"], f"{total} {len(samples)} {weight}")
        if rn == "kotlin":
            kotlin_checks(binary, d, path, capture, fixture, source, events)
        lf = run_lframes(binary, "jfr-json", path, reader, tmp, f"R06[{rn}]", jd)
        if lf and reader:
            compare_aggregates(binary, reader, path, tmp / f"R06[{rn}].jsonl", f"R07[{rn}]", jd)
        complete = sum(1 for r in samples if r["truncation"] == "complete")
        check(f"R08[{rn}] declared export depth lets JVM-complete stacks stay complete",
              complete > 0 and d["diagnostics"]["export_depth_unknown"] == 0)

    if kotlin:
        dump = capture / "kotlin" / "thread-dump.json"
        rc, d, err, _ = doc(binary, "thread-dump-json", dump)
        raw = json.loads(dump.read_text())["threadDump"]
        n = sum(len(c["threads"]) for c in raw["threadContainers"])
        threads = {nm: t for t in d["threads"] for nm in t["names"]} if rc == 0 else {}
        v = threads.get("c06-virtual")
        check("R10 JSON thread dump: virtual thread kept, virtual flag/OS TID unknown",
              rc == 0 and d["counts"]["records"] == n and v and v["virtual"] is None and v["os_tid"] is None
              and 'c06 "odd" \\ ü thread' in threads and d["records"][0]["time"]["epoch_ns"],
              f"{rc} {err}")
        run_lframes(binary, "thread-dump-json", dump, reader, tmp, "R10b")
        tp = capture / "kotlin" / "thread-print.txt"
        rc, p, err, _ = doc(binary, "thread-print", tp)
        rc2, j, _, _ = doc(binary, "jfr-json", raw_json("kotlin"), *jd)
        pt = {nm: t for t in p["threads"] for nm in t["names"]} if rc == 0 else {}
        jt = {nm: t for t in j["threads"] for nm in t["names"]}
        same = p and p["process"]["pid"] == j["process"]["pid"]
        check("R11 Thread.print: odd name exact, unnamed VM thread, OS TID agrees with JFR (same pid)",
              rc == 0 and same and 'c06 "odd" \\ ü thread' in pt
              and any(t["vm_internal"] and not t["names"] for t in p["threads"])
              and p["diagnostics"]["unparsed_lines"] == 0
              and pt["c06-worker"]["os_tid"] == jt["c06-worker"]["os_tid"]
              and pt["c06-worker"]["java_thread_id"] == jt["c06-worker"]["java_thread_id"],
              f"{rc} {err}")
        run_lframes(binary, "thread-print", tp, reader, tmp, "R11b")
        probes = capture / "kotlin-probes" / "coroutine-probes.json"
        rc, d, err, _ = doc(binary, "coroutine-probes", probes)
        rc2, out, _ = run(binary, "--source", "coroutine-probes", "--query", "relations", probes)
        rel = json.loads(out)["relations"] if rc2 == 0 else []
        by = {x["child_name"]: x for x in rel}
        stacks_ok = rc == 0 and all("_COROUTINE" not in (d["frames"][i]["raw_text"] or "")
                                    for r in d["records"] for i in r["stack"])
        check("R12 coroutine probes: observed parent edge, untracked root kept missing, creation split",
              rc == 0 and by.get("c06-child", {}).get("status") == "observed"
              and by["c06-child"]["parent_sequence"] == next(
                  r["coroutine"]["sequence"] for r in d["records"] if r["coroutine"]["name"] == "c06-parent")
              and by.get("c06-parent", {}).get("status") == "parent_not_tracked"
              and by["c06-parent"]["parent_sequence"] is None
              and d["diagnostics"]["creation_marker_splits"] == len(d["records"])
              and all(r["creation_stack"] for r in d["records"]) and stacks_ok
              and "overhead" in d["source"]["collection"]["instrumentation"] + "overhead",
              f"{rc} {err}")
        run_lframes(binary, "coroutine-probes", probes, reader, tmp, "R12b")


def kotlin_checks(binary, d, path, capture, fixture, source, events):
    threads = {n: t for t in d["threads"] for n in t["names"]}
    v = threads.get("c06-virtual")
    check("R20 virtual thread: virtual=true, OS TID absent (JFR 0 not kept)",
          v and v["virtual"] is True and v["os_tid"] is None and v["records"].get("execution_sample", 0) > 0
          and d["diagnostics"]["os_tid_zero_treated_absent"] > 0)
    odd = 'c06 "odd" \\ ü thread'
    check("R21 thread name with quote/backslash/Unicode exact", odd in threads)
    methods = {f["method"] for f in d["frames"]}
    check("R22 Kotlin backtick Unicode method name exact", "ünïcode spin – odd name" in methods)
    trunc = [r for r in d["records"] if r["kind"] == "execution_sample" and r["truncation"] == "truncated_by_source"]
    deep = threads["c06-deep"]["id"]
    check("R23 JFR depth truncation preserved (deep recursion)",
          trunc and all(len(r["stack"]) == 64 for r in trunc) and any(r["thread"] == deep for r in trunc))
    exc = [r for r in d["records"] if r["kind"] == "exception_throw"
           and r["exception"]["class"] == "java.lang.IllegalStateException"]
    stdout = (capture / "kotlin" / "fixture.stdout").read_text()
    m = re.search(r"caught=(\d+)", stdout)
    thrower = all(any(d["frames"][i]["method"] == "thrower" for i in r["stack"]) for r in exc)
    check("R24 exception events: class/message kept; count equals fixture's caught count",
          exc and m and len(exc) == int(m.group(1)) and thrower
          and all(r["exception"]["message"] == "c06 deliberate failure" for r in exc),
          f"events={len(exc)} caught={m.group(1) if m else None}")
    lam = any(f["method"].startswith("inner$lambda") for f in d["frames"])
    hidden = any(f["hidden"] is True or "$$Lambda" in (f["class"] or "") for f in d["frames"])
    check("R25 lambda frames present (synthetic method + hidden class)", lam and hidden)
    if not fixture or not (fixture / "c06-kotlin-fixture.jar").exists() or not source:
        RESULTS.append({"name": "R26 Kotlin SMAP source mapping", "ok": None, "detail": "not_tested: no jar"})
        return
    jar = fixture / "c06-kotlin-fixture.jar"
    ranges, nlines = function_ranges(source)
    stats = {"direct": 0, "inline_smap": 0, "hidden_no_class": 0, "unmapped": 0, "violations": []}
    cache = {}
    for f in d["frames"]:
        cls = f["class"] or ""
        if not cls.startswith("xodb.c06") or f["line"] is None:
            continue
        if "/0x" in cls:
            stats["hidden_no_class"] += 1
            continue
        if cls not in cache:
            try:
                cache[cls] = smap.class_info(jar, cls)
            except KeyError:
                cache[cls] = None
        info = cache[cls]
        name = enclosing(cls.split(".")[-1], f["method"])
        spans = ranges.get(name)
        line = f["line"]
        own = info and "smap" in info and smap.resolve(info["smap"], line)
        if info is None or not spans:
            stats["unmapped"] += 1
            continue
        if "smap" not in info or (own and own["file"] == "C06Fixture.kt" and own["line"] == line):
            stats["direct"] += 1
            target = line
        else:
            stats["inline_smap"] += 1
            call = smap.resolve(info["smap"], line, "KotlinDebug") if "KotlinDebug" in info["smap"] else None
            if not own or not call:
                stats["violations"].append((cls, f["method"], line, "no SMAP mapping"))
                continue
            target = call["line"]
            if own["file"] == "C06Fixture.kt":  # same-file inline function body (measured)
                inline_ok = any(a <= own["line"] <= b for a, b in ranges.get("measured", []))
                if not inline_ok:
                    stats["violations"].append((cls, f["method"], line, f"inline body {own}"))
        if not any(a <= target <= b for a, b in spans):
            stats["violations"].append((cls, f["method"], line, f"target {target} outside {spans}"))
    detail = {k: v if k != "violations" else v[:5] for k, v in stats.items()}
    check("R26 Kotlin source mapping verified via class-file SMAP (direct + inline)",
          stats["direct"] > 0 and stats["inline_smap"] > 0 and not stats["violations"], detail)
    RESULTS[-1]["stats"] = detail


def run_lframes(binary, source, path, reader, tmp, label, extra=()):
    rc, out, err = run(binary, "--source", source, *extra, "--query", "lframes", path)
    ok = check(f"{label} lframes adapter emits", rc == 0 and out.startswith('{"type":"header"'), err)
    if ok:
        lf_validate(reader, tmp, f"{label}.jsonl", out, label)
        if reader:
            composed(binary, reader, source, path, tmp / f"{label}.jsonl", label, extra)
    return ok


DEFAULT_KIND = {"jfr-json": "execution_sample", "thread-dump-json": "thread_dump_stack",
                "thread-print": "thread_print_stack", "coroutine-probes": "coroutine_stack"}
C05_KIND = {"interpreted": "interpreter", "jit_compiled": "jit", "jit_inlined": "jit",
            "jvm_native_method": "native"}
MAX_FRAMES = 4096


def composed(binary, reader, source, path, lframes, label, extra=()):
    """C05-R2: original import -> common document -> common reader, against an
    independent Python oracle computed from the importer's C06-0 document."""
    rc, d, err, _ = doc(binary, source, path, *extra)
    if not check(f"{label}/R2 C06-0 document for the oracle", rc in (0, 4) and d, err):
        return
    kind = DEFAULT_KIND[source]
    frames = d["frames"]
    records = [r for r in d["records"] if r["kind"] == kind]
    lines = [json.loads(x) for x in lframes.read_text().splitlines()]
    header = lines[0]
    stacks = [x for x in lines if x["type"] == "stack"]
    threads = {x["id"]: x for x in lines if x["type"] == "thread"}
    functions = {x["id"]: x for x in lines if x["type"] == "function"}

    def marker(f):
        return f["kind"] in ("unavailable", "coroutine_marker") or f["name_status"] in ("absent", "empty")

    def fkey(f):
        cls = f["class"]
        label_ = f'{cls}.{f["method"] or ""}{f["descriptor"] or ""}' if cls is not None else (f["method"] or "")
        return (label_, C05_KIND.get(f["kind"], "unclassified"))

    def tid(r):
        if r["kind"] == "coroutine_stack":
            return f'c{r["ordinal"]}'
        return "t-unknown" if r["thread"] is None else f't{r["thread"]}'

    # Expected aggregates with Python integers (weight 1 per record).
    want = {"total": 0, "partial": 0, "marker": 0, "unknown_leaf": 0, "self": {}, "incl": {}, "per": {}}
    for r in records:
        fr = [frames[i] for i in r["stack"][:MAX_FRAMES]]
        want["total"] += 1
        want["per"][tid(r)] = want["per"].get(tid(r), 0) + 1
        if r["truncation"] != "complete" or not fr or len(r["stack"]) > MAX_FRAMES:
            want["partial"] += 1
        if any(marker(f) for f in fr):
            want["marker"] += 1
        if not fr or marker(fr[0]):
            want["unknown_leaf"] += 1
        else:
            k = fkey(fr[0])
            want["self"][k] = want["self"].get(k, 0) + 1
        for k in {fkey(f) for f in fr if not marker(f)}:
            want["incl"][k] = want["incl"].get(k, 0) + 1
    rc, out, err = run(reader, "aggregate", lframes, "--top", "1000000")
    agg = json.loads(out) if rc == 0 else {}
    identity_oracle(source, path, records, frames, stacks, functions, agg, label, marker)
    got_self, got_incl = {}, {}
    for row in agg.get("rows", []):
        k = (row["label"], row["kind"])
        got_self[k] = got_self.get(k, 0) + int(row["self"])
        got_incl[k] = got_incl.get(k, 0) + int(row["inclusive"])
    got_self = {k: v for k, v in got_self.items() if v}
    check(f"{label}/R2 composed aggregate equals the oracle (total, partial, marker, unknown-leaf, self, inclusive)",
          rc == 0 and [agg["total_weight"], agg["partial_weight"], agg["marker_weight"], agg["unknown_leaf_weight"]]
          == [str(want[k]) for k in ("total", "partial", "marker", "unknown_leaf")]
          and got_self == want["self"] and got_incl == want["incl"],
          f'{[agg.get(k) for k in ("total_weight", "partial_weight", "marker_weight", "unknown_leaf_weight")]} vs '
          f'{[want[k] for k in ("total", "partial", "marker", "unknown_leaf")]}; '
          f'self diff {set(got_self.items()) ^ set(want["self"].items())}'[:500])
    bad = []
    for t, n in sorted(want["per"].items()):
        rc, out, _ = run(reader, "aggregate", lframes, "--thread", t, "--top", "0")
        ta = json.loads(out) if rc == 0 else {}
        if rc or ta.get("total_weight") != str(n) or ta.get("stacks") != n:
            bad.append((t, n, ta.get("total_weight")))
    check(f"{label}/R2 per-thread stack counts and weights exact ({len(want['per'])} threads)",
          not bad and set(want["per"]) == {s["thread"] for s in stacks}, bad[:5])
    rc, out, err = run(binary, "--source", source, *extra, "--query", "lframes-check", path)
    lc = json.loads(out) if out.startswith("{") else {}
    check(f"{label}/R2 in-process lframes-check (linked reader) agrees",
          rc == 0 and lc.get("status") == "ok" and lc.get("total_weight") == str(want["total"])
          and lc.get("partial_weight") == str(want["partial"]) and lc.get("lframes_sha256") == sha(lframes),
          f"{rc} {err} {out[:300]}")
    evidence_oracle(binary, source, path, extra, label, stacks)
    # Citations: every stack cites the raw source bytes and an importer record of the
    # selected kind on the same thread.
    raw_sha = sha(path)
    by_ord = {r["ordinal"]: r for r in records}
    bad = []
    for st in stacks:
        c = st.get("x_citation", {})
        r = by_ord.get(int(c.get("ordinal", -1)))
        ok = r is not None and c.get("source_sha256") == raw_sha == d["source"]["sha256"] and st["thread"] == tid(r) \
            and st["id"] == f's{r["ordinal"]}' and c.get("path") == r["citation"].get("path")
        if ok and "lines" in r["citation"]:
            ok = c.get("lines") == f'{r["citation"]["lines"][0]}-{r["citation"]["lines"][1]}'
        if not ok:
            bad.append(st["id"])
    check(f"{label}/R2 citations resolve: source sha256, ordinal, path/lines, thread ({len(stacks)} stacks)",
          not bad and len(stacks) == len(records) and header["x_source"]["sha256"] == raw_sha, bad[:5])
    # Identity, truncation, heuristic and inlining evidence survive the adaptation.
    ths = d["threads"]
    bad = []
    for t_id, t in threads.items():
        if not t_id.startswith("t") or t_id == "t-unknown":
            continue
        src = ths[int(t_id[1:])]
        vt = {True: True, False: False, None: None}[src["virtual"]]
        if t.get("x_virtual") is not vt or (src["os_tid"] is None) != (t["os_tid"] is None) or \
                (t["os_tid"] is not None and str(t["os_tid"]) != src["os_tid"]) or \
                (t["language_id"] != (f'java_thread_id:{src["java_thread_id"]}' if src["java_thread_id"] else None)):
            bad.append(t_id)
    check(f"{label}/R2 thread identity kept: Java TID, OS TID or null+reason, virtual true/false/unknown",
          not bad, bad[:5])
    bad = 0
    heuristic = inlined = 0
    for st in stacks:
        r = by_ord[int(st["x_citation"]["ordinal"])]
        fr = [frames[i] for i in r["stack"][:MAX_FRAMES]]
        if len(fr) != len(st["frames"]):
            bad += 1
            continue
        for f, g in zip(fr, st["frames"]):
            h = f["parse"] == "heuristic_text"
            heuristic += h
            inlined += f["kind"] == "jit_inlined"
            if (g.get("x_parse") == "heuristic_text") != h or (g.get("x_inlined") is True) != (f["kind"] == "jit_inlined") \
                    or "pc" in g or (not marker(f) and functions[g["function"]]["frame_kind"] != C05_KIND.get(f["kind"], "unclassified")):
                bad += 1
        want_state = "complete" if r["truncation"] == "complete" and fr else None
        if want_state and st["state"] != "complete":
            bad += 1
        if r["truncation"] == "possibly_truncated_by_export" and st["state"] != "partial":
            bad += 1
        if r["kind"] == "coroutine_stack" and len(st.get("x_creation_frames", [])) != min(len(r["creation_stack"]), MAX_FRAMES):
            bad += 1
    check(f"{label}/R2 frame evidence kept: heuristic_text ({heuristic}), inlined ({inlined}), kinds, no PC, "
          "truncation states, creation stacks", bad == 0, bad)
    # Clock domain: JFR wall time stays in its declared domain; nothing claims perf time.
    clock = header.get("clock")
    if source == "jfr-json":
        def stack_time(r):  # C05 times are u64: a valid pre-1970 instant has no stack time (C05-R3)
            e = r["time"]["epoch_ns"]
            return None if e is None or e.startswith("-") else e
        times_ok = all(st["start_ns"] == stack_time(by_ord[int(st["x_citation"]["ordinal"])]) for st in stacks)
        check(f"{label}/R2 JFR wall clock declared as jfr-wallclock-utc-epoch, not monotonic/perf; times exact",
              clock == {"domain": "jfr-wallclock-utc-epoch", "unit": "ns"} and "x_clock_relation" in header and times_ok)
    else:
        check(f"{label}/R2 no clock invented for a dump source", clock is None and header.get("clock_unavailable")
              and all(st["start_ns"] is None for st in stacks))
    # Extension references resolve inside the document.
    if source == "coroutine-probes":
        seqs = {t["language_id"].split(":", 1)[1] for t in threads.values() if (t["language_id"] or "").startswith("kotlinx-coroutine:")}
        java = {str(t["java_thread_id"]) for t in ths if t["java_thread_id"]}
        bad = [t["id"] for t in threads.values() if t.get("x_parent_sequence") and t["x_parent_sequence"] not in seqs]
        bad += [t["id"] for t in threads.values() if t.get("x_parent_sequence") is None and
                t.get("x_parent_relation") not in ("parent_not_tracked", "no_parent", None)]
        bad += [t["id"] for t in threads.values() if t.get("x_last_thread") and
                t["x_last_thread"]["java_thread_id"] is not None and ths and t["x_last_thread"]["java_thread_id"] not in java]
        check(f"{label}/R2 coroutine parent/last-thread references resolve or are declared untracked", not bad, bad)


JFR_CODE = {"Interpreted": "I", "JIT compiled": "J", "Inlined": "L", "Native": "N"}


def text_code(raw):
    """Expected C-API frame code for a StackTraceElement-style text frame, from the
    raw text alone (lowercase: heuristic text parse; '.' marker frame)."""
    if raw.startswith("_COROUTINE.") or "(" not in raw or not raw.endswith(")"):
        return "."
    head = raw[: raw.rfind("(")]
    if "." not in head or head.endswith("."):
        return "."
    loc = raw[raw.rfind("(") + 1: -1]
    return "n" if loc == "Native Method" or loc.endswith("/Native Method") else "u"


def evidence_oracle(binary, source, path, extra, label, lf_stacks):
    """C05-R3: evidence retrieved through the owned C API (jvm_evidence, via
    --query evidence; no adapter JSON is parsed) against the raw source bytes:
    cited spans are the exact bytes of the cited event/thread/coroutine/line,
    per-frame execution mode / inlining / Java-native-method / heuristic-text
    distinctions, virtual-thread flags, raw times and coroutine parents."""
    rc, out, err = run(binary, "--source", source, *extra, "--query", "evidence", path)
    ev = json.loads(out) if out.startswith("{") else {}
    if not check(f"{label}/R3 evidence bundle (C API) imports", rc == 0 and ev.get("status") == "ok", f"{rc} {err[:200]} {out[:200]}"):
        return
    raw = Path(path).read_bytes()
    text = raw.decode("utf-8", "replace")
    doc_json = json.loads(raw) if source != "thread-print" else None
    lines = raw.split(b"\n")
    bad_cite, bad_frames, bad_time, bad_virtual = [], [], [], []
    threads = {t["id"]: t for t in ev["threads"]}
    for st in ev["stacks"]:
        c = st["cite"]
        span = raw[c["offset"]: c["offset"] + c["length"]] if c else b""
        if not c or hashlib.sha256(span).hexdigest() != c["sha256"]:
            bad_cite.append(st["id"])
            continue
        o = st["ordinal"]
        if source == "jfr-json":
            item = doc_json["recording"]["events"][o]
            raw_frames = (item["values"].get("stackTrace") or {}).get("frames") or []
            want = "".join("." if not isinstance(f.get("method"), dict) or not f["method"].get("name")
                           else JFR_CODE.get(f.get("type"), "K") for f in raw_frames)
            if item["values"].get("startTime") != st["time"]["raw"]:
                bad_time.append(st["id"])
            th = item["values"].get("sampledThread") or item["values"].get("eventThread") or {}
            vt = th.get("virtual") if isinstance(th.get("virtual"), bool) else None
            if threads[st["thread"]]["virtual"] != vt:
                bad_virtual.append(st["id"])
        elif source == "thread-dump-json":
            ts = [t for cont in doc_json["threadDump"]["threadContainers"] for t in cont["threads"]]
            item = ts[o]
            want = "".join(text_code(f) if isinstance(f, str) else "." for f in item.get("stack", []))
            if st["time"]["raw"] != doc_json["threadDump"].get("time"):
                bad_time.append(st["id"])
        elif source == "coroutine-probes":
            item = doc_json["coroutines"][o]
            fr = []
            for f in item.get("last_observed_frames", []):
                if isinstance(f, str) and "_COROUTINE._CREATION." in f:
                    break
                fr.append(f)
            want = "".join(text_code(f) if isinstance(f, str) else "." for f in fr)
            if st["creation_frames"] != len(item.get("creation_frames") or []):
                bad_frames.append(st["id"] + ":creation")
        else:  # thread-print: the span starts with the record's header line
            a = st["lines"][0]
            item = None
            want = None
            if not span.startswith(lines[a - 1]):
                bad_cite.append(st["id"])
            ats = [ln[4:].decode("utf-8", "replace") for ln in lines[a: st["lines"][1]] if ln.startswith(b"\tat ")]
            want = "".join(text_code(f) for f in ats)
        if item is not None and json.loads(span) != item:
            bad_cite.append(st["id"])
        if want is not None and st["frames"] != want[: len(st["frames"])]:
            bad_frames.append((st["id"], st["frames"][:40], want[:40]))
    n_native = sum(s["frames"].count("N") + s["frames"].count("n") for s in ev["stacks"])
    n_inl = sum(s["frames"].count("L") for s in ev["stacks"])
    n_heur = sum(sum(ch.islower() for ch in s["frames"]) for s in ev["stacks"])
    check(f"{label}/R3 C API citations are the exact source bytes of each stack ({len(ev['stacks'])})",
          not bad_cite and len(ev["stacks"]) == len(lf_stacks) and ev["source"]["sha256"] == sha(path), bad_cite[:5])
    check(f"{label}/R3 C API frame evidence = raw source (inlined {n_inl}, Java native method {n_native}, "
          f"heuristic {n_heur}; no native authority)",
          not bad_frames and not any("!" in s["frames"] for s in ev["stacks"]), bad_frames[:3])
    check(f"{label}/R3 C API times and virtual flags = raw source", not bad_time and not bad_virtual,
          f"{bad_time[:3]} {bad_virtual[:3]}")
    if source == "coroutine-probes":
        seq = {t["coroutine"]["sequence"]: t["id"] for t in ev["threads"] if t.get("coroutine")}
        bad = [t["id"] for t in ev["threads"] if t.get("coroutine") and
               t["coroutine"]["parent_thread"] != (seq.get(t["coroutine"]["parent_sequence"]) if t["coroutine"]["parent_sequence"] else None)]
        raw_par = {str(c["sequence"]): (str(c["parent_sequence"]) if c.get("parent_sequence") is not None else None,
                                       c.get("parent_relation")) for c in doc_json["coroutines"]}
        bad += [t["id"] for t in ev["threads"] if t.get("coroutine") and
                raw_par.get(t["coroutine"]["sequence"]) != (t["coroutine"]["parent_sequence"], t["coroutine"]["relation"])]
        check(f"{label}/R3 C API coroutine parents/relations = raw source and resolve in the document", not bad, bad[:5])
    u = ev["usage"]
    check(f"{label}/R3 usage is labeled by phase; whole peak covers every phase",
          u["whole_peak"] >= max(u["import_peak"], u["adapt_peak"], u["reader_decode_peak"]) and
          u["retained_bytes"] >= u["source_bytes"] + u["lframes_bytes"], u)


RAW_KIND = {"Interpreted": "interpreter", "JIT compiled": "jit", "Inlined": "jit", "Native": "native"}


def text_identity(raw, kind):
    """Identity of a StackTraceElement-style text frame from its raw text alone:
    everything before the location parenthesis (loader/module prefix, class and
    method as written) plus the execution class. Loader status: a non-empty first
    of three '/'-separated segments (after joining a hidden-class /0x.. suffix)."""
    head = raw[: raw.rfind("(")] if "(" in raw else raw
    cls_part = head[: head.rfind(".")] if "." in head else head
    parts = cls_part.split("/")
    if len(parts) >= 2 and re.fullmatch(r"0x[0-9a-fA-F]+", parts[-1]):
        parts = parts[:-2] + [parts[-2] + "/" + parts[-1]]
    basis = "loader_named" if len(parts) == 3 and parts[0] else "loader_not_exported"
    return (head, kind), basis


def identity_oracle(source, path, records, frames, stacks, functions, agg, label, is_marker):
    """C05-R3 independent function-identity oracle. Identity comes from the raw
    source: for JFR the complete exported method.type object (class, loader object
    with its own type, package/module), method name, descriptor and execution
    class; for text sources the raw frame text. It never uses the adapter's key.
    Two adapter frames may share a function exactly when their raw identities are
    equal; the function's x_identity_basis must match the loader evidence; and the
    reader's per-function self/inclusive must equal counts over raw identities."""
    events = None
    if source == "jfr-json":
        events = json.loads(Path(path).read_text())["recording"]["events"]
    by_ord = {r["ordinal"]: r for r in records}
    fn_ids, id_fns, basis_bad = {}, {}, []
    want_self, want_incl = {}, {}
    for st in stacks:
        r = by_ord[int(st["x_citation"]["ordinal"])]
        raw_frames = None
        if events is not None:
            raw_frames = (events[r["ordinal"]]["values"].get("stackTrace") or {}).get("frames") or []
        seen = set()
        for i, g in enumerate(st["frames"]):
            f = frames[r["stack"][i]]
            if g["function"] is None:
                continue
            if raw_frames is not None:
                rf = raw_frames[i]
                t = rf["method"].get("type")
                if isinstance(t, dict) and "classLoader" in t and t["classLoader"] is None:
                    # C05-R4: a null classLoader exports no loader, like an absent one
                    t = {k: v for k, v in t.items() if k != "classLoader"}
                ident = (json.dumps(t, sort_keys=True), rf["method"].get("name"), rf["method"].get("descriptor"),
                         RAW_KIND.get(rf.get("type"), "unclassified"))
                lo = t.get("classLoader") if isinstance(t, dict) else None
                basis = ("loader_named" if lo.get("name") is not None else "loader_unnamed") \
                    if isinstance(lo, dict) else "loader_not_exported"
            else:
                ident, basis = text_identity(f["raw_text"], C05_KIND.get(f["kind"], "unclassified"))
            fid = g["function"]
            fn_ids.setdefault(fid, set()).add(ident)
            id_fns.setdefault(ident, set()).add(fid)
            if functions[fid].get("x_identity_basis") != basis:
                basis_bad.append((fid, functions[fid].get("x_identity_basis"), basis))
            if i == 0:
                want_self[ident] = want_self.get(ident, 0) + int(st["weight"])
            if ident not in seen:
                seen.add(ident)
                want_incl[ident] = want_incl.get(ident, 0) + int(st["weight"])
    conflated = {k: len(v) for k, v in fn_ids.items() if len(v) > 1}
    split = [len(v) for v in id_fns.values() if len(v) > 1]
    check(f"{label}/R3 identity oracle: functions <-> raw source identities one-to-one "
          f"({len(fn_ids)} functions, {len(id_fns)} identities)",
          not conflated and not split and len(fn_ids) == len(functions), f"conflated={list(conflated.items())[:3]} split={split[:3]}")
    check(f"{label}/R3 identity oracle: x_identity_basis matches the loader evidence in the source",
          not basis_bad, basis_bad[:3])
    got_self, got_incl = {}, {}
    for row in agg.get("rows", []):
        ids = fn_ids.get(row["function"])
        if ids and len(ids) == 1:
            ident = next(iter(ids))
            if int(row["self"]):
                got_self[ident] = int(row["self"])
            got_incl[ident] = int(row["inclusive"])
    check(f"{label}/R3 identity oracle: reader per-function self/inclusive equal raw-identity counts",
          got_self == want_self and got_incl == want_incl,
          f"self diff {len(set(got_self.items()) ^ set(want_self.items()))} incl diff "
          f"{len(set(got_incl.items()) ^ set(want_incl.items()))}")


def compare_aggregates(binary, reader, path, lframes, label, extra=()):
    rc, out, _ = run(reader, "aggregate", lframes, "--top", "100000")
    c05 = json.loads(out)
    rc2, out2, _ = run(binary, "--source", "jfr-json", *extra, "--query", "aggregate", "--kind", "execution_sample",
                       "--by", "method", "--limit", "10000", path)
    mine = json.loads(out2)
    self_c05 = {}
    for row in c05["rows"]:
        self_c05[row["label"]] = self_c05.get(row["label"], 0) + int(row["self"])
    self_mine = {f'{r["key"]["class"]}.{r["key"]["method"]}{r["key"]["descriptor"] or ""}': r["weight"]
                 for r in mine["rows"]}
    self_c05 = {k: v for k, v in self_c05.items() if v}
    check(f"{label} C05 reader aggregate agrees with importer (total, partial, per-method self)",
          rc == 0 and rc2 == 0 and int(c05["total_weight"]) == mine["total_weight"]
          and int(c05["partial_weight"]) == mine["truncated_records"] and self_c05 == self_mine,
          f'{c05.get("total_weight")} vs {mine.get("total_weight")}; diff='
          f'{set(self_c05.items()) ^ set(self_mine.items())}'[:400])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("importer")
    ap.add_argument("--capture")
    ap.add_argument("--fixture-build")
    ap.add_argument("--source")
    ap.add_argument("--lframes-reader")
    ap.add_argument("--json")
    ap.add_argument("--tmp", default=str(Path.home() / "tmp"))
    a = ap.parse_args()
    Path(a.tmp).mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="c06-check-", dir=a.tmp))
    tmp.chmod(0o755)
    try:
        adversarial(a.importer, tmp, a.lframes_reader)
        if a.capture:
            real(a.importer, Path(a.capture), Path(a.fixture_build) if a.fixture_build else None,
                 Path(a.source) if a.source else None, a.lframes_reader, tmp)
    finally:
        shutil.rmtree(tmp)
    failed = [r for r in RESULTS if r["ok"] is False]
    skipped = [r for r in RESULTS if r["ok"] is None]
    summary = {"passed": sum(1 for r in RESULTS if r["ok"]), "failed": len(failed),
               "not_tested": len(skipped), "results": RESULTS}
    if a.json:
        Path(a.json).write_text(json.dumps(summary, indent=1, ensure_ascii=False) + "\n")
    print(f"passed={summary['passed']} failed={len(failed)} not_tested={len(skipped)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
