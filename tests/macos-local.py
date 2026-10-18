#!/usr/bin/env python3
"""Opt-in real native debugger GUI oracle (offscreen, owned fixtures only)."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def verify(text, wrong=False, close_reason='compositor_close'):
    rows = re.findall(r'debugger state=stopped generation=(\d+) pc=([0-9a-f]+) registers=(\d+) instructions=(\d+) breakpoints=(\d+)', text)
    check(len(rows) == 2, 'did not render two stopped debugger publications')
    first, second = [[int(x, 16 if i == 1 else 10) for i, x in enumerate(row)] for row in rows]
    check(all(row[1] and row[2] > 0 and row[3] > 0 for row in (first, second)), 'stopped PC/registers/disassembly missing')
    check(second[0] > first[0], 'step did not publish a new generation')
    check((second[1] == first[1]) if wrong else (second[1] != first[1]), 'step PC oracle rejected result')
    check('clean shutdown (reason=' + close_reason + ')' in text, 'GUI did not follow normal close path')
    check('unconfirmed' not in text and 'connection ended' not in text, 'owner or detach failed')
    return dict(first=first, second=second)


def heartbeat(path):
    try:
        data = path.read_bytes()
        return struct.unpack('=Q', data)[0] if len(data) == 8 else 0
    except FileNotFoundError:
        return 0


def progress(path, process=None):
    start = heartbeat(path)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process is not None:
            check(process.poll() is None, 'fixture died before heartbeat progress')
        if heartbeat(path) > start:
            return
        time.sleep(.01)
    raise RuntimeError('fixture made no heartbeat progress after detach')


def read_until(process, marker, timeout=30):
    output = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        while marker not in output:
            left = deadline - time.monotonic()
            check(left > 0, 'native phase did not arrive: ' + output.decode(errors='replace'))
            if selector.select(left):
                chunk = os.read(process.stdout.fileno(), 8192)
                check(chunk, 'native GUI exited before requested phase')
                output.extend(chunk)
    return bytes(output)


def native(binary, modes):
    started = time.monotonic()
    check(sys.platform == 'darwin', 'local GUI lane requires Darwin')
    fixture = ROOT / '.work/macos-local-fixture'
    subprocess.run(['cc', '-O0', '-g', str(ROOT / 'tests/fixtures/macos-local.c'), '-o', str(fixture)], check=True, timeout=30)
    env = dict(os.environ, XODB_MAC_OFFSCREEN='1', MVK_CONFIG_LOG_LEVEL='1',
               XODB_TEST_SCRIPT=str(ROOT / 'tests/fixtures/macos-local.script'))
    report = {}
    failures = []
    for mode in modes:
        beat = ROOT / ('.work/macos-local-' + mode + '.heartbeat')
        if beat.exists():
            beat.unlink()
        target = None
        pid = 0
        output = ''
        if mode in ('attach', 'sigterm', 'cmdq', 'detach', 'open_error'):
            target = subprocess.Popen([str(fixture), str(beat)])
            pid = target.pid
        try:
            if target:
                progress(beat, target)
            args = ['--attach', str(pid), '--exe', str(fixture)] if target else ['--', str(fixture), str(beat)]
            if mode == 'symbol':
                args = ['--break', 'fixture_marker', *args]
            if mode == 'missing_symbol':
                args = ['--break', 'no_such_fixture_symbol', *args]
            script = (ROOT / 'tests/fixtures/macos-local.script').read_text()
            close_reason = 'compositor_close'
            if mode == 'cmdq':
                script = script.replace('0 close', '0 key 12 q q 8')
                close_reason = 'compositor_close' # AppKit menu requests normal native close.
            elif mode == 'detach':
                script = script.replace('0 close', '0 click 700 65\n0 detached\n0 state\n0 click 500 65\n0 state\n0 close')
            elif mode in ('sigterm', 'open_error'):
                script = '0 stopped\n0 state\n'
                close_reason = 'signal'
            if mode == 'open_error':
                args = ['--source', str(ROOT / '.work/missing-source-fixture'), *args]
            script_path = ROOT / ('.work/macos-local-' + mode + '.script')
            script_path.write_text(script)
            process = subprocess.Popen([binary, *args], env=dict(env, XODB_TEST_SCRIPT=str(script_path)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                prefix = b''
                if mode in ('sigterm', 'open_error'):
                    prefix = read_until(process, b'native owner ended: SourceUnavailable' if mode == 'open_error' else b'xodb: debugger state=stopped')
                    if mode == 'sigterm':
                        helper = re.search(rb'helper started pid=(\d+)', prefix)
                        check(helper is not None, 'private helper pid not reported')
                        os.kill(int(helper[1]), 0)
                        sockets = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', helper[1].decode(), '-iTCP', '-sTCP:LISTEN', '-Fn'], capture_output=True, timeout=10)
                        check(sockets.returncode in (0, 1) and not re.search(rb'^n', sockets.stdout, re.M), 'helper unexpectedly listens on TCP')
                        os.kill(int(helper[1]), 0)
                    process.terminate()
                output = (prefix + process.communicate(timeout=45)[0]).decode(errors='replace')
            except subprocess.TimeoutExpired:
                process.terminate()
                output = process.communicate(timeout=30)[0].decode(errors='replace')
                raise RuntimeError('native GUI script did not reach close: ' + output[-2000:])
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        remaining = process.communicate(timeout=30)[0]
                    except subprocess.TimeoutExpired:
                        process.kill() # Only the GUI started above, never debugserver.
                        remaining = process.communicate(timeout=5)[0]
                    output += remaining.decode(errors='replace')
                (ROOT / ('.work/macos-local-' + mode + '.log')).write_text(output)
            check(process.returncode == 0, 'native GUI failed: ' + output[-2000:])
            progress(beat, target) # Check target survival even if helper reaping failed.
            report[mode] = dict(detach_heartbeat='pass')
            if mode in ('sigterm', 'open_error'):
                check('clean shutdown (reason=signal)' in output and 'unconfirmed' not in output and 'native helper reaped' in output, 'signal/error cleanup did not reap normally')
                report[mode]['status'] = 'pass'
                continue
            report[mode].update(verify(output, close_reason=close_reason))
            if mode == 'symbol':
                check(report[mode]['first'][4] == 1 and report[mode]['second'][4] == 1, 'symbol breakpoint not retained')
            try:
                verify(output, wrong=True, close_reason=close_reason)
            except RuntimeError as error:
                check(str(error) == 'step PC oracle rejected result', 'planted result failed for unrelated reason')
            else:
                raise RuntimeError('oracle accepted planted unchanged PC')
            if mode == 'missing_symbol':
                check('SymbolNotFound; session retained' in output, 'missing symbol did not retain session')
            if mode == 'detach':
                detached = re.findall(r'debugger state=detached generation=(\d+) pc=0 registers=0 instructions=0 breakpoints=0', output)
                check(len(detached) == 2 and detached[0] == detached[1], 'detach state changed after refused action')
                after = output.split('native pid=0 state=detached', 1)
                check(len(after) == 2 and 'xodb: native pid=' not in after[1], 'owner published again after detach')
            report[mode]['status'] = 'pass'
        except Exception as error:
            report.setdefault(mode, {})['status'] = 'fail'
            report[mode]['error'] = str(error)
            failures.append(mode)
        finally:
            if not target:
                match = re.search(r'native pid=(\d+)', output)
                pid = int(match[1]) if match else 0
            if pid:
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
            if target:
                target.wait(timeout=5)
    report['negative_oracle'] = 'pass' if not failures else 'incomplete'
    report['seconds'] = time.monotonic() - started
    (ROOT / '.work/macos-local-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    check(not failures, 'native GUI cases failed: ' + ', '.join(failures))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='zig-out/xodb.app/Contents/MacOS/xodb')
    parser.add_argument('--modes', nargs='+', default=['launch', 'symbol', 'attach', 'missing_symbol', 'detach', 'cmdq', 'sigterm', 'open_error'])
    args = parser.parse_args()
    native(args.binary, args.modes)
