#!/usr/bin/env python3
"""Runner component tests. Synthetic collection is labelled; replay uses real xodb.

XODB_BIN selects the real archive reader. --work-root retains owned fixtures/logs.
"""
import argparse
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools/experiments/run.py"
module = importlib.util.spec_from_file_location("experiments", RUNNER)
r = importlib.util.module_from_spec(module)
module.loader.exec_module(r)
MAGIC = b"XODBINVOC\x01\r\n"


def fixture(duration):
    identity = dict(session_id=1, capture_id=2, process_id=3, pid=100, image_epoch=4, generation=5)
    function = dict(id=1, name="work", path="/untrusted/never-open-this", identity=dict(device=1, inode=2, size=4096, mtime_sec=0, mtime_ns=0, ctime_sec=0, ctime_ns=0), file_offset=100, link_address=100, runtime_address=0x400100)
    records = []
    for ordinal, (phase, timestamp) in enumerate((("enter", 20), ("leave", 20+duration))):
        records.append(dict(ordinal=ordinal, event=dict(thread_id=1, tid=100, time_ns=timestamp, data=dict(sample=dict(phase=phase, function_id=1, stack_key=4096)))))
    evidence = dict(metadata=dict(identity=identity, started_ns=10, ended_ns=100, threads=[dict(id=1, tid=100)], functions=[function], config={}, stop_reason="manual", finish_reason="capture_end", comparison_selection=dict(threshold_ns=10)), records=records, calls=[dict(id=0, thread_id=1, tid=100, function_id=1, entry_record=0, return_record=1, reason="complete")], first_gap=None, unread_possible=False, rejected=0)
    body = json.dumps(dict(version=1, pairing_algorithm="xodb-invocation-pairing-v1", evidence=evidence)).encode()
    return MAGIC + hashlib.sha256(body).digest() + body


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="experiment-components-", dir=OPTIONS.work_root)).resolve()
        cls.work.chmod(0o755)
        print(cls.work, flush=True)
        cls.xodb = str(Path(os.environ.get("XODB_BIN", ROOT / "zig-out/bin/xodb")).resolve())
        for duration in (5, 6, 7, 10, 12, 14):
            path = cls.work / f"golden-{duration}.xoi"
            path.write_bytes(fixture(duration))
            proc = subprocess.run([cls.xodb, "--open-observation", str(path)], capture_output=True, timeout=60)
            if proc.returncode:
                raise AssertionError(proc.stderr.decode())
            value = json.loads(proc.stdout)
            value["outcome"] = dict(reason="stop_symbol")
            value["archive"]["publication"] = dict(state="published")
            (cls.work / f"golden-{duration}.json").write_text(json.dumps(value))
        cls.recipe = cls.work / "recipe.json"
        cls.recipe.write_text((ROOT / "examples/observation.recipe.json").read_text())
        cls.input = cls.work / "input.txt"
        cls.input.write_text("original")
        script = cls.work / "synthetic-collector.py"
        script.write_text('''import hashlib,json,os,pathlib,signal,subprocess,sys,time
w=pathlib.Path(__file__).resolve().parent
a=sys.argv[1:]; destination=pathlib.Path(a[a.index('--observation-out')+1]); index=int(destination.parent.name.split('-')[1]); args=a[a.index('--')+2:]; mode=args[0] if args else 'baseline'
if mode=='failed' or (mode=='oncefail' and index==1): sys.exit(7)
if mode in ('timeout','cancel'):
 p=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'],start_new_session=True)
 (w/'child-pid').write_text(str(p.pid)); time.sleep(60)
if mode=='output':
 while True: os.write(1,b'x'*65536)
if mode=='twofiles':
 for i in range(5): (destination.parent/f'extra-{i}').write_bytes(b'x'*(1536*1024))
if mode=='input':
 (w/'pin-ready').write_text('ready'); time.sleep(.4); (w/'pin-read').write_bytes(pathlib.Path(args[1]).read_bytes())
duration=([5,6,7] if mode=='changed' else [10,12,14])[index%3]
raw=(w/f'golden-{duration}.xoi').read_bytes();destination.write_bytes(raw)
value=json.loads((w/f'golden-{duration}.json').read_text());value['archive']['sha256']=hashlib.sha256(raw).hexdigest();print(json.dumps(value))
''')
        wrapper = cls.work / "wrapper.c"
        wrapper.write_text('''#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
 char **v = calloc((size_t)argc+2, sizeof(*v)); if (!v) return 2;
 v[0]="python3"; v[1]=SCRIPT; for (int i=1;i<argc;i++) v[i+1]=argv[i];
 execvp(v[0],v); return 127;
}
''')
        cls.fake = cls.work / "synthetic-collector"
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", '-DSCRIPT="'+str(script)+'"', str(wrapper), "-o", str(cls.fake)], check=True, timeout=60)
        cls.spec = dict(version=1, xodb=str(cls.fake), recipe=str(cls.recipe), variants=[dict(name="baseline", exe="/bin/true", args=["baseline"]), dict(name="changed", exe="/bin/true", args=["changed"]), dict(name="control", exe="/bin/true", args=["baseline"])], repetitions=3, warmups=1, order="interleaved", seed=7, timeout_seconds=3, output_bytes=32*1024*1024)

    def launch(self, label, spec=None, wait=True):
        spec = spec or self.spec
        path = self.work / (label + ".json")
        path.write_text(json.dumps(spec))
        command = [sys.executable, str(RUNNER), "run", str(path), "--out", str(self.work / label)]
        if not wait:
            return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc = subprocess.run(command, capture_output=True, timeout=40)
        (self.work / (label + ".stdout")).write_bytes(proc.stdout)
        (self.work / (label + ".stderr")).write_bytes(proc.stderr)
        return proc

    def manifest(self, label):
        return json.loads((self.work / label / "manifest.json").read_text())

    def test_01_repeated_offline_replay_and_control(self):
        p = self.launch("success")
        self.assertEqual(p.returncode, 0, p.stderr)
        value = self.manifest("success")
        r.validate_manifest(value)
        self.assertEqual(len(value["runs"]), 12)
        summary = r.summarize(value)
        for v in summary["variants"].values():
            self.assertEqual((v["planned"], v["warmups"], v["eligible_runs"]), (3, 1, 3))
            self.assertGreaterEqual(v["ns_per_complete_call"]["sample_sd_display_ns"], 0)
        p = subprocess.run([sys.executable, str(RUNNER), "summarize", str(self.work / "success"), "--xodb", self.xodb], capture_output=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("replayed", json.loads(p.stdout)["verification"])
        # Mutating a derived denominator must fail even with intact evidence.
        changed = copy.deepcopy(value)
        changed["runs"][0]["result"]["comparison"]["summary"]["complete_calls"] = 99
        with self.assertRaises(ValueError): r.summarize(changed)
        # A forged, internally consistent result is rejected by real replay.
        changed = copy.deepcopy(value)
        changed["runs"][0]["result"]["comparison"]["slow"]["duration"]["total_ns"] = "999"
        (self.work / "success/manifest.json").write_text(json.dumps(changed))
        p = subprocess.run([sys.executable, str(RUNNER), "summarize", str(self.work / "success"), "--xodb", self.xodb], capture_output=True, timeout=60)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b"contradicts", p.stderr)
        (self.work / "success/manifest.json").write_text(json.dumps(value))

    def test_02_no_overwrite(self):
        self.assertEqual(self.launch("exclusive").returncode, 0)
        before = (self.work / "exclusive/manifest.json").read_bytes()
        self.assertNotEqual(self.launch("exclusive").returncode, 0)
        self.assertEqual(before, (self.work / "exclusive/manifest.json").read_bytes())

    def test_03_failure_stays_in_denominator(self):
        spec = copy.deepcopy(self.spec)
        spec.update(warmups=0, order="ordered")
        spec["variants"][0]["args"] = ["oncefail"]
        self.assertEqual(self.launch("failed-once", spec).returncode, 1)
        value = self.manifest("failed-once")
        summary = r.summarize(value)
        self.assertEqual(summary["variants"]["baseline"]["statuses"]["failed"], 1)
        self.assertEqual(summary["variants"]["baseline"]["planned"], 3)
        self.assertEqual(summary["variants"]["baseline"]["eligible_runs"], 2)
        self.assertEqual(len(value["runs"]), 9)

    def test_04_timeout_reaps_detached_child(self):
        spec = copy.deepcopy(self.spec)
        spec.update(repetitions=1, warmups=0, timeout_seconds=.15, order="ordered")
        spec["variants"][0]["args"] = ["timeout"]
        self.assertEqual(self.launch("timeout", spec).returncode, 1)
        row = self.manifest("timeout")["runs"][0]
        self.assertEqual(row["status"], "timeout")
        self.assertTrue(row["cleanup_verified"])
        pid = int((self.work / "child-pid").read_text())
        self.assertFalse(Path(f"/proc/{pid}").exists())

    def test_05_cancel_publishes_pending_denominator(self):
        marker = self.work / "child-pid"
        if marker.exists(): marker.unlink()
        spec = copy.deepcopy(self.spec)
        spec.update(repetitions=2, warmups=0, timeout_seconds=20, order="ordered")
        spec["variants"][0]["args"] = ["cancel"]
        p = self.launch("cancel", spec, False)
        try:
            deadline = time.monotonic()+10
            while not marker.exists():
                self.assertIsNone(p.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            p.send_signal(signal.SIGINT)
            out, err = p.communicate(timeout=10)
            self.assertEqual(p.returncode, 130, err)
            value = self.manifest("cancel")
            self.assertEqual(value["runs"][0]["status"], "cancelled")
            self.assertEqual(sum(row["status"] == "not_run" for row in value["runs"]), 5)
            self.assertFalse(Path('/proc/'+marker.read_text()).exists())
        finally:
            if p.poll() is None: p.kill(); p.communicate(timeout=10)

    def test_06_output_limits(self):
        spec = copy.deepcopy(self.spec)
        spec.update(warmups=0, order="ordered")
        spec["variants"][0]["args"] = ["output"]
        self.assertEqual(self.launch("output", spec).returncode, 1)
        value = self.manifest("output")
        self.assertEqual(value["runs"][0]["status"], "output_budget")
        self.assertTrue(value["runs"][0]["cleanup_verified"])
        spec["output_bytes"] = r.RESERVE + 4096
        self.assertEqual(self.launch("budget-before-run", spec).returncode, 1)
        self.assertTrue(all(row["status"] == "not_run" for row in self.manifest("budget-before-run")["runs"]))

    def test_07_input_changes_do_not_change_launched_bytes(self):
        spec = copy.deepcopy(self.spec)
        spec.update(repetitions=1, warmups=0, order="ordered", inputs=[dict(name="data", path=str(self.input))])
        spec["variants"][0]["args"] = ["input", "{input:data}"]
        p = self.launch("pinned", spec, False)
        try:
            deadline = time.monotonic()+10
            while not (self.work / "pin-ready").exists():
                self.assertIsNone(p.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            self.input.write_text("changed after pinning")
            out, err = p.communicate(timeout=20)
            self.assertEqual(p.returncode, 0, err)
            self.assertEqual((self.work / "pin-read").read_text(), "original")
            self.assertEqual(self.manifest("pinned")["plan"]["identities"]["inputs"]["data"]["sha256"], hashlib.sha256(b"original").hexdigest())
        finally:
            if p.poll() is None: p.kill(); p.communicate(timeout=10)
        pin = r.Pin(self.input, 1024)
        try:
            with self.assertRaises(OSError): os.write(pin.fd, b"x")
            self.assertTrue(fcntl.fcntl(pin.fd, fcntl.F_GET_SEALS) & fcntl.F_SEAL_WRITE)
        finally: pin.close()

    def test_08_manifest_rejects_paths_schedule_and_omissions(self):
        value = self.manifest("success")
        changes = [lambda v: v["runs"].pop(), lambda v: v["runs"][0].update(archive=dict(path="../outside.xoi", bytes=0, sha256="0"*64)), lambda v: v.update(version=2), lambda v: v["runs"][0].update(status="completed", cleanup_verified=False), lambda v: v["plan"]["identities"].update(xodb=dict(bytes=1, sha256="bad"))]
        for change in changes:
            v = copy.deepcopy(value)
            change(v)
            with self.assertRaises(ValueError): r.validate_manifest(v)
        with self.assertRaises(ValueError): r.loads(b'{"a":1,"a":2}')
        with self.assertRaises(ValueError): r.loads(b'{"a":NaN}')

    def test_destination_symlink_and_prelaunch_failure_leave_no_claim(self):
        missing = self.work / "not-created-through-link"
        (self.work / "dangling-out").symlink_to(missing)
        proc = self.launch("dangling-out")
        self.assertEqual(proc.returncode, 1)
        self.assertFalse(missing.exists())
        for label, argument in (("undeclared", "{input:nope}"), ("partial", "prefix{input:nope}")):
            spec = copy.deepcopy(self.spec)
            spec["variants"][0]["args"] = [argument]
            proc = self.launch(label, spec)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse((self.work / label).exists())
            if label == "undeclared":
                self.assertIn(b"undeclared input placeholder: nope", proc.stderr)
        for label, path in (("missing-input", self.work / "absent"), ("fifo-input", self.work / "fifo")):
            if label == "fifo-input":
                os.mkfifo(path)
            spec = copy.deepcopy(self.spec)
            spec["inputs"] = [dict(name="data", path=str(path))]
            self.assertEqual(self.launch(label, spec).returncode, 1)
            self.assertFalse((self.work / label).exists())

    def test_aggregate_output_marks_failure_before_completed_publication(self):
        spec = copy.deepcopy(self.spec)
        spec.update(repetitions=1, warmups=0, order="ordered", output_bytes=r.RESERVE + 6*1024*1024)
        spec["variants"][0]["args"] = ["twofiles"]
        self.assertEqual(self.launch("aggregate-output", spec).returncode, 1)
        value = self.manifest("aggregate-output")
        r.validate_manifest(value)
        self.assertEqual(value["state"], "output_budget")
        self.assertEqual(value["runs"][0]["status"], "output_budget")
        self.assertIsNone(value["runs"][0]["result"])
        self.assertTrue(all(row["status"] == "not_run" for row in value["runs"][1:]))
        row = json.loads((self.work / "aggregate-output/run-000/result.json").read_text())
        self.assertEqual(row["status"], "output_budget")

    def test_sealed_inode_rechecked_after_write_window(self):
        original = fcntl.fcntl
        def altered(fd, command, *args):
            if command == fcntl.F_ADD_SEALS:
                os.pwrite(fd, b"changed!", 0)
            return original(fd, command, *args)
        with mock.patch.object(r.fcntl, "fcntl", side_effect=altered):
            with self.assertRaisesRegex(ValueError, "sealed input changed"):
                r.Pin(self.input, r.MAX_INPUT)

    def test_09_known_statistics_exact_denominators(self):
        value = self.manifest("success")
        value = copy.deepcopy(value)
        # Every baseline/control measurement uses 100,200,300 ns; changed 50,100,150.
        for row in value["runs"]:
            comp = row["result"]["comparison"]
            amount = (row["repetition"]+1) * (50 if row["variant"] == "changed" else 100)
            comp["fast"]["count"] = comp["fast"]["duration"]["count"] = 0
            comp["fast"]["duration"]["total_ns"] = "0"
            comp["slow"]["count"] = comp["slow"]["duration"]["count"] = 1
            comp["slow"]["duration"]["total_ns"] = str(amount)
        summary = r.summarize(value)
        self.assertEqual(summary["median_ratios"]["changed"]["baseline_over_variant"], 2)
        self.assertEqual(summary["median_ratios"]["control"]["baseline_over_variant"], 1)
        base = summary["variants"]["baseline"]["ns_per_complete_call"]
        self.assertEqual(base["median"]["numerator"], "200")
        self.assertEqual(base["sample_sd_display_ns"], 100)
        # One measurement is a distribution with unknown spread and no ratio.
        for row in value["runs"]:
            if not row["warmup"] and row["repetition"] != 0:
                row.update(status="failed", result=None, exit_code=1)
        value["state"] = "completed_with_failures"
        self.assertEqual(r.summarize(value)["median_ratios"], {})


if __name__ == "__main__":
    os.umask(0o022)
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-root", default=os.environ.get("XODB_TEST_TMPDIR"))
    OPTIONS, remaining = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
