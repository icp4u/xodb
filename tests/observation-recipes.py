#!/usr/bin/env python3
"""Owned function observations through the production CLI and immutable MCP.

Use --helper PATH to explicitly permit the existing sudo helper. XODB_BIN and
XODB_RUNTIME_AGENT follow tests/client.py; run once without/with the latter.
Artifacts use --work-root, XODB_TEST_TMPDIR, or the TMPDIR-aware system default.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from client import Client

ROOT = Path(__file__).resolve().parents[1]
MAGIC = b"XODBINVOC\x01\r\n"
NORMAL_REASONS = {"stop_symbol", "duration", "target_exit", "limit"}


def process_identity(pid):
    try:
        return (pid, Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19])
    except (FileNotFoundError, ProcessLookupError):
        return None


def descendants(pid):
    result = []
    pending = [pid]
    while pending:
        current = pending.pop()
        try:
            children = Path(f"/proc/{current}/task/{current}/children").read_text().split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        for child in children:
            child = int(child)
            result.append(child)
            pending.append(child)
    return result


def word(value):
    assert isinstance(value, str) and value.startswith("0x"), value
    return int(value, 16)


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", help="explicit allocation/function helper executable")
    parser.add_argument("--work-root", default=os.environ.get("XODB_TEST_TMPDIR"))
    parser.add_argument("--fixture", default=str(ROOT / "zig-out/bin/xodb-observation-fixture"))
    options = parser.parse_args()
    os.chdir(ROOT)
    binary = Path(os.environ.get("XODB_BIN", "./zig-out/bin/xodb")).resolve()
    os.environ["XODB_BIN"] = str(binary)
    work = Path(tempfile.mkdtemp(prefix="xodb-observation-recipes-", dir=options.work_root)).resolve()
    work.chmod(0o755)
    print(work, flush=True)
    fixture = work / "fixture"
    if Path(options.fixture).is_file():
        shutil.copyfile(options.fixture, fixture)
        fixture.chmod(0o755)
    else:
        subprocess.run(["cc", "-g", "-O0", "-fno-omit-frame-pointer", "-fno-optimize-sibling-calls", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/fixtures/observations.c"), "-o", str(fixture)], check=True, env=dict(os.environ, TMPDIR=str(work)))
    # Isolated adverse fixture derived from the same owned C source. Its stdout
    # must be redirected away from CLI JSON, and its peer must settle at phase.
    source = (ROOT / "tests/fixtures/observations.c").read_text()
    source = source.replace("#include <stdint.h>", "#include <stdint.h>\n#include <signal.h>\n#include <pthread.h>\n#include <stdatomic.h>")
    source = source.replace("int main(int argc, char **argv) {", """static atomic_int peer_running = 1;
