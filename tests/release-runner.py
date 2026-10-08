#!/usr/bin/env python3
"""Exercise environment isolation, deadlines and owned descendant cleanup."""
import ctypes
from importlib.machinery import SourceFileLoader
import importlib.util
import json
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

    def exercise(self, source, timeout=5, env=None, prefix=()):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='gate-test-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            result = gate.run_step('owned', [*prefix, sys.executable, '-c', source],
                                   timeout, directory, dict(os.environ) if env is None else env, directory)
            self.assertEqual(result.get('remaining_pids', []), [])
            result['output'] = (directory / 'owned.log').read_text()
            return result

    def test_shell_preferences_do_not_reach_steps(self):
        poisoned = dict(os.environ, NO_COLOR='1', COLORTERM='truecolor', FORCE_COLOR='3',
                        CLICOLOR='1', CLICOLOR_FORCE='1', TERM='xterm-256color',
                        TERMINFO='/fixture/terminfo', TERMINFO_DIRS='/fixture/info',
                        TERMCAP='fixture', TERM_PROGRAM='fixture', TERM_PROGRAM_VERSION='99',
                        COLORFGBG='15;0', COLUMNS='900', LINES='3', LANG='invalid.fixture',
                        LANGUAGE='fixture', LC_ALL='invalid.fixture', LC_MESSAGES='invalid.fixture',
                        LC_FUTURE_CATEGORY='fixture', TZ='UTC+11', XODB_TEST_SENTINEL='preserved')
        before = dict(poisoned)
        keys = ['NO_COLOR', 'COLORTERM', 'FORCE_COLOR', 'CLICOLOR', 'CLICOLOR_FORCE',
                'TERMINFO', 'TERMINFO_DIRS', 'TERMCAP', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION',
                'COLORFGBG', 'COLUMNS', 'LINES', 'LANGUAGE', 'LC_MESSAGES', 'LC_FUTURE_CATEGORY']
        source = f'''import json,locale,os,time
locale.setlocale(locale.LC_ALL, '')
print(json.dumps({{'removed':{{k:os.environ.get(k) for k in {keys!r}}},
 'fixed':{{k:os.environ.get(k) for k in ('TERM','LANG','LC_ALL','TZ')}},
 'sentinel':os.environ.get('XODB_TEST_SENTINEL'),
 'number':locale.format_string('%.1f',1.5), 'zone':time.strftime('%z',time.gmtime(0))}}))
'''
        result = self.exercise(source, env=poisoned)
        self.assertEqual(result['status'], 'passed', result['output'])
        seen = json.loads(result['output'])
        self.assertTrue(all(v is None for v in seen['removed'].values()), seen)
        self.assertEqual(seen['fixed'], dict(TERM='dumb', LANG='C.UTF-8', LC_ALL='C.UTF-8', TZ='UTC'))
        self.assertEqual(seen['sentinel'], 'preserved')
        self.assertEqual(seen['number'], '1.5')
        self.assertEqual(seen['zone'], '+0000')
        self.assertEqual(poisoned, before)  # Caller/next step configuration survives.

    def test_explicit_step_capabilities_survive(self):
        result = self.exercise('''import os
assert os.environ['TERM']=='xterm-256color'
assert os.environ['COLORTERM']=='truecolor'
assert os.environ['NO_COLOR']=='1'
assert os.environ['LC_ALL']=='C'
assert os.environ['COLUMNS']=='100'
''', prefix=('env', 'TERM=xterm-256color', 'COLORTERM=truecolor', 'NO_COLOR=1', 'LC_ALL=C', 'COLUMNS=100'))
        self.assertEqual(result['status'], 'passed', result['output'])

    def test_each_step_gets_a_fresh_environment(self):
        env = dict(os.environ)
        self.assertEqual(self.exercise('import os; assert "NO_COLOR" not in os.environ', env=env)['status'], 'passed')
        env['NO_COLOR'] = '1'
        self.assertEqual(self.exercise('import os; assert "NO_COLOR" not in os.environ', env=env)['status'], 'passed')
        self.assertEqual(env['NO_COLOR'], '1')

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
        portable = {s[0] for s in gate.plan('portable')}
        self.assertTrue({'build-tests', 'release-runner', 'package-source', 'mapping-identity'} <= portable)
        self.assertFalse(portable & {'remote', 'mcp', 'shared-sessions', 'gui-overview', 'vulkan-faults', 'observations-live'})
        names = [s[0] for s in gate.plan('all')]
        for required in ('remote', 'm2-limits', 'm2-archive', 'hidden-window', 'wayland-read-race', 'vulkan-faults'):
            self.assertIn(required, names)
        self.assertNotIn('observations-live', names)
        observed = [s[0] for s in gate.plan('host', uprobes=True)]
        for required in ('inspections-agent', 'inspection-lifecycle-agent', 'observations-live', 'observation-recipes-agent', 'observation-associations'):
            self.assertIn(required, observed)


if __name__ == '__main__':
    unittest.main()
