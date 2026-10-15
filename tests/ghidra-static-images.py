#!/usr/bin/env python3
"""Owned PE and arm64 Mach-O image-only pseudo-C integration."""
import atexit
import ctypes
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
ghidra = os.environ.get("GHIDRA_HOME") or os.environ.get("XODB_GHIDRA_HOME")
if not ghidra or not (Path(ghidra) / "support/analyzeHeadless").exists():
    print("skip: static PE/Mach-O Ghidra test (set GHIDRA_HOME)")
    raise SystemExit(0)

ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)
work = Path(tempfile.mkdtemp(prefix="xodb-ghs-", dir=os.environ.get("XODB_TEST_TMPDIR")))
atexit.register(shutil.rmtree, work, True)
source = ROOT / "tests/fixtures/semq/static-image.c"
pe_object, pe, macho = work / "static.obj", work / "static.exe", work / "static-arm64"
subprocess.run(["clang", "--target=x86_64-pc-windows-msvc", "-O2", "-g", "-gcodeview", "-c", str(source), "-o", str(pe_object)], check=True, timeout=60)
subprocess.run(["lld-link", "/entry:entry", "/subsystem:console", "/machine:x64", "/debug", "/pdb:" + str(work / "static.pdb"), "/pdbaltpath:static.pdb", "/out:" + str(pe), str(pe_object)], check=True, timeout=60)
subprocess.run(["zig", "cc", "-target", "aarch64-macos", "-O2", "-g", str(source), "-o", str(macho)], check=True, timeout=120)

starter = ROOT / "scripts/ghidra-sidecar"
environment = os.environ.copy()
environment.update(
    XDG_RUNTIME_DIR=str(work / "run"),
    XODB_GHIDRA_SOCKET=str(work / "run/.xodb.ghidra.s"),
    XODB_GHIDRA_SIDECAR=str(starter),
    XODB_GHIDRA_HOME=ghidra,
    XODB_GHIDRA_CACHE=str(work / "cache"),
    XODB_GHIDRA_STATE=str(work / "state"),
    XODB_GHIDRA_XMX="2g",
    XODB_GHIDRA_SOFT_MAX="512m",
)
binary = Path(os.environ.get("XODB_BIN", ROOT / "zig-out/bin/xodb"))
try:
    for label, image in (("PE", pe), ("arm64 Mach-O", macho)):
        run = subprocess.run([str(binary), "--decompile", str(image), "--function", "xodb_static_target"],
                             env=environment, capture_output=True, text=True, timeout=240)
        assert run.returncode == 0, (label, run.returncode, run.stderr)
        assert "xodb_static_target" in run.stdout and "0x55" in run.stdout and "* 7" in run.stdout, (label, run.stdout)
        if label == "PE":
            sidecar_log = (work / "state/sidecar.log").read_text(errors="replace")
            assert "PDB analyzer parsing file:" in sidecar_log, sidecar_log
            assert "PDB Function Internals Processing Terminated Normally" in sidecar_log, sidecar_log
        print(f"pass: static {label} pseudo-C")
finally:
    subprocess.run([str(starter), "stop"], env=environment, check=False, timeout=20,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.waitpid(-1, os.WNOHANG)[0] == 0:
            time.sleep(.02)
    except ChildProcessError:
        break
else:
    raise AssertionError("the stopped static-image sidecar left a process behind")
