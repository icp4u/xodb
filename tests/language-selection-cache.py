#!/usr/bin/env python3
"""Stopped Python selections reuse memory evidence and expire after stepping."""
import argparse
import json
import os
from pathlib import Path
import time
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--python', required=True)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--agent', type=Path)
a = p.parse_args()
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
if a.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(a.agent.resolve())
c = None
report = {'status':'running'}
try:
    c = Client('control', a.python, args=['-c', 'def f(n):\n return f(n-1) if n else len([1])\nf(3)'], options=['--break', 'builtin_len'])
    c.stopped()
    c.continue_initial_stop()
    stop = c.stopped('breakpoint', seconds=30)
    tid, generation = stop['threads'][0]['tid'], stop['generation']
    deadline = time.monotonic()+60
    while not c.inspect('get_language_tabs')['view']['complete']:
        assert time.monotonic() < deadline
        time.sleep(.02)
    stack = c.inspect('get_language_stack', language='python', tid=tid)
    si, segment = next((i,s) for i,s in enumerate(stack['segments']) if s['anchor'] and s['frames'])
    index = segment['anchor']['frame']
    pc = c.inspect('get_stack', tid=tid)['frames'][index]['pc']
    def native():
        return c.inspect('select_native_frame', generation=c.session()['generation'], tid=tid, frame=index)['view']
    started = time.monotonic()
    cold = native()
    report['cold_ms'] = (time.monotonic()-started)*1000
    assert cold['selected'] == 'native', cold
    assert any(o['language']=='python' and o['segment']==si for o in cold['offers']['items']), cold
    for tab in ('registers', 'native'):
        c.action('select_language_tab', tab=tab)
        assert native()['selected']==tab
    c.action('select_language_tab', tab='python')
    assert native()['selected']=='python'
    registers = c.inspect('get_registers', tid=tid)
    elapsed = []
    def warm():
        for _ in range(10):
            before = time.monotonic()
            view = native()
            c.action('select_language_frame', tid=tid, language='python', segment=si, frame=0)
            elapsed.append((time.monotonic()-before)*1000)
            assert view['logical_selection']['native_anchor']==index, view
        # Audit's explicit read verifies that it attached to the real reader.
        c.inspect('read_memory', address=hex(pc), length=1)
    reader = SimpleNamespace(p=SimpleNamespace(pid=c.collector_pid()), inspect=c.inspect, session=c.session)
    report['warm_audit'] = audit(reader, tid, w/'warm.strace', warm)
    calls = report['warm_audit']['syscalls']
    assert calls.get('process_vm_readv') == 2 and not calls.get('pread64') and not calls.get('ptrace:PTRACE_PEEKDATA'), calls
    report['warm_pair_ms'] = elapsed
    assert c.session()['generation']==generation and c.inspect('get_registers',tid=tid)==registers
    c.action('step_instruction', tid=tid)
    c.stopped()
    assert c.session()['generation']!=generation
    assert c.inspect('get_language_tabs')['view']['logical_selection'] is None
    def after_step():
        native()
        c.inspect('read_memory', address=hex(pc), length=1)
    report['new_stop_audit'] = audit(reader, tid, w/'new-stop.strace', after_step)
    assert report['new_stop_audit']['syscalls'].get('process_vm_readv',0)>2, report
    report.update(status='pass', loadavg=os.getloadavg(), cpu_count=os.cpu_count(), anchor=segment['anchor'])
except BaseException as exc:
    report.update(status='fail', error=repr(exc))
    raise
finally:
    if c:
        c.close()
        (w/'transcript.json').write_text(json.dumps(c.transcript,indent=1)+'\n')
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Cached language selection: native tab preserved, warm reads absent, new stop reread')
