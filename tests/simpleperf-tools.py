#!/usr/bin/env python3
"""Host-only checks for Android profile export and device cleanup boundaries."""
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace as NS
import unittest

ROOT = Path(__file__).resolve().parents[1]
summarize = runpy.run_path(str(ROOT / 'scripts/report-simpleperf'))['summarize']
Capture = runpy.run_path(str(ROOT / 'scripts/profile-android-app'))['Capture']


class Samples:
    def __init__(self, rows):
        self.rows = iter(rows)

    def GetArch(self): return 'aarch64'
    def GetRecordCmd(self): return 'fixture'
    def MetaInfo(self): return {}

    def GetNextSample(self):
        self.row = next(self.rows, None)
        if self.row is None:
            return None
        return NS(pid=7, tid=8, thread_comm='worker', period=self.row[0], time=1000,
                  in_kernel=False)

    def GetEventOfCurrentSample(self): return NS(name=self.row[3])
    def GetSymbolOfCurrentSample(self): return NS(symbol_name=self.row[1], dso_name='/lib/app.so')

    def GetCallChainOfCurrentSample(self):
        entries = [NS(symbol=NS(symbol_name=name, dso_name='/lib/app.so')) for name in self.row[2]]
        return NS(nr=len(entries), entries=entries)


class ExportTests(unittest.TestCase):
    def test_leaf_only_sample_and_root_first_callers_preserve_weight(self):
        summary, stacks = summarize(Samples([(11, 'leaf', [], 'task-clock:u'),
                                             (23, 'busy', ['caller', 'root'], 'task-clock:u')]))
        self.assertEqual(summary['sample_count'], 2)
        self.assertEqual(stacks, {'worker [7/8];leaf (app.so)': 11,
                                 'worker [7/8];root (app.so);caller (app.so);busy (app.so)': 23})
        self.assertEqual(sum(stacks.values()), summary['events']['task-clock:u'])

    def test_mixed_event_units_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'incompatible'):
            summarize(Samples([(1, 'one', [], 'task-clock:u'), (2, 'two', [], 'cpu-cycles:u')]))

    def test_empty_capture_stays_empty(self):
        summary, stacks = summarize(Samples([]))
        self.assertEqual((summary['sample_count'], summary['timestamp_span_seconds'], stacks), (0, 0, {}))


class DeviceBoundaryTests(unittest.TestCase):
    def test_unconfirmed_device_exit_never_removes_files(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.work') as tmp:
            capture = object.__new__(Capture)
            capture.run = Path(tmp)
            capture.directory = 'cache/xodb-profile.Abc123'
            capture.finished = False
            capture.evidence = {'clean': False}
            capture.app = lambda *args: self.fail('Unexpected device operation: ' + repr(args))
            with self.assertRaisesRegex(RuntimeError, 'exit unconfirmed'):
                capture.close()

    def test_confirmed_exit_removes_only_owned_capture_and_empty_directory(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.work') as tmp:
            capture = object.__new__(Capture)
            capture.run = Path(tmp)
            capture.directory = 'cache/xodb-profile.Abc123'
            capture.finished = True
            capture.evidence = {'clean': False}
            operations = []
            capture.app = lambda *args: operations.append(args)
            capture.close()
            self.assertEqual(operations, [('rm', '-f', 'cache/xodb-profile.Abc123/perf.data'),
                                          ('rmdir', 'cache/xodb-profile.Abc123')])
            self.assertTrue(capture.evidence['clean'])

    def test_restrictive_perf_policy_fails_before_any_write(self):
        capture = object.__new__(Capture)
        capture.serial = None
        capture.evidence = {'operations': []}
        capture.rate = 99
        capture.adb = lambda *args: b'2000' if args == ('shell', 'id', '-u') else b'fixture'
        def app(*args):
            self.assertEqual(args, ('id', '-u'))
            return '10391'
        capture.app = app
        capture.settings = lambda: {'limits': {'perf_event_paranoid': 3}, 'properties': {}}
        with self.assertRaisesRegex(RuntimeError, 'no settings changed'):
            capture.prepare()


if __name__ == '__main__':
    unittest.main()
