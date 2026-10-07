#!/usr/bin/env python3
"""Private GUI navigation for logical frames; optional owned JIT demo.

frames-gui.py LOGICAL.jsonl [CAPTURE.xoc RESOLVED.xof AMBIGUOUS.xof]
Screenshots and OCR transcripts remain in .work; no visible desktop is used.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

paths = [str(Path(p).resolve()) for p in sys.argv[1:]]
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
gui_root = Path(os.environ.get('XODB_TEST_GUI_ROOT', root))
spec = importlib.util.spec_from_file_location('frame_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
work = root / '.work' / ('input-frames-' + str(time.time_ns())[-10:])
work.mkdir(parents=True); h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)


def ready(d):
    end = time.monotonic() + 20
    while True:
        s = d.tool('get_frame_status')
        if s['status'] != 'pending':
            assert s['error_name'] is None, s
            return s
        assert time.monotonic() < end
        time.sleep(.02)


def shot(d, name):
    time.sleep(.3)
    path = d.shot(name)
    r = subprocess.run(['tesseract', path, 'stdout'], capture_output=True, text=True, check=True, timeout=15)
    Path(path + '.txt').write_text(r.stdout)
    return r.stdout.lower()


if not paths:
    logical = work / 'python.jsonl'
    subprocess.run(['python3', 'tests/logical-frames/python_workload.py', str(logical),
                    str(work / 'python-meta.json'), '.25', '10'], check=True, timeout=30)
    paths = [str(logical)]

d = None
checks = []
try:
    d = h.Display(str(gui_root), ['--agent-scope', 'control', '--open-frames', paths[0]])
    s = ready(d)['sources'][0]
    fs = d.tool('get_frame_functions', source_id=s['source_id'], limit=64)['rows']
    agg = d.tool('get_frame_aggregate', source_id=s['source_id'], limit=64)['rows']
    order = sorted(agg, key=lambda r: (-int(r['inclusive']), r['function']))
    by_id = {f['index']: f for f in fs}
    selected = next(i for i, row in enumerate(order) if by_id[row['function']]['function']['name'] == 'fib')
    if selected: d.keys(*sum((['tap', 36] for _ in range(selected)), []))
    d.keys('tap', 28)
    text = shot(d, 'logical-source')
    assert 'separate from native stacks' in text and 'observation' in text and 'fib' in text, text
    assert 'matches recorded' in text and 'return' in text, text
    checks.append('Python hot frame, collection method, exact count and matching source preview')
    d.keys('tap', 36)
    text = shot(d, 'selection-clears-preview')
    assert 'enter opens' in text and 'matches recorded' not in text, text
    d.keys('tap', 38)  # L: ordinary workspace
    text = shot(d, 'native-separate')
    assert 'separate from native stacks' not in text, text
    d.keys('tap', 38)
    assert 'separate from native stacks' in shot(d, 'logical-reopened')
    checks.append('Selection invalidates preview; L switches separate native/logical views')
    d.close(); d = None
    d = h.Display(str(gui_root), ['--agent-scope', 'control', '--open-frames', paths[0], *h.M1])
    ready(d); d.stopped(); d.keys('tap', 38)  # native workspace
    d.keys('tap', 18, 'tap', 45, 'tap', 38, 'tap', 23)  # E, x l i
    text = shot(d, 'editor-owns-l')
    assert 'separate from native stacks' not in text and 'return adds to the watch list' in text, text
    assert [e.get('text') for e in d.trace() if e['kind'] == 'press'][-3:] == ['x', 'l', 'i']
    d.keys('tap', 1, 'tap', 30, 'tap', 38)  # Esc, A allocations, L lifetimes
    text = shot(d, 'allocation-owns-l')
    assert 'allocations' in text and 'separate from native stacks' not in text, text
    checks.append('Expression field consumes l; allocation panel retains L')
    d.close(); d = None
    # Generate an owned capture and deliberately invalid optional payload.
    optional = subprocess.run(['python3', '-B', 'tests/frame-archive.py', '--case', 'optional'],
                              capture_output=True, text=True, timeout=60)
    (work / 'optional.log').write_text(optional.stdout + optional.stderr)
    assert optional.returncode == 0, optional.stdout + optional.stderr
    evidence = Path(next(line.split(': ', 1)[1] for line in optional.stdout.splitlines()
                         if line.startswith('Frame archive evidence: ')))
    d = h.Display(str(gui_root), ['--agent-scope', 'control', '--open-capture', str(evidence / 'version.xoc')])
    end = time.monotonic() + 15
    while d.tool('get_frame_status')['status'] == 'pending':
        assert time.monotonic() < end
        time.sleep(.02)
    text = shot(d, 'unavailable-native')
    assert 'archive frames' in text and 'unsupported' in text, text
    d.keys('tap', 38)
    text = shot(d, 'unavailable-logical')
    assert 'archive attachments' in text and 'original bytes retained' in text, text
    checks.append('Unsupported attachment remains visible in native and logical GUI views')
    d.close(); d = None
    if len(paths) == 4:
        for bundle, outcome in ((paths[2], 'resolved'), (paths[3], 'ambiguous')):
            d = h.Display(str(gui_root), ['--agent-scope', 'control', '--open-capture', paths[1], '--open-frames', bundle])
            ready(d)
            d.keys('tap', 38, 'tap', 23)  # L native, I sampled stack
            end = time.monotonic() + 15
            while True:
                text = shot(d, 'jit-' + outcome)
                if 'jit ' + outcome in text: break
                assert time.monotonic() < end, text
                time.sleep(.1)
            assert 'sampled pc' in text and 'hot mix' in text.replace('_', ' '), text
            checks.append('Native sampled PC and ' + outcome + ' JIT label')
            d.close(); d = None
finally:
    if d: d.close()
(work / 'results.json').write_text(json.dumps(checks, indent=2))
print('Frame GUI:', len(checks), 'checks passed;', work.relative_to(root))
