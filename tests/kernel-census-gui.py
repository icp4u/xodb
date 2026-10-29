#!/usr/bin/env python3
"""Fast private GUI: opt-in kernel census, shared cache, pause and small layout."""
import importlib.util
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-kc-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('census_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm',
                '-o', h.HELPER], check=True)

def until(fn):
    end = time.monotonic() + 10
    while True:
        if fn():
            return
        if time.monotonic() > end:
            raise AssertionError('GUI census did not settle')
        time.sleep(.02)

d = None
try:
    os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
    d = h.Display(str(root), ['--overview', '--kernel-pid', str(os.getpid())], trace=False)
    cold = d.tool('get_kernel_stacks', refresh=False)
    assert cold['sequence'] == 0 and not cold['pending'], cold
    print('PASS existing startup does not collect kernel stacks')
    d.keys('tap', 37)  # K
    until(lambda: d.tool('get_kernel_stacks', refresh=False).get('task_count', 0) > 0)
    until(lambda: any(row['value'] == 'Kernel stacks · D-state first' for row in d.tool('get_layout')['rows']))
    assert d.tool('get_layout')['text_overlaps'] == 0
    d.shot('kernel-census')
    assert d.tool('get_kernel_stacks', refresh=False)['scope_pid'] == os.getpid()
    d.keys('tap', 25)  # P
    until(lambda: not d.tool('get_kernel_stacks', refresh=False)['pending'])
    sequence = d.tool('get_kernel_stacks', refresh=False)['sequence']
    d.keys('tap', 108, 'tap', 103)
    assert d.tool('get_kernel_stacks', refresh=False)['sequence'] == sequence
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', '720x480'],
                   env=d.env, check=True, capture_output=True)
    until(lambda: d.tool('get_layout')['window']['width'] == 720)
    layout = d.tool('get_layout')
    assert layout['text_overlaps'] == 0
    assert any(row['value'] == 'Kernel stacks · D-state first' and not row['value_elided'] for row in layout['rows'])
    d.shot('kernel-census-small')
    d.keys('tap', 25)
    until(lambda: d.tool('get_kernel_stacks', refresh=False)['sequence'] > sequence)
    print('PASS visible census, owned scope, pause, scrolling, resize and resume')
finally:
    if d:
        d.close()
