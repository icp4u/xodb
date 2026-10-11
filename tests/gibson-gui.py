#!/usr/bin/env python3
"""Fast private GUI lane: real sampled memory city, camera, selection and redaction.

--evidence adds replay animation and owned Node performance evidence.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import statistics
import select
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
work = root / '.work' / ('input-gb' + str(time.time_ns())[-5:])
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
    rows = [line for line in Path(d.log).read_text().splitlines() if line.startswith('xodb: gibson frame=')]
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


base, replay = work / 'base.jsonl', work / 'replay.jsonl'
subprocess.run(['python3', '-B', 'tests/fixtures/overview-synth.py', str(base), '--frames', '3'], check=True)
subprocess.run(['python3', '-B', 'tests/fixtures/memmap-synth.py', str(base), str(replay)], check=True)
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
frames = [json.loads(line) for line in replay.read_text().splitlines()]
# Exercise a partially observed file cell, preserving every byte bound.
for frame in frames:
    cell = next(c for c in frame['memory_map']['cells'] if c.get('file', 0) > 0)
    cell['observed'] //= 2
    cell['present'] //= 2
    cell['file'] = min(cell['file'], cell['present'])
replay.write_text(''.join(json.dumps(frame, separators=(',', ':'))+'\n' for frame in frames))
expected = frames[-1]['memory_map']
visible = [c for c in expected['cells'] if not c.get('gap', 0) and (c.get('mapped', 0) or not c.get('mapping_known', True))]
evidence = {}

def send(*cmd):
    if d.keys(*cmd, wait=False).wait(timeout=10):
        raise AssertionError('private input failed')

def has_city(im):
    # Byte triples avoid a Pillow-version-specific pixel iterator.
    raw = im.convert('RGB').tobytes()
    pixels = list(zip(raw[0::3], raw[1::3], raw[2::3]))
    return (sum(1 for r,g,b in pixels if b > 70 and g > 80 and r < g*.7) > 30
            and sum(1 for r,g,b in pixels if r > 80 and b > 50 and g < r*.7) > 30)

def snapshot(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    status = Path(f'/proc/{pid}/status').read_text()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(re.search(r'VmRSS:\s+(\d+)', status).group(1))*1024)

def periodic():
    global d
    d = h.Display(str(root), ['--overview', '--look', 'gibson', '--panel', 'memory_map', '--redact',
                  '--pause', '--interval-ms', '2000', '--replay', str(replay)], stdio=False, trace=False,
                  binary=a.binary, output_size=(1280, 720))
    until(lambda r: int(r['collapsed']) > 0 and float(r['ease']) == 1, 'replay ready')
    fly = []
    for i in range(5):
        capture(f'fly-{i:02d}')
        fly.append(latest())
    check('flythrough changes camera from real sample', len({r['yaw'] for r in fly}) > 1 and all(int(r['towers']) == len(visible) for r in fly))
    key(33, lambda r: r['auto'] == 'false', 'freeze camera for collapse oracle')
    send('tap', 25)
    until(lambda r: int(r['seq']) == frames[1]['memory_map']['sequence'], 'preceding page sample')
    until(lambda r: int(r['seq']) == expected['sequence'] and float(r['ease']) < .8, 'actual collapse transition')
    captures, images = [], []
    for i in range(8):
        path = d.shot(f'collapse-{i:02d}')
        row = latest()
        if int(row['seq']) != expected['sequence']:
            raise AssertionError('capture crossed page publication')
        captures.append(dict(path=str(Path(path).relative_to(root)), state=row, monotonic=time.monotonic()))
        with Image.open(path) as im:
            x, y, field_w, field_h = (float(row[k]) for k in ('x', 'y', 'w', 'h'))
            images.append(im.convert('RGB').crop((int(x), int(y), int(x+field_w), int(y+field_h))))
    check('collapse frames include easing and measured PMD events', len({r['state']['ease'] for r in captures}) > 1 and all(int(r['state']['collapsed']) > 0 for r in captures))
    check('collapse sequence changes city pixels with camera frozen and HUD excluded', any(ImageChops.difference(images[0], im).getbbox() for im in images[1:]))
    evidence['flythrough'] = fly
    evidence['collapse'] = captures
    evidence['animation_log'] = str(Path(d.log).relative_to(root))
    close()
    script = work / 'large.js'
    script.write_text("const blocks = Array.from({length:16}, () => Buffer.alloc(32*1024*1024, 0x5a));\n"
                      "console.log('ready'); let n=0; setInterval(() => {const b=blocks[n++%blocks.length]; b[(n*4096)%b.length]^=1;},50);\n")
    target = subprocess.Popen(['node', str(script)], stdout=subprocess.PIPE, stderr=open(work/'node.log','wb'))
    try:
        ready, _, _ = select.select([target.stdout], [], [], 20)
        if not ready or target.stdout.readline().strip() != b'ready':
            raise AssertionError('owned Node did not start')
        evidence['target'] = snapshot(target.pid)
        perf = []
        os.environ['XODB_MEMMAP_PERF'] = '1'
        for size in ((1920,1080), (3840,2160)):
            d = h.Display(str(root), ['--overview', '--look', 'gibson', '--panel', 'memory_map', '--redact',
                          '--memmap-pid', str(target.pid)], stdio=False, trace=False, binary=a.binary, output_size=size)
            until(lambda r: int(r['towers']) >= 256 and int(r['unknown']) < int(r['towers']), 'owned Node sampled')
            before = snapshot(d.app.pid)
            begin = time.monotonic()
            mark = len(Path(d.log).read_text())
            peak = before['rss_bytes']
            while time.monotonic()-begin < 6:
                if not d.alive(): raise AssertionError(d.tail())
                peak = max(peak, snapshot(d.app.pid)['rss_bytes'])
                time.sleep(.1)
            elapsed = time.monotonic()-begin
            after = snapshot(d.app.pid)
            load = os.getloadavg()
            lines = Path(d.log).read_text()[mark:].splitlines()
            frame_cost = [line for line in lines if 'memmap perf ' in line]
            gpu = [int(m.group(1)) for line in lines if (m := re.search(r'gpu_ns=(\d+)', line))]
            if not frame_cost or not gpu: raise AssertionError('missing real-process timing evidence')
            capture(f'owned-node-{size[0]}')
            perf.append(dict(size=size, seconds=elapsed, cpu_pct=100*(after['cpu_seconds']-before['cpu_seconds'])/elapsed,
                             before=before, after=after, peak_rss_bytes=max(peak,after['rss_bytes']), load=load,
                             measurable=load[0] <= len(os.sched_getaffinity(0)), frame_cost=frame_cost,
                             gpu_ns_median=statistics.median(gpu), gpu_ns_max=max(gpu), state=latest(),
                             log=str(Path(d.log).relative_to(root))))
            close()
        evidence['performance'] = perf
    finally:
        close()
        if target.poll() is None:
            if Path(os.readlink(f'/proc/{target.pid}/cwd')) != root: raise AssertionError('owned Node cwd changed')
            target.terminate()
        try: target.wait(timeout=5)
        except subprocess.TimeoutExpired:
            target.kill()
            target.wait(timeout=5)

try:
    d = h.Display(str(root), ['--overview', '--look', 'gibson', '--panel', 'memory_map',
                  '--pause', '--frames', '100000', '--replay', str(replay)], stdio=False, trace=False, binary=a.binary, output_size=(1280, 720))
    row = until(lambda r: int(r['towers']) > 0 and float(r['ease']) == 1, 'city populated')
    check('one tower per measured or unmeasured mapped cell; compressed gaps omitted', int(row['towers']) == len(visible))
    check('fixture exercises unknown, collapse and split', all(int(row[k]) > 0 for k in ('unknown', 'partial', 'collapsed', 'split')))
    check('GPU timestamp proves 3D commands were submitted', row['gpu_ns'] != 'null')
    check('district labels are present before redaction', int(row['labels']) > 0)
    key(33, lambda r: r['auto'] == 'false', 'manual camera')  # f
    baseline = capture('angle-1')
    check('city has cyan and magenta towers', has_city(baseline))
    check('planted blank-city image is rejected', not has_city(Image.new('RGB', baseline.size)))
    yaw = float(latest()['yaw'])
    key(106, lambda r: float(r['yaw']) > yaw, 'arrow camera')
    angle2 = capture('angle-2')
    check('camera changes rendered city', ImageChops.difference(baseline, angle2).getbbox() is not None)
    yaw = float(latest()['yaw'])
    row = latest()
    x, y = float(row['x'])+float(row['w'])/2, float(row['y'])+float(row['h'])/2
    send('fastdrag', int(x), int(y), int(x+90), int(y+20))
    until(lambda r: float(r['yaw']) < yaw, 'drag camera')
    capture('angle-3')
    check('drag preserves selection', latest()['selected'] == 'null')
    zoom = float(latest()['zoom'])
    send('scroll', int(x), int(y), -2)
    until(lambda r: float(r['zoom']) < zoom, 'wheel dolly')
    check('wheel changes camera zoom', float(latest()['zoom']) < zoom)
    key(19, lambda r: r['auto'] == 'true', 'resume flythrough')
    key(17, lambda r: r['auto'] == 'false', 'W enters manual movement')
    check('WASD takes camera control', latest()['auto'] == 'false')
    key(35, lambda r: r['height'] == 'huge', 'THP height')
    key(35, lambda r: r['height'] == 'swapped', 'swap height')
    key(35, lambda r: r['height'] == 'resident', 'present height')
    key(46, lambda r: r['colour'] == 'district', 'district encoding')
    check('height and colour controls retain known states', int(latest()['unknown']) > 0)
    key(46, lambda r: r['colour'] == 'backing', 'backing encoding')
    # Reset to a stable overview, then pick a visible tower using screen points.
    key(19, lambda r: r['auto'] == 'true' and float(r['zoom']) == 1, 'reset camera')
    key(33, lambda r: r['auto'] == 'false', 'freeze camera')
    row = latest()
    for dy in (0.5, 0.6, 0.4, 0.7):
        for dx in (0.5, 0.4, 0.6, 0.3, 0.7):
            send('click', int(float(row['x'])+float(row['w'])*dx), int(float(row['y'])+float(row['h'])*dy))
            # Every click dirties the frame, even if it misses.
            frame = int(latest()['frame'])
            until(lambda r: int(r['frame']) > frame, 'pick repaint')
            if latest()['selected'] != 'null':
                break
        if latest()['selected'] != 'null':
            break
    check('ray selects an actual sampled address', latest()['selected'] != 'null' and int(latest()['selected']) in {c['start'] for c in visible})
    capture('selected')
    key(1, lambda r: r['selected'] == 'null', 'escape clears selection')
    send('tap', 24)  # O: picker
    def picker():
        rows = re.findall(r'gibson picker selected=(\d+) rows=(\d+)', Path(d.log).read_text())
        return tuple(map(int, rows[-1])) if rows else None
    until(lambda r: picker() is not None, 'picker opens')
    selected, count = picker()
    destination = selected+1 if selected+1 < count else selected-1
    send('tap', 108 if destination > selected else 103)
    until(lambda r: picker()[0] == destination, 'picker keyboard selection survives repaint')
    check('process picker keeps keyboard navigation', picker()[0] == destination)
    frame = int(latest()['frame'])
    send('tap', 1)
    until(lambda r: int(r['frame']) > frame, 'picker Escape returns to city')
    key(45, lambda r: r['redacted'] == 'true', 'redaction')
    capture('redacted')
    check('redaction keeps geometry', int(latest()['towers']) == len(visible))
    check('redaction removes all billboard glyphs', int(latest()['labels']) == 0)
    log = Path(d.log).read_text()
    overlaps = re.findall(r'overview layout .*panel=memory_map overlaps=(\d+)', log)
    check('city labels do not overlap', bool(overlaps) and all(int(n) == 0 for n in overlaps))
    for width, height in ((800,600), (240,160), (1920,1080), (1280,720)):
        subprocess.run(['swaymsg', '-t', 'command', f'output HEADLESS-1 mode {width}x{height}'], env=d.env,
                       check=True, stdout=subprocess.DEVNULL, timeout=10)
        until(lambda r: f'layout {width}x{height} panel=memory_map ' in Path(d.log).read_text(), 'resize repaint')
    until(lambda r: float(r['h']) > 0, 'restored GPU field')
    capture('resized')
    check('GPU city survives tiny and full-size output changes', d.alive())
    evidence['log'] = str(Path(d.log).relative_to(root))
    close()
    if a.evidence: periodic()
finally:
    close()
    (work / 'result.json').write_text(json.dumps(dict(checks=checks, seconds=time.monotonic()-started, evidence=evidence), indent=2)+'\n')
print(json.dumps(dict(passed=len(checks), seconds=time.monotonic()-started, work=str(work))))
