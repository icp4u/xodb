#!/usr/bin/env python3
"""Fast private GUI: flame identity and fixed chart interval across live updates."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
p = argparse.ArgumentParser()
p.add_argument('--binary')
args = p.parse_args()
work = root / '.work' / ('input-atf' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('input_helper', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
home = work / 'home'
home.mkdir()
os.environ['HOME'] = str(home)
os.environ['CODEX_HOME'] = str(home / '.codex')

def event(t, kind, **fields):
    return {'timestamp': t, 'type': 'response_item' if kind in ('message', 'function_call', 'function_call_output') else 'event_msg', 'payload': {'type': kind, **fields}}

source = work / 'session.jsonl'
source.write_text(''.join(json.dumps(row) + '\n' for row in [
    event(1, 'task_started'),
    event(1, 'message', role='user', content=[{'type': 'input_text', 'text': 'Focus "quoted" ' + str(home) + '/notes'}]),
    event(3, 'function_call', call_id='tool-a', name='exec', arguments=json.dumps({'cmd': 'git diff --stat'})),
    event(7, 'function_call_output', call_id='tool-a'),
    event(9, 'task_complete'),
]))
prefix = 'xodb: agent-time view '
# The view audit is debug-level: it carries turn titles and command summaries.
os.environ['XODB_LOG'] = 'profile=debug'
d = None
started = time.monotonic()

def states():
    lines = h.complete_lines(d.log)
    return [json.loads(line[line.index(prefix) + len(prefix):]) for line in lines if prefix in line]

def wait(predicate):
    deadline = time.monotonic() + 15 * h.load_scale()
    while True:
        rows = states()
        if rows and predicate(rows):
            return rows[-1]
        assert d.app.poll() is None, d.tail()
        assert time.monotonic() < deadline, rows
        time.sleep(.02)

def action(*keys):
    count = len(states())
    d.keys(*keys)
    return wait(lambda rows: len(rows) > count and rows[-1]['reason'] == 'input')

def live_update(action_fn):
    count = sum(row['reason'] == 'live' for row in states())
    action_fn()
    return wait(lambda rows: sum(row['reason'] == 'live' for row in rows) > count and rows[-1]['reason'] == 'live')

def append(t):
    with source.open('a') as stream:
        stream.write(json.dumps(event(t, 'progress')) + '\n')

def same_flame(before, after):
    assert after['layout'] == 'flame' and after['focused'], after
    assert (before['selected'], before['zoom']) == (after['selected'], after['zoom']), (before, after)

def same_chart(before, after):
    assert after['layout'] == 'chart' and after['focused'], after
    assert (before['selected'], before['start'], before['end']) == (after['selected'], after['start'], after['end']), (before, after)

try:
    d = h.Display(str(root), ['--agent-time', '--agent-kind', 'codex', '--agent-log', str(source)], stdio=False, binary=args.binary)
    wait(lambda rows: rows[-1]['reason'] == 'ready')
    selected = action('click', 200, 232)  # Turn frame at depth 3.
    assert 'Focus "quoted"' in selected['selected'], selected
    flame = action('tap', 44)  # Z.
    assert flame['focused'] and flame['zoom'] == selected['selected'], flame
    same_flame(flame, live_update(lambda: d.keys('tap', 20)))
    same_flame(flame, live_update(lambda: append(10)))
    action('tap', 20)  # Off, then chart.
    action('tap', 38)
    selected = action('click', d.width // 2, 232)
    assert 'git diff --stat' in selected['selected'], selected
    chart = action('tap', 44)
    assert chart['focused'] and chart['start'] == 3 and chart['end'] == 7, chart
    same_chart(chart, live_update(lambda: d.keys('tap', 20)))
    same_chart(chart, live_update(lambda: append(11)))
    reset = action('tap', 14)  # Backspace restores full range intentionally.
    assert not reset['focused'] and reset['end'] > chart['end'], reset
    d.keys('tap', 16)
    assert d.app.wait(timeout=10) == 0, d.tail()
    d.close()
    # --redact: labels become stable hashes; no prompt text or paths reach the log.
    d = h.Display(str(root), ['--agent-time', '--agent-kind', 'codex', '--agent-log', str(source), '--redact'], stdio=False, binary=args.binary)
    wait(lambda rows: rows[-1]['reason'] == 'ready')
    hashed = action('click', 200, 232)
    assert hashed['selected'].startswith('#') and len(hashed['selected']) == 17, hashed
    lines = '\n'.join(line for line in h.complete_lines(d.log) if prefix in line)
    assert str(home) not in lines and 'Focus' not in lines and 'git diff' not in lines, 'audit bypassed redaction'
    d.keys('tap', 16)
    assert d.app.wait(timeout=10) == 0, d.tail()
    print(json.dumps({'status': 'pass', 'seconds': round(time.monotonic() - started, 3), 'ocr_calls': 0}))
finally:
    if d:
        d.close()
