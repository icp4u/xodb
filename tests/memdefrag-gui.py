#!/usr/bin/env python3
"""The overview's Memory map panel on a private headless display.

Synthetic replays (tests/fixtures/memmap-synth.py) give deterministic
screenshots of the four looks (Windows 9x Defrag, MS-DOS DEFRAG, modern, and
the deep map: recorded explicit viewports at 2 MiB, 64 KiB and 4 KiB) at
1920x1080 and 1280x720, the layout audit (no label overlaps), redaction,
unknown/hatched states, the three kinds of change, the working buttons, and
the Processes -> Memory map hand-off. With --live it also maps an owned
fixture that madvise(MADV_HUGEPAGE)s 1 GiB, collapses it step by step and
forces a split, and zooms the deep map into the split at 4 KiB. --shots DIR
saves the screenshots; --perf records deep-map frame cost (evidence only).
"""
import argparse
import glob
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--shots', type=Path, help='save the screenshots here')
parser.add_argument('--live', action='store_true', help='also map the owned 1 GiB THP fixture')
parser.add_argument('--mib', type=int, default=1024, help='fixture size for --live')
parser.add_argument('--only', help='comma-separated sections: looks,layout,redact,states,buttons,handoff,deep,live,deeplive,perf')
parser.add_argument('--perf', action='store_true', help='also measure deep-map frame time, CPU and RSS on the live fixture')
parser.add_argument('--perf-binary', help='with --perf, also measure this build (e.g. the parent) in the modern look')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-memdefrag-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('memdefrag_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
base = work / 'base.jsonl'
subprocess.run([sys.executable, '-B', 'tests/fixtures/overview-synth.py', str(base), '--frames', '12'], check=True)
replays = {}
for scenario in ('process', 'fallback', 'system'):
    replays[scenario] = work / f'{scenario}.jsonl'
    subprocess.run([sys.executable, '-B', 'tests/fixtures/memmap-synth.py', str(base), str(replays[scenario]), '--scenario', scenario], check=True)
replays['deep'] = work / 'deep.jsonl'
subprocess.run([sys.executable, '-B', 'tests/fixtures/memmap-synth.py', str(base), str(replays['deep']), '--scenario', 'process', '--viewports'], check=True)
last_map = json.loads(replays['process'].read_text().splitlines()[-1])['memory_map']
results = []
KEY = dict(h.KEY, n0=11, n3=4, t=20, p=25, d=32, g=34, m=50, o=24, x=45, enter=28, esc=1, down=108, up=103, right=106, left=105,
           pgdn=109, pgup=104, minus=12, equal=13, bracketright=27, bracketleft=26)
sections = set((args.only or 'looks,layout,redact,states,buttons,handoff,deep' + (',live,deeplive' if args.live else '') + (',perf' if args.perf else '')).split(','))
shots = args.shots.resolve() if args.shots else None
if shots:
    shots.mkdir(parents=True, exist_ok=True)


def check(name, ok, detail=''):
    results.append({'check': name, 'ok': bool(ok), 'detail': str(detail)[:600]})
    print(('ok   ' if ok else 'FAIL ') + name + (': ' + str(detail)[:300] if detail else ''), flush=True)
    return ok


class Overview:
    """A private headless Sway (no input devices) running one overview window."""
    count = 0

    def __init__(self, options, size=(1920, 1080), source=None, env_extra=None, replay=True, binary=None):
        Overview.count += 1
        self.size = size
        self.dir = work / f'run-{Overview.count:02d}'
        self.runtime = work / 'rt' / str(Overview.count)
        self.dir.mkdir()
        self.runtime.mkdir(parents=True, mode=0o700)
        config = self.dir / 'sway.conf'
        config.write_text(f'xwayland disable\noutput HEADLESS-1 mode {size[0]}x{size[1]}\noutput * bg #000000 solid_color\n'
                          'default_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
        env = dict(os.environ)
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        env.update(TMPDIR=str(work / 'tmp'), XDG_CACHE_HOME=str(work / 'cache'), XDG_RUNTIME_DIR=str(self.runtime), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1', XODB_TEST_PRIVATE_DISPLAY='1')
        self.env = env
        self.procs = []
        self.sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', str(config)], env=env,
                                     stdout=open(self.dir / 'sway.log', 'wb'), stderr=subprocess.STDOUT)
        self.procs.append(self.sway)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sockets = [p for p in glob.glob(str(self.runtime / 'wayland-*')) if not p.endswith('.lock')]
            ipc = glob.glob(str(self.runtime / 'sway-ipc*.sock'))
            if sockets and ipc:
                break
            time.sleep(0.05)
        else:
            raise TimeoutError('private compositor did not start')
        env['WAYLAND_DISPLAY'] = os.path.basename(sockets[0])
        env['SWAYSOCK'] = ipc[0]
        self.log = self.dir / 'xodb.log'
        app_env = dict(env, XODB_OVERVIEW_LAYOUT='1', **(env_extra or {}))
        source_args = ['--replay', str(source or replays['process'])] if replay else []
        self.app = subprocess.Popen([binary or str(root / 'zig-out/bin/xodb'), '--overview', *source_args, *options], cwd=root, env=app_env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(self.log, 'wb'))
        self.procs.append(self.app)
        h.Display.wait_focused(self)
        time.sleep(0.8)

    def keys(self, *commands):
        script = ['layout', 'us', *[str(c) for c in commands]]
        helper = subprocess.run([h.HELPER, str(self.size[0]), str(self.size[1]), *script], env=self.env, timeout=60)
        if helper.returncode != 0:
            raise RuntimeError(f'input helper exited {helper.returncode}')
        time.sleep(0.5)

    def tap(self, *names):
        cmds = []
        for n in names:
            cmds += ['tap', KEY[n]]
        self.keys(*cmds)

    def move(self, x, y):
        self.keys('m', int(x), int(y))

    def click(self, x, y):
        self.keys('click', int(x), int(y))

    def shot(self, name):
        path = self.dir / (name + '.png')
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(path)], env=self.env, check=True, timeout=10)
        return path

    def text(self):
        return self.log.read_text(errors='replace')

    def grid(self):
        lines = re.findall(r'memmap grid x=([\d.]+) y=([\d.]+) pitch=([\d.]+) cols=(\d+) first_row=(\d+) count=(\d+)', self.text())
        if not lines:
            return None
        x, y, p, cols, first, count = lines[-1]
        return dict(x=float(x), y=float(y), pitch=float(p), cols=int(cols), first=int(first), count=int(count))

    def textgrid(self):
        lines = re.findall(r'memmap text x=([\d.]+) y=([\d.]+) cw=([\d.]+) ch=([\d.]+)', self.text())
        return dict(zip(('x', 'y', 'cw', 'ch'), map(float, lines[-1]))) if lines else None

    def cell_xy(self, index):
        g = self.grid()
        row, col = divmod(index, g['cols'])
        return g['x'] + (col + 0.5) * g['pitch'], g['y'] + (row - g['first'] + 0.5) * g['pitch']

    def deep(self):
        """The deep field's last audit line: geometry, view and what it shows."""
        lines = re.findall(r'memmap deep x=.*', self.text())
        if not lines:
            return None
        out = {}
        for k, v in re.findall(r'(\w+)=(\S+)', lines[-1]):
            out[k] = v if k in ('mini', 'box') else int(v, 16) if v.startswith('0x') else float(v) if '.' in v else int(v)
        return out

    def deep_detail(self):
        found = re.findall(r'memmap deep detail (.*)', self.text())
        return found[-1] if found else ''

    def deep_xy(self, address):
        g = self.deep()
        i = (address - g['origin']) // g['cell']
        row, col = divmod(i, g['cols'])
        return g['x'] + (col + 0.5) * g['pitch'], g['y'] + (row + 0.5) * g['pitch']

    def wait_deep(self, pred, timeout=8):
        deadline = time.monotonic() + timeout
        while True:
            g = self.deep()
            if g and pred(g) or time.monotonic() > deadline:
                return g
            time.sleep(0.2)

    def rows(self):
        found = re.findall(r'memmap row (\d\d) (.*)', self.text())
        return [r for _, r in found[-25:]]

    def layout_lines(self):
        return [l for l in self.text().splitlines() if 'overview layout' in l and 'panel=memory_map' in l]

    def close(self):
        if self.app.poll() is None:
            self.app.send_signal(signal.SIGTERM)
        for p in reversed(self.procs):
            if p.poll() is None and p is not self.app:
                p.send_signal(signal.SIGTERM)
        for p in reversed(self.procs):
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()


