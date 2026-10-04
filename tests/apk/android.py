#!/usr/bin/env python3
"""One explicitly reviewed owned Bionic test over ADB stdio. No APK installation.
Requires review of docs/ANDROID_APK_TEST_PLAN.md and --execute-reviewed-plan.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import runpy
import shlex
import subprocess
ROOT = Path(__file__).resolve().parents[2]
NAMES = ('xodb', 'loader', 'libraries.apk', 'left.debug', 'right.debug', 'tick.c')
Rpc = runpy.run_path(str(ROOT / 'tests/android-app/check.py'))['Rpc']

class DeviceSession:
    def __init__(self, bundle):
        self.bundle = Path(bundle).resolve()
        self.manifest = json.loads((self.bundle / 'manifest.json').read_text())
        if self.manifest['kind'] != 'xodb-bionic-apk-test-v1' or set(self.manifest['files']) != set(NAMES):
            raise ValueError('Unexpected bundle manifest')
        for name in NAMES:
            data = (self.bundle / name).read_bytes()
            expected = self.manifest['files'][name]
            if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                raise ValueError('Bundle changed: ' + name)
        self.run = ROOT / '.work' / ('bionic-apk-check-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
        self.run.mkdir(parents=True)
        self.serial = self.directory = self.server = self.target_pid = None
        self.closed = self.clean = False
        self.operations = []
        self.log = self.run / 'server.log'

    def adb(self, *argv, timeout=20):
        selector = ['-s', self.serial] if self.serial else ['-d']
        result = subprocess.run(['adb', *selector, *argv], capture_output=True, text=True, timeout=timeout)
        self.operations.append(dict(argv=argv, code=result.returncode,
                                    stdout='<pinned device>' if argv == ('get-serialno',) else result.stdout,
                                    stderr=result.stderr))
        result.check_returncode()
        return result.stdout.strip()

    def start(self):
        self.serial = self.adb('get-serialno')
        if (self.adb('shell', 'id', '-u') != '2000' or
            self.adb('shell', 'getprop', 'ro.product.model') != 'Pixel 8 Pro' or
            self.adb('shell', 'getprop', 'ro.product.cpu.abi') != 'arm64-v8a'):
            raise RuntimeError('Expected the reviewed Pixel 8 Pro with ordinary ADB shell')
        candidate = self.adb('shell', 'mktemp', '-d', '/data/local/tmp/xodb-apk.XXXXXX')
        if not re.fullmatch(r'/data/local/tmp/xodb-apk\.[A-Za-z0-9]{6}', candidate):
            raise RuntimeError('Unexpected mktemp result: ' + repr(candidate))
        self.directory = candidate
        for name in NAMES:
            self.adb('push', str(self.bundle / name), self.directory + '/' + name)
            digest = self.adb('shell', 'sha256sum', self.directory + '/' + name).split()[0]
            if digest != self.manifest['files'][name]['sha256']:
                raise RuntimeError('Upload identity mismatch: ' + name)
        self.adb('shell', 'chmod', '700', self.directory + '/xodb', self.directory + '/loader')
        service = ['./xodb', '--headless', '--mcp', '--agent-scope', 'control', '--source', './tick.c',
                   '--debug-file', './left.debug', '--debug-file', './right.debug', '--break', 'fixture_ready',
                   '--', './loader', self.directory + '/libraries.apk']
        wrapper = shlex.join(service) + '; result=$?; echo XODB_APK_REAPED=$result >&2; exit "$result"'
        command = 'cd ' + shlex.quote(self.directory) + ' && exec ' + shlex.join([
            '/system/bin/timeout', '-s', 'TERM', '-k', '5', '90', '/system/bin/sh', '-c', wrapper])
        self.operations.append(dict(server_shell=command))
        with self.log.open('xb') as log:
            self.server = subprocess.Popen(['adb', '-s', self.serial, 'shell', '-T', command],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        return self

    def close(self):
        if self.closed: return
        self.closed = True
        errors = []
        if self.server:
            try: self.server.stdin.close()
            except BrokenPipeError: pass
            try:
                code = self.server.wait(timeout=15)
                if code != 0 or 'XODB_APK_REAPED=0' not in self.log.read_text():
                    errors.append('Normal service exit was not confirmed')
            except subprocess.TimeoutExpired:
                # Stop only our host adb client; the remote 90s deadline remains.
                self.server.terminate()
                try: self.server.wait(timeout=3)
                except subprocess.TimeoutExpired: self.server.kill(); self.server.wait(timeout=3)
                errors.append('Service cleanup unconfirmed; remote deadline remains in force')
            self.server.stdout.close()
        if self.target_pid and not errors:
            try:
                # Read-only check; never signal a PID from the remote snapshot.
                self.adb('shell', 'test', '!', '-e', '/proc/' + str(self.target_pid))
            except Exception as exc: errors.append('Owned target exit unconfirmed: ' + str(exc))
        if self.directory and not errors:
            try:
                for name in NAMES: self.adb('shell', 'rm', '-f', self.directory + '/' + name)
                self.adb('shell', 'rmdir', self.directory)
            except Exception as exc: errors.append('Exact file cleanup failed: ' + str(exc))
        self.clean = not errors
        (self.run / 'lifecycle.json').write_text(json.dumps(dict(clean=self.clean, directory=self.directory,
            target_pid=self.target_pid, errors=errors, operations=self.operations), indent=2) + '\n')
        if errors: raise RuntimeError('; '.join(errors) + '; retained directory: ' + str(self.directory))


def exercise(rpc, source, ready=None):
    initial = rpc.tool('get_debug_view')
    assert initial['state'] == 'stopped' and initial['owned']
    rpc.action('continue'); tid = rpc.stopped('breakpoint')
    view = rpc.tool('get_debug_view', tid=tid)
    assert view['frames'][0]['symbol'] == 'fixture_ready', view['frames']
    if ready: ready(initial['pid'])
    rpc.clear_breakpoints()
    symbols = [rpc.tool('find_symbol', name='apk_' + name + '_tick') for name in ('left', 'right')]
    assert symbols[0]['module_id'] != symbols[1]['module_id'], symbols
    line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if 'APK_STORE' in text)
    probes = rpc.action('set_breakpoint', file='tick.c', line=line)['ids']
    assert len(probes) == 2, probes
    stops = []
    for name, before, amount in [('left', 7, 5), ('right', 100, 3)]:
        rpc.action('continue'); tid = rpc.stopped('breakpoint')
        view = rpc.tool('get_debug_view', tid=tid)
        assert view['frames'][0]['symbol'] == 'apk_' + name + '_tick', view['frames']
        assert view['frames'][0]['source']['line'] == line and view['instructions'] and view['registers']
        assert any(f['symbol'] == 'main' for f in view['frames'][1:]), view['frames']
        local = {v['name']: v for v in view['locals']}
        assert {key: int(local[key]['display']) for key in ('value', 'before', 'next', 'amount')} == dict(value=before, before=before, next=before+amount, amount=amount), local
        assert rpc.tool('evaluate_expression', tid=tid, expression='value')['value']['display'] == str(before)
        stops.append(view)
    watch = rpc.action('set_watchpoint', address=hex(local['value']['address']), length=4, kind='write')['id']
    rpc.clear_breakpoints()
    hits = []
    for before in (100, 103):
        rpc.action('continue'); tid = rpc.stopped('watchpoint')
        view = rpc.tool('get_debug_view', tid=tid)
        hit = view['watch_hits'][0]
        assert (hit['before'], hit['after']) == (before, before + 3), hit
        assert hit['phase'] == ('completed' if view['architecture'] == 'aarch64' else 'after_access'), hit
        hits.append(hit)
    rpc.action('remove_watchpoint', id=watch)
    previous = view['frames'][0]['source']['line']
    rpc.action('step_source', tid=tid); rpc.stopped()
    assert rpc.tool('get_debug_view', tid=tid)['frames'][0]['source']['line'] != previous
    return dict(architecture=view['architecture'], symbols=symbols, stops=stops, hits=hits, pid=initial['pid'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--execute-reviewed-plan', action='store_true')
    args = parser.parse_args()
    if not args.execute_reviewed_plan:
        parser.error('Review docs/ANDROID_APK_TEST_PLAN.md before authorizing device writes')
    session = DeviceSession(args.bundle)
    rpc = None
    try:
        session.start()
        print(session.run, flush=True)
        rpc = Rpc(lambda b: (session.server.stdin.write(b), session.server.stdin.flush()), session.server.stdout)
        session.target_pid = rpc.tool('get_session')['pid']
        def mapped(pid):
            maps = session.adb('shell', 'cat', '/proc/' + str(pid) + '/maps')
            assert any(session.directory + '/libraries.apk' in row and row.split()[1][2] == 'x' for row in maps.splitlines()), maps
            (session.run / 'fixture-maps.txt').write_text(maps)
        result = exercise(rpc, session.bundle / 'tick.c', mapped)
        assert result['architecture'] == 'aarch64'
        (session.run / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    finally:
        try:
            if rpc: (session.run / 'transcript.json').write_text(json.dumps(rpc.transcript, indent=2) + '\n')
        finally:
            session.close()
    print('PASS: real Bionic APK mappings, two companions, source/stack/locals/eval, two hardware writes, source step, owned cleanup')
if __name__ == '__main__': main()
