#!/usr/bin/env python3
"""Live flame refresh colors, using an owned fixture and private headless Sway."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from PIL import Image, ImageChops

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prefix', default='zig-out')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('input_repro', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
work = root/'.work'/('input-flame-'+str(time.time_ns())[-10:])
work.mkdir()
h.WORK = str(work)
for name in ('tmp', 'cache', 'cache/mesa', 'cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True)
h.HELPER = str(work/'vinput')
compile_env = dict(os.environ, TMPDIR=str(work/'tmp'))
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, env=compile_env)
fault = work/'worker-fault.so'
subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', 'tests/flame-worker-fault.c', '-ldl', '-pthread', '-o', str(fault)], check=True, env=compile_env)
tree = work/'tree'
tree.mkdir()
(tree/'zig-out').symlink_to(Path(args.prefix).resolve(), target_is_directory=True)
os.environ.update(LD_PRELOAD=str(fault), XODB_TEST_FLAME_WORKER_GATE=str(work/'gate'))
d = None
try:
    d = h.Display(str(tree), ['--agent-scope', 'control', '--break', 'profile_ready', '--', str(root/'zig-out/bin/xodb-profile-fixture'), '30', 'threads'])
    d.keys('tap', 57)
    assert d.stopped('breakpoint'), d.tail()
    (work/'gate').write_text('delay')
    d.keys('tap', 25)
    d.keys('tap', 57)
    samples = []
    header = None
    active_jobs = 0
    def warning_pixels(path):
        with Image.open(path) as image:
            rgb = image.convert('RGB').crop((20, 176, 1250, 195))
            pixels = rgb.tobytes()
            return sum(r > 110 and r > g*1.15 and g > b*1.2
                       for r, g, b in zip(pixels[0::3], pixels[1::3], pixels[2::3]))
    for i in range(20):
        profile = d.tool('get_profile')
        active_jobs += profile['recorded_view_job'] is not None
        samples.append(profile['capture']['stored_samples'])
        path = Path(d.shot(f'live-{i:02}'))
        assert warning_pixels(path) == 0, f'Routine refresh flashed a warning: {path.relative_to(root)}'
        with Image.open(path) as image:
            current = image.convert('RGB').crop((10, 96, 1250, 125))
        if header is None:
            header = current
        assert ImageChops.difference(header, current).getbbox() is None, 'Static toolbar moved'
        time.sleep(.05)
    assert active_jobs >= 2 and samples[-1] > samples[0], (active_jobs, samples)
    # This file is owned test scratch; retain its previous state before changing it.
    (work/'gate.before-failure').write_bytes((work/'gate').read_bytes())
    (work/'gate').write_text('fail')
    deadline = time.monotonic()+3
    i = 0
    while True:
        path = Path(d.shot(f'failure-{i:02}'))
        if warning_pixels(path) > 100:
            break
        assert time.monotonic() < deadline, 'Worker failure lost warning emphasis'
        i += 1
        time.sleep(.1)
    d.app.stdin.close()
    assert d.app.wait(timeout=5) == 0, d.tail()
    (work/'results.json').write_text(json.dumps({'live_frames':20, 'active_jobs':active_jobs, 'first_samples':samples[0], 'last_samples':samples[-1], 'failure_warning':True}, indent=2)+'\n')
    print('Live refresh stays neutral; failed worker stays orange; toolbar stable:', work.relative_to(root))
finally:
    if d:
        d.close()
