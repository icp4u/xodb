#!/usr/bin/env python3
"""Independent-consumer check: record the owned JIT fixture with perf
(CLOCK_MONOTONIC) and let "perf inject -j" read the fixture's jitdump. perf's
generated ELF symbols/code bytes and its MMAP2 timestamps must match the
fixture ground truth. The full dump (with JIT_CODE_MOVE) is injected
separately because perf 7.2.6 was observed to crash on CODE_MOVE; that result
is recorded, not hidden. Build-id cache writes stay under OUT_DIR.

usage: jitmap-perf-crosscheck.py BUILD_DIR OUT_DIR
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys

build, out = sys.argv[1], os.path.abspath(sys.argv[2])
os.makedirs(out, mode=0o755, exist_ok=True)
env = dict(os.environ, PERF_BUILDID_DIR=os.path.join(out, "buildid"), DEBUGINFOD_URLS="")
report = {"perf": None, "status": "not_tested", "checks": [], "failures": []}


def check(cond, what):
    report["checks"].append(what)
    if not cond:
        report["failures"].append(what)


def done(code):
    print(json.dumps(report, indent=1))
    sys.exit(code)


if not shutil.which("perf"):
    report["reason"] = "perf not installed"
    done(0)
report["perf"] = subprocess.run(["perf", "version"], capture_output=True, text=True).stdout.strip()
data = os.path.join(out, "perf.data")
p = subprocess.run(["perf", "record", "-k", "mono", "-N", "-q", "-o", data, "--",
                    os.path.join(build, "jit-fixture"), out], capture_output=True, text=True, env=env, timeout=60)
if p.returncode != 0:
    report.update(status="permission_denied" if "paranoid" in p.stderr or "ermission" in p.stderr else "failed",
                  reason=p.stderr[-600:])
    done(0 if report["status"] == "permission_denied" else 1)
pid = p.stdout.strip().splitlines()[-1]
dump = os.path.join(out, "jit-%s.dump" % pid)
truth = {"loads": []}
for line in open(os.path.join(out, "truth-%s.txt" % pid), encoding="utf-8"):
    if line.startswith("load "):
        f = dict(re.findall(r"(\w+)=(\S+)", line.split(" name=")[0]))
        f["name"] = line.rstrip("\n").split(" name=", 1)[1]
        truth["loads"].append(f)
original = open(dump, "rb").read()


def without(ids):
    body, at = original[:40], 40
    while at + 16 <= len(original):
        rid, size = struct.unpack_from("<II", original, at)
        if rid not in ids:
            body += original[at:at + size]
        at += size
    return body


def inject(name):
    for f in os.listdir(out):
        if f.startswith("jitted-"):
            os.remove(os.path.join(out, f))
    target = os.path.join(out, name)
    q = subprocess.run(["perf", "inject", "-j", "-i", data, "-o", target], capture_output=True, text=True, env=env,
                       timeout=120)
    return q.returncode, target


# 1. Without CODE_MOVE (perf reads the dump path recorded in the MMAP event).
open(dump, "wb").write(without({1}))
rc, injected = inject("perf.jit-nomove.data")
check(rc == 0, "perf inject -j succeeds without CODE_MOVE (rc=%d)" % rc)
mm = subprocess.run(["perf", "script", "-i", injected, "--show-mmap-events"], capture_output=True, text=True,
                    env=env, timeout=60).stdout
events = re.findall(r"(\d+)\.(\d+): PERF_RECORD_MMAP2 \d+/\d+: \[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ \S+ .*?(jitted-\d+-(\d+)\.so)",
                    mm)
check(len(events) == len(truth["loads"]), "one injected MMAP2 per CODE_LOAD (%d)" % len(events))
for sec, frac, start, size, so, index in events:
    load = [l for l in truth["loads"] if l["index"] == index][0]
    check(int(start, 16) == int(load["addr"], 16) and int(size, 16) == int(load["size"], 16),
          "index %s mmap range" % index)
    t = int(sec) * 10**9 + int(frac) * 10**(9 - len(frac))
    check(abs(t - int(load["time"])) < 1000, "index %s mmap time equals load timestamp (us resolution)" % index)
    elf = os.path.join(out, so)
    check(load["name"].encode() + b"\0" in open(elf, "rb").read(), "index %s symbol name bytes in perf ELF" % index)
    raw = subprocess.run(["objcopy", "-O", "binary", "-j", ".text", elf, elf + ".text"], capture_output=True)
    code = open(elf + ".text", "rb").read() if raw.returncode == 0 else b""
    check(load["code"] in code.hex(), "index %s code bytes in perf ELF .text" % index)
    if index == "1":
        lines = subprocess.run(["readelf", "--debug-dump=decodedline", elf], capture_output=True, text=True).stdout
        check(re.search(r"fixture-alpha\.toy\s+1\s+0x[0-9a-f]+", lines) is not None and
              re.search(r"fixture-alpha\.toy\s+2\s+0x[0-9a-f]+", lines) is not None,
              "debug info lines 1 and 2 (incl. 0xff repeated name) in perf ELF")
    report.setdefault("injected", []).append({"index": index, "start": start, "size": size, "elf": so})

# 2. The complete dump including CODE_MOVE.
open(dump, "wb").write(original)
rc, injected = inject("perf.jit-full.data")
report["full_dump_inject_rc"] = rc
report["perf_move_concern"] = ("perf inject -j crashed (signal %d) on the dump containing JIT_CODE_MOVE" % -rc
                               if rc < 0 or rc >= 128 else "no crash with JIT_CODE_MOVE (rc=%d)" % rc)
for f in os.listdir(out):
    if f.startswith("jitted-") or f.endswith(".text"):
        os.remove(os.path.join(out, f))
shutil.rmtree(os.path.join(out, "buildid"), ignore_errors=True)
report["status"] = "supported" if not report["failures"] else "failed"
done(1 if report["failures"] else 0)
