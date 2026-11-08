#!/usr/bin/env python3
"""Exercise environment isolation, deadlines and owned descendant cleanup."""
import contextlib
import ctypes
from importlib.machinery import SourceFileLoader
import fnmatch
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
from unittest import mock

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
        ('run on a riscv64 guest by tests/riscv64-guest.sh (periodic --riscv64-guest)', ('runtime-riscv64.py',)),
        ('run on a Linux aarch64 machine by tests/aarch64-pac.sh (all or periodic --aarch64-pac)', ('aarch64-pac.py',)),
        ('run on Darwin by macos-native.py --local (release-check --macos)', ('macos-local.py',)),
        ('needs a device profile', ('simpleperf-import.py', 'simpleperf-import-gui.py',)),
        ('needs sudo: the privileged allocation helper, or a configured host', ('allocations-live.py', 'm2-syscall-configured.py',)),
        ('measurement, no pass criteria', ('allocation-cost.py', 'memory-cost.py', 'm2-server-cost.py', 'm2-workload-cost.py',)),
        ('opt-in release-check --compare-binary; needs an explicitly selected reference build', ('command-compare.py',)),
        ('not gated: needs arguments or fixtures that no step builds', ('cfi-image.py', 'metadata-job.py', 'metadata-image-job.py', 'source-confinement.py', 'observation-association-lifecycle.py', 'observation-saved-associations.py', 'vulkan-leaks.py', 'frame-jit.py', 'jitmap-fixture.py', 'jitmap-perf-crosscheck.py', 'jitmap-runtime-producers.py',)),
        ('not gated: needs output from another test', ('core-gui.py', 'discovery-gui.py', 'syscall-gui.py', 'm2-archive-gui.py', 'm2-limits-gui.py',)),
        ('not gated: passes alone, but its compositor socket path is too long inside a gate snapshot', ('m2-intervals-gui.py', 'm2-preferences-gui.py', 'm2-values-gui.py',)),
        ('not gated: fails when run alone', ('allocations-gui.py', 'allocations-live-gui.py', 'fdgraph.py', 'm2-dynamic-threads-gui.py', 'm2-timeline-gui.py', 'm2-values.py', 'process-capacity.py', 'sysstat-live.py', 'runtime-leaks.py', 'simpleperf-tools.py',)),
    ) for name in names
}


def lane(tier, *args, **flags):
    # A tier's steps together with the ones PERIODIC moved out of it.
    return [*gate.plan(tier, *args, **flags), *gate.plan(tier, *args, **flags, moved=True)]


