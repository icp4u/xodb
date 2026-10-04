#!/usr/bin/env python3
"""Host-only checks for Bionic test scope, teardown and its actual MCP exercise."""
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
module = runpy.run_path(str(ROOT / 'tests/apk/android.py'))
DeviceSession, NAMES = module['DeviceSession'], module['NAMES']
RUN = ROOT / '.work' / ('bionic-apk-host-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
RUN.mkdir(parents=True)
BUNDLE = RUN / 'fake-bundle'
BUNDLE.mkdir()
for name in NAMES: (BUNDLE / name).write_bytes(b'owned fixture')
(BUNDLE / 'manifest.json').write_text(json.dumps(dict(kind='xodb-bionic-apk-test-v1', files={
    name: dict(bytes=13, sha256=hashlib.sha256(b'owned fixture').hexdigest()) for name in NAMES})))

class Fake(DeviceSession):
    def __init__(self, mode='good'):
        super().__init__(BUNDLE)
        self.mode, self.calls = mode, []
    def adb(self, *args, **kwargs):
        self.calls.append(args)
        if args == ('get-serialno',): return 'fixture-device'
        if args == ('shell', 'id', '-u'): return '0' if self.mode == 'root' else '2000'
        if args == ('shell', 'getprop', 'ro.product.model'): return 'wrong device' if self.mode == 'model' else 'Pixel 8 Pro'
        if args == ('shell', 'getprop', 'ro.product.cpu.abi'): return 'wrong abi' if self.mode == 'abi' else 'arm64-v8a'
        if args[:2] == ('shell', 'mktemp'): return '/data/local/tmp/xodb-apk.ABC123'
        if args[0] == 'push': return ''
        if args[:2] == ('shell', 'sha256sum'): return ('0' * 64 if self.mode == 'hash' else self.manifest['files'][Path(args[2]).name]['sha256']) + '  file'
        if args[:2] in (('shell', 'chmod'), ('shell', 'rm'), ('shell', 'rmdir')): return ''
        if args[:2] == ('shell', 'test'):
            if self.mode == 'alive': raise RuntimeError('owned target remains')
            return ''
        raise AssertionError(args)

class Finished:
    def __init__(self): self.stdin, self.stdout = io.BytesIO(), io.BytesIO()
    def wait(self, timeout): return 0

class Checks(unittest.TestCase):
    def test_scope_and_upload_identity_refusals(self):
        for mode in ('root', 'model', 'abi', 'hash'):
            with self.subTest(mode=mode):
                device = Fake(mode)
                with patch.object(module['subprocess'], 'Popen') as spawn:
                    with self.assertRaises(RuntimeError): device.start()
                    spawn.assert_not_called()
                if mode != 'hash': self.assertFalse(any(args[0] == 'push' for args in device.calls))
                device.close()
                if mode == 'hash':
                    self.assertEqual([a[3] for a in device.calls if a[:2] == ('shell', 'rm')],
                                     [device.directory + '/' + name for name in NAMES])

    def test_exact_stdio_launch_and_cleanup(self):
        device = Fake()
        def spawn(argv, **kwargs):
            self.assertEqual(argv[:5], ['adb', '-s', 'fixture-device', 'shell', '-T'])
            command = argv[5]
            self.assertIn('timeout -s TERM -k 5 90', command)
            self.assertIn('--debug-file ./left.debug --debug-file ./right.debug', command)
            self.assertNotIn('--attach', command); self.assertNotIn('--listen', command)
            kwargs['stderr'].write(b'XODB_APK_REAPED=0\n'); kwargs['stderr'].flush()
            return Finished()
        with patch.object(module['subprocess'], 'Popen', side_effect=spawn): device.start()
        self.assertEqual(len([a for a in device.calls if a[0] == 'push']), len(NAMES))
        device.target_pid = 9876
        device.close()
        self.assertTrue(device.clean)
        self.assertEqual([a[3] for a in device.calls if a[:2] == ('shell', 'rm')],
                         [device.directory + '/' + name for name in NAMES])
        self.assertIn(('shell', 'test', '!', '-e', '/proc/9876'), device.calls)
        count = len(device.calls); device.close(); self.assertEqual(len(device.calls), count)

    def test_uncertain_service_or_target_retains_files(self):
        for mode in ('missing-marker', 'alive'):
            with self.subTest(mode=mode):
                device = Fake(mode)
                device.directory = '/data/local/tmp/xodb-apk.ABC123'
                device.server = Finished()
                device.target_pid = 9876
                device.log.write_text('XODB_APK_REAPED=0\n' if mode == 'alive' else '')
                with self.assertRaises(RuntimeError): device.close()
                self.assertFalse(device.clean)
                self.assertFalse(any(a[:2] in (('shell', 'rm'), ('shell', 'rmdir')) for a in device.calls))

    def test_real_host_companion_debugging_exercise(self):
        run = RUN / 'native'; run.mkdir()
        helpers = runpy.run_path(str(ROOT / 'tests/apk/check.py'))
        source = helpers['build'](run)
        subprocess.run(['gcc', '-g', '-gdwarf-4', '-O0', str(ROOT / 'tests/fixtures/apk/bionic-loader.c'), '-ldl', '-o', str(run / 'bionic-host')], check=True)
        argv = [str(ROOT / 'zig-out/bin/xodb'), '--headless', '--mcp', '--agent-scope', 'control', '--break', 'fixture_ready',
                '--source', str(source), '--debug-file', str(run / 'left.debug'), '--debug-file', str(run / 'right.debug'),
                '--', str(run / 'bionic-host'), str(run / 'left.stripped.so'), str(run / 'right.stripped.so')]
        rpc = None
        with (run / 'server.log').open('x') as log:
            process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, cwd=ROOT)
            try:
                rpc = module['Rpc'](lambda b: (process.stdin.write(b), process.stdin.flush()), process.stdout)
                result = module['exercise'](rpc, source)
                (run / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
            finally:
                if rpc: (run / 'transcript.json').write_text(json.dumps(rpc.transcript, indent=2) + '\n')
                process.stdin.close()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                process.stdout.close()
            self.assertEqual(process.returncode, 0)
            self.assertFalse(Path('/proc/' + str(result['pid'])).exists())

if __name__ == '__main__':
    print(RUN, flush=True)
    unittest.main(verbosity=2)
