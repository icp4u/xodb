#!/usr/bin/env python3
"""Fast private GUI lane: GPU depth, clip, bloom, atlas and resource lifecycle.

--evidence adds synthetic throughput at two resolutions and three instance counts.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time
from PIL import Image, ImageChops

p = argparse.ArgumentParser()
p.add_argument('--binary')
p.add_argument('--evidence', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-s3' + str(time.time_ns())[-5:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
checks = []
d = None
started = time.monotonic()

def check(name, ok):
    if not ok:
        raise AssertionError(name + ': ' + d.tail())
    checks.append(name)
    print('PASS ' + name, flush=True)

def latest():
    rows = [line for line in Path(d.log).read_text().splitlines() if line.startswith('scene3d frame=')]
    return dict(re.findall(r'(\w+)=([^ ]+)', rows[-1])) if rows else {}

def until(fn, name):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not d.alive():
            raise AssertionError(d.tail())
        row = latest()
        if row and fn(row):
            return row
        time.sleep(.01)
    raise AssertionError(name + ': ' + d.tail())

def capture(name):
    frame = int(latest().get('frame', '0'))
    until(lambda r: int(r['frame']) >= frame + 2, 'present next two frames')
    with Image.open(d.shot(name)) as im:
        return im.convert('RGB')

def key(code, predicate, name):
    helper = d.keys('tap', code, wait=False)
    if helper.wait(timeout=10):
        raise AssertionError('private input failed')
    return until(predicate, name)

def close():
    global d
    if d:
        for proc in d.procs:
            if proc.poll() is None:
                try:
                    cwd = os.readlink(f'/proc/{proc.pid}/cwd')
                except PermissionError:
                    # A capability-bearing compositor hides its cwd; it is still our own child.
                    continue
                except FileNotFoundError:
                    continue
                if Path(cwd) != root:
                    raise AssertionError('owned-process cwd changed before cleanup')
        d.close()
        d = None

def red(pixel):
    r, g, b = pixel
    return r > 50 and r > 4 * max(g, b)

def depth_pixel(im):
    return im.getpixel((im.width // 2, im.height // 2 + 35))

def snapshot():
    fields = Path(f'/proc/{d.app.pid}/stat').read_text().rsplit(')', 1)[1].split()
    status = Path(f'/proc/{d.app.pid}/status').read_text()
    return dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(re.search(r'VmRSS:\s+(\d+)', status).group(1)) * 1024)

try:
    d = h.Display(str(root), ['--scene3d-probe', '--instances', '4000'], stdio=False, trace=False,
                  binary=a.binary, output_size=(1280, 720))
    row = until(lambda r: int(r['frame']) >= 3, 'first scene')
    im = capture('baseline')
    check('opaque front face hides rear box and point', red(depth_pixel(im)))
    check('planted green depth result is rejected', not red((0, 255, 0)))
    check('2D magenta overlay survives composite', im.getpixel((640, 348)) == (255, 0, 255))
    check('2D instance batch survives composite', im.getpixel((688, 348)) == (255, 255, 0))
    check('scene covers earlier 2D instance batch', im.getpixel((100, 100)) == (0, 0, 0))
    check('scene remains inside its clipped panel', all(im.getpixel(pos) == im.getpixel((16, 360)) for pos in ((16, 360), (1264, 360), (640, 704))))
    check('all primitive paths drew with one instance buffer each', int(row['glyphs']) == 71 and int(row['draws']) >= 9)
    # Camera is fixed for the probe: project just these oracle locations.
    focal = (720 - 80) / (2 * math.tan(.5) * 6)
    px, py = round(640 - 1.5 * focal), round(368 - .5 * focal)
    check('visible point is green and bright', im.getpixel((px, py))[1] > 180)
    label = im.crop((590, round(368 - 1.3 * focal) - 8, 690, round(368 - 1.3 * focal) + 16))
    check('shared atlas billboard produces white glyph pixels', sum(min(v) > 100 for v in list(label.get_flattened_data())) > 40)
    key(19, lambda r: r.get('reverse') == 'true', 'reverse submission')
    reverse = capture('reverse')
    check('depth is independent of instance submission order', red(depth_pixel(reverse)))
    translucent = (round(640 + 1.5 * focal), round(368 - .5 * focal))
    check('translucent faces accumulate without submission sorting', all(abs(x-y) <= 2 for x, y in zip(im.getpixel(translucent), reverse.getpixel(translucent))))
    key(48, lambda r: r.get('bloom') == '0', 'disable bloom')
    dark = capture('no-bloom')
    ring = [(x, y) for x in range(px - 30, px + 31) for y in range(py - 30, py + 31) if 18 ** 2 <= (x-px)**2 + (y-py)**2 <= 28 ** 2]
    glow = sum(im.getpixel(pos)[1] - dark.getpixel(pos)[1] for pos in ring)
    check('post-pass bloom adds light outside point geometry', glow > len(ring))
    key(35, lambda r: r.get('bytes') == '0', 'hide scene')
    check('hiding retires all scene allocations', latest().get('bytes') == '0')
    key(35, lambda r: int(r.get('bytes', '0')) > 0, 'show scene')
    check('scene recreates after retirement', red(depth_pixel(capture('restored'))))
    mark = len(Path(d.log).read_text())
    key(44, lambda r: 'scene3d zero_extent images=0' in Path(d.log).read_text()[mark:], 'zero extent')
    check('explicit zero extent retires depth before recreation', red(depth_pixel(capture('zero-extent'))))
    key(45, lambda r: r.get('generation') == '1', 'recreate renderer')
    check('renderer recreation preserves scene and font atlas', red(depth_pixel(capture('reinitialized'))))
    for width, height in ((40, 40), (640, 480), (1280, 720)):
        subprocess.run(['swaymsg', '-t', 'command', f'output HEADLESS-1 mode {width}x{height}'], env=d.env, capture_output=True, check=True, timeout=10)
        until(lambda r: r.get('size') == f'{width}x{height}' or (width == 40 and r.get('bytes') == '0'), 'resize scene')
        if width == 40:
            check('empty logical panel allocates no zero-sized images', latest().get('bytes') == '0')
        else:
            check(f'depth and composite survive resize {width}x{height}', red(depth_pixel(capture(f'resize-{width}'))))
    close()
    evidence = []
    if a.evidence:
        for width, height in ((1920, 1080), (3840, 2160)):
            for count in (4000, 65000, 250000):
                d = h.Display(str(root), ['--scene3d-probe', '--instances', str(count)], stdio=False, trace=False,
                              binary=a.binary, output_size=(width, height))
                until(lambda r: int(r['frame']) >= 8, 'warm scene')
                before = snapshot()
                first = int(latest()['frame'])
                t0 = time.monotonic()
                until(lambda r: int(r['frame']) >= first + 90, 'measure 90 frames')
                wall = time.monotonic() - t0
                after = snapshot()
                last = int(latest()['frame'])
                rows = [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in Path(d.log).read_text().splitlines() if line.startswith('scene3d frame=')]
                rows = [r for r in rows if first < int(r['frame']) <= last]
                gpu = [int(r['gpu_ns']) / 1e6 for r in rows if r.get('gpu_ns') != 'null']
                load = os.getloadavg()
                cpus = len(os.sched_getaffinity(0))
                evidence.append(dict(kind='synthetic', width=width, height=height, instances=count, frames=last-first,
                    wall_seconds=wall, fps=(last-first)/wall, cpu_ms_per_frame=(after['cpu_seconds']-before['cpu_seconds'])*1000/(last-first),
                    submit_wall_ms_median=statistics.median(int(r['submit_wall_ns'])/1e6 for r in rows),
                    gpu_ms_median=statistics.median(gpu) if gpu else None,
                    rss_before=before['rss_bytes'], rss_after=after['rss_bytes'], allocated_bytes=int(rows[-1]['bytes']),
                    load_average=load, allowed_cpus=cpus, measurable=load[0] <= cpus))
                capture(f'synthetic-{width}-{count}')
                print(json.dumps(evidence[-1]), flush=True)
                close()
    (work/'results.json').write_text(json.dumps(dict(checks=checks, evidence=evidence, seconds=time.monotonic()-started), indent=2)+'\n')
    print(f'{len(checks)} passed; evidence {work}', flush=True)
finally:
    close()
