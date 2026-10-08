#!/usr/bin/env python3
"""The overview's Memory map panel on a private headless display.

Synthetic replays (tests/fixtures/memmap-synth.py) give deterministic
screenshots of the three looks (Windows 9x Defrag, MS-DOS DEFRAG, modern) at
1920x1080 and 1280x720, the layout audit (no label overlaps), redaction,
unknown/hatched states, the three kinds of change, the working buttons, and
the Processes -> Memory map hand-off. With --live it also maps an owned
fixture that madvise(MADV_HUGEPAGE)s 1 GiB, collapses it step by step and
forces a split. --shots DIR saves the screenshots.
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
parser.add_argument('--only', help='comma-separated sections: looks,layout,redact,states,buttons,handoff,live')
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
last_map = json.loads(replays['process'].read_text().splitlines()[-1])['memory_map']
results = []
KEY = dict(h.KEY, n3=4, t=20, p=25, d=32, g=34, m=50, o=24, x=45, enter=28, esc=1, down=108, up=103, right=106, left=105,
           pgdn=109, pgup=104, minus=12, equal=13, bracketright=27, bracketleft=26)
sections = set((args.only or 'looks,layout,redact,states,buttons,handoff' + (',live' if args.live else '')).split(','))
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

    def __init__(self, options, size=(1920, 1080), source=None, env_extra=None, replay=True):
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
        self.app = subprocess.Popen([str(root / 'zig-out/bin/xodb'), '--overview', *source_args, *options], cwd=root, env=app_env,
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
                    found = {k: count_rgb(shot, c, 6) for k, c in WIN9X.items()}
                    check(f'win9x {size[0]} draws the desktop, title bar and cell colours, the change kinds distinct',
                          all(v > 20 for v in found.values()), found)
                    nav = 236 if size[0] >= 1500 else 196
                    text = ocr(shot) + ' ' + ocr(shot, (nav, 72, size[0], 108)) + ' ' + ocr(shot, (size[0] // 2, size[1] - 200, size[0], size[1] - 28))
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
            text = ocr(shot)
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

# 6. Live: an owned 1 GiB MADV_HUGEPAGE fixture collapses step by step, then splits.
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

(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
failed = [r for r in results if not r['ok']]
print(f'memdefrag-gui: {len(results) - len(failed)}/{len(results)} checks passed; {work}')
sys.exit(1 if failed else 0)
