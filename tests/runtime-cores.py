#!/usr/bin/env python3
"""Fast host lane: owned runtime cores distinguish absence from unavailable data."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
for language in ('python', 'ruby', 'perl'):
    p.add_argument('--' + language, type=Path)
p.add_argument('--lua', action='append', type=Path, default=[])
a = p.parse_args()
# A runtime that is not installed is simply not passed; a passed path must exist.
for flag, path in [(f, getattr(a, f)) for f in ('python', 'ruby', 'perl')] + [('lua', x) for x in a.lua]:
    assert path is None or path.is_file(), f'--{flag} {path}: no such executable'
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = a.work.resolve()
work.mkdir(parents=True, mode=0o755)


def ordinary_dump_filter():
    # Inherited only by this owned GDB and its child, never a system setting.
    with open('/proc/self/coredump_filter', 'w') as stream:
        stream.write('0x33')


def capture(command, core, stop):
    pre = ['-ex', 'catch syscall exit_group'] if stop == 'exit' else []
    gdb = ['gdb', '-nx', '-nh', '-batch', '-iex', 'set auto-load safe-path /nonexistent',
           '-ex', 'set debuginfod enabled off', '-ex', 'set confirm off',
           '-ex', 'set use-coredump-filter on', *pre, '-ex', 'run',
           '-ex', 'generate-core-file ' + str(core), '-ex', 'kill', '--args', *command]
    with core.with_suffix('.gdb.log').open('w') as log:
        proc = subprocess.Popen(gdb, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True, preexec_fn=ordinary_dump_filter)
        try:
            assert proc.wait(timeout=45) == 0, command
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    assert core.is_file(), command


def error_of(reply):
    result = reply['result']
    return result['content'][0]['text'] if result.get('isError') else None


started = time.monotonic()
exe = work / 'native-fixture'
subprocess.run(['cc', '-g', '-O0', '-pthread', str(root / 'tests/fixtures/core.c'),
                '-o', str(exe)], check=True, timeout=30)
cases = [('native', 'python', [str(exe)], 'abort')]
if a.python:
    cases.append(('python', 'python', [str(a.python.resolve()), '-c', 'import os; os.abort()'], 'abort'))
if a.ruby:
    cases.append(('ruby', 'ruby', [str(a.ruby.resolve()), '-e', 'Process.kill(:ABRT, $$)'], 'abort'))
if a.perl:
    cases.append(('perl', 'perl', [str(a.perl.resolve()), '-e', 'kill "ABRT", $$'], 'abort'))
for i, lua in enumerate(a.lua):
    cases.append(('lua-' + str(i), 'lua', [str(lua.resolve()), '-e', 'x=1'], 'exit'))
# What each owned default-filter core shows today, exactly. A reader that
# improves (for example Ruby frames from a core) updates its row here; any
# other change, including a runtime turning absent, fails.
EXPECTED = {
    'python': ('ready', None),
    'ruby': ('unavailable', 'RubyModuleIdentityUnavailable'),
    'perl': ('unavailable', 'CoreMemoryOmitted'),
    'lua': ('unavailable', 'LuaModuleIdentityUnavailable'),
}
results = []
for label, language, command, stop in cases:
    core = work / (label + '.core')
    capture(command, core, stop)
    for explicit in (False, True):
        options = ['--core', str(core)]
        if explicit:
            options += ['--exe', command[0]]
        client = Client('control', None, options=options)
        try:
            session = client.session()
            assert session['mode'] == 'core' and session['state'] == 'stopped', session
            deadline = time.monotonic() + 30
            while True:
                view = client.inspect('get_language_tabs')['view']
                if view['complete']:
                    break
                assert time.monotonic() < deadline, view
                time.sleep(.01)
            tab = next(t for t in view['tabs'] if t['tab'] == language)
            selected = client.tool('select_language_tab', generation=session['generation'], tab=language)
            stack = client.prepared_tool('get_language_stack', tid=session['threads'][0]['tid'], language=language)
            frames = []
            if label == 'native':
                assert tab['status'] == 'absent' and not tab['visible'], tab
                assert tab['reason'] == 'RuntimeNotDetected', tab
                assert error_of(selected) == 'LanguageTabUnavailable', selected
                assert error_of(stack) == 'PythonModuleIdentityUnavailable', stack
            elif EXPECTED[language][0] == 'ready':
                assert tab['visible'] and tab['status'] == 'ready' and tab['reason'] is None, tab
                assert tab['build_id'] and tab['version'], tab
                assert error_of(selected) is None, selected
                assert client.inspect('get_language_tabs')['view']['selected'] == language
                assert error_of(stack) is None, stack
                frames = [f['name'] for segment in stack['result']['structuredContent']['segments']
                          for f in segment['frames']]
                if language == 'python':
                    assert '<module>' in frames, stack
            else:
                # Partial cores can legitimately lack memory needed by a
                # reader, but must not claim that the runtime was absent.
                assert not tab['visible'] and (tab['status'], tab['reason']) == EXPECTED[language], tab
                assert error_of(selected) == 'LanguageTabUnavailable', selected
                assert error_of(stack) == tab['reason'], (tab, stack)
            results.append({'case': label, 'explicit_executable': explicit, 'tab': tab,
                            'select_error': error_of(selected), 'stack_error': error_of(stack), 'frames': frames})
        finally:
            (work / (label + ('-explicit.json' if explicit else '-automatic.json'))).write_text(
                json.dumps(client.transcript, indent=2))
            client.close()
    core.unlink()  # Both modes passed; a failing case keeps its core as evidence.
(work / 'results.json').write_text(json.dumps({'status': 'pass', 'seconds': time.monotonic() - started,
                                             'cases': results}, indent=2))
print('Owned runtime cores: ' + str(len(results)) + ' automatic/explicit tab, selection and stack cases passed')
