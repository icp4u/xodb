#!/usr/bin/env python3
"""Run owned C06 JVM fixtures and capture declared-source evidence.

Only the JVM launched here is inspected (jcmd/jfr against its own PID). Each run
produces raw files plus capture-manifest.json listing commands, exit statuses,
SHA-256 digests, tool versions and process identity (pid, boot id, JVM start).
Usage: capture.py BUILD_DIR OUT_DIR [--seconds N] [--java-only]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

os.umask(0o022)
STACK_DEPTH = 2048  # >= JFR's recording stackdepth (64 by default, at most 2048)
EVENTS = ("jdk.ExecutionSample,jdk.NativeMethodSample,jdk.JavaExceptionThrow,"
          "jdk.JavaErrorThrow,jdk.JVMInformation,jdk.OSInformation,jdk.ActiveRecording,"
          "jdk.ThreadStart,jdk.ThreadEnd,jdk.VirtualThreadStart,jdk.VirtualThreadEnd,"
          "jdk.VirtualThreadPinned,jdk.CPUInformation")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def env():
    e = dict(os.environ)
    for key in ("DISPLAY", "WAYLAND_DISPLAY"):
        e.pop(key, None)
    return e


def run(manifest, label, argv, out=None, limit=120):
    start = time.time()
    with open(out, "wb") if out else open(os.devnull, "wb") as sink:
        p = subprocess.run(argv, stdout=sink, stderr=subprocess.PIPE, timeout=limit, env=env())
    record = {"label": label, "argv": argv, "exit": p.returncode,
              "seconds": round(time.time() - start, 3),
              "stderr": p.stderr.decode("utf-8", "replace")[-2000:]}
    if out:
        record["output"] = os.path.basename(out)
    manifest["commands"].append(record)
    if p.returncode != 0:
        raise SystemExit(f"{label} failed ({p.returncode}): {record['stderr']}")


def capture(name, argv_tail, out, manifest, seconds, probes, extra_jvm):
    out.mkdir(parents=True, exist_ok=True)
    jfr_file = out / "recording.jfr"
    ready = out / "ready.pid"
    if ready.exists():
        ready.unlink()
    jvm = ["java", "-Xmx256m", "-Djava.awt.headless=true",
           "-XX:+UnlockDiagnosticVMOptions", "-XX:+DebugNonSafepoints",
           f"-XX:StartFlightRecording:filename={jfr_file},settings=profile,"
           "jdk.JavaExceptionThrow#enabled=true,jdk.VirtualThreadStart#enabled=true,"
           "jdk.VirtualThreadEnd#enabled=true,dumponexit=true"] + extra_jvm
    argv = jvm + argv_tail(str(seconds), str(ready))
    started = time.time()
    log = open(out / "fixture.stdout", "wb")
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, env=env(),
                            start_new_session=True)
    record = {"name": name, "argv": argv, "pid": proc.pid, "probes": probes,
              "launched_unix": started}
    manifest["runs"].append(record)
    try:
        deadline = time.time() + 30
        while not ready.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.05)
        if not ready.exists():
            raise SystemExit(f"{name}: fixture never became ready")
        reported = int(ready.read_text().strip())
        if reported != proc.pid:
            raise SystemExit(f"{name}: PID mismatch {reported} != {proc.pid}")
        time.sleep(max(1.0, seconds * 0.3))
        pid = str(proc.pid)
        if not probes:
            run(manifest, f"{name}:thread-print", ["jcmd", pid, "Thread.print", "-l"],
                str(out / "thread-print.txt"), 60)
            dump = out / "thread-dump.json"
            run(manifest, f"{name}:thread-dump-json",
                ["jcmd", pid, "Thread.dump_to_file", "-format=json", str(dump)], None, 60)
        rc = proc.wait(timeout=seconds + 60)
        record["exit"] = rc
    finally:
        if proc.poll() is None:
            os.kill(proc.pid, signal.SIGKILL)  # only our own fixture PID
            proc.wait()
            record["killed"] = True
        log.close()
    record["reaped"] = proc.returncode is not None
    run(manifest, f"{name}:jfr-summary", ["jfr", "summary", str(jfr_file)],
        str(out / "jfr-summary.txt"))
    # jfr print cuts stacks to 5 frames by default while keeping truncated=false.
    run(manifest, f"{name}:jfr-json", ["jfr", "print", "--json", "--stack-depth", str(STACK_DEPTH),
                                       "--events", EVENTS, str(jfr_file)],
        str(out / "recording.json"), 300)
    record["files"] = {p.name: {"sha256": sha(p), "bytes": p.stat().st_size}
                       for p in sorted(out.iterdir()) if p.is_file()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("build")
    ap.add_argument("out")
    ap.add_argument("--seconds", type=int, default=6)
    ap.add_argument("--java-only", action="store_true")
    a = ap.parse_args()
    build, out = Path(a.build).resolve(), Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    out.chmod(0o755)
    version = subprocess.run(["java", "-version"], capture_output=True, text=True).stderr
    manifest = {"format": "xodb-c06-capture", "version": 1,
                "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                "java_version_output": version, "build_manifest":
                json.loads((build / "build-manifest.json").read_text()),
                "jfr_events": EVENTS.split(","), "jfr_print_stack_depth": STACK_DEPTH,
                "commands": [], "runs": []}
    java_cp = str(build / "c06-java-fixture.jar")
    capture("java", lambda s, r: ["-cp", java_cp, "xodb.c06j.C06JavaFixture", s, r],
            out / "java", manifest, a.seconds, False, [])
    kotlin = build / "c06-kotlin-fixture.jar"
    if not a.java_only and kotlin.exists():
        runtime = (build / "kotlin-runtime-classpath.txt").read_text().split()
        cp = ":".join([str(kotlin)] + runtime)
        coroutines = [p for p in runtime if "coroutines" in p][0]
        capture("kotlin", lambda s, r: ["-cp", cp, "xodb.c06.C06Fixture", s, r],
                out / "kotlin", manifest, a.seconds, False, [])
        probe_file = out / "kotlin-probes" / "coroutine-probes.json"
        capture("kotlin-probes",
                lambda s, r: ["-cp", cp, "xodb.c06.C06Fixture", s, r, str(probe_file)],
                out / "kotlin-probes", manifest, a.seconds, True,
                [f"-javaagent:{coroutines}", "-Dkotlinx.coroutines.debug=on",
                 "-Dkotlinx.coroutines.debug.enable.creation.stack.trace=true"])
        # Probe file sits in the run directory; refresh its hash after the run.
        run_record = manifest["runs"][-1]
        run_record["files"]["coroutine-probes.json"] = {"sha256": sha(probe_file),
                                                       "bytes": probe_file.stat().st_size}
    else:
        manifest["kotlin"] = "unavailable: Kotlin acceptance unverified"
    (out / "capture-manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(out / "capture-manifest.json")


if __name__ == "__main__":
    sys.exit(main())