def ocr(path, box=None):
    if box:
        crop = Path(str(path) + f'.{box[0]}-{box[1]}.png')
        with Image.open(path) as im:
            im.convert('RGB').crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.LANCZOS).save(crop)
        path = crop
    return re.sub(r'\s+', ' ', h.ocr(str(path)))


def count_rgb(path, rgb, tol=8, region=None):
    with Image.open(path) as im:
        im = im.convert('RGB')
        if region:
            im = im.crop(region)
        return sum(n for n, c in im.getcolors(1 << 24) if all(abs(a - b) <= tol for a, b in zip(c, rgb)))


def colorful(path, region=None):
    with Image.open(path) as im:
        im = im.convert('RGB')
        if region:
            im = im.crop(region)
        return len(set(im.resize((320, 180)).getdata()))


def save(path, name, box=None):
    if shots:
        if box:
            with Image.open(path) as im:
                im.crop(box).save(shots / name)
        else:
            (shots / name).write_bytes(Path(path).read_bytes())


# Live shots keep only the Defragmenting Memory dialog: the header, the
# process picker and the system strip show the host, not the owned fixture.
LIVE_BOX = (636, 72, 1910, 1040)


def index_of(pred):
    for i, c in enumerate(last_map['cells']):
        if pred(c):
            return i
    return None


vma_tag = {i: v for i, v in enumerate(last_map['vmas'])}
CACHE = index_of(lambda c: c.get('vma') is not None and (vma_tag[c['vma']].get('path') or '').endswith('secret-cache.db') and c.get('changed'))
SPLIT = index_of(lambda c: c.get('split'))
COLLAPSED = index_of(lambda c: c.get('collapsed'))
ZERO = index_of(lambda c: c.get('zero'))
UNKNOWN = index_of(lambda c: c.get('mapped') and not c.get('observed') and not c.get('gap'))
SECRETS = ('browser', 'secret-cache', '/home/demo', 'demo-host')
WIN9X = dict(desktop=(0, 128, 128), title=(0, 0, 128), thp=(0x18, 0x38, 0xd8), anon=(0, 0xd8, 0xd8), changed=(0x10, 0xd0, 0x10), split=(0xff, 0x10, 0x10))
DOS = dict(blue=(0, 0, 0xaa), grey=(0xaa, 0xaa, 0xaa), cyan=(0, 0xaa, 0xaa))

