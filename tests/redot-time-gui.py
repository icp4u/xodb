#!/usr/bin/env python3
"""Fast private GUI lane: frame -> slow script -> native, inspector filter/expansion."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--demo', action='store_true', help='Periodic lane: also exercise the public launcher')
p.add_argument('--status-only', action='store_true', help='Fast lane: empty-pane sampling and startup failure')
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
sys.path.insert(0, str(root / 'scripts/helpers'))
from redot_scene import start_scene
from redot_time import sample_time, capture_status

w = (args.work / '.work/input-time').resolve()
w.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (w / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w / (stem + '.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w / (stem + '.c'))], check=True, timeout=10)
h.HELPER = str(w / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c', str(w / 'virtual-pointer.c'), str(w / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=30)
shutil.copytree(root / 'tests/fixtures/redot-time', w / 'project')
os.environ.pop('XODB_TEST_RUNTIME_AGENT', None)
d = None
began = time.monotonic()
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--redot-debugger', '--image-limit', '1600M', '--image-total-limit', '2G', '--', str(Path(args.redot).resolve()), '--headless', '--path', str(w / 'project')])
    scene = start_scene(d.tool)
    def visible(label, words):
        deadline = time.monotonic() + 10
        while True:
            shot = d.shot(label)
            text = subprocess.run(['tesseract', shot, 'stdout', '--psm', '11'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=20).stdout
            compact = ''.join(c for c in text.lower() if c.isalnum())
            if all(word in compact for word in words):
                return text
            assert time.monotonic() < deadline, (label, text, d.tail())
            time.sleep(.02)
    if args.status_only:
        d.keys('tap', 22, 'tap', 20)  # U T, before any profiler frames arrive.
        capture_status(d.tool, 'sampling', 3, 12)
        visible('sampling', ['sampling', '3of12'])
        capture_status(d.tool, 'failed', 3, 12, 'Owned sample startup stopped')
        visible('startup-failed', ['scenestartup', 'ownedsamplestartupstopped'])
        (args.work / 'results.json').write_text(json.dumps(dict(status='pass', seconds=round(time.monotonic()-began, 2)))+'\n')
        print('Redot time status: sampling progress and startup failure visible without frames')
        sys.exit(0)
    samples = sample_time(d.tool, 8)
    profile = d.tool('get_redot_profile', limit=256)
    target = max((s for s in samples if any(f['name'] == 'burn' and f['reason'] is None and f['native_frame'] is not None for f in s['script']) and any(f['number'] == s['frame_number'] for f in profile['frames'])), key=lambda s: max(f['native_frame'] for f in s['script'] if f['name'] == 'burn' and f['native_frame'] is not None))
    ordinal = next(i for i, f in enumerate(profile['frames']) if f['number'] == target['frame_number'])
    detail = d.tool('get_redot_profile', frame_number=target['frame_number'])
    function_index = next(i for i, f in enumerate(detail['selected']['functions']) if f['signature'].endswith('::burn'))
    assert function_index < 6
    d.keys('tap', 22, 'click', 180, 256, 'tap', 20)  # U, Slow, T
    visible('timeline', ['frametime', 'functions'])
    d.keys('click', 506 + (ordinal+.5)*740/len(profile['frames']), 230)
    d.keys('click', 800, 164+193+function_index*24+8)
    timing = visible('time-native', ['processframe', 'slowgd', 'burn', 'nativeframes', 'owner', 'physics'])
    d.keys('tap', 25, 'tap', 53, 'tap', 23, 'tap', 49, 'tap', 47, 'tap', 18, 'tap', 49, 'tap', 20, 'tap', 24, 'tap', 19, 'tap', 21, 'tap', 28)  # P /inventory Enter
    visible('filtered', ['filter', 'inventory'])
    d.keys('click', 800, 292)
    expanded = visible('expanded', ['damage', 'sharp', 'steel'])
    # Input remains captured even after continue, without an object selection.
    d.keys('click', 180, 200, 'tap', 53, 'tap', 32, 'tap', 1)
    assert d.tool('get_session')['state'] == 'running'
    d.app.stdin.close()
    assert d.app.wait(timeout=10) == 0, d.tail()
    if args.demo:
        with (w / 'demo.log').open('wb') as output:
            demo = subprocess.Popen(['scripts/demo-redot', 'time'], env=dict(d.env, REDOT=str(Path(args.redot).resolve()), XODB=str(root / 'zig-out/bin/xodb'), REDOT_PROJECT=str(w / 'project')), stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 40
                while 'Time ready.' not in (w / 'demo.log').read_text():
                    assert demo.poll() is None and time.monotonic() < deadline, (w / 'demo.log').read_text()
                    time.sleep(.02)
                assert 'ORACLE frame ' not in (w / 'demo.log').read_text()
                d.keys('tap', 22, 'tap', 20, 'tap', 33)  # U T F
                visible('demo-time', ['frametime', 'slow', 'functions'])
            finally:
                if demo.poll() is None:
                    demo.send_signal(signal.SIGINT)
                demo.wait(timeout=15)
    (args.work / 'results.json').write_text(json.dumps(dict(status='pass', seconds=round(time.monotonic()-began, 2), timing=timing, expanded=expanded, public_demo='pass' if args.demo else 'not_run'), indent=2)+'\n')
finally:
    if d:
        d.close()
print('Redot time GUI: frame/function/native drill-down, filter and nested expansion pass' + ('; public time demo passes' if args.demo else ''))