class RunnerTests(unittest.TestCase):
    def assertOnlyToolCaches(self, home):
        allowed = tuple(Path(name) for name in (
            '.cache/zig', '.cache/go-build', 'go/pkg/mod',
            '.cache/mesa_shader_cache', '.cache/mesa_shader_cache_db',
            '.cache/mesa_shader_cache_sf', '.cache/radv_builtin_shaders'))
        unexpected = []
        for path in home.rglob('*'):
            relative = path.relative_to(home)
            if any(relative == cache or cache in relative.parents for cache in allowed):
                continue
            if path.is_dir() and any(relative in cache.parents for cache in allowed):
                continue
            unexpected.append(str(relative))
        self.assertEqual(sorted(unexpected), [], 'unexpected writes under fake HOME')

    def test_fake_home_allowlist_rejects_application_paths(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='home-allowlist-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            home = directory / 'home'
            for cache in ('.cache/zig', '.cache/go-build', 'go/pkg/mod',
                          '.cache/mesa_shader_cache', '.cache/mesa_shader_cache_db',
                          '.cache/mesa_shader_cache_sf', '.cache/radv_builtin_shaders'):
                path = home / cache / 'owned'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('tool cache')
            self.assertOnlyToolCaches(home)
            for bad in ('.cache/xodb-debug-v2/0.names', '.cache/xodb/ghidra-sidecar/image',
                        '.local/state/xodb/sidecar.log', '.config/xodb/settings',
                        '.cache/zig-unrelated/owned', 'go/pkg/unrelated/owned'):
                with self.subTest(path=bad), tempfile.TemporaryDirectory(dir=directory) as other:
                    fake = Path(other)
                    fake.chmod(0o755)
                    planted = fake / bad
                    planted.parent.mkdir(parents=True)
                    planted.write_text('not a tool cache')
                    with self.assertRaisesRegex(AssertionError, 'unexpected writes under fake HOME'):
                        self.assertOnlyToolCaches(fake)

    def test_real_xodb_session_keeps_fake_home_clean(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='home-session-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            home = directory / 'home'
            home.mkdir()
            inherited = dict(os.environ, HOME=str(home))
            for key in ('XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
                        'XODB_TEST_XDG_ROOT', 'ZIG_GLOBAL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE',
                        'GOPATH', 'MESA_SHADER_CACHE_DIR', 'XODB_RUNTIME_AGENT', 'XODB_TEST_RUNTIME_AGENT'):
                inherited.pop(key, None)
            inherited.update(XODB_BIN=str(root / 'zig-out/bin/xodb'), XODB_GHIDRA_SIDECAR='off')
            env = gate.isolated_test_environment(inherited, directory / 'private')
            source = '''import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from client import Client
private, home = Path(sys.argv[2]), Path(sys.argv[3])
# No target: the portable tier needs neither ptrace/perf nor a display.
client = Client('observe', None)
try:
    session = client.session()
    assert session['pid'] == 0 and not session['threads'], session
    actual = dict(entry.split('=', 1) for entry in Path(f'/proc/{client.p.pid}/environ').read_text().split('\\0') if '=' in entry)
    assert actual['HOME'] == str(home)
    for kind in ('CACHE', 'STATE', 'CONFIG'):
        assert Path(actual['XDG_' + kind + '_HOME']) == private / kind.lower()
finally:
    client.close()
print('PASS real targetless MCP session and private XDG inheritance')
'''
            result = gate.run_step('fake-home-xodb', [sys.executable, '-c', source, str(root / 'tests'),
                                   str(directory / 'private'), str(home)], 15, root, env, directory)
            output = Path(result['log']).read_text()
            self.assertEqual(result['status'], 'passed', output)
            self.assertIn('PASS real targetless MCP session', output)
            self.assertOnlyToolCaches(home)

    def test_xdg_runs_are_private_and_tool_caches_stay_shared(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='xdg-runs-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            inherited = {'HOME': str(directory / 'caller'), 'XDG_CACHE_HOME': str(directory / 'shared'),
                         'XDG_STATE_HOME': str(directory / 'caller-state'), 'XDG_CONFIG_HOME': str(directory / 'caller-config'),
                         'GOPATH': str(directory / 'go') + os.pathsep + str(directory / 'second-go')}
            original = dict(inherited)
            first = gate.isolated_test_environment(inherited, directory / 'first')
            second = gate.isolated_test_environment(inherited, directory / 'second')
            self.assertEqual(inherited, original)
            for kind in ('CACHE', 'STATE', 'CONFIG'):
                key = f'XDG_{kind}_HOME'
                self.assertEqual(Path(first[key]), directory / 'first' / kind.lower())
                self.assertTrue(Path(first[key]).is_dir())
                self.assertNotEqual(first[key], second[key])
            self.assertEqual(first['ZIG_GLOBAL_CACHE_DIR'], str(directory / 'shared/zig'))
            self.assertEqual(first['GOCACHE'], str(directory / 'shared/go-build'))
            self.assertEqual(first['GOMODCACHE'], str(directory / 'go/pkg/mod'))
            self.assertEqual(first['MESA_SHADER_CACHE_DIR'], str(directory / 'shared'))
            for key in ('ZIG_GLOBAL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE', 'MESA_SHADER_CACHE_DIR'):
                self.assertEqual(first[key], second[key])
            explicit = dict(inherited, **{key: str(directory / key) for key in (
                'ZIG_GLOBAL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE', 'MESA_SHADER_CACHE_DIR')})
            kept = gate.isolated_test_environment(explicit, directory / 'explicit')
            for key in ('ZIG_GLOBAL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE', 'MESA_SHADER_CACHE_DIR'):
                self.assertEqual(kept[key], explicit[key])

    def test_xdg_missing_home_does_not_find_the_real_home(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='xdg-no-home-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            for inherited in ({}, {'XDG_CACHE_HOME': 'relative-cache'}):
                env = gate.isolated_test_environment(inherited, directory)
                self.assertNotIn('HOME', env)
                for key in ('XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_CONFIG_HOME',
                            'ZIG_GLOBAL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE', 'MESA_SHADER_CACHE_DIR'):
                    self.assertTrue(Path(env[key]).is_relative_to(directory), (key, env[key]))

    def test_xdg_applies_to_plain_gate_children(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='xdg-child-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            caller = directory / 'caller'
            caller.mkdir()
            inherited = dict(os.environ, XDG_CACHE_HOME=str(caller), XDG_STATE_HOME=str(caller), XDG_CONFIG_HOME=str(caller))
            env = gate.isolated_test_environment(inherited, directory / 'run')
            source = '''import os
from pathlib import Path
for kind in ('CACHE', 'STATE', 'CONFIG'):
    path = Path(os.environ[f'XDG_{kind}_HOME'])
    assert path.is_relative_to(Path(os.environ['XODB_TEST_XDG_ROOT']))
    (path / 'owned-marker').write_text(kind)
'''
            result = gate.run_step('xdg-owned', [sys.executable, '-c', source], 5, directory, env, directory)
            self.assertEqual(result['status'], 'passed')
            self.assertEqual(list(caller.iterdir()), [])
            for kind in ('cache', 'state', 'config'):
                self.assertTrue((directory / 'run' / kind / 'owned-marker').is_file())

    def test_main_installs_xdg_before_running_any_step(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='xdg-main-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            caller = directory / 'caller'
            caller.mkdir()
            observed = []
            def run(steps, tree, env, logs, report, *args):
                del steps, args
                observed.append(env)
                for kind in ('CACHE', 'STATE', 'CONFIG'):
                    self.assertTrue(Path(env[f'XDG_{kind}_HOME']).is_relative_to(tree))
                result = gate.run_step('xdg-main-child', [sys.executable, '-c',
                    "import os; from pathlib import Path; "
                    "[(Path(os.environ['XDG_'+kind+'_HOME'])/'marker').write_text(kind) "
                    "for kind in ('CACHE','STATE','CONFIG')]"], 5, tree, env, logs)
                report['steps'].append(result)
                return 0 if result['status'] == 'passed' else 1
            with mock.patch.object(gate, 'ROOT', directory), \
                 mock.patch.object(gate, 'plan', return_value=gate.Steps()), \
                 mock.patch.object(gate, 'snapshot', return_value={}), \
                 mock.patch.object(gate, 'run_steps', run), \
                 mock.patch.object(gate.subprocess, 'check_output', return_value='fixture\n'), \
                 mock.patch.object(gate.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout='', stderr='')), \
                 mock.patch.object(gate.shutil, 'which', return_value='/fixture/tool'), \
                 mock.patch.dict(os.environ, XDG_CACHE_HOME=str(caller), XDG_STATE_HOME=str(caller), XDG_CONFIG_HOME=str(caller)):
                self.assertEqual(gate.main(['portable', '--headless']), 0)
                self.assertEqual(os.environ['XDG_CACHE_HOME'], str(caller))
            self.assertEqual(len(observed), 1)
            self.assertEqual(list(caller.iterdir()), [])
            for kind in ('CACHE', 'STATE', 'CONFIG'):
                self.assertEqual((Path(observed[0][f'XDG_{kind}_HOME']) / 'marker').read_text(), kind)

    def test_standalone_client_isolates_once_and_keeps_explicit_cases(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='xdg-client-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            caller = directory / 'caller'
            caller.mkdir()
            env = dict(os.environ, XODB_TEST_TMPDIR=str(directory), XDG_CACHE_HOME=str(caller),
                       XDG_STATE_HOME=str(caller), XDG_CONFIG_HOME=str(caller))
            env.pop('XODB_TEST_XDG_ROOT', None)
            source = f'''import os, sys
from pathlib import Path
sys.path.insert(0, {str(root / 'tests')!r})
import client
from helpers.environment import ensure
private = Path(os.environ['XODB_TEST_XDG_ROOT'])
assert private.parent == Path(os.environ['XODB_TEST_TMPDIR'])
for kind in ('CACHE', 'STATE', 'CONFIG'):
    path = Path(os.environ[f'XDG_{{kind}}_HOME'])
    assert path.is_relative_to(private)
    (path / 'owned-marker').write_text(kind)
os.environ['XDG_CACHE_HOME'] = str(private / 'explicit-cache-case')
ensure()
assert os.environ['XDG_CACHE_HOME'].endswith('/explicit-cache-case')
os.environ.pop('XDG_CACHE_HOME')
ensure()
assert 'XDG_CACHE_HOME' not in os.environ
'''
            result = gate.run_step('standalone-xdg', [sys.executable, '-c', source], 5, directory, env, directory)
            self.assertEqual(result['status'], 'passed', (directory / 'standalone-xdg.log').read_text())
            self.assertEqual(list(caller.iterdir()), [])
            self.assertFalse(list(directory.glob('test-xdg-*')), 'standalone temporary state is cleaned after process exit')

    def test_soak_render_node_selection_and_private_override(self):
        from helpers import display
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sysfs, dri = root / 'sys', root / 'dri'
            dri.mkdir()
            for name, vendor in [('renderD128', '0x1002'), ('renderD129', '0x10de')]:
                device = sysfs / name / 'device'
                device.mkdir(parents=True)
                (device / 'vendor').write_text(vendor + '\n')
                (dri / name).touch()
            nvidia = str(dri / 'renderD129')
            self.assertEqual(display.nvidia_render_node(sysfs, dri), nvidia)
            (dri / 'renderD129').unlink()
            self.assertIsNone(display.nvidia_render_node(sysfs, dri))
            (sysfs / 'renderD129/device/vendor').unlink()
            self.assertIsNone(display.nvidia_render_node(sysfs, dri))
            self.assertIsNone(display.nvidia_render_node(root / 'absent', dri))
            # No compositor or compiler is started. Only the child environment
            # changes, and an ordinary Display keeps its inherited selection.
            with mock.patch.object(display, 'WORK', str(root / 'work')), \
                 mock.patch.object(display.subprocess, 'run'), \
                 mock.patch.object(display.subprocess, 'Popen'), \
                 mock.patch.object(display.Display, 'wait_ready', lambda self, env: setattr(self, 'env', env)), \
                 mock.patch.dict(os.environ, {'WLR_RENDER_DRM_DEVICE': 'inherited', 'XODB_VK_DEVICE': 'unchanged'}):
                ordinary = display.Display('ordinary')
                pinned = display.Display('pinned', render_node=nvidia)
                try:
                    self.assertEqual(ordinary.env['WLR_RENDER_DRM_DEVICE'], 'inherited')
                    self.assertEqual(pinned.env['WLR_RENDER_DRM_DEVICE'], nvidia)
                    self.assertEqual(os.environ['WLR_RENDER_DRM_DEVICE'], 'inherited')
                    self.assertEqual(pinned.env['XODB_VK_DEVICE'], 'unchanged')
                finally:
                    ordinary.close()
                    pinned.close()
    def test_gui_evidence_first_failure_survives_retry(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='ocr-evidence-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            inherited = dict(os.environ, XODB_TEST_LOG_DIR='unused-inherited-directory')
            source = '''import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from helpers import gui_evidence
frame = Path('owned-frame.png')
frame.write_bytes(b'first failing frame')
gui_evidence.record(frame, 'original OCR: lnmatched')
gui_evidence.first_failure()
frame.write_bytes(b'later frame')
gui_evidence.record(frame, 'later OCR')
gui_evidence.first_failure()
frame.unlink()
raise SystemExit(int(sys.argv[2]))
'''
            for attempt, exit_code in (('gui-owned', 1), ('gui-owned.retry1', 0)):
                result = gate.run_step(attempt, [sys.executable, '-c', source, str(root / 'tests'), str(exit_code)],
                                       5, directory, inherited, directory)
                self.assertEqual(result['status'], 'failed' if exit_code else 'passed')
                artifacts = directory / (attempt + '.artifacts')
                self.assertEqual((artifacts / 'ocr-first-failure/frame.png').read_bytes(), b'first failing frame')
                self.assertEqual((artifacts / 'ocr-first-failure/ocr.txt').read_text(), 'original OCR: lnmatched')
                self.assertEqual((artifacts / 'ocr-latest/frame.png').read_bytes(), b'later frame')
            self.assertEqual(inherited['XODB_TEST_LOG_DIR'], 'unused-inherited-directory')
            self.assertEqual((directory / 'gui-owned.artifacts/ocr-first-failure/ocr.txt').read_text(), 'original OCR: lnmatched')

    def test_gui_ocr_timeout_captures_without_relaxing_predicate(self):
        from helpers import input as display_input
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='ocr-timeout-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            frame = directory / 'owned.png'
            frame.write_bytes(b'owned synthetic frame')
            artifacts = directory / 'artifacts'
            display = mock.Mock()
            display.shot.return_value = str(frame)
            with mock.patch.dict(os.environ, XODB_TEST_LOG_DIR=str(artifacts)), \
                 mock.patch.object(display_input.subprocess, 'run', return_value=mock.Mock(stdout='lnmatched\n')), \
                 mock.patch.object(display_input, 'load_scale', return_value=1):
                text = display_input.ocr_until(display, 'status', lambda text: 'unmatched' in text, seconds=-1)
                self.assertEqual(text, 'lnmatched')
                self.assertEqual((artifacts / 'ocr-first-failure/ocr.txt').read_text(), 'lnmatched\n')
                self.assertEqual((artifacts / 'ocr-first-failure/frame.png').read_bytes(), frame.read_bytes())
                text = display_input.ocr_until(display, 'status', lambda text: 'lnmatched' in text)
                self.assertEqual(text, 'lnmatched')
                self.assertEqual((artifacts / 'ocr-first-failure/ocr.txt').read_text(), 'lnmatched\n')

    def test_gui_direct_assertion_keeps_evidence_before_successful_retry(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='ocr-assert-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            source = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from helpers import gui_evidence
frame = Path('owned.png')
frame.write_bytes(sys.argv[2].encode())
gui_evidence.record(frame, sys.argv[2])
frame.unlink()
assert sys.argv[2] == 'pass'
'''
            for attempt, text in (('gui-assert', 'first failure'), ('gui-assert.retry1', 'pass')):
                result = gate.run_step(attempt, [sys.executable, '-c', source, str(root / 'tests'), text],
                                       5, directory, dict(os.environ), directory)
                self.assertEqual(result['status'], 'passed' if text == 'pass' else 'failed')
            first = directory / 'gui-assert.artifacts/ocr-first-failure'
            self.assertEqual((first / 'frame.png').read_bytes(), b'first failure')
            self.assertEqual((first / 'ocr.txt').read_text(), 'first failure')
            self.assertFalse((directory / 'gui-assert.retry1.artifacts/ocr-first-failure').exists())

    def test_gui_evidence_errors_do_not_replace_assertions(self):
        from helpers import gui_evidence
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='ocr-error-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            obstacle = directory / 'not-a-directory'
            obstacle.write_text('owned obstacle')
            with mock.patch.dict(os.environ, XODB_TEST_LOG_DIR=str(obstacle)), contextlib.redirect_stderr(io.StringIO()) as errors:
                gui_evidence.record('missing.png', 'failure')
                gui_evidence.first_failure()
            self.assertIn('GUI evidence capture failed', errors.getvalue())

    def test_vulkan_filter_retry_requires_its_report(self):
        from helpers.vulkan_outcomes import reported_filter_retry
        rules = 'poison=1;fail=vkCreateInstance@1:oodm'
        summary = {'calls': {'vkCreateInstance': [2, 0]}}
        report = 'Vulkan early loader filter gave no instance (OutOfDeviceMemory); loading every driver'
        self.assertTrue(reported_filter_retry(rules, summary, report))
        # Plant the missing-report regression: two calls alone are not proof.
        self.assertFalse(reported_filter_retry(rules, summary, ''))
        self.assertFalse(reported_filter_retry(rules, summary, 'loading every driver'))
        self.assertFalse(reported_filter_retry(rules, {'calls': {'vkCreateInstance': [1, 0]}}, report))

    def test_vulkan_empty_device_selector_is_automatic(self):
        from helpers.vulkan_outcomes import requested_error
        self.assertIsNone(requested_error('start-devices-0', {}))
        for value in ('', ' \t'):
            self.assertIsNone(requested_error('start-devices-0', {'XODB_VK_DEVICE': value}))
            self.assertIsNone(requested_error('start-families-0', {'XODB_VK_DEVICE': value}))
        for value in ('NVIDIA', '0'):
            self.assertEqual(requested_error('start-devices-0', {'XODB_VK_DEVICE': value}), 'VulkanDeviceNotFound')
            self.assertEqual(requested_error('start-families-0', {'XODB_VK_DEVICE': value}), 'VulkanDeviceCannotPresent')

    def test_snapshot_keeps_native_build_entry(self):
        def tracked(argv, **kwargs):
            del kwargs
            return b'build_macos.zig\0' if 'build_macos.zig' in argv else b''
        with tempfile.TemporaryDirectory(prefix='native-snapshot-') as directory:
            with mock.patch.object(gate.subprocess, 'check_output', tracked):
                hashes = gate.snapshot(Path(directory))
            self.assertIn('build_macos.zig', hashes)
            self.assertEqual((Path(directory) / 'build_macos.zig').read_bytes(), (root / 'build_macos.zig').read_bytes())

    @classmethod
    def setUpClass(cls):
        assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
        (root / '.work').mkdir(exist_ok=True)

    def test_focused_gui_keeps_headless_app_build(self):
        selected = gate.select(gate.plan('gui'), only=['gui-debug'])
        by_name = {step.name: step for step in selected}
        self.assertIn('headless-app', by_name)
        self.assertIn('-Dgui=false', by_name['headless-app'].argv)
        self.assertEqual(by_name['headless-app'].kind, 'build')
        self.assertIn('headless-app', by_name['build-tests'].needs)
        self.assertNotIn('headless-app', {step.name for step in gate.plan('portable', headless=True)})

    def test_go_native_value_lanes(self):
        for tier in ('quick', 'host', 'gui', 'all', 'periodic'):
            steps = {name: cmd for name, cmd, _ in lane(tier, go='/fixture/go')}
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

    def test_gdscript_lanes(self):
        # The engine is a runtime option like the others: no steps without it.
        for tier in ('host', 'gui', 'all', 'periodic', 'periodic-gui'):
            self.assertFalse([name for name, _, _ in lane(tier) if name.startswith('gdscript-')], tier)
            self.assertIn('dwarf-types', {name for name, _, _ in gate.plan(tier)})
        for tier in ('host', 'all'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier, redot='/fixture/engine')}
            self.assertIn('--strace', steps['gdscript-stack'])
            self.assertIn('--strace', steps['gdscript-values'])
            self.assertIn('--values', steps['gdscript-demo-values'])
            self.assertNotEqual(steps['gdscript-demo'][-1], steps['gdscript-demo-values'][-1])
            for name in ('gdscript-stack', 'gdscript-demo', 'gdscript-values', 'gdscript-demo-values'):
                self.assertEqual(steps[name][steps[name].index('--redot') + 1], '/fixture/engine')
        for tier in ('gui', 'all'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier, redot='/fixture/engine')}
            for name in ('gdscript-gui', 'gdscript-values-gui'):
                self.assertEqual(steps[name][steps[name].index('--redot') + 1], '/fixture/engine')
        self.assertFalse({'gdscript-gui', 'gdscript-values-gui'} & {name for name, _, _ in gate.plan('host', redot='/fixture/engine')})
        self.assertFalse({'gdscript-stack', 'gdscript-values'} & {name for name, _, _ in gate.plan('gui', redot='/fixture/engine')})
        for tier in ('portable', 'perf'):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                gate.main([tier, '--redot', '/fixture/engine', '--list'])

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
            for variant in ('chain', 'debug-frame', 'companions', 'mixed'):
                self.assertIn('tests/module-unwind.py', steps['module-unwind-'+variant])
            self.assertIn('--mixed', steps['module-unwind-mixed'])
            self.assertNotIn('module-unwind-eviction', steps)
            self.assertNotIn('module-unwind-eviction-agent-lane', steps)
        for tier in ('periodic', 'periodic-gui'):
            steps = {name: cmd for name, cmd, _ in gate.plan(tier)}
            for variant in ('eviction', 'budget', 'full-dwarf', 'large-companions'):
                self.assertIn('--'+variant, steps['module-unwind-'+variant])
            self.assertIn('tests/cfi-job.py', steps['cfi-job'])
            self.assertIn('--agent', steps['cfi-job'])
        periodic = {name: cmd for name, cmd, _ in gate.plan('periodic')}
        lane = periodic['module-unwind-eviction-agent-lane']
        self.assertEqual(lane[:2], ['env', 'XODB_TEST_RUNTIME_AGENT=./zig-out/bin/xodb-agent'])
        self.assertIn('--eviction', lane)
        self.assertNotIn('module-unwind-eviction-agent-lane', {name for name, _, _ in gate.plan('periodic-gui')})
        self.assertNotIn('module-unwind-eviction-agent-lane', {name for name, _, _ in gate.plan('periodic', headless=True)})

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
            steps={name:cmd for name,cmd,_ in lane(tier)}
            self.assertNotIn('--agent',steps['gui-jai-writes'])
            self.assertIn('--agent',steps['gui-jai-writes-agent'])

    def test_elisp_has_local_agent_and_gui_oracles(self):
        steps = {name: cmd for name, cmd, _ in lane('all', emacs='chosen-emacs')}
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
            steps = {name: cmd for name, cmd, _ in lane(tier)}
            local = steps['gui-safe-keys']
            agent = steps['gui-safe-keys-agent']
            self.assertIn('tests/safe-keys-gui.py', local)
            self.assertNotIn('--agent', local)
            self.assertEqual(agent[agent.index('--agent') + 1], 'zig-out/bin/xodb-agent')
            self.assertNotEqual(local[local.index('--work') + 1], agent[agent.index('--work') + 1])

    def test_lua_table_paths_have_transport_and_gui_coverage(self):
        steps = lane('all', False, 'ReleaseSafe', lua=[('lua54','src54','lib54'), ('lua52','src52','lib52')])
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

    def test_optional_lab_steps_are_skipped_without_configuration(self):
        names = {'kernel-target-lab', 'kernel-target-lab-core', 'kernel-target-lab-kcore',
                 'gui-kernel-target-lab', 'gui-kernel-target-lab-core', 'kernel-census-lab'}
        planned = [step for tier in ('periodic', 'periodic-gui') for step in gate.plan(tier) if step.name in names]
        self.assertEqual({step.name for step in planned}, names)
        self.assertEqual(len(planned), len(names))
        # These optional fixtures are leaves, never a substitute for a build.
        self.assertFalse(any(names.intersection(step.needs) for tier in self.TIERS for step in gate.plan(tier)))
        for jobs in (1, 2):
            for setting in (None, ''):
                with self.subTest(jobs=jobs, setting=setting), tempfile.TemporaryDirectory(dir=root / '.work', prefix='lab-skip-') as name:
                    directory = Path(name)
                    directory.chmod(0o755)
                    env = dict(os.environ)
                    env.pop('XODB_KERNEL_LAB', None)
                    if setting is not None:
                        env['XODB_KERNEL_LAB'] = setting
                    report = dict(steps=[])
                    # An absent fixture is not launched, even as a GUI retry.
                    with mock.patch.object(gate.subprocess, 'Popen', side_effect=AssertionError('unconfigured lab launched')):
                        code = gate.run_steps(planned, directory, env, directory, report, retries=2, jobs=jobs)
                    self.assertEqual(code, 0)
                    self.assertEqual(report['summary'], dict(planned=6, passed=0, skipped=6, flaky=0, failed=0, not_run=0))
                    self.assertEqual(report['failures'], [])
                    for step in report['steps']:
                        self.assertEqual(step['status'], 'skipped')
                        self.assertEqual(step['reason'], 'XODB_KERNEL_LAB is not configured')
                        self.assertNotIn('exit_code', step)
                        self.assertNotIn('earlier_attempts', step)
                        self.assertIn(step['reason'], Path(step['log']).read_text())
                    self.assertEqual(json.loads(json.dumps(report))['summary']['skipped'], 6)

    def test_configured_lab_runs_and_skip_text_is_not_a_skip_contract(self):
        with tempfile.TemporaryDirectory(dir=root / '.work', prefix='lab-configured-') as name:
            directory = Path(name)
            directory.chmod(0o755)
            (directory / 'tests').mkdir()
            script = directory / 'tests/kernel-target-lab.py'
            env = dict(os.environ, XODB_KERNEL_LAB='/fixture/lab')
            for code in (0, 3):
                script.write_text(f"print('SKIP is just diagnostic text here')\nraise SystemExit({code})\n")
                result = gate.run_step('configured-' + str(code), [sys.executable, '-B', 'tests/kernel-target-lab.py'],
                                       5, directory, env, directory)
                self.assertEqual(result['status'], 'passed' if code == 0 else 'failed')
                self.assertEqual(result['exit_code'], code)
            env.pop('XODB_KERNEL_LAB')
            result = gate.run_step('ordinary', [sys.executable, '-c', "print('SKIP unrelated diagnostic')"],
                                   5, directory, env, directory)
            self.assertEqual(result['status'], 'passed')

    def test_lab_skip_continues_unrelated_work_but_cannot_satisfy_a_dependency(self):
        for dependent in (False, True):
            with self.subTest(dependent=dependent), tempfile.TemporaryDirectory(dir=root / '.work', prefix='lab-needs-') as name:
                directory = Path(name)
                directory.chmod(0o755)
                env = dict(os.environ)
                env.pop('XODB_KERNEL_LAB', None)
                planned = [gate.Step('optional', [sys.executable, 'tests/kernel-target-lab.py'], 5),
                           gate.Step('after', [sys.executable, '-c', 'pass'], 5,
                                     needs=['optional'] if dependent else [])]
                report = dict(steps=[])
                code = gate.run_steps(planned, directory, env, directory, report)
                self.assertEqual(report['summary']['skipped'], 1)
                if dependent:
                    self.assertEqual(code, 1)
                    self.assertEqual(report['not_run'], ['after'])
                    self.assertEqual(report['summary']['passed'], 0)
                    self.assertFalse((directory / 'after.log').exists())
                else:
                    self.assertEqual(code, 0)
                    self.assertEqual(report['summary']['passed'], 1)
                    self.assertEqual(report['steps'][1]['status'], 'passed')

    def test_keep_going_runs_every_step_and_summarises(self):
        steps = [('one', 'raise SystemExit(3)'), ('two', 'pass'), ('three', 'import time; time.sleep(9)')]
        code, report = self.sequence(steps)
        self.assertEqual((code, [s['name'] for s in report['steps']]), (1, ['one']))
        self.assertEqual(report['summary'], dict(planned=3, passed=0, skipped=0, flaky=0, failed=1, not_run=2))
        code, report = self.sequence(steps, keep_going=True)
        self.assertEqual((code, [s['name'] for s in report['steps']]), (1, ['one', 'two', 'three']))
        self.assertEqual([(f['name'], f['status']) for f in report['failures']], [('one', 'failed'), ('three', 'timeout')])
        self.assertEqual(report['summary'], dict(planned=3, passed=1, skipped=0, flaky=0, failed=2, not_run=0))
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
        self.assertEqual(report['summary'], dict(planned=2, passed=1, skipped=0, flaky=1, failed=0, not_run=0))
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
        picked = [name for name, _, _ in gate.select(steps, ['gui-fdgraph', 'source-paths'])]
        self.assertEqual(picked, [n for n in names if n in ('headless-app', 'build-tests', 'source-paths-build', 'source-paths', 'gui-fdgraph')])
        later = [name for name, _, _ in gate.select(steps, start='gui-fdgraph')]
        self.assertEqual(later, ['headless-app', 'build-tests', *names[names.index('gui-fdgraph'):]])
        self.assertEqual([name for name, _, _ in gate.select(steps, start='build-tests')], names)
        with self.assertRaises(ValueError): gate.select(steps, ['gui-fdgraph', 'no-such-step'])
        with self.assertRaises(ValueError): gate.select(steps, start='no-such-step')

    RUNTIMES = (['--perl', 'P', '--padwalker', 'W'], ['--python', 'Y'], ['--emacs', 'E'], ['--ruby', 'R'], ['--node', 'N'],
                ['--node', 'N', '--node-refusal', 'NR'], ['--go', 'G'], ['--redot', 'RD'], ['--macos-ssh', 'MAC'], ['--macos', 'MAC'],
                ['--arm64-sidecar', 'SSH', 'AGENT', 'FIXTURE'], ['--riscv64-guest', 'SSH', 'AGENT', 'FIXTURE'], ['--aarch64-pac', 'SSH'], ['--wine', 'WINE'], ['--uprobes'], ['--headless'],
                ['--lua', 'l', 's', 'b', '--lua', 'l2', 's2', 'b2'])
    EVERYTHING = dict(uprobes=True, perl='P', node='N', lua=[('l', 's', 'b'), ('l2', 's2', 'b2')], python='Y', padwalker='W',
                      ruby='R', node_refusal='NR', go='G', wine='WINE', emacs='E', redot='RD', macos_ssh='MAC',
                      arm64_sidecar=('SSH', 'AGENT', 'FIXTURE'), macos='MAC',
                      riscv64_guest=('SSH', 'AGENT', 'FIXTURE'), aarch64_pac='SSH')
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
        self.assertEqual(kinds['vulkan-scale-recovery'].argv,
                         [sys.executable, '-B', 'tests/vulkan-scale-recovery.py'])
        self.assertEqual(kinds['perl-gui'].needs, ('build-tests', 'perl-gui-fixtures'))
        self.assertTrue(kinds['gui-memdefrag-smoke'].serial and not kinds['gui-fdgraph'].serial)
        self.assertTrue({'vulkan-faults', 'gui-overview', 'gui-win95-all-panels', 'gui-clipboard', 'gui-memdefrag', 'gui-files',
                         'gui-memdefrag-modern-evidence'}
                        <= {step.name for step in gate.plan('periodic-gui') if step.kind == 'gui'})
        records = self.listed('gui', '--records')
        self.assertEqual(records['schema'], 2)
        self.assertEqual(records['steps'][0], dict(name='headless-app', argv=gate.plan('gui')[0].argv, timeout=600, kind='build',
                                                   needs=[], paths=[], serial=False, work=['headless-app']))
        vendored = self.listed('gui', '--capstone', 'vendored', '--only', 'gui-fdgraph')
        self.assertEqual([name for name, _, _ in vendored], ['headless-app', 'build-tests', 'gui-fdgraph'])
        self.assertEqual(vendored[0][1][-1], '-Dcapstone=vendored')

    def test_moved_steps_run_unchanged_in_the_periodic_tiers(self):
        flags = {**self.EVERYTHING, 'uprobes': False}
        batch = {step.name: step for step in gate.plan('all', **flags)}
        moved = gate.plan('all', **flags, moved=True)
        live, gui = ({step.name: step for step in gate.plan(tier, **flags)} for tier in ('periodic', 'periodic-gui'))
        for pattern in gate.PERIODIC:
            self.assertTrue(any(fnmatch.fnmatchcase(step.name, pattern) for step in moved), pattern + ' names no step')
        for step in moved:
            self.assertNotIn(step.name, batch)
            self.assertIn(step.kind, ('live', 'gui'), step.name)  # never a build or unit step
            there = (gui if step.kind == 'gui' else live)[step.name]
            self.assertNotIn(step.name, live if step.kind == 'gui' else gui)
            self.assertEqual(there.record(), step.record(), step.name)
        # Never moved: the runner's own test, device selection, and checks of scope, refusal, redaction and limits on untrusted input.
        for name in ('release-runner', 'mcp-exact-guard', 'review-boundaries', 'controller-scope-0', 'controller-scope-1', 'vulkan-device',
                     'vulkan-enumeration', 'vulkan-faults', 'lua-refusals-0', 'lua-refusals-1', 'gui-fdflow-denied',
                     'gui-overview', 'gui-clipboard', 'gui-memdefrag-smoke', 'elisp-limits', 'elisp-limits-agent', 'mcp-list-pages'):
            self.assertIn(name, batch)
        self.assertIn('redact', batch['gui-memdefrag-smoke'].argv[-1])
        # Each runtime and area keeps a live and a GUI step in the batch gate, and one GUI step drives the C agent.
        for names in (('lua-named-0', 'lua-named-shared-agent-0', 'lua-named-gui-0'), ('python-named-0', 'python-named-1', 'python-lua-named-0', 'python-gui'),
                      ('perl-named-0', 'perl-named-shared-1', 'perl-gui'), ('ruby-language', 'ruby-language-agent', 'ruby-watches-gui', 'ruby-gui'),
                      ('javascript-language', 'javascript-watches-agent', 'javascript-gui'), ('go-language', 'go-language-agent', 'go-gui'),
                      ('elisp-language', 'elisp-values-agent-language', 'elisp-bindings-1-1', 'elisp-gui'), ('jai-writes-0-0', 'jai-writes-1-0', 'gui-jai-runtime'),
                      ('sysstat-sensors', 'gui-overview', 'gui-win95', 'gui-themes'), ('fdactivity', 'gui-fdactivity', 'gui-fdgraph'),
                      ('memory-registers', 'memory-search-ranges', 'memdefrag-tui', 'gui-vga'), ('m2-profile', 'gui-profile', 'gui-flame-status'),
                      ('remote', 'remote-stops', 'remote-panes', 'gui-shared-jobs-agent'), ('module-symbols', 'debug-discovery', 'gui-symbol-discovery'),
                      ('breakpoint-policy', 'run-control', 'gui-breakpoints', 'gui-restart', 'gui-debug'), ('hidden-window', 'wayland-read-race')):
            self.assertTrue(set(names) <= batch.keys(), sorted(set(names) - batch.keys()))
        # periodic --headless stays the portable lane; the runtime flags that all takes are accepted by both.
        self.assertFalse({step.name for step in moved} & {step.name for step in gate.plan('periodic', headless=True)})
        every = ['--perl', 'P', '--padwalker', 'W', '--python', 'Y', '--emacs', 'E', '--ruby', 'R', '--node', 'N', '--node-refusal', 'NR', '--go', 'G', '--lua', 'l', 's', 'b']
        for tier in ('periodic', 'periodic-gui'):
            self.assertIsNotNone(self.listed(tier, *every), tier)
        # affected reaches a moved step through the test script it runs, and only that way.
        steps = [*batch.values(), *moved]
        picked = lambda *changed: [step.name for step in gate.affected(steps, changed, [])[0]]
        self.assertEqual(picked('tests/memdefrag-gui.py'), ['headless-app', 'build-tests', 'release-runner', 'gui-memdefrag-smoke', 'gui-memdefrag'])
        self.assertEqual(picked('tests/m2-limits.py'), ['headless-app', 'build-tests', 'release-runner', 'm2-limits'])
        self.assertEqual(picked('tests/client.py'), list(batch))
        self.assertFalse({step.name for step in moved} & set(picked('src/memdefrag/map.zig', 'src/language/lua_layout.c', 'src/profile/flame.zig')))

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
        self.assertFalse({'gui-fdgraph', 'lua-gui', 'lua-named-gui-0', 'm2-archive', 'vulkan-faults'} & set(names))
        self.assertIn('src/mcp/memory.zig: ', lines[0])
        self.assertNotIn('not mapped', lines[0])
        for changed, required, absent in (
                ('src/language/lua_layout.c', ('lua-component-0', 'lua-watches-0-1', 'lua-named-gui-0', 'python-lua-named-0', 'gui-language-tabs'), 'ruby-gui'),
                ('src/language/go_map.c', ('go-maps-component', 'go-maps', 'go-native-values-1-1', 'go-gui'), 'lua-gui'),
                ('src/ui/overview/treemap_panel.zig', ('gui-overview', 'gui-fdgraph', 'gui-win95', 'gui-memdefrag-smoke', 'sysstat-sensors'), 'mcp'),
                ('src/runtime/fdflow.c', ('fdactivity', 'gui-fdflow-denied', 'gui-fdgraph'), 'gui-overview'),
                ('src/debug/source_paths.c', ('source-paths-build', 'source-paths', 'debug-discovery', 'gui-inline'), 'lua-named-gui-0'),
                ('src/binary/object.c', ('mapping-identity', 'apk-symbols', 'gui-symbol-discovery'), 'gui-fdgraph'),
                ('src/frames/model.zig', ('frame-host', 'frame-jvm', 'frame-archive'), 'gui-fdgraph'),
                ('src/profile/flame.zig', ('m2-profile', 'm2-archive', 'gui-profile', 'gui-flame-status'), 'lua-named-gui-0'),
                ('tests/perl-gui.py', ('perl-gui-fixtures', 'perl-gui'), 'perl-named-gui'),
                ('tests/memory-search-speed.py', ('memory-search-speed', 'memory-search-speed-agent'), 'mcp'),
                ('docs/GUIDE.md', ('package-source',), 'mcp'),
                ('src/model/session.zig', ('go-language', 'go-language-agent', 'run-control', 'gui-run-control'), 'mcp')):
            names, lines = chosen(changed)
            self.assertTrue(set(required) <= set(names), (changed, sorted(set(required) - set(names))))
            self.assertNotIn(absent, names, changed)
            self.assertNotIn('not mapped', lines[0])
            self.assertEqual(names, [step.name for step in steps if step.name in names])  # plan order
        # No step covers these: the whole gui tier runs, beside what is mapped.
        for unmapped in ('src/ui/workspace.zig', 'build.zig', 'brand-new-file'):
            names, lines = chosen(unmapped, 'src/mcp/memory.zig')
            self.assertIn('not mapped, so the full gui tier', lines[0])
            self.assertTrue(set(fallback) <= set(names), unmapped)
            self.assertIn('memory-registers', names)
        # A helper may be loaded by any step of either lane: tests/client.py is, by most live steps.
        for helper in ('tests/client.py', 'tests/helpers/readonly.py', 'tests/helpers/display.py', 'tests/check.h', 'scripts/build'):
            names, lines = chosen(helper)
            self.assertIn('not mapped, so every planned step', lines[0])
            self.assertEqual(names, [step.name for step in steps], helper)
        names, lines = chosen('tests/helpers/listen.py')
        self.assertEqual(names, ['headless-app', 'build-tests', 'release-runner', 'remote-startup', 'log-levels',
                                 'private-network-evidence', 'live-network-evidence', 'remote', 'gui-themes'])
        self.assertIn('tests/helpers/listen.py: 6 steps', lines[0])
        self.assertNotIn('not mapped', lines[0])
        # The runner's own file selects the steps whose registration changed, or else the gui tier.
        names, lines = chosen('scripts/release-check')
        self.assertIn('no registration changed, so the full gui tier', lines[0])
        self.assertTrue(set(fallback) <= set(names))
        picked, lines = gate.affected(steps, ['scripts/release-check'], fallback, ['m2-flow', 'gui-capture-setup'])
        self.assertEqual([step.name for step in picked], ['headless-app', 'build-tests', 'release-runner', 'm2-flow', 'gui-capture-setup'])
        self.assertTrue(set(gate.registered_since('HEAD', ())) <= {step.name for step in gate.plan('all')})
        self.assertEqual(gate.registered_since('no-such-revision', ()), [])
        # A mapped file whose steps need a runtime that was not passed is not silently skipped.
        bare = gate.plan('all')
        picked, lines = gate.affected(bare, ['src/language/ruby.c'], fallback)
        self.assertIn('gui-language-tabs', [step.name for step in picked])
        picked, lines = gate.affected(bare, ['src/mcp/observation.zig'], fallback)
        self.assertIn('inspections', [step.name for step in picked])

    def test_affected_follows_the_import_graph(self):
        # A synthetic graph over real paths: leaf.zig <- mid.zig <- covered.zig;
        # orphan.zig <- uncovered root; hubbed.zig <- the session hub.
        Step = gate.Step
        steps = [Step('release-runner', ['x'], 1), Step('deps', ['x'], 1, paths=['src/*']),
                 Step('cov', ['x'], 1, paths=['src/covered.zig']), Step('leafstep', ['x'], 1, paths=['src/leaf.zig']),
                 Step('hubstep', ['x'], 1, paths=['src/model/session.zig']), Step('gui-a', ['x'], 1), Step('gui-b', ['x'], 1)]
        fallback = ['gui-a', 'gui-b']
        graph = {'src/leaf.zig': {'src/mid.zig'}, 'src/mid.zig': {'src/covered.zig'}, 'src/covered.zig': {'src/main.zig'},
                 'src/orphan.zig': {'src/root.zig'}, 'src/hubbed.zig': {'src/model/session.zig'},
                 'src/model/session.zig': {'src/main.zig'}, 'src/both.zig': {'src/covered.zig', 'src/root.zig'},
                 'src/cyc.zig': {'src/cyc_a.zig'}, 'src/cyc_a.zig': {'src/cyc_b.zig', 'src/covered.zig'}, 'src/cyc_b.zig': {'src/cyc_a.zig'}}
        pick = lambda path: [step.name for step in gate.affected(steps, [path], fallback, (), graph)[0]]
        # A mapped file also runs the steps of its nearest covered importer.
        self.assertEqual(set(pick('src/leaf.zig')), {'release-runner', 'deps', 'leafstep', 'cov'})
        # An unmapped file whose every import path reaches covered files runs those steps only.
        # It keeps the ALWAYS steps (deps) that COVERS gave it.
        self.assertEqual(set(pick('src/mid.zig')), {'release-runner', 'deps', 'cov'})
        # An import cycle whose only way in is a covered file is walked once and narrows.
        self.assertEqual(set(pick('src/cyc.zig')), {'release-runner', 'deps', 'cov'})
        # An import path that ends at an uncovered root keeps the full fallback.
        self.assertTrue(set(fallback) <= set(pick('src/orphan.zig')))
        self.assertTrue(set(fallback) <= set(pick('src/both.zig')))
        # The walk stops at a hub: the hub's steps are not enough to stand for every use.
        self.assertTrue(set(fallback) <= set(pick('src/hubbed.zig')))
        # Without a graph, behaviour is exactly the COVERS mapping.
        self.assertEqual(set(step.name for step in gate.affected(steps, ['src/leaf.zig'], fallback)[0]), {'release-runner', 'deps', 'leafstep'})
        # The real graph is available and knows the session hub's importers.
        real = gate.importers_from_deps()
        self.assertIsNotNone(real)
        self.assertGreater(len(real.get('src/model/session.zig', ())), 50)
        self.assertIn('src/model/session.zig', gate.hubs())

    def test_agent_lane_uses_one_switch_and_keeps_the_property(self):
        import client
        keys = ('XODB_TEST_RUNTIME_AGENT', 'XODB_RUNTIME_AGENT')
        saved = {key: os.environ.pop(key, None) for key in keys}
        try:
            # No switch: a launch and an attach stay in-process.
            self.assertEqual(client.with_runtime_agent(['--break', 'ready'], './fixture'), ['--break', 'ready'])
            self.assertEqual(client.with_runtime_agent([], None), [])
            os.environ['XODB_TEST_RUNTIME_AGENT'] = './zig-out/bin/xodb-agent'
            # The lane switch applies to a launch and to an attach.
            self.assertEqual(client.with_runtime_agent([], None), ['--runtime-agent', './zig-out/bin/xodb-agent'])
            self.assertEqual(client.with_runtime_agent(['--break', 'ready'], './fixture')[:2], ['--runtime-agent', './zig-out/bin/xodb-agent'])
            # A core, a capture and a protocol the caller named are not redirected.
            for held in (['--core', 'dump'], ['--open-capture', 'cap'], ['--gdb-remote', 'host:9'], ['--runtime-agent', 'other']):
                self.assertEqual(client.with_runtime_agent(held, './fixture'), held)
            # An argv that already names the agent is not doubled.
            self.assertEqual(client.with_runtime_agent(['--runtime-agent', './zig-out/bin/xodb-agent', '--break', 'ready'], None).count('--runtime-agent'), 1)
            # A launch that sets its own agent keeps that agent. An attach still follows the lane.
            os.environ['XODB_RUNTIME_AGENT'] = 'proxy-agent'
            self.assertEqual(client.with_runtime_agent(['--break', 'ready'], './fixture')[:2], ['--runtime-agent', 'proxy-agent'])
            self.assertEqual(client.with_runtime_agent([], None)[:2], ['--runtime-agent', './zig-out/bin/xodb-agent'])
            # Overview and a saved packet capture reject the agent. Planted injection would add it.
            self.assertEqual(client.with_runtime_agent(['--overview'], None), ['--overview'])
            self.assertEqual(client.with_runtime_agent(['--open-pcap', 'cap'], './fixture'), ['--open-pcap', 'cap'])
            self.assertEqual(client.with_runtime_agent(['--open-mitmproxy', 'flows'], None), ['--open-mitmproxy', 'flows'])
            self.assertEqual(client.with_runtime_agent(['--redot-debugger'], './engine'), ['--redot-debugger'])
            # The engine image cap is a product failure, not an omission.
            self.assertNotIn('gdscript-stack', gate.AGENT_INELIGIBLE)
            self.assertNotIn('gdscript-values', gate.AGENT_INELIGIBLE)
            os.environ.pop('XODB_RUNTIME_AGENT')
            # Planted bug: forgetting the switch leaves the attach in-process, and this property fails.
            planted = []
            self.assertNotEqual(client.with_runtime_agent([], None), planted)
            os.environ.pop('XODB_TEST_RUNTIME_AGENT')
            os.environ['XODB_RUNTIME_AGENT'] = './zig-out/bin/xodb-agent'
            # The older switch is launch-only. An attach does not gain an agent.
            self.assertEqual(client.with_runtime_agent([], None), [])
            self.assertEqual(client.with_runtime_agent([], './fixture'), ['--runtime-agent', './zig-out/bin/xodb-agent'])
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        replaced, notes = gate.apply_agent_lane(gate.plan('host'))
        names = [step.name for step in replaced]
        self.assertIn('run-control-agent-lane', names)
        self.assertNotIn('run-control', names)
        # Quoting the debugger path, or using it as a fixture filename, is not a launch.
        self.assertIn('release-runner', names)
        self.assertIn('demo-binary', names)
        self.assertNotIn('core-debugging', names)
        self.assertNotIn('runtime-host', names)
        self.assertNotIn('runtime-host-agent-lane', names)
        self.assertIn('lane switch cannot reach it', dict(notes)['runtime-host'])
        self.assertNotIn('system-capture', names)
        self.assertIn('system overview rejects', dict(notes)['system-capture'])
        self.assertIn('opens a packet capture', dict(notes)['private-network-evidence'])
        self.assertIn('core-debugging', [name for name, _ in notes])
        real_ghidra = next(step for step in gate.plan('host') if step.name == 'ghidra-sidecar-real')
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('GHIDRA_HOME', None)
            os.environ.pop('XODB_GHIDRA_HOME', None)
            self.assertEqual(gate.agent_fate(real_ghidra)[0], 'ineligible')
            with tempfile.TemporaryDirectory() as directory:
                support = Path(directory) / 'support'
                support.mkdir()
                (support / 'analyzeHeadless').touch()
                os.environ['GHIDRA_HOME'] = directory
                self.assertEqual(gate.agent_fate(real_ghidra)[0], 'eligible')
        redot_lane, redot_notes = gate.apply_agent_lane(gate.plan('host', redot='fixture-engine'))
        redot_names = [step.name for step in redot_lane]
        redot_why = dict(redot_notes)
        self.assertIn('gdscript-stack-agent-lane', redot_names)
        self.assertIn('gdscript-values-agent-lane', redot_names)
        self.assertNotIn('redot-protocol', redot_names)
        self.assertIn('Redot debugger', redot_why['redot-protocol'])
        self.assertIn('no target', redot_why['gdscript-demo'])
        self.assertIn(gate.AGENT_INELIGIBLE['core-debugging'], dict(notes)['core-debugging'])
        # These three are periodic steps. The host lane never schedules them.
        # Their agent forms are omitted from the periodic plan, with a reason.
        moved, moved_notes = gate.apply_agent_lane(gate.plan('host', moved=True))
        moved_names = [step.name for step in moved]
        moved_why = dict(moved_notes)
        self.assertNotIn('macos-names-matrix-agent-lane', moved_names)
        self.assertIn('a GDB remote replay stub', moved_why['macos-names-matrix'])
        self.assertNotIn('m2-sampled-agent-lane', moved_names)
        self.assertNotIn('m2-limits-agent-lane', moved_names)
        self.assertIn('does not read the lane switch', moved_why['m2-sampled'])
        self.assertIn('does not read the lane switch', moved_why['m2-limits'])
        for variant in ('chain', 'debug-frame', 'companions', 'mixed'):
            self.assertIn('module-unwind-' + variant + '-agent-lane', names)
        self.assertNotIn('module-unwind-eviction', gate.AGENT_INELIGIBLE)
        self.assertNotIn('memory-search-speed', names)
        self.assertIn('memory-search-speed-agent', names)
        self.assertNotIn('memory-search-speed-agent-lane', names)
        variant = next(step for step in replaced if step.name == 'run-control-agent-lane')
        self.assertEqual(variant.argv[:2], ['env', 'XODB_TEST_RUNTIME_AGENT=./zig-out/bin/xodb-agent'])
        # `all` stays one copy. The periodic tier carries the host variants.
        self.assertFalse(any(step.name.endswith(gate.AGENT_LANE_SUFFIX) for step in gate.plan('all')))
        periodic = gate.plan('periodic')
        periodic_names = [step.name for step in periodic]
        self.assertEqual(len(periodic_names), len(set(periodic_names)))
        self.assertIn('run-control-agent-lane', periodic_names)
        self.assertNotIn('core-debugging-agent-lane', periodic_names)
        self.assertNotIn('runtime-host-agent-lane', periodic_names)
        self.assertNotIn('macos-names-matrix-agent-lane', periodic_names)
        self.assertNotIn('m2-sampled-agent-lane', periodic_names)
        self.assertNotIn('m2-limits-agent-lane', periodic_names)
        self.assertIn('module-unwind-eviction-agent-lane', periodic_names)
        self.assertNotIn('memory-search-speed-agent-lane', periodic_names)
        self.assertNotIn('run-control-agent-lane', {step.name for step in gate.plan('periodic', headless=True)})
        present = set(periodic_names)
        for step in periodic:
            if step.name.endswith(gate.AGENT_LANE_SUFFIX):
                for need in step.needs:
                    self.assertIn(need, present, step.name)
        # The GUI owner matrix already names the agent, so the lane keeps it.
        owners = [step for step in gate.plan('periodic-gui') if step.name.startswith('gui-owner-')]
        self.assertTrue(owners)
        kept, owner_notes = gate.apply_agent_lane(owners)
        self.assertEqual([step.name for step in kept], [step.name for step in owners])
        self.assertEqual(owner_notes, [])

    def test_host_census_has_no_fictitious_agent_twin(self):
        host = gate.plan('host')
        census = next(step for step in host if step.name == 'kernel-census')
        fate, reason = gate.agent_fate(census)
        self.assertEqual(fate, 'ineligible')
        self.assertIn('host procfs', reason)
        lane, notes = gate.apply_agent_lane([census])
        self.assertEqual(lane, [])
        self.assertEqual(dict(notes)['kernel-census'], reason)
        self.assertNotIn('kernel-census-agent-lane', {step.name for step in gate.plan('periodic')})
        self.assertIn('kernel-census', {step.name for step in host})

    def test_agent_lane_step_fails_when_the_agent_never_starts(self):
        # The switch points at a wrapper that records a start, then executes the
        # agent. A lane step that exits 0 without that record is not coverage.
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            cwd = Path(directory)
            logs = cwd / 'logs'
            logs.mkdir()
            agent = cwd / 'zig-out' / 'bin' / 'xodb-agent'
            agent.parent.mkdir(parents=True)
            # The real agent records its arguments: the wrapper must execute it.
            agent.write_text('#!/bin/sh\nprintf %s "$*" > "$0.ran"\n')
            agent.chmod(0o755)
            switch = ['env', 'XODB_TEST_RUNTIME_AGENT=./zig-out/bin/xodb-agent']
            started = gate.run_step('probe-agent-lane', switch + ['sh', '-c', 'exec "$XODB_TEST_RUNTIME_AGENT" one two'],
                                    30, cwd, os.environ.copy(), logs)
            self.assertEqual(started['status'], 'passed')
            self.assertIs(started['agent_started'], True)
            self.assertEqual((agent.parent / 'xodb-agent.ran').read_text(), 'one two')
            skipped = gate.run_step('skip-agent-lane', switch + ['sh', '-c', 'exit 0'],
                                    30, cwd, os.environ.copy(), logs)
            self.assertEqual(skipped['status'], 'agent_not_started')
            self.assertIs(skipped['agent_started'], False)
            plain = gate.run_step('plain', ['sh', '-c', 'exit 0'], 30, cwd, os.environ.copy(), logs)
            self.assertEqual(plain['status'], 'passed')
            self.assertNotIn('agent_started', plain)

    def test_direct_launchers_have_a_reason_class_and_the_routable_ones_join_the_lane(self):
        saved = {key: os.environ.pop(key, None) for key in ('XODB_TEST_RUNTIME_AGENT', 'XODB_RUNTIME_AGENT')}
        try:
            import client
            self.assertEqual(client.runtime_agent_args(), [])
            os.environ['XODB_TEST_RUNTIME_AGENT'] = './zig-out/bin/xodb-agent'
            self.assertEqual(client.runtime_agent_args()[0], '--runtime-agent')
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        steps = gate.plan('host', perl='perl', padwalker='pad', python='python', ruby='ruby',
                          node='node', go='go', emacs='emacs', redot='engine',
                          lua=[('lua', 'src', 'lib')])
        replaced, notes = gate.apply_agent_lane(steps)
        names = {step.name for step in replaced}
        why = dict(notes)
        for name in ('mcp', 'stale-interrupt', 'local-large-symbols', 'fdactivity'):
            self.assertIn(name + '-agent-lane', names)
            self.assertNotIn(name, why)
        classes = ('is the subject', 'agent twin', 'no target')
        omitted = (
            'agent-startup', 'remote-startup', 'remote-broken-exit', 'remote-unknown',
            'shared-sessions', 'shared-processes', 'shared-cleanup', 'log-levels',
            'metadata-session', 'language-tabs', 'javascript-cache', 'python-named-shared-0',
            'perl-named-shared-0', 'lua-named-shared-0', 'remote-queued-drop', 'remote-stops',
            'sysstat-headless', 'system-capture-flow', 'ghidra-static-images', 'apk-symbols',
            'gdscript-demo', 'gdscript-demo-values', 'memdefrag-tui', 'observation-experiments',
        )
        for name in omitted:
            self.assertTrue(any(phrase in why[name] for phrase in classes), (name, why.get(name)))
            self.assertNotIn(name + '-agent-lane', names)
        self.assertIn('is the subject', why['agent-startup'])
        self.assertIn('agent twin', why['shared-sessions'])
        self.assertIn('no target', why['memdefrag-tui'])
        self.assertIn('no target', why['observation-experiments'])
        self.assertNotIn('perl-path-component-agent-lane', names)
        self.assertIn('in-process', why['perl-path-component'])
        self.assertIn('perl-path-watches-0-agent-lane', names)

    def test_a_plain_step_whose_script_names_a_launch_flag_fails_classification(self):
        # A file that names the flags but does not start the debugger must not
        # stay plain. tests/release-runner.py quotes the gate flag and stays plain.
        plant = root / 'tests' / '_plain_flag_plant.py'
        gate._CLIENT_CACHE = None
        try:
            step = gate.Step('planted-plain', ['python3', '-B', 'tests/_plain_flag_plant.py'], 30)
            # Each flag alone is enough.
            for flag in ('--headless', '--listen'):
                plant.write_text('value = "%s"\n' % flag)
                gate._CLIENT_CACHE = None
                fate, reason = gate.agent_fate(step)
                self.assertEqual(fate, 'invalid', flag)
                self.assertEqual(reason, 'a plain step whose script contains --headless or --listen')
                with self.assertRaises(ValueError):
                    gate.apply_agent_lane([step])
            runner = next(item for item in gate.plan('host') if item.name == 'release-runner')
            self.assertEqual(gate.agent_fate(runner), ('plain', ''))
        finally:
            plant.unlink(missing_ok=True)
            gate._CLIENT_CACHE = None

    def test_native_mac_paths_have_focused_coverage(self):
        steps = gate.plan('all', macos='fixture-mac')
        for path in ('build_macos.zig', 'src/macos_main.zig', 'scripts/macos-bundle.py', 'tests/cocoa-native.m'):
            selected, why = gate.affected(steps, [path], ['gui-overview'])
            names = {step.name for step in selected}
            self.assertTrue({'platform-cocoa', 'platform-cocoa-tests', 'release-runner', 'macos-native'} <= names)
            self.assertNotIn('gui-overview', names)
            self.assertFalse(any('not mapped' in line for line in why))
        periodic = {step.name for step in gate.plan('periodic', macos='fixture-mac')}
        self.assertIn('macos-native-stress', periodic)
        self.assertNotIn('macos-native-stress', {step.name for step in steps})
        self.assertIn('macos-bootstrap', {step.name for step in steps})
        self.assertNotIn('macos-bootstrap', {step.name for step in gate.plan('all')})
        self.assertIn('macos-local', {step.name for step in steps})
        self.assertNotIn('macos-local', {step.name for step in gate.plan('all')})
        for path in ('src/model/macos_session.zig', 'tests/macos-local.py', 'tests/fixtures/macos-local.c'):
            picked, _ = gate.affected(steps, [path], ['gui-overview'])
            self.assertIn('macos-local', {step.name for step in picked})
        picked, _ = gate.affected(steps, ['src/runtime/macos_debugserver.c'], ['gui-overview'])
        self.assertIn('macos-bootstrap', {step.name for step in picked})
        self.assertNotIn('gui-overview', {step.name for step in picked})

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
        self.assertEqual(report['summary'], dict(planned=9, passed=9, skipped=0, flaky=0, failed=0, not_run=0))
        self.assertEqual([step['name'] for step in report['steps'] if step.get('beside')], [name for name in names if name.startswith('gui-')])

    def test_jobs_keep_failures_retries_and_leaks_exact(self):
        bad = 'open("bad","w").close(); raise SystemExit(4)'
        slow = 'import os,time\nwhile not os.path.exists("bad"): time.sleep(.01)\ntime.sleep(.3)'
        # A failed step stops new work; steps already running finish and are reported.
        code, report = self.sequence([('gui-bad', bad), ('gui-slow', slow), ('gui-next', 'pass'), ('gui-later', 'pass'), ('last', 'pass')], jobs=2)
        self.assertEqual(code, 1)
        self.assertEqual([(step['name'], step['status']) for step in report['steps']], [('gui-bad', 'failed'), ('gui-slow', 'passed')])
        self.assertEqual(report['summary'], dict(planned=5, passed=1, skipped=0, flaky=0, failed=1, not_run=3))
        # With keep_going everything else runs, except what needed the failed step.
        code, report = self.sequence([('gui-bad', bad), ('gui-slow', slow), ('gui-needs-bad', 'pass'), ('gui-then', 'pass'), ('last', 'pass')],
                                     keep_going=True, jobs=2, fields={'gui-needs-bad': dict(needs=['gui-bad']), 'gui-then': dict(needs=['gui-needs-bad'])})
        self.assertEqual([(step['name'], step['status']) for step in report['steps']], [('gui-bad', 'failed'), ('gui-slow', 'passed'), ('last', 'passed')])
        self.assertEqual(report['summary'], dict(planned=5, passed=2, skipped=0, flaky=0, failed=1, not_run=2))
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
            steps = {name: argv for name, argv, _ in lane(tier, python='/fixture/python')}
            self.assertTrue({'python-path-component', 'python-path-watches-0', 'python-path-watches-1'} <= steps.keys())
            self.assertIn('--sanitize', steps['python-path-component'])
            self.assertNotIn('--agent', steps['python-path-watches-0'])
            self.assertIn('--agent', steps['python-path-watches-1'])
        for tier in ('gui', 'all'):
            steps = {name: argv for name, argv, _ in lane(tier, python='/fixture/python')}
            self.assertIn('--paths', steps['python-path-watch-gui'])

    def test_ruby_watch_coverage(self):
        for tier in ('host', 'all'):
            names={name for name,_,_ in lane(tier,ruby='/fixture/ruby')}
            self.assertTrue({'ruby-watch-component','ruby-watches','ruby-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in lane(tier,ruby='/fixture/ruby')}
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
            names={name for name,_,_ in lane(tier,node='/fixture/node')}
            self.assertTrue({'javascript-watches','javascript-watches-agent'} <= names)
        for tier in ('gui', 'all'):
            names={name for name,_,_ in lane(tier,node='/fixture/node')}
            self.assertIn('javascript-watches-gui',names)

    def test_node_refusal_is_separate_from_positive_watch_coverage(self):
        for tier in ('gui', 'all'):
            steps={name:(argv,seconds) for name,argv,seconds in lane(tier,node='/fixture/supported-node',node_refusal='/fixture/unproved-node')}
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
        self.assertTrue({'build-tests', 'release-runner', 'package-source', 'mapping-identity', 'syscall-tables'} <= portable)
        self.assertFalse(portable & {'remote', 'mcp', 'shared-sessions', 'gui-overview', 'vulkan-faults', 'observations-live'})
        names = [s[0] for s in gate.plan('all')]
        for required in ('remote', 'm2-archive', 'hidden-window', 'wayland-read-race', 'vulkan-faults'):
            self.assertIn(required, names)
        self.assertNotIn('observations-live', names)
        observed = [s[0] for s in gate.plan('host', uprobes=True)]
        for required in ('inspections-agent', 'inspection-lifecycle-agent', 'observations-live', 'observation-recipes-agent', 'observation-associations'):
            self.assertIn(required, observed)

    def test_preferences_cover_both_live_backends(self):
        for tier in ('host', 'all'):
            commands = {name: cmd for name, cmd, _ in lane(tier)}
            self.assertEqual(commands['m2-preferences'][-1], 'tests/m2-preferences.py')
            self.assertEqual(commands['m2-preferences-agent'][:2],
                             ['env', 'XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent'])
            self.assertEqual(commands['m2-preferences-agent'][-1], 'tests/m2-preferences.py')
        for tier in ('portable', 'gui', 'perf'):
            self.assertFalse({'m2-preferences', 'm2-preferences-agent'} &
                             {name for name, _, _ in lane(tier)})

    def test_syscall_measurements_keep_the_correctness_lane(self):
        perf = {name: cmd for name, cmd, _ in gate.plan('perf')}
        self.assertEqual(perf['syscall-measurements'], [sys.executable, '-B',
            'tests/syscall-timing.py', '--perf', '--work', '.work/perf-syscalls'])
        for tier in ('host', 'all'):
            regular = {name: cmd for name, cmd, _ in lane(tier)}
            self.assertEqual(regular['syscall-timing'], [sys.executable, '-B', 'tests/syscall-timing.py'])
        for tier in ('portable', 'host', 'gui', 'all', 'periodic', 'periodic-gui'):
            self.assertNotIn('syscall-measurements', {name for name, _, _ in lane(tier)})

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
            'frame-vkQueuePresentKHR-lost', 'repeat-init-fails-late', 'resize-real-output',
            # The early Vulkan setup path (SR03-F2): its failures must reach recovery.
            'partial-vkCreateInstance', 'partial-vkCreateImage', 'start-memory-no-device-local'})
        for delay in (25, 50, 100):
            name = f'symbol-discovery-latency-{delay}'
            self.assertNotIn(name, regular)
            self.assertEqual(periodic[name], [sys.executable, '-B',
                'tests/symbol-discovery-install.py', '--reply-delay-ms', str(delay),
                '--read-delay-ms', '0', '--rate', '10000000000', '--timeout', '70',
                '--cases', 'complete', 'interrupt'])
        self.assertTrue({'m2-archive', 'hidden-window', 'wayland-read-race', 'gui-symbol-discovery'} <= regular.keys())
        self.assertTrue({'acquire-timeout', 'fence-timeout', 'gui-overview-live'} <= periodic.keys())
        self.assertTrue({'symbol-discovery', 'symbol-discovery-install', 'm2-limits'} <= {name for name, _, _ in gate.plan('periodic')})
        headless = {name for name, _, _ in gate.plan('periodic', headless=True)}
        self.assertTrue({'source-paths-differential', 'symbol-discovery-latency-25',
            'symbol-discovery-latency-50', 'symbol-discovery-latency-100'} <= headless)
        self.assertFalse(headless & {'vulkan-faults', 'gui-overview', 'gui-clipboard'})



if __name__ == '__main__':
    unittest.main()
