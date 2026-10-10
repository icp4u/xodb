#!/usr/bin/env python3
"""Exercise environment isolation, deadlines and owned descendant cleanup."""
import contextlib
import ctypes
from importlib.machinery import SourceFileLoader
import importlib.util
import io
import json
import itertools
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

root = Path(__file__).resolve().parents[1]
loader = SourceFileLoader('release_check', str(root / 'scripts/release-check'))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


# Test scripts that no release-check tier runs, and why. "not gated" entries
# are gaps to close, not exemptions.
UNREGISTERED = {
    name: reason for reason, names in (
        ('loaded by other test scripts, not run alone', ('client.py', 'elisp-memory.py', 'elisp-values-memory.py', 'elisp-bindings-memory.py', 'go-maps-gdb.py', 'go-values-gdb.py', 'pe_profile.py',)),
        ('needs an ARM64 host', ('arm64-demo.py', 'arm64-native.py', 'arm64-watchpoints.py', 'remote-ssh-gui.py',)),
        ('needs gdbserver and QEMU targets', ('gdb-remote.py',)),
        ('needs a device profile', ('simpleperf-import.py', 'simpleperf-import-gui.py',)),
        ('needs sudo: the privileged allocation helper, or a configured host', ('allocations-live.py', 'm2-syscall-configured.py',)),
        ('measurement, no pass criteria', ('allocation-cost.py', 'memory-cost.py', 'm2-server-cost.py', 'm2-workload-cost.py',)),
        ('not gated: needs arguments or fixtures that no step builds', ('cfi-image.py', 'metadata-job.py', 'metadata-image-job.py', 'source-confinement.py', 'observation-association-lifecycle.py', 'observation-saved-associations.py', 'python-language.py', 'vulkan-leaks.py', 'frame-jit.py', 'jitmap-fixture.py', 'jitmap-perf-crosscheck.py', 'jitmap-runtime-producers.py',)),
        ('not gated: needs output from another test', ('core-gui.py', 'discovery-gui.py', 'syscall-gui.py', 'm2-archive-gui.py', 'm2-limits-gui.py',)),
        ('not gated: passes alone, but its compositor socket path is too long inside a gate snapshot', ('m2-intervals-gui.py', 'm2-preferences-gui.py', 'm2-values-gui.py',)),
        ('not gated: passes, but leaves a process behind, which the runner reports as a leak', ('process-tree.py',)),
        ('not gated: fails when run alone', ('allocations-gui.py', 'allocations-live-gui.py', 'process-gui.py', 'fdgraph.py', 'm2-dynamic-threads-gui.py', 'm2-timeline-gui.py', 'm2-values.py', 'process-capacity.py', 'sysstat-live.py', 'runtime-leaks.py', 'simpleperf-tools.py',)),
    ) for name in names
}


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
        (root / '.work').mkdir(exist_ok=True)

    def test_go_native_value_lanes(self):
        for tier in ('quick', 'host', 'gui', 'all', 'periodic'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier, go='/fixture/go')}
            self.assertIn('go-type-index', steps)
            if tier in ('host', 'all'):
                for remote in (0, 1):
                    for shared in (0, 1):
                        command = steps[f'go-native-values-{remote}-{shared}']
                        self.assertIn('--strace', command)
                        self.assertEqual('--agent' in command, bool(remote))
                        self.assertEqual('--shared' in command, bool(shared))
            if tier in ('gui', 'all'):
                self.assertIn('go-native-values-gui', steps)

    def test_go_value_lanes(self):
        for tier in ('host', 'all', 'gui'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            self.assertIn('go-values-component', steps)
            self.assertIn('go-maps-component', steps)
            self.assertNotIn('go-values', steps)
        for tier in ('host', 'all'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier, go='/fixture/go')}
            self.assertIn('--strace', steps['go-values'])
            self.assertIn('--strace', steps['go-maps'])
            self.assertNotIn('go-maps-interleaved', steps)
            self.assertEqual(steps['go-values'][steps['go-values'].index('--go')+1], '/fixture/go')

    def test_go_map_alternative_layout_lane(self):
        steps={name:cmd for name,cmd,_ in gate.plan('periodic',go='/fixture/go')}
        self.assertIn('nomapsplitgroup',steps['go-maps-interleaved'])
        self.assertIn('--strace',steps['go-maps-interleaved'])

    def test_pe_worker_and_wine_checks_are_gated(self):
        for tier in ('periodic', 'periodic-gui'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            self.assertIn('--sanitize', steps['pe-job'])
            self.assertFalse(any(name.startswith('pe-wine-') for name in steps))
            self.assertNotIn('pe-corpus', steps)
            steps = {name: cmd for name, cmd, _ in gate.plan(tier, wine='/fixture/wine')}
            self.assertIn('/fixture/wine', steps['pe-wine-native'])
            self.assertIn('--eviction', steps['pe-wine-eviction'])
            self.assertEqual(steps['pe-corpus'], [sys.executable, '-B', 'tests/pe-corpus.py',
                             '--wine', '/fixture/wine', '--work', '.work/pe-corpus'])
        for tier in ('host', 'all'):
            self.assertNotIn('pe-job', {name for name, _, _ in gate.plan(tier)})

    def test_module_cache_checks_are_gated(self):
        for tier in ('host', 'all'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            self.assertIn('tests/module-symbols.py', steps['module-symbols'])
            for variant in ('chain', 'debug-frame', 'companions'):
                self.assertIn('tests/module-unwind.py', steps['module-unwind-'+variant])
            self.assertNotIn('module-unwind-eviction', steps)
        for tier in ('periodic', 'periodic-gui'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            for variant in ('eviction', 'budget', 'full-dwarf', 'large-companions'):
                self.assertIn('--'+variant, steps['module-unwind-'+variant])
            self.assertIn('tests/cfi-job.py', steps['cfi-job'])
            self.assertIn('--agent', steps['cfi-job'])

    def test_jai_demo_lanes(self):
        for tier in ('host', 'all'):
            steps={name:cmd for name,cmd,_ in gate.plan(tier)}
            self.assertNotIn('--agent',steps['jai-elf-demo-0'])
            self.assertIn('--writes',steps['jai-elf-demo-0'])
            for remote in (False,True):
                for shared in (False,True):
                    cmd=steps[f'jai-writes-{int(remote)}-{int(shared)}']
                    self.assertEqual('--agent' in cmd,remote)
                    self.assertEqual('--shared' in cmd,shared)
            self.assertIn('--agent',steps['jai-elf-demo-1'])
            self.assertFalse(any(name.startswith('jai-pe-demo-') for name in steps))
        for tier in ('periodic','periodic-gui'):
            self.assertFalse(any(name.startswith('jai-pe-demo-') for name,_,_ in gate.plan(tier)))
            steps={name:cmd for name,cmd,_ in gate.plan(tier,wine='/fixture/wine')}
            for remote in (False,True):
                cmd=steps[f'jai-pe-demo-{int(remote)}']
                self.assertEqual(cmd[cmd.index('--wine')+1],'/fixture/wine')
                self.assertEqual(cmd[cmd.index('--kind')+1],'pe')
                self.assertIn('--writes',cmd)
                self.assertEqual('--agent' in cmd,remote)

    def test_jai_write_gui_backends(self):
        for tier in ('gui','all'):
            steps={name:cmd for name,cmd,_ in gate.plan(tier)}
            self.assertNotIn('--agent',steps['gui-jai-writes'])
            self.assertIn('--agent',steps['gui-jai-writes-agent'])

    def test_elisp_has_local_agent_and_gui_oracles(self):
        steps = {name: cmd for name, cmd, _ in gate.plan('all', emacs='chosen-emacs')}
        for name in ('elisp-reader-live', 'elisp-language', 'elisp-language-agent', 'elisp-gui', 'elisp-values', 'elisp-values-language', 'elisp-values-agent-language', 'elisp-bindings'):
            self.assertEqual(steps[name][steps[name].index('--emacs') + 1], 'chosen-emacs')
        self.assertNotIn('--agent', steps['elisp-language'])
        self.assertIn('--agent', steps['elisp-language-agent'])
        self.assertNotIn('--agent', steps['elisp-values-language'])
        self.assertIn('--agent', steps['elisp-values-agent-language'])
        self.assertNotIn('elisp-gui', {name for name, _, _ in gate.plan('gui')})
        for remote in (False, True):
            for shared in (False, True):
                command = steps[f'elisp-bindings-{int(remote)}-{int(shared)}']
                self.assertEqual('--agent' in command, remote)
                self.assertEqual('--shared' in command, shared)
            self.assertEqual('--agent' in steps[f'elisp-bindings-gui-{int(remote)}'], remote)
        self.assertIn('tests/emacs-demo.py', steps['emacs-demo'])
        self.assertIn('--agent', steps['emacs-demo-agent'])
        for remote in (False, True):
            cmd=steps['elisp-limits'+('-agent' if remote else '')]
            self.assertIn('tests/elisp-limits.py',cmd)
            self.assertEqual('--agent' in cmd,remote)
            if remote:self.assertEqual(cmd[cmd.index('--case')+1],'deep')
        self.assertNotIn('elisp-limits',{name for name,_,_ in gate.plan('gui',emacs='chosen-emacs')})
        periodic={name:cmd for name,cmd,_ in gate.plan('periodic',emacs='chosen-emacs')}
        self.assertIn('elisp-preview-stress-agent',periodic)
        self.assertEqual(periodic['elisp-preview-stress-agent'][-3:],['budget','--agent','zig-out/bin/xodb-agent'])

    def test_jai_fuzz_periodic_only(self):
        steps = {name: cmd for name, cmd, _ in gate.plan('periodic', headless=True)}
        self.assertEqual(steps['jai-fuzz'], [sys.executable, '-B', 'tests/jai-fuzz.py',
                                           '--work', '.work/jai-fuzz', '--cases', '2000'])
        for tier in ('portable', 'host', 'gui', 'all', 'periodic-gui', 'perf'):
            self.assertNotIn('jai-fuzz', {name for name, _, _ in gate.plan(tier)})

    def test_safe_keys_cover_both_live_backends(self):
        for tier in ('gui', 'all'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            local = steps['gui-safe-keys']
            agent = steps['gui-safe-keys-agent']
            self.assertIn('tests/safe-keys-gui.py', local)
            self.assertNotIn('--agent', local)
            self.assertEqual(agent[agent.index('--agent') + 1], 'zig-out/bin/xodb-agent')
            self.assertNotEqual(local[local.index('--work') + 1], agent[agent.index('--work') + 1])

    def test_lua_table_paths_have_transport_and_gui_coverage(self):
        steps = gate.plan('all', False, 'ReleaseSafe', lua=[('lua54','src54','lib54'), ('lua52','src52','lib52')])
        paths = [(name, cmd) for name, cmd, _ in steps if name.startswith('lua-path-watches-')]
        self.assertEqual(len(paths), 4)
        for source in ('src54','src52'):
            selected = [cmd for _, cmd in paths if source in cmd]
            self.assertEqual(len(selected), 2)
            self.assertEqual(sum('--agent' in cmd for cmd in selected), 1)
        gui = [cmd for name, cmd, _ in steps if name.startswith('lua-path-watch-gui-')]
        self.assertEqual(len(gui), 2)
        self.assertTrue(all('--paths' in cmd for cmd in gui))

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

    def sequence(self, steps, keep_going=False, retries=0, jobs=1, fields={}):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='gate-test-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            report = dict(steps=[])
            planned = [gate.Step(step, [sys.executable, '-c', source], .5 if 'sleep(9)' in source else 5,
                                 **{'kind': 'gui' if step.startswith('gui-') else 'unit', **fields.get(step, {})}) for step, source in steps]
            started = time.monotonic()
            code = gate.run_steps(planned, directory, dict(os.environ), directory, report, keep_going, retries, jobs)
            report['wall'] = time.monotonic() - started
            report['work'] = sorted(os.listdir(directory / '.work')) if (directory / '.work').exists() else []
            report['logs'] = sorted(path.name for path in directory.glob('*.log'))
            return code, report

    # Fails on the first attempt in a run directory, then passes.
    once = 'import os,sys\nif os.path.exists("m"): sys.exit(0)\nopen("m","w").close(); sys.exit(1)'

    def test_keep_going_runs_every_step_and_summarises(self):
        steps = [('one', 'raise SystemExit(3)'), ('two', 'pass'), ('three', 'import time; time.sleep(9)')]
        code, report = self.sequence(steps)
        self.assertEqual((code, [s['name'] for s in report['steps']]), (1, ['one']))
        self.assertEqual(report['summary'], dict(planned=3, passed=0, flaky=0, failed=1, not_run=2))
        code, report = self.sequence(steps, keep_going=True)
        self.assertEqual((code, [s['name'] for s in report['steps']]), (1, ['one', 'two', 'three']))
        self.assertEqual([(f['name'], f['status']) for f in report['failures']], [('one', 'failed'), ('three', 'timeout')])
        self.assertEqual(report['summary'], dict(planned=3, passed=1, flaky=0, failed=2, not_run=0))
        self.assertEqual(report['reason'], 'one: failed, three: timeout')
        code, report = self.sequence([('build-tests', 'raise SystemExit(1)'), ('two', 'pass')], keep_going=True)
        self.assertEqual((code, report['summary']['not_run']), (1, 1))

    def test_gui_retry_is_recorded_as_flaky(self):
        code, report = self.sequence([('gui-once', self.once), ('two', 'pass')], retries=1)
        self.assertEqual(code, 0)
        step = report['steps'][0]
        self.assertEqual((step['name'], step['status']), ('gui-once', 'flaky'))
        self.assertEqual([s['status'] for s in step['earlier_attempts']], ['failed'])
        self.assertEqual(report['flaky'], ['gui-once'])
        self.assertEqual(report['summary'], dict(planned=2, passed=1, flaky=1, failed=0, not_run=0))
        self.assertEqual(report['logs'], ['gui-once.log', 'gui-once.retry1.log', 'two.log'])
        code, report = self.sequence([('gui-broken', 'raise SystemExit(1)')], retries=1)
        self.assertEqual((code, report['steps'][0]['status'], report['summary']['flaky']), (1, 'failed', 0))
        self.assertEqual(len(report['steps'][0]['earlier_attempts']), 1)
        for name, retries in (('plain', 1), ('gui-once', 0)):
            code, report = self.sequence([(name, self.once)], retries=retries)
            self.assertEqual((code, report['steps'][0]['status']), (1, 'failed'))
            self.assertNotIn('earlier_attempts', report['steps'][0])
    def test_gui_retry_sets_the_failed_work_directory_aside(self):
        # Like the GUI tests: a plain mkdir of a fixed work directory, so an
        # unchanged retry stops with FileExistsError unless the runner moved
        # the failed attempt's directory away.
        source = 'import os,sys\nos.mkdir(".work/wd")\nopen(".work/wd/evidence","w").close()\n' + self.once
        with tempfile.TemporaryDirectory(dir=root / '.work') as name:
            directory = Path(name)
            directory.chmod(0o755)
            for made in ('.work/kept', 'first', 'second'):
                (directory / made).mkdir(parents=True)
            step = gate.Step('gui-workdir', [sys.executable, '-c', source], 5, 'gui')
            report = dict(steps=[])
            code = gate.run_steps([step], directory, dict(os.environ), directory / 'first', report, False, 1)
            result = report['steps'][0]
            self.assertEqual((code, result['status'], report['flaky']), (0, 'flaky', ['gui-workdir']))
            self.assertEqual([(s['status'], s['set_aside']) for s in result['earlier_attempts']], [('failed', ['wd'])])
            self.assertEqual(sorted(os.listdir(directory / '.work')), ['kept', 'wd', 'wd.attempt1'])
            self.assertTrue((directory / '.work/wd.attempt1/evidence').exists())
            self.assertNotIn('FileExistsError', (directory / 'first/gui-workdir.retry1.log').read_text())
            # A directory that existed before the step is not the attempt's to move.
            (directory / 'm').unlink()
            report = dict(steps=[])
            code = gate.run_steps([step], directory, dict(os.environ), directory / 'second', report, False, 1)
            result = report['steps'][0]
            self.assertEqual((code, result['status'], result['earlier_attempts'][0]['set_aside']), (1, 'failed', []))
            self.assertIn('FileExistsError', (directory / 'second/gui-workdir.retry1.log').read_text())
            self.assertEqual(sorted(os.listdir(directory / '.work')), ['kept', 'wd', 'wd.attempt1'])


    def test_only_and_from_keep_their_builds(self):
        steps = gate.plan('gui')
        names = [name for name, _, _ in steps]
        picked = [name for name, _, _ in gate.select(steps, ['gui-files', 'source-paths'])]
        self.assertEqual(picked, [n for n in names if n in ('build-tests', 'source-paths-build', 'source-paths', 'gui-files')])
        later = [name for name, _, _ in gate.select(steps, start='gui-files')]
        self.assertEqual(later, ['build-tests', *names[names.index('gui-files'):]])
        self.assertEqual([name for name, _, _ in gate.select(steps, start='build-tests')], names)
        with self.assertRaises(ValueError): gate.select(steps, ['gui-files', 'no-such-step'])
        with self.assertRaises(ValueError): gate.select(steps, start='no-such-step')

    RUNTIMES = (['--perl', 'P', '--padwalker', 'W'], ['--python', 'Y'], ['--emacs', 'E'], ['--ruby', 'R'], ['--node', 'N'],
                ['--node', 'N', '--node-refusal', 'NR'], ['--go', 'G'], ['--wine', 'WINE'], ['--uprobes'], ['--headless'],
                ['--lua', 'l', 's', 'b', '--lua', 'l2', 's2', 'b2'])
    EVERYTHING = dict(uprobes=True, perl='P', node='N', lua=[('l', 's', 'b'), ('l2', 's2', 'b2')], python='Y', padwalker='W',
                      ruby='R', node_refusal='NR', go='G', wine='WINE', emacs='E')
    TIERS = ('portable', 'host', 'gui', 'all', 'periodic', 'periodic-gui', 'perf')

    def listed(self, *argv):
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main([*argv, '--list']), 0)
        except SystemExit:
            return None  # this tier refuses the flag
        return json.loads(out.getvalue())

    def reachable(self):
        steps = RunnerTests.cache = getattr(RunnerTests, 'cache', {})
        if steps:
            return steps
        for tier in self.TIERS:
            accepted = [flags for flags in self.RUNTIMES if self.listed(tier, *flags) is not None]
            both = [flag for flags in accepted if flags != ['--headless'] for flag in flags]
            for flags in ([], *accepted, both):
                for name, argv, _ in self.listed(tier, *flags):
                    steps.setdefault(name, []).append(argv)
        return steps

    def test_step_records_keep_the_listed_triples(self):
        for tier in self.TIERS:
            steps = gate.plan(tier, **self.EVERYTHING)
            names = [step.name for step in steps]
            self.assertEqual(len(names), len(set(names)), tier)
            for index, step in enumerate(steps):
                self.assertEqual(tuple(step), (step.name, step.argv, step.timeout))
                self.assertIn(step.kind, ('build', 'unit', 'live', 'gui', 'periodic'))
                self.assertTrue(step.paths or step.kind == 'build', step.name)
                self.assertEqual('build-tests' in step.needs, step.kind != 'build', step.name)
                for need in step.needs:
                    self.assertIn(need, names[:index], step.name)
                self.assertFalse(step.serial and step.kind != 'gui', step.name)
            self.assertEqual(self.listed(tier), json.loads(json.dumps(gate.plan(tier))))
        kinds = {step.name: step for step in gate.plan('all', **self.EVERYTHING)}
        for name, kind in (('build-tests', 'build'), ('source-paths-build', 'build'), ('source-paths', 'unit'), ('mcp', 'live'),
                           ('remote-panes', 'gui'), ('lua-watch-gui-0', 'gui'), ('hidden-window', 'gui')):
            self.assertEqual(kinds[name].kind, kind, name)
        # Fault-injection and race steps are not retried: exactly the steps that were retried before records.
        for step in kinds.values():
            before = 'gui' in step.name.split('-') or any(str(arg).endswith('-gui.py') for arg in step.argv)
            self.assertEqual(step.kind == 'gui' and step.name not in gate.NO_RETRY, before, step.name)
        self.assertEqual(kinds['source-paths'].needs, ('build-tests', 'source-paths-build'))
        self.assertEqual(kinds['perl-gui'].needs, ('build-tests', 'perl-gui-fixtures'))
        self.assertTrue(kinds['gui-memdefrag'].serial and not kinds['gui-files'].serial)
        self.assertEqual({step.name for step in gate.plan('periodic-gui') if step.kind == 'gui'},
                         {'vulkan-faults', 'gui-overview', 'gui-win95-all-panels', 'gui-clipboard'})
        records = self.listed('gui', '--records')
        self.assertEqual(records['schema'], 2)
        self.assertEqual(records['steps'][0], dict(name='build-tests', argv=gate.plan('gui')[0].argv, timeout=600, kind='build',
                                                   needs=[], paths=[], serial=False, work=[]))
        vendored = self.listed('gui', '--capstone', 'vendored', '--only', 'gui-files')
        self.assertEqual([name for name, _, _ in vendored], ['build-tests', 'gui-files'])
        self.assertEqual(vendored[0][1][-1], '-Dcapstone=vendored')

    def test_parallel_gui_steps_never_share_a_work_directory(self):
        # Fixed .work names come from argv or from the step's declaration.
        # Other GUI tests name their directory after the clock.
        for tier in ('gui', 'all', 'periodic-gui'):
            owners = {}
            for step in gate.plan(tier, **self.EVERYTHING):
                if step.kind != 'gui':
                    continue
                if '--work' in step.argv and step.argv[step.argv.index('--work') + 1] == '.':
                    self.assertTrue(step.work, step.name + ' creates a fixed .work/input-* directory; declare it')
                for entry in step.work:
                    if entry != 'pgf':  # perl-gui reads the fixtures its prerequisite wrote
                        self.assertNotIn(entry, owners, step.name)
                        owners[entry] = step.name
        for step in gate.plan('gui', **self.EVERYTHING):
            script = next((arg for arg in step.argv if str(arg).startswith('tests/') and str(arg).endswith('.py')), None)
            for entry in step.work if script and '.' in step.argv and entry.startswith('input-') else ():
                self.assertIn(f"'.work/{entry}'", (root / script).read_text().replace('"', "'"), step.name)

    def test_every_registered_step_is_reachable(self):
        reachable = self.reachable()
        registered = {step.name for tier in self.TIERS for flags in ({}, self.EVERYTHING) for step in gate.plan(tier, **flags)}
        self.assertEqual(sorted(registered - reachable.keys()), [])
        self.assertEqual(sorted(reachable.keys() - registered), [])
        for flags in (['--base', 'HEAD'], ['--jobs', '0'], ['--records']):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                gate.main(['gui', *flags])

    def test_every_test_script_is_registered_or_listed(self):
        run = {arg for commands in self.reachable().values() for argv in commands for arg in argv}
        scripts = sorted(path.name for path in (root / 'tests').glob('*.py'))
        unregistered = [name for name in scripts if 'tests/' + name not in run]
        self.assertEqual([name for name in unregistered if name not in UNREGISTERED], [],
                         'register these in scripts/release-check, or list them in UNREGISTERED with a reason')
        self.assertEqual([name for name in UNREGISTERED if name not in unregistered], [], 'stale UNREGISTERED entries')
        self.assertTrue(all(reason.strip() for reason in UNREGISTERED.values()))

    def test_affected_maps_changes_to_both_lanes(self):
        steps = gate.plan('all', **{**self.EVERYTHING, 'wine': None})
        fallback = [step.name for step in gate.plan('gui')]

        def chosen(*changed):
            picked, lines = gate.affected(steps, changed, fallback)
            return [step.name for step in picked], lines

        names, lines = chosen('src/mcp/memory.zig')
        for required in ('build-tests', 'release-runner', 'memory-registers', 'memory-search-speed', 'memory-search-speed-agent',
                         'memory-search-ranges', 'memory-search-ranges-agent', 'mcp', 'mcp-precision', 'controller-scope-1'):
            self.assertIn(required, names)
        self.assertFalse({'gui-files', 'lua-gui', 'm2-archive', 'vulkan-faults'} & set(names))
        self.assertIn('src/mcp/memory.zig: ', lines[0])
        self.assertNotIn('not mapped', lines[0])
        for changed, required, absent in (
                ('src/language/lua_layout.c', ('lua-component-0', 'lua-watches-1-1', 'lua-gui', 'python-lua-named-1', 'gui-language-tabs'), 'ruby-gui'),
                ('src/language/go_map.c', ('go-maps-component', 'go-maps', 'go-native-values-1-1', 'go-gui'), 'lua-gui'),
                ('src/ui/overview/treemap_panel.zig', ('gui-overview', 'gui-fdtreemap', 'gui-files', 'gui-memdefrag', 'sysstat-sensors'), 'mcp'),
                ('src/runtime/fdflow.c', ('fdactivity', 'lsof-top', 'gui-fdflow-denied', 'gui-fdgraph'), 'gui-overview'),
                ('src/debug/source_paths.c', ('source-paths-build', 'source-paths', 'debug-discovery', 'gui-inline'), 'lua-gui'),
                ('src/binary/object.c', ('mapping-identity', 'apk-symbols', 'gui-symbol-discovery'), 'gui-files'),
                ('src/frames/model.zig', ('frame-host', 'frame-jvm', 'frame-archive', 'gui-frames'), 'gui-files'),
                ('src/profile/flame.zig', ('m2-profile', 'm2-archive', 'gui-profile', 'gui-flame-status'), 'lua-gui'),
                ('tests/perl-gui.py', ('perl-gui-fixtures', 'perl-gui'), 'perl-named-gui'),
                ('tests/memory-search-speed.py', ('memory-search-speed', 'memory-search-speed-agent'), 'mcp'),
                ('docs/GUIDE.md', ('package-source',), 'mcp')):
            names, lines = chosen(changed)
            self.assertTrue(set(required) <= set(names), (changed, sorted(set(required) - set(names))))
            self.assertNotIn(absent, names, changed)
            self.assertNotIn('not mapped', lines[0])
            self.assertEqual(names, [step.name for step in steps if step.name in names])  # plan order
        # No step covers these: the whole gui tier runs, beside what is mapped.
        for unmapped in ('src/model/session.zig', 'src/ui/workspace.zig', 'build.zig', 'brand-new-file'):
            names, lines = chosen(unmapped, 'src/mcp/memory.zig')
            self.assertIn('not mapped, so the full gui tier', lines[0])
            self.assertTrue(set(fallback) <= set(names), unmapped)
            self.assertIn('memory-registers', names)
        # A helper may be loaded by any step of either lane: tests/client.py is, by most live steps.
        for helper in ('tests/client.py', 'tests/helpers/readonly.py', 'tests/helpers/display.py', 'tests/check.h', 'scripts/build'):
            names, lines = chosen(helper)
            self.assertIn('not mapped, so every planned step', lines[0])
            self.assertEqual(names, [step.name for step in steps], helper)
        # The runner's own file selects the steps whose registration changed, or else the gui tier.
        names, lines = chosen('scripts/release-check')
        self.assertIn('no registration changed, so the full gui tier', lines[0])
        self.assertTrue(set(fallback) <= set(names))
        picked, lines = gate.affected(steps, ['scripts/release-check'], fallback, ['m2-flow', 'gui-capture-setup'])
        self.assertEqual([step.name for step in picked], ['build-tests', 'release-runner', 'm2-flow', 'gui-capture-setup'])
        self.assertTrue(set(gate.registered_since('HEAD', ())) <= {step.name for step in gate.plan('all')})
        self.assertEqual(gate.registered_since('no-such-revision', ()), [])
        # A mapped file whose steps need a runtime that was not passed is not silently skipped.
        bare = gate.plan('all')
        picked, lines = gate.affected(bare, ['src/language/ruby.c'], fallback)
        self.assertIn('gui-language-tabs', [step.name for step in picked])
        picked, lines = gate.affected(bare, ['src/mcp/observation.zig'], fallback)
        self.assertIn('inspections', [step.name for step in picked])

    def test_jobs_run_gui_steps_together_and_serial_steps_alone(self):
        # No sleeps: a step is busy between its .in and .out files. The four
        # "together" steps finish only once all four are busy at once. Every
        # step fails if it starts beside one that must run alone, or over the
        # job limit. Later arguments name steps that must have finished.
        script = r"""import os, sys, time
name, mode, limit, done = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
os.makedirs('.work', exist_ok=True)
names = os.listdir('.work')
busy = [x[:-3] for x in names if x.endswith('.in') and x[:-3] + '.out' not in names]
assert len(busy) < limit and not (busy and mode == 'alone') and not any(x.startswith('alone-') for x in busy), busy
assert all(x + '.out' in names for x in done), names
open(f'.work/{name}.in', 'w').close()
end = time.monotonic() + 30
while mode == 'together' and sum(os.path.exists(f'.work/gui-{x}.in') for x in 'abcd') < 4:
    assert time.monotonic() < end
    time.sleep(.01)
open(f'.work/{name}.out', 'w').close()
"""
        def run(jobs, mode):
            steps = [('alone-unit', 'alone', 'unit', {}), ('gui-a', mode, 'gui', {}), ('gui-b', mode, 'gui', {}),
                     ('alone-gui', 'alone', 'gui', dict(serial=True)), ('gui-c', mode, 'gui', {}), ('gui-d', mode, 'gui', {}),
                     ('gui-e', 'free', 'gui', {}), ('gui-after-a', 'free', 'gui', dict(needs=['gui-a'])), ('alone-last', 'alone', 'unit', {})]
            with tempfile.TemporaryDirectory(dir=root / '.work', prefix='gate-test-') as name:
                directory = Path(name)
                directory.chmod(0o755)
                report = dict(steps=[])
                planned = [gate.Step(step, [sys.executable, '-c', script, step, mode, str(jobs), *fields.get('needs', ())], 60, kind, **fields)
                           for step, mode, kind, fields in steps]
                code = gate.run_steps(planned, directory, dict(os.environ), directory, report, True, 0, jobs)
                return code, report, [step[0] for step in steps]

        code, report, names = run(1, 'free')
        self.assertEqual((code, [step['name'] for step in report['steps']]), (0, names))
        self.assertFalse(any('beside' in step for step in report['steps']))
        code, report, names = run(4, 'together')
        self.assertEqual((code, [step['name'] for step in report['steps']]), (0, names))  # reported in plan order
        self.assertEqual(report['summary'], dict(planned=9, passed=9, flaky=0, failed=0, not_run=0))
        self.assertEqual([step['name'] for step in report['steps'] if step.get('beside')], [name for name in names if name.startswith('gui-')])

    def test_jobs_keep_failures_retries_and_leaks_exact(self):
        bad = 'open("bad","w").close(); raise SystemExit(4)'
        slow = 'import os,time\nwhile not os.path.exists("bad"): time.sleep(.01)\ntime.sleep(.3)'
        # A failed step stops new work; steps already running finish and are reported.
        code, report = self.sequence([('gui-bad', bad), ('gui-slow', slow), ('gui-next', 'pass'), ('gui-later', 'pass'), ('last', 'pass')], jobs=2)
        self.assertEqual(code, 1)
        self.assertEqual([(step['name'], step['status']) for step in report['steps']], [('gui-bad', 'failed'), ('gui-slow', 'passed')])
        self.assertEqual(report['summary'], dict(planned=5, passed=1, flaky=0, failed=1, not_run=3))
        # With keep_going everything else runs, except what needed the failed step.
        code, report = self.sequence([('gui-bad', bad), ('gui-slow', slow), ('gui-needs-bad', 'pass'), ('gui-then', 'pass'), ('last', 'pass')],
                                     keep_going=True, jobs=2, fields={'gui-needs-bad': dict(needs=['gui-bad']), 'gui-then': dict(needs=['gui-needs-bad'])})
        self.assertEqual([(step['name'], step['status']) for step in report['steps']], [('gui-bad', 'failed'), ('gui-slow', 'passed'), ('last', 'passed')])
        self.assertEqual(report['summary'], dict(planned=5, passed=2, flaky=0, failed=1, not_run=2))
        # A step waits for what it needs, even when that runs alone and later.
        code, report = self.sequence([('gui-first', 'pass'), ('late', 'open("late","w").close()'), ('gui-needs-late', 'import os; assert os.path.exists("late")')],
                                     jobs=2, fields={'gui-needs-late': dict(needs=['late'])})
        self.assertEqual((code, report['summary']['passed']), (0, 3))
        # A retry beside other steps moves only the step's declared directory.
        mine = 'import os,sys,time\nwhile not os.path.exists(".work/other"): time.sleep(.01)\nos.mkdir(".work/mine")\nif os.path.exists("m"): sys.exit(0)\nopen("m","w").close(); sys.exit(1)'
        other = 'import os,time\nos.makedirs(".work/other")\nwhile not os.path.exists("m"): time.sleep(.01)\ntime.sleep(.3)\nassert os.path.isdir(".work/other")'
        code, report = self.sequence([('gui-other', other), ('gui-mine', mine)], retries=1, jobs=2, fields={'gui-mine': dict(work=['mine'])})
        self.assertEqual((code, report['flaky'], report['work']), (0, ['gui-mine'], ['mine', 'mine.attempt1', 'other']))
        retried = report['steps'][1]
        self.assertEqual((retried['beside'], retried['earlier_attempts'][0]['set_aside']), (True, ['mine']))
        # Without the declaration the retry is not helped, and stays a failure.
        code, report = self.sequence([('gui-other', other), ('gui-mine', mine)], retries=1, jobs=2)
        self.assertEqual((code, report['steps'][1]['status'], report['work']), (1, 'failed', ['mine', 'other']))
        # A step named in NO_RETRY fails on its first failure, alone or beside others.
        once = 'import os,sys\nif os.path.exists("again"): sys.exit(0)\nopen("again","w").close(); sys.exit(1)'
        for jobs in (1, 2):
            code, report = self.sequence([('fence-timeout', once)], retries=2, jobs=jobs, fields={'fence-timeout': dict(kind='gui')})
            self.assertEqual((code, report['steps'][0]['status'], report['flaky']), (1, 'failed', []))
        # Steps that can never start are a failure, never a pass with steps left over; skipped steps are named.
        for jobs in (1, 2):
            code, report = self.sequence([('gui-a', 'pass'), ('gui-b', 'pass'), ('last', 'pass')], jobs=jobs,
                                         fields={'gui-a': dict(needs=['gui-b']), 'gui-b': dict(needs=['gui-a'])})
            self.assertEqual((code, report['not_run'], report['failures'][0]['status']), (1, ['gui-a', 'gui-b'], 'unscheduled'))
        code, report = self.sequence([('gui-bad', bad), ('gui-needs-bad', 'pass'), ('gui-then', 'pass')], keep_going=True, jobs=2,
                                     fields={'gui-needs-bad': dict(needs=['gui-bad']), 'gui-then': dict(needs=['gui-needs-bad'])})
        self.assertEqual(report['skipped'], [dict(name='gui-needs-bad', needs=['gui-bad']), dict(name='gui-then', needs=['gui-needs-bad'])])
        self.assertEqual(report['not_run'], ['gui-needs-bad', 'gui-then'])
        # A leak inside the step's session is charged to that step, beside a clean one.
        leak = 'import os,time\nopen("bad","w").close()\nif os.fork(): os._exit(0)\ntime.sleep(60)'
        code, report = self.sequence([('gui-leak', leak), ('gui-slow', slow)], keep_going=True, jobs=2)
        self.assertEqual([(step['name'], step['status']) for step in report['steps']], [('gui-leak', 'leaked_processes'), ('gui-slow', 'passed')])
        # One that left the session is caught when the batch ends, and names the batch.
        escaped = 'import os,time\nopen("bad","w").close()\nr,w=os.pipe()\nif os.fork(): os.close(w); os.read(r,1); os._exit(0)\nos.close(r)\nos.setsid()\nos.write(w,b"1")\ntime.sleep(60)'
        code, report = self.sequence([('gui-escape', escaped), ('gui-slow', slow)], keep_going=True, jobs=2)
        self.assertEqual(code, 1)
        stray = report['steps'][-1]
        self.assertEqual((stray['name'], stray['status'], stray['among'], stray['remaining_pids']), ('parallel-strays', 'leaked_processes', ['gui-escape', 'gui-slow'], []))
        self.assertEqual([step['status'] for step in report['steps'][:2]], ['passed', 'passed'])
        self.assertEqual(report['summary']['failed'], 1)
        self.assertEqual(gate.children(), set())

    def test_python_path_coverage(self):
        for tier in ('host', 'all'):
            steps = {name: argv for name, argv, _ in gate.plan(tier, python='/fixture/python')}
            self.assertTrue({'python-path-component', 'python-path-watches-0', 'python-path-watches-1'} <= steps.keys())
            self.assertIn('--sanitize', steps['python-path-component'])
            self.assertNotIn('--agent', steps['python-path-watches-0'])
            self.assertIn('--agent', steps['python-path-watches-1'])
        for tier in ('gui', 'all'):
            steps = {name: argv for name, argv, _ in gate.plan(tier, python='/fixture/python')}
            self.assertIn('--paths', steps['python-path-watch-gui'])

    def test_ruby_watch_coverage(self):
        for tier in ('host', 'all'):
            names={name for name,_,_ in gate.plan(tier,ruby='/fixture/ruby')}
            self.assertTrue({'ruby-watch-component','ruby-watches','ruby-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in gate.plan(tier,ruby='/fixture/ruby')}
            self.assertIn('ruby-watches-gui',names)

    def test_ruby_frame_names_cover_components_and_transports(self):
        for tier in ('host', 'all'):
            steps={name:argv for name,argv,_ in gate.plan(tier,ruby='/fixture/ruby')}
            self.assertIn('ruby-frame-names-component',steps)
            self.assertNotIn('--agent',steps['ruby-frame-names'])
            self.assertIn('--agent',steps['ruby-frame-names-agent'])
            self.assertTrue(all('--strace' in steps[name] for name in ('ruby-frame-names','ruby-frame-names-agent')))

    def test_javascript_watch_coverage(self):
        for tier in ('host', 'all'):
            names={name for name,_,_ in gate.plan(tier,node='/fixture/node')}
            self.assertTrue({'javascript-watches','javascript-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in gate.plan(tier,node='/fixture/node')}
            self.assertIn('javascript-watches-gui',names)

    def test_node_refusal_is_separate_from_positive_watch_coverage(self):
        for tier in ('gui', 'all'):
            steps={name:(argv,seconds) for name,argv,seconds in gate.plan(tier,node='/fixture/supported-node',node_refusal='/fixture/unproved-node')}
            positive,positive_seconds=steps['javascript-watches-gui']
            refusal,refusal_seconds=steps['javascript-frame-refusal-gui']
            self.assertEqual(positive[positive.index('--node')+1],'/fixture/supported-node')
            self.assertNotIn('--expect-node-frame-refusal',positive)
            self.assertEqual(refusal[refusal.index('--node')+1],'/fixture/unproved-node')
            self.assertIn('--expect-node-frame-refusal',refusal)
            self.assertNotEqual(positive[positive.index('--work')+1],refusal[refusal.index('--work')+1])
            self.assertGreater(positive_seconds,900)
            self.assertGreater(refusal_seconds,900)
            self.assertNotIn('javascript-frame-refusal-gui',{name for name,_,_ in gate.plan(tier,node='/fixture/supported-node')})

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
    def test_pe_reader_has_fast_and_periodic_lanes(self):
        for tier in ('portable', 'host', 'gui', 'all', 'periodic', 'periodic-gui'):
            steps = {name: argv for name, argv, _ in gate.plan(tier)}
            self.assertEqual(steps['pe-image'], [sys.executable, '-B',
                             'tests/pe-image.py', '--work', '.work/pe-image'])
            self.assertEqual(steps['pe-unwind'], [sys.executable, '-B',
                             'tests/pe-unwind.py', '--work', '.work/pe-unwind'])
            self.assertEqual('pe-unwind-fuzz' in steps, tier in ('periodic', 'periodic-gui'))
            self.assertEqual('pe-image-fuzz' in steps, tier in ('periodic', 'periodic-gui'))
            if 'pe-image-fuzz' in steps:
                self.assertIn('--fuzz', steps['pe-image-fuzz'])

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