static void *peer(void *unused) {
    (void)unused;
    while (atomic_load(&peer_running)) {
        struct timespec delay = { .tv_nsec = 1000000 };
        nanosleep(&delay, 0);
    }
    return 0;
}
int main(int argc, char **argv) {""")
    source = source.replace("    observation_ready();", """    pthread_t sibling;
    const int threaded = !strcmp(mode, "threads");
    if (threaded && pthread_create(&sibling, 0, peer, 0)) return 4;
    if (!strcmp(mode, "noisy")) { puts("owned-fixture-stdout-before"); fflush(stdout); }
    observation_ready();
    if (!strcmp(mode, "noisy")) { puts("owned-fixture-stdout-during"); fflush(stdout); }
    if (!strcmp(mode, "signal")) raise(SIGUSR1);""")
    source = source.replace("    observation_done();", """    observation_done();
    if (threaded) { atomic_store(&peer_running, 0); pthread_join(sibling, 0); }""")
    adverse_source = work / "adverse.c"
    adverse_source.write_text(source)
    adverse = work / "adverse-fixture"
    subprocess.run(["cc", "-g", "-O0", "-pthread", "-fno-omit-frame-pointer", "-fno-optimize-sibling-calls", "-Wall", "-Wextra", "-Werror", str(adverse_source), "-o", str(adverse)], check=True, env=dict(os.environ, TMPDIR=str(work)))
    base = json.loads((ROOT / "examples/observation.recipe.json").read_text())
    live_options = ["--allocation-helper", str(Path(options.helper).resolve())] if options.helper else []
    if os.environ.get("XODB_RUNTIME_AGENT"):
        live_options += ["--runtime-agent", str(Path(os.environ["XODB_RUNTIME_AGENT"]).resolve())]

    def execute(label, args, expected=0):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=90)
        (work / f"{label}.stdout").write_text(result.stdout)
        (work / f"{label}.stderr").write_text(result.stderr)
        if expected == 0:
            assert result.returncode == 0, (label, result.returncode, result.stderr)
        elif expected == "failure":
            assert result.returncode != 0, label
        return result

    def capture(label, mode="balanced", overrides=None, interrupted=False, target=fixture):
        config = dict(base, **(overrides or {}))
        recipe = work / f"{label}.recipe.json"
        recipe.write_text(json.dumps(config))
        archive = work / f"{label}.xoi"
        result = execute(label, ["--observe-recipe", str(recipe), "--observation-out", str(archive), *live_options, "--", str(target), mode], None if interrupted else 0)
        value = json.loads(result.stdout)
        reason = value["outcome"]["reason"]
        assert (result.returncode == 0) == (reason in NORMAL_REASONS), (label, reason, result.stderr)
        assert value["archive"]["publication"]["state"] == "published", value
        assert value["observation"]["state"] == "completed" and not value["observation"]["cleanup_pending"], value
        assert json.loads(value["observation"]["recipe_json"]) == config, value
        return archive, value

    archive, balanced = capture("balanced")
    observed, cohorts = balanced["observation"], balanced["comparison"]
    assert observed["records"] == 32 and observed["calls"] == 16 and observed["first_gap"] is None, observed
    assert cohorts["fast"]["count"] == cohorts["slow"]["count"] == 8, cohorts
    for name, arg, ret in (("fast", 0, 0xF000000000000006), ("slow", 1, 0xF000000000000007)):
        row = cohorts[name]
        assert word(row["arguments"][0]["values"][0]["value"]) == arg, row
        assert word(row["arguments"][1]["values"][0]["value"]) == 0xF000000000000002, row
        assert word(row["returns"]["values"][0]["value"]) == ret, row
        assert isinstance(row["duration"]["total_ns"], str), row
    print("balanced: 16 complete, fast8/slow8, exact high-bit words", flush=True)

    _, recursive = capture("recursive", "recursive", {"functions": ["observed_recursive"]})
    assert recursive["comparison"]["summary"]["complete_calls"] == 5, recursive
    _, limited = capture("limit", "limit", {"record_limit": 6})
    assert limited["observation"]["records"] == 6 and limited["observation"]["stop_reason"] == "record_limit" and limited["observation"]["first_gap"], limited
    _, partial = capture("duration", "limit", {"duration_ms": 5})
    assert partial["outcome"]["reason"] == "duration" and partial["comparison"]["summary"]["incomplete_calls"] >= 1 and partial["observation"]["first_gap"], partial
    _, stackless = capture("stackless", overrides={"callstacks": False})
    assert stackless["comparison"]["summary"]["complete_calls"] == 16, stackless
    _, changed = capture("exec", "exec", interrupted=True)
    assert changed["observation"]["stop_reason"] == "image_changed" and changed["observation"]["unread_possible"], changed
    _, exited = capture("exit", "exit", interrupted=True)
    assert exited["observation"]["stop_reason"] in ("target_ended", "thread_ended"), exited
    _, threaded = capture("threads", "threads", target=adverse)
    assert len(threaded["observation"]["threads"]) == 2 and threaded["comparison"]["summary"]["complete_calls"] == 16, threaded
    _, noisy = capture("noisy", "noisy", target=adverse)
    assert noisy["comparison"]["summary"]["complete_calls"] == 16 and "owned-fixture-stdout-before" in (work / "noisy.stderr").read_text() and "owned-fixture-stdout-during" in (work / "noisy.stderr").read_text(), noisy
    _, signalled = capture("signal", "signal", interrupted=True, target=adverse)
    assert signalled["outcome"]["reason"] == "signal" and signalled["observation"]["calls"] == 0, signalled
    print("recursion, limits, partial duration, stackless, exec, exit, peer-thread phase, noisy stdout and signal: explicit evidence", flush=True)

    # Deliver SIGINT only after an owned fixture is sleeping in observed_work;
    # setup cancellation would not necessarily have a published capture to save.
    cancel_recipe = work / "cancel.recipe.json"
    cancel_recipe.write_text(json.dumps(base))
    cancel_archive = work / "cancel.xoi"
    p = subprocess.Popen([str(binary), "--observe-recipe", str(cancel_recipe), "--observation-out", str(cancel_archive), *live_options, "--", str(fixture), "limit"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    owned = set()
    try:
        deadline = time.monotonic() + 15
        while True:
            assert p.poll() is None, "recipe exited before cancellation"
            ready = False
            for pid in descendants(p.pid):
                try:
                    if Path(f"/proc/{pid}/exe").resolve() != fixture:
                        continue
                    identity = process_identity(pid)
                    if identity:
                        owned.add(identity)
                    state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
                    ready |= state == "S"
                except (FileNotFoundError, ProcessLookupError):
                    pass
            if ready:
                p.send_signal(signal.SIGINT)
                break
            assert time.monotonic() < deadline, "fixture did not reach observed sleep"
            time.sleep(.002)
        out, err = p.communicate(timeout=20)
        (work / "cancel.stdout").write_text(out)
        (work / "cancel.stderr").write_text(err)
        value = json.loads(out)
        assert p.returncode != 0 and value["outcome"]["reason"] == "cancelled" and cancel_archive.is_file(), (value, err)
        assert not value["observation"]["cleanup_pending"], value
        deadline = time.monotonic() + 5
        while any(process_identity(identity[0]) == identity for identity in owned):
            assert time.monotonic() < deadline, ("owned fixture remained after CLI cleanup", owned)
            time.sleep(.01)
    finally:
        if p.poll() is None:
            p.kill()
            p.communicate(timeout=5)
    print("SIGINT: saved interrupted evidence and reaped owned fixture", flush=True)

    original = archive.read_bytes()
    denied = execute("no-overwrite", ["--observe-recipe", str(work / "balanced.recipe.json"), "--observation-out", str(archive), *live_options, "--", str(fixture)], "failure")
    assert "ObservationArchiveNotPublished" in denied.stderr and archive.read_bytes() == original, denied.stderr
    assert not list(work.glob(".xodb-*")), list(work.iterdir())

    # Move both evidence and executable. Reopening must be entirely self-contained.
    moved = work / "relocated.xoi"
    archive.rename(moved)
    fixture.rename(work / "fixture-unavailable")
    reopened = json.loads(execute("reopened", ["--open-observation", str(moved)]).stdout)
    assert reopened["observation"]["offline"] and reopened["comparison"] == cohorts, reopened
    assert reopened["observation"]["recipe_json"] == observed["recipe_json"], reopened
    override = json.loads(execute("threshold-override", ["--open-observation", str(moved), "--observation-threshold-ns", "0"]).stdout)
    assert override["comparison"]["fast"]["count"] == 0 and override["comparison"]["slow"]["count"] == 16, override

    client = Client("observe", None, options=["--open-observation", str(moved)])
    try:
        status = client.inspect("get_observation")
        identity = status["identity"]
        selection = {key: identity[key] for key in ("session_id", "capture_id")}

        def pages(tool, field):
            values, start = [], 0
            while True:
                page = client.inspect(tool, **selection, start=start, limit=7)
                values += page[field]
                if page["next"] is None:
                    return values
                start = page["next"]

        calls = pages("get_observation_calls", "calls")
        records = pages("get_observation_records", "records")
        assert len(calls) == 16 and len(records) == 32, (calls, records)
        for i, row in enumerate(calls):
            assert row["call"]["reason"] == "complete" and row["call"]["entry_record"] == 2 * i and row["call"]["return_record"] == 2 * i + 1, row
            assert word(row["args"][0]) == i % 2 and word(row["args"][1]) == 0xF000000000000002, row
            assert word(row["result"]) == 0xF000000000000006 + i % 2, row
            assert row["duration_ns"] == row["end_ns"] - row["start_ns"], row
        job = client.inspect("compare_observation", **selection, threshold_ns=4000000, argument_index=1, argument_value="0xf000000000000002")
        deadline = time.monotonic() + 10
        while True:
            result = client.inspect("get_observation_comparison", id=job["id"])
            if result["state"] != "running":
                break
            assert time.monotonic() < deadline, result
            time.sleep(.002)
        assert result["state"] == "completed" and result["result"]["fast"]["count"] == result["result"]["slow"]["count"] == 8, result
        assert pages("get_observation_calls", "calls") == calls and pages("get_observation_records", "records") == records
        bad = client.tool("get_observation_calls", **dict(selection, capture_id=identity["capture_id"] + 1))
        assert bad["result"]["isError"] and "StaleObservation" in bad["result"]["content"][0]["text"], bad
        mutate = client.tool("stop_observation", generation=client.session()["generation"], **selection)
        assert mutate["result"]["isError"], mutate
        assert moved.read_bytes() == original, "analysis changed the archive"
    finally:
        (work / "offline-mcp.json").write_text(json.dumps(client.transcript, indent=2))
        client.close()
    print("relocated offline CLI/MCP: exact immutable calls/records, paged citations and high-bit filter", flush=True)

    corrupt = work / "corrupt.xoi"
    damaged = bytearray(original)
    damaged[-1] ^= 1
    corrupt.write_bytes(damaged)
    bad = execute("corrupt", ["--open-observation", str(corrupt)], "failure")
    assert "ArchiveChecksum" in bad.stderr, bad.stderr
    assert original.startswith(MAGIC)
    body = json.loads(original[len(MAGIC) + 32:])
    body["version"] = 2
    payload = json.dumps(body, separators=(",", ":")).encode()
    version = work / "future-version.xoi"
    version.write_bytes(MAGIC + hashlib.sha256(payload).digest() + payload)
    bad = execute("future-version", ["--open-observation", str(version)], "failure")
    assert "ObservationArchiveVersion" in bad.stderr, bad.stderr
    print("no-overwrite, checksum corruption and unsupported version: rejected", flush=True)
    print("PASS", "agent" if os.environ.get("XODB_RUNTIME_AGENT") else "native", work, flush=True)


if __name__ == "__main__":
    main()
