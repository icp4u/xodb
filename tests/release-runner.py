#!/usr/bin/env python3
"""Exercise environment isolation, deadlines and owned descendant cleanup."""
import ctypes
from importlib.machinery import SourceFileLoader
import importlib.util
import json
import itertools
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

    def test_performance_report_preserves_each_measurement(self):
        paths = ('.work/perf-observers/results.json',
                 '.work/perf-remote-stops/results.json',
                 '.work/perf-syscalls/results.json')
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='perf-summary-') as name:
            tree = Path(name); tree.chmod(0o755)
            for path in paths: (tree / path).parent.mkdir(parents=True)
            for statuses in itertools.product(('measured', 'not-measurable'), repeat=3):
                values = [dict(status=statuses[0], sample='observer'),
                          dict(performance=dict(status=statuses[1]), sample='remote'),
                          dict(status=statuses[2], sample='syscall')]
                for path, value in zip(paths, values): (tree / path).write_text(json.dumps(value))
                result = gate.performance_summary(tree)
                self.assertEqual(result['status'], 'not-measurable' if 'not-measurable' in statuses else 'passed')
                self.assertEqual([result[key] for key in ('measurements', 'remote_stop_measurements', 'syscall_measurements')], values)
            for invalid in ('failed', 'running', 'passed', None):
                (tree / paths[1]).write_text(json.dumps(dict(performance=dict(status=invalid))))
                with self.assertRaises(ValueError): gate.performance_summary(tree)
            (tree / paths[1]).write_text('{}')
            with self.assertRaises(KeyError): gate.performance_summary(tree)
            (tree / paths[1]).unlink()
            with self.assertRaises(FileNotFoundError): gate.performance_summary(tree)
        steps = {name: argv for name,argv,_ in gate.plan('perf')}
        command = steps['remote-stop-measurements']
        self.assertEqual(command[command.index('--work')+1], '.work/perf-remote-stops')

    def exercise(self, source, timeout=5, env=None, prefix=()):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='gate-test-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            result = gate.run_step('owned', [*prefix, sys.executable, '-c', source],
                                   timeout, directory, dict(os.environ) if env is None else env, directory)
            self.assertEqual(result.get('remaining_pids', []), [])
            result['output'] = (directory / 'owned.log').read_text()
            return result

    def test_ruby_watch_coverage(self):
        for tier in ('host', 'all'):
            names={name for name,_,_ in gate.plan(tier,ruby='/fixture/ruby')}
            self.assertTrue({'ruby-watch-component','ruby-watches','ruby-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in gate.plan(tier,ruby='/fixture/ruby')}
            self.assertIn('ruby-watches-gui',names)

    def test_javascript_watch_coverage(self):
        for tier in ('host', 'all'):
            names={name for name,_,_ in gate.plan(tier,node='/fixture/node')}
            self.assertTrue({'javascript-watches','javascript-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in gate.plan(tier,node='/fixture/node')}
            self.assertIn('javascript-watches-gui',names)

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

    def test_preferences_cover_both_live_backends(self):
        for tier in ('host', 'all'):
            commands = {name: cmd for name, cmd, _ in gate.plan(tier)}
            self.assertEqual(commands['m2-preferences'][-1], 'tests/m2-preferences.py')
            self.assertEqual(commands['m2-preferences-agent'][:2],
                             ['env', 'XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent'])
            self.assertEqual(commands['m2-preferences-agent'][-1], 'tests/m2-preferences.py')
        for tier in ('portable', 'periodic', 'gui', 'perf'):
            self.assertFalse({'m2-preferences', 'm2-preferences-agent'} &
                             {name for name, _, _ in gate.plan(tier)})

    def test_syscall_measurements_keep_the_correctness_lane(self):
        perf = {name: cmd for name, cmd, _ in gate.plan('perf')}
        self.assertEqual(perf['syscall-measurements'], [sys.executable, '-B',
            'tests/syscall-timing.py', '--perf', '--work', '.work/perf-syscalls'])
        for tier in ('host', 'all'):
            regular = {name: cmd for name, cmd, _ in gate.plan(tier)}
            self.assertEqual(regular['syscall-timing'], [sys.executable, '-B', 'tests/syscall-timing.py'])
        for tier in ('portable', 'host', 'gui', 'all', 'periodic', 'periodic-gui'):
            self.assertNotIn('syscall-measurements', {name for name, _, _ in gate.plan(tier)})

    def test_measurements_are_explicit_and_separate(self):
        perf = {s[0] for s in gate.plan('perf', headless=True)}
        self.assertIn('observer-measurements', perf)
        self.assertIn('remote-stop-measurements', perf)
        command = next(cmd for name, cmd, _ in gate.plan('perf') if name == 'remote-stop-measurements')
        self.assertEqual(command[2:4], ['tests/remote-stops.py', '--perf'])
        self.assertFalse(perf & {'mcp', 'vulkan-faults', 'gui-overview'})
        for tier in ('portable', 'host', 'gui', 'all', 'periodic', 'periodic-gui'):
            self.assertFalse({'observer-measurements', 'remote-stop-measurements'} &
                             {s[0] for s in gate.plan(tier)})
    def test_periodic_keeps_complete_matrices_and_quick_keeps_lifecycles(self):
        regular = {name: argv for name, argv, _ in gate.plan('all')}
        periodic = {name: argv for name, argv, _ in gate.plan('periodic-gui')}
        for name, script in (('gui-overview', 'tests/overview-gui.py'),
                             ('gui-clipboard', 'tests/clipboard-gui.py')):
            self.assertEqual(periodic[name], [sys.executable, '-B', script])
            self.assertEqual(regular[name], [sys.executable, '-B', script, '--focused'])
        self.assertEqual(periodic['vulkan-faults'], [sys.executable, '-B',
            'tests/vulkan-fault.py', 'zig-out/bin/xodb', '.work/vulkan-faults.json'])
        self.assertEqual(set(regular['vulkan-faults'][5:]), {
            'baseline', 'partial-vkCreateFramebuffer', 'poison-vkCreateSwapchainKHR',
            'frame-vkQueuePresentKHR-lost', 'repeat-init-fails-late', 'resize-real-output'})
        for delay in (25, 50, 100):
            name = f'symbol-discovery-latency-{delay}'
            self.assertNotIn(name, regular)
            self.assertEqual(periodic[name], [sys.executable, '-B',
                'tests/symbol-discovery-install.py', '--reply-delay-ms', str(delay),
                '--read-delay-ms', '0', '--rate', '10000000000', '--timeout', '70',
                '--cases', 'complete', 'interrupt'])
        self.assertTrue({'symbol-discovery', 'symbol-discovery-install',
            'm2-limits', 'm2-archive', 'hidden-window', 'acquire-timeout',
            'fence-timeout', 'wayland-read-race', 'gui-overview-live'} <= regular.keys())
        headless = {name for name, _, _ in gate.plan('periodic', headless=True)}
        self.assertTrue({'source-paths-differential', 'symbol-discovery-latency-25',
            'symbol-discovery-latency-50', 'symbol-discovery-latency-100'} <= headless)
        self.assertFalse(headless & {'vulkan-faults', 'gui-overview', 'gui-clipboard'})



if __name__ == '__main__':
    unittest.main()
