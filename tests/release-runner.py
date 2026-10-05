#!/usr/bin/env python3
"""Exercise deadlines and descendant cleanup using only owned Python children."""
import ctypes
from importlib.machinery import SourceFileLoader
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

root = Path(__file__).resolve().parents[1]
loader = SourceFileLoader('release_check', str(root / 'scripts/release-check'))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
        (root / '.work').mkdir(exist_ok=True)

    def exercise(self, source, timeout=5):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='gate-test-') as name:
            directory = Path(name)
            result = gate.run_step('owned', [sys.executable, '-c', source],
                                   timeout, directory, dict(os.environ), directory)
            self.assertEqual(result.get('remaining_pids', []), [])
            return result

    def test_success_and_nonzero(self):
        self.assertEqual(self.exercise('print("ok")')['status'], 'passed')
        result = self.exercise('raise SystemExit(7)')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['exit_code'], 7)

    def test_timeout_cleans_stubborn_descendants(self):
        result = self.exercise('''import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.fork()
time.sleep(60)
''', .2)
        self.assertEqual(result['status'], 'timeout')
        self.assertGreaterEqual(len(result['leftover_pids']), 2)

    def test_success_with_orphan_is_failure(self):
        result = self.exercise('''import os, time
if os.fork(): os._exit(0)
time.sleep(60)
''')
        self.assertEqual(result['status'], 'leaked_processes')

    def test_orphan_that_changes_session_is_reaped(self):
        result = self.exercise('import os,time\nr,w=os.pipe()\nif os.fork(): os.close(w); os.read(r,1); os._exit(0)\nos.close(r)\nos.setsid()\nos.write(w,b"1")\ntime.sleep(60)')
        self.assertEqual(result['status'], 'leaked_processes')
        self.assertTrue(result.get('adopted_pids'))

    def test_portable_never_schedules_live_commands(self):
        self.assertEqual([s[0] for s in gate.plan('portable')], ['build-tests', 'package-source', 'mapping-identity'])
        names = [s[0] for s in gate.plan('all')]
        for required in ('remote', 'm2-limits', 'm2-archive', 'hidden-window', 'wayland-read-race', 'vulkan-faults'):
            self.assertIn(required, names)
        self.assertNotIn('observations-live', names)
        observed = [s[0] for s in gate.plan('host', uprobes=True)]
        for required in ('inspections-agent', 'inspection-lifecycle-agent', 'observations-live', 'observation-recipes-agent', 'observation-associations'):
            self.assertIn(required, observed)


if __name__ == '__main__':
    unittest.main()
