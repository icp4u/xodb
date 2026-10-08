#!/usr/bin/env python3
"""A suspended coroutine has logical frames, but no active native VM anchor."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

root = Path(__file__).resolve().parents[1]
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--include', required=True)
p.add_argument('--library', required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--strace', action='store_true')
a = p.parse_args()
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
exe = w/'fixture'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror',
                '-I'+a.include, 'tests/fixtures/lua/unanchored.c', a.library, '-lm', '-ldl',
                '-Wl,--build-id=sha1', '-o', str(exe)], check=True, timeout=60)
client = None
result = {'status':'running'}
try:
    client = Client('control', str(exe), options=['--break', 'xodb_unanchored_stop'])
    client.stopped()
    client.continue_initial_stop()
    state = client.stopped('breakpoint')
    tid, generation = state['pid'], state['generation']
    deadline = time.monotonic() + 30
    while True:
        tabs = client.inspect('get_language_tabs')['view']
        if tabs['complete']:
            break
        assert time.monotonic() < deadline, tabs
        time.sleep(.02)
    assert any(t['tab']=='lua' and t['visible'] for t in tabs['tabs']), tabs
    stack = client.inspect('get_language_stack', language='lua', tid=tid)
    assert len(stack['segments']) == 2, stack
    assert all(s['frames'] and s['anchor'] is None and not s['additional_anchors'] for s in stack['segments']), stack
    addresses = {s['runtime_instance']['address'] for s in stack['segments']}
    assert len(addresses) == 2, stack
    registers = client.inspect('get_registers', tid=tid)
    pc = client.inspect('get_stack', tid=tid)['frames'][0]['pc']
    native = client.action('select_native_frame', tid=tid, frame=1)['view']['native_selection']
    assert native['frame'] == 1
    selected = []
    for segment in (0, 1):
        view = client.action('select_language_frame', tid=tid, language='lua', segment=segment, frame=0)['view']
        logical = view['logical_selection']
        assert logical['segment'] == segment and logical['frame'] == 0, logical
        assert logical['anchor_basis'] == 'unproved' and logical['native_anchor'] is None and logical['native_pc'] is None, logical
        assert logical['reason'] == 'LanguageNativeAnchorUnproved', logical
        assert view['native_selection'] == native, view
        selected.append(view)
    for changes, reason in [({'segment':2, 'frame':0},'InvalidLanguageSegment'),
                            ({'segment':0, 'frame':63},'InvalidLanguageFrame')]:
        before = client.inspect('get_language_tabs')['view']
        reply = client.tool('select_language_frame', generation=generation, tid=tid, language='lua', **changes)
        assert reply['result']['isError'] and reply['result']['content'][0]['text']==reason, reply
        assert client.inspect('get_language_tabs')['view'] == before
    def observe():
        client.action('select_language_frame', tid=tid, language='lua', segment=0, frame=0)
        client.action('select_language_frame', tid=tid, language='lua', segment=1, frame=0)
        # Prove the tracer reached the real reader even though selections
        # are warm cached data. Selection must add no reads of its own.
        client.inspect('read_memory', address=hex(pc), length=1)
    if a.strace:
        reader = SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid()), inspect=client.inspect, session=client.session)
        result['readonly'] = audit(reader, tid, w/'selection.strace', observe)
        calls = result['readonly']['syscalls']
        assert calls.get('process_vm_readv') == 2 and not calls.get('pread64') and not calls.get('ptrace:PTRACE_PEEKDATA'), calls
    assert client.inspect('get_registers', tid=tid)==registers and client.session()['generation']==generation
    client.action('step_instruction', tid=tid)
    client.stopped()
    after = client.inspect('get_language_tabs')['view']
    assert after['native_selection'] is None and after['logical_selection'] is None and after['selected']=='lua', after
    stale = client.tool('select_language_frame', generation=generation, tid=tid, language='lua', segment=0, frame=0)
    assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot', stale
    observed = client.inspect('get_language_tabs')['view']
    # Detection may complete between calls; rejected selection changes none
    # of the presentation choices, regardless of that background progress.
    for key in ('native_selection', 'logical_selection', 'offers', 'selected'):
        assert observed[key] == after[key], (key, after, observed)
    result.update(status='pass', language_stack=stack, selected=selected, after_step=after)
except BaseException as exc:
    result.update(status='fail', error=repr(exc))
    raise
finally:
    if client:
        client.close()
        (w/'transcript.json').write_text(json.dumps(client.transcript,indent=1)+'\n')
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Unanchored coroutine selections remain partial and preserve native selection')
