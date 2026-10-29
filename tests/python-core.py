#!/usr/bin/env python3
"""Fast host lane: a default-filter Python core retains runtime discovery."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--python', required=True, type=Path)
p.add_argument('--work', required=True, type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = a.work.resolve()
work.mkdir(parents=True, mode=0o755)
core = work / 'python.core'
command = ['gdb', '-nx', '-nh', '-batch', '-iex', 'set auto-load safe-path /nonexistent',
           '-ex', 'set debuginfod enabled off', '-ex', 'set confirm off',
           '-ex', 'set use-coredump-filter on', '-ex', 'run',
           '-ex', 'generate-core-file ' + str(core), '-ex', 'kill',
           '--args', str(a.python.resolve()), str(root / 'tests/fixtures/python/core.py')]
started = time.monotonic()
with (work / 'gdb.log').open('w') as log:
    proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        assert proc.wait(timeout=45) == 0
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
assert core.is_file(), (work / 'gdb.log').read_text()
results = []
for explicit in (False, True):
    options = ['--core', str(core)]
    if explicit:
        options += ['--exe', str(a.python.resolve())]
    client = Client('control', None, options=options)
    try:
        session = client.session()
        assert session['mode'] == 'core' and session['state'] == 'stopped', session
        deadline = time.monotonic() + 30
        while True:
            tabs = client.inspect('get_language_tabs')['view']
            if tabs['complete']:
                break
            assert time.monotonic() < deadline, tabs
            time.sleep(.01)
        tab = next(t for t in tabs['tabs'] if t['tab'] == 'python')
        assert tab['visible'] and tab['status'] in ('ready', 'unwitnessed'), tab
        assert tab['build_id'] and tab['version'], tab
        stack = client.inspect('get_language_stack', language='python', tid=session['threads'][0]['tid'])
        frames = [f for segment in stack['segments'] for f in segment['frames']]
        assert any(f['name'] == 'core_marker' and Path(f['file']).name == 'core.py' for f in frames), stack
        results.append({'explicit_executable': explicit, 'tab': tab, 'stack': stack})
    finally:
        (work / ('explicit.json' if explicit else 'automatic.json')).write_text(json.dumps(client.transcript, indent=2))
        client.close()
(work / 'results.json').write_text(json.dumps({'status': 'pass', 'seconds': time.monotonic() - started,
                                             'cases': results}, indent=2))
print('Python default-filter core: tab and witnessed frame, automatic and explicit executable passed')
