#!/usr/bin/env python3
"""Opt-in real native debugger GUI oracle (offscreen, owned fixtures only)."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def verify(text, wrong=False):
    rows = re.findall(r'debugger state=stopped generation=(\d+) pc=([0-9a-f]+) registers=(\d+) instructions=(\d+) breakpoints=(\d+)', text)
    check(len(rows) == 2, 'did not render two stopped debugger publications')
    first, second = [[int(x, 16 if i == 1 else 10) for i, x in enumerate(row)] for row in rows]
    check(all(row[1] and row[2] > 0 and row[3] > 0 for row in (first, second)), 'stopped PC/registers/disassembly missing')
    check(second[0] > first[0], 'step did not publish a new generation')
    check((second[1] == first[1]) if wrong else (second[1] != first[1]), 'step PC oracle rejected result')
    check('clean shutdown (reason=compositor_close)' in text, 'GUI did not follow normal close path')
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


def native(binary):
    started = time.monotonic()
    check(sys.platform == 'darwin', 'local GUI lane requires Darwin')
    fixture = ROOT / '.work/macos-local-fixture'
    subprocess.run(['cc', '-O0', '-g', str(ROOT / 'tests/fixtures/macos-local.c'), '-o', str(fixture)], check=True, timeout=30)
    env = dict(os.environ, XODB_MAC_OFFSCREEN='1', MVK_CONFIG_LOG_LEVEL='1',
               XODB_TEST_SCRIPT=str(ROOT / 'tests/fixtures/macos-local.script'))
    report = {}
    for mode in ('launch', 'symbol', 'attach'):
        beat = ROOT / ('.work/macos-local-' + mode + '.heartbeat')
        if beat.exists():
            beat.unlink()
        target = None
        pid = 0
        output = ''
        if mode == 'attach':
            target = subprocess.Popen([str(fixture), str(beat)])
            pid = target.pid
        try:
            if target:
                progress(beat, target)
            args = ['--attach', str(pid), '--exe', str(fixture)] if target else ['--', str(fixture), str(beat)]
            if mode == 'symbol':
                args = ['--break', 'fixture_marker', *args]
            process = subprocess.Popen([binary, *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                output = process.communicate(timeout=45)[0]
            except subprocess.TimeoutExpired:
                process.terminate()
                output = process.communicate(timeout=15)[0]
                raise RuntimeError('native GUI script did not reach close: ' + output[-2000:])
            finally:
                (ROOT / ('.work/macos-local-' + mode + '.log')).write_text(output)
            check(process.returncode == 0, 'native GUI failed: ' + output[-2000:])
            report[mode] = verify(output)
            if mode == 'symbol':
                check(report[mode]['first'][4] == 1 and report[mode]['second'][4] == 1, 'symbol breakpoint not retained')
            try:
                verify(output, wrong=True)
            except RuntimeError as error:
                check(str(error) == 'step PC oracle rejected result', 'planted result failed for unrelated reason')
            else:
                raise RuntimeError('oracle accepted planted unchanged PC')
            progress(beat, target)
            report[mode]['detach_heartbeat'] = 'pass'
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
    report['negative_oracle'] = 'pass'
    report['seconds'] = time.monotonic() - started
    (ROOT / '.work/macos-local-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='zig-out/xodb.app/Contents/MacOS/xodb')
    native(parser.parse_args().binary)