# 1. Every look at both sizes, redacted for the shot set; layout audit on every frame.
if 'looks' in sections or 'layout' in sections:
    for size in ((1920, 1080), (1280, 720)):
        for look in ('win9x', 'dos', 'modern'):
            d = Overview(['--pause', '--redact', '--panel', 'memory_map', '--look', look], size=size)
            try:
                shot = d.shot(f'{look}-{size[0]}')
                save(shot, f'{look}-{size[0]}x{size[1]}.png')
                check(f'{look} {size[0]}x{size[1]} renders', colorful(shot) > 30 and 'Draw failed' not in d.text(), d.text()[-300:])
                if look == 'win9x':
                    # The title strip alone as well: on the whole row its gradient reads differently per GPU.
                    found = {k: count_rgb(shot, c, 6) for k, c in WIN9X.items()}
                    check(f'win9x {size[0]} draws the desktop, title bar and cell colours, the change kinds distinct',
                          all(v > 20 for v in found.values()), found)
                    nav = 236 if size[0] >= 1500 else 196
                    text = ocr(shot) + ' ' + ocr(shot, (nav, 72, size[0], 108)) + ' ' + ocr(shot, (size[0] * 3 // 8, 72, size[0] - 80, 108)) + ' ' + ocr(shot, (size[0] // 2, size[1] - 200, size[0], size[1] - 28)) + ' ' + ocr(shot, (size[0] // 2, size[1] // 2, size[0], size[1])) + ' ' + ocr(shot, (nav, size[1] - 200, size[0], size[1] - 28))
                    want = ['Defragmenting Memory', 'Which process do you', 'Complete', 'Stop', 'Legend', 'Hide Details', 'cost-limited']
                    check(f'win9x {size[0]} chrome text', all(w.lower() in text.lower() for w in want), [w for w in want if w.lower() not in text.lower()] or text[:200])
                if look == 'dos':
                    found = {k: count_rgb(shot, c, 4) for k, c in DOS.items()}
                    check(f'dos {size[0]} uses the VGA palette', found['blue'] > size[0] * size[1] * 0.12 and found['grey'] > 500 and found['cyan'] > 500, found)
                    rows = d.rows()
                    want = ['Optimize  Analyze  Configure  Exit', 'Status', 'Legend', '% complete', 'Refresh 5.2 s (cost-limited)', 'recorded']
                    joined = '\n'.join(rows)
                    check(f'dos {size[0]} menu bar and status boxes', len(rows) == 25 and all(w in joined for w in want), [w for w in want if w not in joined] or joined[:200])
                    check(f'dos {size[0]} map has THP, 4K, unknown, r/W, collapse and split glyphs', all(g in joined for g in '█▓▒■≈') and ('W' in rows[9] + rows[10] or 'r' in rows[9] + rows[10]), rows[2:6])
                if look == 'modern':
                    nav = 236 if size[0] >= 1500 else 196
                    text = ocr(shot, (nav + 250, 52, size[0], size[1] - 28)) + ' ' + ocr(shot)
                    check(f'modern {size[0]} names coverage and the legend', 'coverage' in text.lower() and 'unmapped' in text.lower(), text[:200])
                lines = d.layout_lines()
                bad = [l for l in lines if 'overlaps=0 ' not in l]
                sized = [l for l in lines if f'layout {size[0]}x{size[1]} ' in l]
                check(f'{look} {size[0]}x{size[1]} has no overlapping labels', sized and not bad, bad[:2] or sized[-1:] or lines[-1:])
                leaks = [s for s in SECRETS if s in ocr(shot)]
                check(f'{look} {size[0]} redacted shot shows no names or paths', not leaks, leaks)
            finally:
                d.close()

# 2. Redaction of hover details: the file path shows only without --redact.
if 'redact' in sections:
    for redact in (False, True):
        d = Overview(['--pause', '--panel', 'memory_map', '--look', 'win9x', *(['--redact'] if redact else [])])
        try:
            d.tap('right')  # cursor on, so the grid geometry is printed
            d.move(*d.cell_xy(CACHE))
            shot = d.shot('hover-cache-' + ('redacted' if redact else 'plain'))
            text = ocr(shot, (0, d.size[1] - 30, d.size[0], d.size[1])) + ' ' + ocr(shot)
            if redact:
                check('redacted hover hides the path and the process name', 'secret-cache' not in text and 'browser' not in text and 'path hidden' in text, text[-400:])
                save(shot, 'win9x-hover-redacted.png')
            else:
                check('plain hover shows the mapping path, range and known bits', 'secret-cache' in text and '0x' in text and 'known' in text, text[-400:])
        finally:
            d.close()

# 3. Unknown is hatched, never a state; the three kinds of change are separate.
if 'states' in sections:
    d = Overview(['--pause', '--panel', 'memory_map', '--look', 'win9x', '--redact'])
    try:
        d.tap('right')
        for name, index, want in (('unknown', UNKNOWN, 'unknown'), ('split', SPLIT, 'split from THP'), ('collapsed', COLLAPSED, 'collapsed into THP'), ('changed', CACHE, 'changed this poll'), ('zero', ZERO, 'zero page, not yet backed')):
            x, y = d.cell_xy(index)
            d.move(x, y)
            shot = d.shot('hover-' + name)
            text = ocr(shot, (0, d.size[1] - 30, d.size[0], d.size[1]))
            check(f'hovering the {name} cell names it', want in text.lower() or want in text, text[:300])
            if name == 'unknown':
                # Hatching: both the light ground and the darker lines inside the cell.
                p = d.grid()['pitch'] / 2 - 1
                box = (int(x - p), int(y - p), int(x + p), int(y + p))
                light = count_rgb(shot, (0xb0, 0xb0, 0xb0), 10, box)
                dark = count_rgb(shot, (0x6a, 0x6a, 0x6a), 24, box)
                check('the unknown cell is hatched', light > 0 and dark > 0, (light, dark))
                save(shot, 'win9x-hover-unknown.png')
            if name == 'split':
                save(shot, 'win9x-hover-split.png')
    finally:
        d.close()
    d = Overview(['--pause', '--panel', 'memory_map', '--look', 'win9x', '--redact'], source=replays['fallback'])
    try:
        shot = d.shot('fallback')
        save(shot, 'win9x-fallback-unknown-coverage.png')
        text = ocr(shot)
        check('unknown denominator: "Coverage unknown", never 0 %', 'coverage unknown' in text.lower() and ' 0% complete' not in text.lower(), text[-300:])
        d.tap('t')
        shot = d.shot('fallback-dos')
        save(shot, 'dos-fallback-unknown-coverage.png')
        check('DOS fallback says coverage unknown', 'coverage unknown' in ocr(shot).lower())
    finally:
        d.close()
    d = Overview(['--pause', '--panel', 'memory_map', '--look', 'win9x', '--redact'], source=replays['system'])
    try:
        shot = d.shot('system')
        save(shot, 'win9x-system-free-blocks.png')
        text = ocr(shot)
        check('system view: contiguous free memory and kcompactd from vmstat', 'contiguous' in text.lower() and 'kcompactd' in text.lower(), text[-300:])
        d.tap('t')
        save(d.shot('system-dos'), 'dos-system-free-blocks.png')
    finally:
        d.close()

# 4. The buttons work: Legend, Hide Details, Pause, Stop; t cycles the looks.
if 'buttons' in sections:
    d = Overview(['--pause', '--panel', 'memory_map', '--look', 'win9x', '--redact'])
    try:
        shot = d.shot('buttons-before')
        boxes = {}
        # Buttons sit bottom-right of the dialog; find them by OCR word boxes.
        tsv = subprocess.run(['tesseract', str(shot), '-', 'tsv'], capture_output=True, text=True).stdout.splitlines()
        for row in tsv[1:]:
            f = row.split('\t')
            if len(f) == 12 and f[11].strip() in ('Stop', 'Resume', 'Legend', 'Hide'):
                boxes.setdefault(f[11].strip().replace('Resume', 'Pause'), (int(f[6]) + int(f[8]) // 2, int(f[7]) + int(f[9]) // 2))
        check('the four buttons are on screen', len(boxes) == 4, boxes)
        if len(boxes) == 4:
            d.click(*boxes['Legend'])
            shot = d.shot('legend')
            save(shot, 'win9x-legend.png')
            text = ocr(shot) + ' ' + ocr(shot, (d.size[0] // 4, d.size[1] // 4, 3 * d.size[0] // 4, 3 * d.size[1] // 4))
            check('Legend opens the legend dialog', 'not observable' in text and 'unknown' in text.lower() and 'split from THP' in text, text[:300])
            d.tap('g')
            d.click(*boxes['Hide'])
            shot = d.shot('compact')
            save(shot, 'win9x-compact.png')
            text = ocr(shot, (d.size[0] // 4, d.size[1] // 3, 3 * d.size[0] // 4, 2 * d.size[1] // 3))
            check('Hide Details shows the compact dialog', ('Show Details' in text or 'Complete' in text) and count_rgb(shot, WIN9X['anon'], 6) < 50, text[:200])
            d.tap('d')
            d.click(*boxes['Pause'])
            text = ocr(d.shot('resumed'))
            check('Resume (paused start) toggles to Pause', 'Pau' in text and 'Resume' not in text, text[-200:])
            d.click(*boxes['Stop'])
            shot = d.shot('stopped')
            text = ocr(shot)
            check('Stop leaves the process for the system view', 'Analyzing free memory' in text or 'Contiguous' in text, text[:300])
        d.tap('t')
        shot = d.shot('look-dos')
        check('t switches to the DOS look', count_rgb(shot, DOS['blue'], 4) > 200000)
        d.tap('o')
        shot = d.shot('dos-picker')
        save(shot, 'dos-select-process.png')
        check('o opens the DOS Select Process dialog', 'Select Process' in ocr(shot), '')
        d.tap('esc', 'g')
        shot = d.shot('dos-legend')
        save(shot, 'dos-legend.png')
        check('g opens the DOS legend (system view after Stop)', 'Buddy allocator counts' in '\n'.join(d.rows()))
        d.tap('esc', 't')
        shot = d.shot('look-modern')
        check('t switches to the modern look', count_rgb(shot, DOS['blue'], 4) < 1000 and count_rgb(shot, WIN9X['desktop'], 4) < 1000)
    finally:
        d.close()

# 5. Processes -> m opens the Memory map (replay explains it has no per-row maps).
if 'handoff' in sections:
    d = Overview(['--pause', '--panel', 'processes'])
    try:
        d.tap('m')
        shot = d.shot('handoff')
        text = ocr(shot)
        check('m on Processes opens the Memory map panel', 'Defragmenting Memory' in text and 'recorded per replay' in text, text[-300:])
    finally:
        d.close()

# 6. The deep map: replayed explicit viewports at 2 MiB, 64 KiB and 4 KiB.
MIB = 1 << 20
ARENA, HEAP = 0x7f3a00000000, 0x555555400000 + 16 * MIB
SPLIT_AT = ARENA + 37 * 2 * MIB      # the synthetic forced split (2 MiB block 37)
CACHE_AT = ARENA + 1024 * MIB + 2 * MIB  # the shared file mapping (path is private)
UNSCANNED_AT = ARENA + 1800 * MIB + 8 * MIB
ZERO_AT = HEAP + 40 * 2 * MIB        # read-faulted onto the huge zero page
OUTSIDE = (40, 30)                   # pointer parked on the header: keys zoom at the centre
if 'deep' in sections:
    CLUSTER = 2048 * MIB + 6 * 720 * 1024    # the arena through the last library
    REC4K = (ARENA + 64 * MIB, ARENA + 64 * MIB + 65536 * 4096)
    log2 = lambda x: x.bit_length() - 1
    for size in ((1920, 1080), (1280, 720)):
        tag = f'{size[0]}x{size[1]}'
        d = Overview(['--pause', '--redact', '--panel', 'memory_map', '--look', 'deep'], size=size, source=replays['deep'])
        try:
            d.move(*OUTSIDE)
            g = d.wait_deep(lambda g: g['count'] > 0)
            time.sleep(0.5)
            g = d.deep()
            fit_cell = min(c for c in (4096 << k for k in range(10)) if -(-CLUSTER // c) <= g['count'])
            shot = d.shot('deep-fit-' + tag)
            save(shot, f'deep-fit-{fit_cell // 1024}k-{tag}.png')
            check(f'deep {tag} renders the field', g and colorful(shot) > 30 and 'Draw failed' not in d.text(), d.text()[-300:])
            check(f'deep {tag} fit: the arena cluster whole at the finest cell size ({fit_cell // 1024} KiB), at most 65,536 cells',
                  g['cell'] == fit_cell and g['origin'] == ARENA and 30000 < g['count'] <= 65536, g)
            if size[0] == 1920:
                check('deep 1920x1080 draws more than 60,000 cells at once', g['count'] > 60000, g['count'])
            check(f'deep {tag} recorded view: nothing pending; unknown, collapse ring, split edge and changed cells all present',
                  g['pending'] == 0 and g['unknown'] > 0 and g['collapsed'] > 0 and g['split'] > 0 and g['changed'] > 0, g)
            lines = d.layout_lines()
            sized = [l for l in lines if f'layout {tag} ' in l]
            check(f'deep {tag} layout audit: no overlapping labels', sized and all('overlaps=0 ' in l for l in sized), sized[-1:] or lines[-1:])
            text = ocr(shot)
            leaks = [x for x in SECRETS if x in text]
            check(f'deep {tag} redacted shot shows no names or paths', not leaks, leaks)
            check(f'deep {tag} legend names the three change kinds apart', all(w in text for w in ('changed', 'collapse ring', 'split edge', 'pending', 'unknown')), text[-300:])
            # Hover: range, VMA, mapping (redacted), state bits, VMA NUMA totals.
            d.move(*d.deep_xy(CACHE_AT))
            det = d.deep_detail()
            shot = d.shot('deep-hover-cache-' + tag)
            save(shot, f'deep-hover-redacted-{tag}.png')
            text = ocr(shot)
            check(f'deep {tag} redacted hover: range and known bits, path hidden', '0x7f3a40' in det and 'known: present' in det and 'path hidden' in det and 'secret-cache' not in det and 'secret-cache' not in text, det)
            check(f'deep {tag} hover shows NUMA only as VMA totals', 'VMA totals (whole VMA, not per page)' in det and 'N1 150 MiB' in det and 'VMA totals' in text, det)
            # Click selects: the details stay when the pointer leaves; Esc clears.
            d.click(*d.deep_xy(SPLIT_AT))
            d.move(*OUTSIDE)
            det = d.deep_detail()
            check(f'deep {tag} click selects a cell and keeps its details', det.startswith('Selected 0x7f3a04a00000') and 'split from THP' in det, det)
            d.tap('esc')
            det = d.deep_detail()
            check(f'deep {tag} Esc clears the selection (and keeps the process)', det.startswith('Hover or click') and d.deep()['cell'] == g['cell'], det)
            d.move(*d.deep_xy(UNSCANNED_AT))
            det = d.deep_detail()
            check(f'deep {tag} unknown cell is named, not guessed', 'unknown: not observed' in det, det)
            p = d.deep()['pitch']
            x, y = d.deep_xy(UNSCANNED_AT + 16 * g['cell'])
            shot = d.shot('deep-unknown-' + tag)
            hatch = colorful(shot, (int(x - 4 * p), int(y - p / 2), int(x + 4 * p), int(y + p / 2)))
            check(f'deep {tag} unknown cells are hatched (two tones)', hatch >= 2, hatch)
            if size[0] == 1920:
                save(shot, 'deep-hover-unknown-1920x1080.png')
            d.move(*d.deep_xy(SPLIT_AT))
            det = d.deep_detail()
            check(f'deep {tag} split cell names the split', 'split from THP' in det, det)
            d.move(*d.deep_xy(ARENA + 470 * 2 * MIB + 4 * MIB))
            det = d.deep_detail()
            check(f'deep {tag} collapsed cell names the collapse', 'collapsed into THP' in det, det)
            # Zoom in at the split, anchored under the pointer, down to 4 KiB.
            sx, sy = d.deep_xy(SPLIT_AT)
            for _ in range(log2(g['cell'] // 4096)):
                d.keys('scroll', int(sx), int(sy), -1)
            g = d.wait_deep(lambda g: g['cell'] == 4096)
            check(f'deep {tag} wheel zooms to 4 KiB with the split block still under the pointer',
                  g['cell'] == 4096 and g['origin'] <= SPLIT_AT < g['origin'] + g['count'] * 4096 and abs(d.deep_xy(SPLIT_AT)[0] - sx) <= g['pitch'] + 1, g)
            end = g['origin'] + g['count'] * 4096
            expect = (max(0, end - REC4K[1]) + max(0, REC4K[0] - g['origin'])) // 4096
            check(f'deep {tag} 4 KiB: 512 split cells; exactly the unrecorded part pending ({expect} cells)', g['split'] == 512 and g['pending'] == expect, g)
            d.move(*d.deep_xy(SPLIT_AT + 4096 * 7))
            det = d.deep_detail()
            check(f'deep {tag} 4 KiB hover is one page', '(4 KiB)' in det and 'split from THP' in det, det)
            shot = d.shot('deep-4k-' + tag)
            save(shot, f'deep-4k-split-{tag}.png')
            if expect:
                d.move(*d.deep_xy(end - 3 * 4096))
                det = d.deep_detail()
                check(f'deep {tag} pending cell says not recorded, shows no data', 'pending' in det and 'not recorded' in det and 'mapped' not in det, det)
            # Back to the fit, then 2 MiB at the centre.
            d.move(*OUTSIDE)
            d.tap('n0')
            g = d.wait_deep(lambda g: g['cell'] == fit_cell)
            check(f'deep {tag} 0 fits the process again', g['cell'] == fit_cell and g['origin'] == ARENA, g)
            d.tap(*['minus'] * log2(2 * MIB // fit_cell))
            g = d.wait_deep(lambda g: g['cell'] == 2 * MIB)
            check(f'deep {tag} - zooms out to 2 MiB cells around the same place', g['cell'] == 2 * MIB and g['origin'] <= ARENA < g['origin'] + g['count'] * 2 * MIB, g)
            shot = d.shot('deep-2m-' + tag)
            save(shot, f'deep-2m-{tag}.png')
            box = [float(v) for v in g['box'].split('..')]
            check(f'deep {tag} 2 MiB: the minimap box spans the arena island', box[1] - box[0] > 20, g['box'])
            # Pan: a drag of 20 cells left moves the view 20 cells on; arrows pan too.
            d.tap('n0')
            g = d.wait_deep(lambda g: g['cell'] == fit_cell)
            x, y = d.deep_xy(ARENA + fit_cell * (g['cols'] * 10 + 40))
            d.keys('fastdrag', int(x), int(y), int(x - 20 * g['pitch']), int(y))
            g2 = d.wait_deep(lambda h: h['origin'] != g['origin'])
            check(f'deep {tag} drag pans by whole cells', g2['origin'] - g['origin'] == 20 * fit_cell, (hex(g['origin']), hex(g2['origin'])))
            d.move(*OUTSIDE)
            d.tap('down')
            g3 = d.wait_deep(lambda h: h['origin'] != g2['origin'])
            check(f'deep {tag} Down pans an eighth of the field', g3['origin'] - g2['origin'] == max(1, g3['rows'] // 8) * g3['cols'] * fit_cell, (hex(g2['origin']), hex(g3['origin'])))
            shot = d.shot('deep-pan-' + tag)
            save(shot, f'deep-pan-{tag}.png')
            # [ jumps VMA by VMA back to the heap (recorded at 64 KiB): the huge zero page is never THP.
            d.tap('n0')
            if fit_cell != 65536:
                d.tap(*['equal'] * log2(fit_cell // 65536))
            for _ in range(3):
                d.tap('bracketleft')
                g = d.wait_deep(lambda g: True)
                if g['origin'] < ARENA:
                    break
            check(f'deep {tag} [ jumps to the previous VMAs, down to the heap', g['origin'] == HEAP and g['cell'] == 65536 and g['zero'] > 0, g)
            d.move(*d.deep_xy(ZERO_AT + 65536 * 3))
            det = d.deep_detail()
            check(f'deep {tag} HUGE|ZERO cell reads zero page, never THP', 'zero page, not yet backed' in det and 'not THP' in det and 'THP, PMD-mapped' not in det, det)
            shot = d.shot('deep-heap-' + tag)
            save(shot, f'deep-heap-zero-{tag}.png')
            d.move(*OUTSIDE)
            d.tap('bracketright')
            g = d.wait_deep(lambda g: g['origin'] > HEAP)
            check(f'deep {tag} ] jumps forward again', g['origin'] > HEAP, g)
            # Minimap: a click on the low island centres the view there.
            mini = [float(v) for v in g['mini'].split(',')]
            d.click(mini[0] + 16, mini[1] + mini[3] / 2)
            g = d.wait_deep(lambda h: h['origin'] < 0x600000000000)
            check(f'deep {tag} minimap click moves the view to that island', g['origin'] < 0x600000000000, hex(g['origin']))
            # Pending: an unrecorded zoom (16 KiB) is all pending, never the old cells relabelled.
            d.move(*OUTSIDE)
            d.tap('n0')
            g = d.wait_deep(lambda g: g['cell'] == fit_cell)
            d.tap(*['equal'] * log2(fit_cell // 16384))
            g = d.wait_deep(lambda g: g['cell'] == 16384)
            check(f'deep {tag} unrecorded 16 KiB view is entirely pending', g['cell'] == 16384 and g['pending'] == g['count'], g)
            shot = d.shot('deep-pending-' + tag)
            save(shot, f'deep-pending-{tag}.png')
            text = ocr(shot)
            check(f'deep {tag} pending is labelled on screen', 'not recorded' in text.lower(), text[-200:])
            lines = [l for l in d.layout_lines() if f'layout {tag} ' in l]
            check(f'deep {tag} no overlapping labels across zooms and pans', lines and all('overlaps=0 ' in l for l in lines), lines[-2:])
            # t cycles deep -> win9x.
            d.tap('t')
            shot = d.shot('deep-cycle')
            check(f'deep {tag} t cycles on to the Windows 9x look', count_rgb(shot, WIN9X['desktop'], 4) > 1000 and d.app.poll() is None)
        finally:
            d.close()
    # Without --redact the mapping path shows in the hover details.
    d = Overview(['--pause', '--panel', 'memory_map', '--look', 'deep'], source=replays['deep'])
    try:
        d.move(*OUTSIDE)
        d.wait_deep(lambda g: g['count'] > 0)
        d.move(*d.deep_xy(CACHE_AT))
        det = d.deep_detail()
        shot = d.shot('deep-plain-hover')
        check('deep plain hover shows the mapping path', 'secret-cache.db' in det, det)
    finally:
        d.close()

# 6b. Frame cost (evidence; a property only when the host is not overloaded):
# continuous redraw (--frames) of the live owned fixture, modern vs deep, and
# optionally another build (--perf-binary, e.g. the parent) on the same fixture.
def measure(binary, look, pid, seconds=6, redraw=True):
    exe = str(binary)
    d = Overview(['--panel', 'memory_map', '--look', look, '--redact', '--memmap-pid', str(pid), *(['--frames', '100000'] if redraw else [])], replay=False,
                 env_extra={'XODB_MEMMAP_PERF': '1'}, binary=exe)
    try:
        d.move(*OUTSIDE)
        app = d.app.pid
        def cpu_rss():
            f = open(f'/proc/{app}/stat').read().rsplit(')', 1)[1].split()
            rss = int(re.search(r'VmRSS:\s+(\d+)', open(f'/proc/{app}/status').read()).group(1))
            return (int(f[11]) + int(f[12])) / os.sysconf('SC_CLK_TCK'), rss
        time.sleep(4)  # first publications and the 4 KiB-free fit settle
        mark = len(d.text())
        c0, r0 = cpu_rss()
        t0 = time.monotonic()
        peak = r0
        while time.monotonic() - t0 < seconds:
            time.sleep(0.5)
            peak = max(peak, cpu_rss()[1])
        c1, r1 = cpu_rss()
        t1 = time.monotonic()
        lines = re.findall(r'memmap perf look=(\w+) frames=(\d+) fps=([\d.]+) cells=(\d+) frame_cpu_ms_avg=([\d.]+) frame_cpu_ms_max=([\d.]+) builds=(\d+)', d.text()[mark:])
        g = d.deep() if look == 'deep' else None
        return dict(binary='this build' if exe == str(root / 'zig-out/bin/xodb') else 'other build', look=look, redraw='continuous' if redraw else 'on change', cpu_pct=round((c1 - c0) * 100 / (t1 - t0), 2),
                    rss_mib=round(r1 / 1024, 1), rss_peak_mib=round(peak / 1024, 1), perf=lines, cells=g['count'] if g else None, load=os.getloadavg())
    finally:
        d.close()


if 'perf' in sections:
    exe = work / 'memdefrag-fixture'
    if not exe.exists():
        subprocess.run(['cc', '-O2', '-o', str(exe), 'tests/memdefrag-fixture.c'], check=True)
    fx = subprocess.Popen([str(exe), str(args.mib)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    try:
        json.loads(fx.stdout.readline())
        fx.stdin.write('collapse\n')
        fx.stdout.readline()
        runs = []
        for redraw in (False, True):
            if args.perf_binary:
                runs.append(measure(args.perf_binary, 'modern', fx.pid, redraw=redraw))
            runs.append(measure(root / 'zig-out/bin/xodb', 'modern', fx.pid, redraw=redraw))
            runs.append(measure(root / 'zig-out/bin/xodb', 'deep', fx.pid, redraw=redraw))
    finally:
        fx.stdin.write('quit\n')
        fx.stdin.flush()
        fx.wait(timeout=10)
    for r in runs:
        print('perf', json.dumps(r), flush=True)
    (work / 'perf.json').write_text(json.dumps(runs, indent=2) + '\n')
    deep = runs[-1]
    load = os.getloadavg()[0]
    if load > os.cpu_count():
        check('deep frame cost: not measurable (host overloaded)', True, dict(load=load))
    else:
        fps = [float(x[2]) for x in deep['perf']]
        cpu = [float(x[5]) for x in deep['perf']]
        check('deep live field at 1920x1080: over 60,000 cells at 60 fps, every frame under 16.7 ms CPU',
              deep['cells'] and deep['cells'] > 60000 and fps and min(fps) >= 55 and max(cpu) < 16.7, deep)

# 7. Live: an owned 1 GiB MADV_HUGEPAGE fixture collapses step by step, then splits.
if 'live' in sections:
    exe = work / 'memdefrag-fixture'
    subprocess.run(['cc', '-O2', '-o', str(exe), 'tests/memdefrag-fixture.c'], check=True)
    fx = subprocess.Popen([str(exe), str(args.mib)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    try:
        ready = json.loads(fx.stdout.readline())
        check('fixture ready with 4 KiB pages under MADV_HUGEPAGE', ready['phase'] == 'ready' and ready['rc'] == 0, ready)
        d = Overview(['--panel', 'memory_map', '--look', 'win9x', '--redact', '--memmap-pid', str(fx.pid)], replay=False)
        try:
            time.sleep(2.5)
            first = d.shot('live-0')
            save(first, 'live-win9x-0-before.png', LIVE_BOX)
            pct = lambda t: int(m.group(1)) if (m := re.search(r'(\d+)% Complete', t)) else None
            seen = [pct(ocr(first, LIVE_BOX))]
            for step in range(4):
                fx.stdin.write('collapse\n')
                reply = json.loads(fx.stdout.readline())
                # ENOMEM is the kernel finding no free huge page now; partial collapse still counts.
                check(f'fixture collapse step {step + 1} (MADV_COLLAPSE rc 0 or ENOMEM)', reply['rc'] == 0 or reply['errno'] == 12, reply)
                # Cheap huge maps refresh at 1 Hz; wait out a cost-limited period too.
                deadline = time.monotonic() + 9
                while True:
                    time.sleep(1.2)
                    shot = d.shot(f'live-{step + 1}')
                    now_pct = pct(ocr(shot, LIVE_BOX))
                    if (now_pct is not None and now_pct > (seen[-1] or 0)) or time.monotonic() > deadline:
                        break
                seen.append(now_pct)
                save(shot, f'live-win9x-{step + 1}-collapse.png', LIVE_BOX)
            known = [p for p in seen if p is not None]
            check('live coverage rises step by step as the fixture collapses', len(known) == len(seen) and known == sorted(known) and known[0] < known[-1], seen)
            fx.stdin.write('split\n')
            fx.stdout.readline()
            # The highlight lasts one publication (about a second when cheap): sample it.
            found = 0
            deadline = time.monotonic() + 8
            k = 0
            while time.monotonic() < deadline and not found:
                time.sleep(0.3)
                shot = d.shot(f'live-split-{k}')
                k += 1
                found = count_rgb(shot, WIN9X['split'], 6)
            save(shot, 'live-win9x-split.png', LIVE_BOX)
            check('live split shows the red-edge highlight', found > 10, found)
            fx.stdin.write('quit\n')
            fx.stdin.flush()
            fx.wait(timeout=10)
            expected = f'Process {fx.pid} exited'
            deadline = time.monotonic() + 30
            text = ''
            while time.monotonic() < deadline and expected.lower() not in text.lower():
                time.sleep(0.2)
                shot = d.shot('live-exited')
                text = ocr(shot, LIVE_BOX)
            check('live reaped target shows Process N exited', expected.lower() in text.lower(), text)
            save(shot, 'live-win9x-exited.png', LIVE_BOX)
        finally:
            d.close()
    finally:
        if fx.poll() is None:
            fx.stdin.write('quit\n')
            fx.stdin.flush()
        try:
            fx.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fx.kill()
            fx.wait()

# 8. Live deep map: the owned 1 GiB fixture collapses, the deep map zooms to
# 4 KiB at its first huge block, then the fixture splits that block.
DEEP_BOX = (596, 60, 1910, 1040)  # the map panel only: the side lists show the host
if 'deeplive' in sections:
    exe = work / 'memdefrag-fixture'
    if not exe.exists():
        subprocess.run(['cc', '-O2', '-o', str(exe), 'tests/memdefrag-fixture.c'], check=True)
    fx = subprocess.Popen([str(exe), str(args.mib)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    try:
        ready = json.loads(fx.stdout.readline())
        base_at = int(ready['start'], 16)
        fx.stdin.write('collapse\n')
        reply = json.loads(fx.stdout.readline())
        check('deep live: fixture collapses its first quarter (rc 0 or ENOMEM)', ready['rc'] == 0 and (reply['rc'] == 0 or reply['errno'] == 12), reply)
        d = Overview(['--panel', 'memory_map', '--look', 'deep', '--redact', '--memmap-pid', str(fx.pid)], replay=False)
        try:
            d.move(*OUTSIDE)
            g = d.wait_deep(lambda g: g['count'] > 0 and g['pending'] < g['count'] and g['origin'] <= base_at < g['origin'] + g['count'] * g['cell'], 20)
            check('deep live: the view fits the fixture and samples it', g and g['origin'] <= base_at < g['origin'] + g['count'] * g['cell'] and g['pending'] < g['count'], g)
            shot = d.shot('deep-live-fit')
            save(shot, 'live-deep-0-fit.png', DEEP_BOX)
            text = ocr(shot, DEEP_BOX)
            check('deep live: refresh cadence and data age are shown', 'Refresh' in text and 'age' in text, text[:300])
            # Zoom to 4 KiB with the fixture's first huge block under the pointer.
            sx, sy = d.deep_xy(base_at)
            log2 = lambda x: x.bit_length() - 1
            for _ in range(log2(g['cell'] // 4096)):
                d.keys('scroll', int(sx), int(sy), -1)
            g = d.wait_deep(lambda g: g['cell'] == 4096 and g['pending'] == 0, 20)
            check('deep live: 4 KiB viewport requested and sampled (pending clears)', g['cell'] == 4096 and g['pending'] == 0 and g['origin'] <= base_at, g)
            probe = base_at + 3 * 4096
            d.move(*d.deep_xy(probe))
            time.sleep(0.4)
            before = d.deep_detail()
            check('deep live: the first block is THP at 4 KiB before the split', 'THP, PMD-mapped' in before or 'collapsed into THP' in before, before)
            shot = d.shot('deep-live-4k-before')
            save(shot, 'live-deep-1-4k-before-split.png', DEEP_BOX)
            seen = len(d.text())
            fx.stdin.write('split\n')
            split_reply = json.loads(fx.stdout.readline())
            check('deep live: the fixture splits its first huge block (mprotect one page)', split_reply['rc'] == 0, split_reply)
            # One publication carries the split edge; then the block reads 4 KiB.
            deadline = time.monotonic() + 15
            edge = None
            after = ''
            k = 0
            while time.monotonic() < deadline:
                time.sleep(0.25)
                new = d.text()[seen:]
                hit = re.findall(r'memmap deep x=.* split=(\d+)', new)
                if edge is None and any(int(x) > 0 for x in hit):
                    edge = d.shot(f'deep-live-split-{k}')
                    k += 1
                after = d.deep_detail()
                if edge is not None and 'THP, PMD-mapped' not in after and 'split from THP' not in after:
                    break
            check('deep live: the split shows as a split edge for one publication', edge is not None, re.findall(r'split=\d+', d.text()[seen:])[-5:])
            if edge is not None:
                save(edge, 'live-deep-2-4k-split-edge.png', DEEP_BOX)
            check('deep live: afterwards the probed page reads 4 KiB, not THP', '4 KiB anonymous' in after and 'THP, PMD-mapped' not in after, after)
            shot = d.shot('deep-live-4k-after')
            save(shot, 'live-deep-3-4k-after-split.png', DEEP_BOX)
            leaks = [x for x in ('memdefrag-fixture', str(work)) if x in ocr(shot, DEEP_BOX)]
            check('deep live: redacted (no fixture name or path)', not leaks, leaks)
        finally:
            d.close()
    finally:
        if fx.poll() is None:
            fx.stdin.write('quit\n')
            fx.stdin.flush()
        try:
            fx.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fx.kill()
            fx.wait()

(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
failed = [r for r in results if not r['ok']]
print(f'memdefrag-gui: {len(results) - len(failed)}/{len(results)} checks passed; {work}')
sys.exit(1 if failed else 0)
