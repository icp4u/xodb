#!/usr/bin/env python3
"""Fast GUI lane: Win95 chrome, menus, font switching and modal input.

--all-panels is periodic: retain synthetic screenshots for every panel and size.
Only a private headless compositor is used. Evidence stays in .work.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--all-panels', action='store_true')
args = parser.parse_args()
started = time.monotonic()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-w95-' + str(time.time_ns())[-8:])
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
replay = work / 'replay.jsonl'
subprocess.run(['python3', '-B', 'tests/fixtures/overview-synth.py', str(replay), '--frames', '150'], check=True)
if args.all_panels:
    mapped = work / 'mapped.jsonl'
    subprocess.run(['python3', '-B', 'tests/fixtures/memmap-synth.py', str(replay), str(mapped), '--scenario', 'process'], check=True)
    replay = mapped
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
results = []

def check(name, ok):
    results.append({'name': name, 'ok': bool(ok)})
    if not ok:
        raise AssertionError(name)
    print('PASS ' + name, flush=True)

def until(fn, label):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not d.alive():
            raise RuntimeError(d.tail())
        if fn():
            return
        time.sleep(.025)  # condition polling only
    raise TimeoutError(label + ': ' + d.tail())

def send(*commands):
    code = d.keys(*commands, wait=False).wait(timeout=10)
    if code:
        raise RuntimeError('private input helper exit ' + str(code))

def log():
    return Path(d.log).read_text(errors='replace')

def pixel(name, xy, expected):
    with Image.open(d.shot(name)) as im:
        return im.convert('RGB').getpixel(xy) == expected

# Marks the bundled bitmap face gained, as its 8x16 cell rows (see src/render/font.zig).
CHECK = [0] * 4 + [0x03, 0x06, 0x06, 0x0C, 0xCC, 0x78, 0x78, 0x30] + [0] * 4
DOWN = [0] * 6 + [0x7C, 0x7C, 0x38, 0x38, 0x10] + [0] * 5

def glyph(name, rows, box):
    """True when one text cell in `box` shows exactly this bitmap in a single ink colour."""
    ink = [(x, y) for y, row in enumerate(rows) for x in range(8) if row & (0x80 >> x)]
    blank = [(x, y) for y in range(16) for x in range(8) if (x, y) not in set(ink)]
    with Image.open(d.shot(name)) as im:
        px = im.convert('RGB').load()
    for top in range(box[1], box[3] - 16):
        for left in range(box[0], box[2] - 8):
            colour = px[left + ink[0][0], top + ink[0][1]]
            if all(px[left + x, top + y] == colour for x, y in ink) and all(px[left + x, top + y] != colour for x, y in blank):
                return True
    return False

def resize(width, height):
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', f'{width}x{height}'], env=d.env, check=True, capture_output=True, timeout=5)
    d.width, d.height = width, height  # the pointer helper scales to the output
    def settled():
        with Image.open(d.shot('resize')) as im:
            return im.size == (width, height) and im.convert('RGB').getpixel((2, height - 60)) == (0, 128, 128)
    until(settled, f'window follows the {width}x{height} output')

def near(name, xy, expected, slack=4):
    """A gradient pixel: each channel within `slack` of `expected`."""
    with Image.open(d.shot(name)) as im:
        return all(abs(a - b) <= slack for a, b in zip(im.convert('RGB').getpixel(xy), expected))

panels = ['summary', 'performance', 'processes', 'memory', 'disk', 'disk_space', 'network',
          'connections', 'power', 'system', 'users', 'services', 'apps', 'files', 'memory_map', 'graph', 'galaxy', 'inheritance', 'treemap']
sizes = [(1280, 720), (1920, 1080)] if args.all_panels else [(1280, 720)]
try:
    for width, height in sizes:
        d = h.Display(str(root), ['--overview', '--look', 'win95', '--pause', '--redact', '--replay', str(replay)],
                      stdio=False, trace=False, output_size=(width, height))
        try:
            until(lambda: 'panel=summary' in log(), 'initial frame')
            until(lambda: pixel('summary', (2, 100), (0, 128, 128)), 'teal desktop')
            check('teal desktop and visible overview at ' + str(width), True)
            check('nav raised bevel', pixel('bevel', (17, 74), (128, 128, 128)))
            # Menus swallow q and execute the selected item through the same action path.
            send('tap', 68, 'tap', 16, 'tap', 108, 'tap', 28)  # F10 q Down Enter
            until(lambda: 'panel=processes' in log(), 'menu selects Processes')
            check('menu consumes quit shortcut and opens Processes', d.alive())
            # Processes opens in tree mode. Its marks come from the bundled face;
            # a missing glyph would be a box.
            until(lambda: glyph('tree-chip', CHECK, (200, 90, width - 8, 260)), 'tree chip check mark')
            check('tree chip shows a check mark, not a missing-glyph box', True)
            check('tree rows show expander triangles', glyph('tree-rows', DOWN, (200, 130, width - 40, height - 60)))
            def first_row():
                with Image.open(d.shot('scroll-row')) as im:
                    return im.crop((230, 177, 700, 210)).tobytes()
            before_scroll = first_row()
            send('fastdrag', width - 32, 200, width - 32, 440, 'm', 2, 100)
            until(lambda: first_row() != before_scroll, 'scrollbar moves process rows')
            check('dragging the scrollbar scrolls actual process rows', True)
            # A narrow window slides the Help pull-down left; its row stays clickable.
            resize(262, 400)
            send('click', 244, 49, 'click', 120, 79)
            until(lambda: near('narrow-about', (5, 90), (0, 0, 128)), 'Help row opens About in a 262 px window')
            check('Help pull-down stays on-screen and usable in a narrow window', d.alive())
            send('tap', 1)
            resize(width, height)
            # The compositor owns maximize; one that declines it must leave the window as it was.
            send('click', width - 51, 23)
            until(lambda: pixel('maximize', (2, 100), (0, 128, 128)) and pixel('maximize', (width - 3, height - 60), (0, 128, 128)), 'window intact after maximize request')
            check('caption maximize follows the compositor', d.alive())
            # Return via taskbar and cycle the embedded atlas out and back in.
            send('click', 150, height - 20, 'tap', 20)
            until(lambda: not pixel('smooth-font', (2, 100), (0, 128, 128)), 'leave classic theme')
            send(*[x for _ in range(6) for x in ('tap', 20)])
            until(lambda: pixel('bitmap-restored', (2, 100), (0, 128, 128)), 'restore bitmap theme')
            check('theme cycle replaces and restores glyph atlas', True)
            # Help is a modal; q cannot fall through to the application.
            send('click', 245, 49, 'click', 270, 77, 'tap', 16)
            until(lambda: pixel('about', (width // 2 - 275, height // 2 - 110), (0, 0, 128)), 'about dialog')
            check('help dialog consumes quit shortcut', d.alive())
            send('tap', 1)
            if args.all_panels:
                for i, panel in enumerate(panels):
                    previous = len(log())
                    send('click', 80, 84 + i * 29, 'm', 2, 100)
                    if panel != 'summary':
                        until(lambda p=panel, n=previous: 'panel=' + p + ' ' in log()[n:], 'panel ' + panel)
                    shot = d.shot(panel)
                    with Image.open(shot) as im:
                        check(f'{width} {panel} captured', im.size == (width, height))
            if args.all_panels:
                # Only this output size: the narrow-window step above is not a layout target.
                layout = [line for line in log().splitlines() if f'overview layout {width}x{height} ' in line]
                # The layout probe also records unavailable-data panels; no hidden live reads.
                bad = [line for line in layout if 'overlaps=0 ' not in line]
                (Path(d.dir) / 'layout-findings.json').write_text(json.dumps(bad, indent=2))
                check('no label collisions at ' + str(width), not bad)
            check('no draw failure or panic' , all(word not in log() for word in ('Draw failed', 'frame failed', 'panic:')))
            send('click', width - 27, 23)
            check('caption close exits cleanly', d.app.wait(timeout=5) == 0)
        finally:
            d.close()
    if args.all_panels:
        import sys
        import re
        fixture_dir = work / 'owned'
        fixture_dir.mkdir()
        fixture_code = """import os, socket, sys, json
files=[open('owned-%d' % i,'w+b') for i in range(48)]
pair=socket.socketpair(); pipe=os.pipe(); control=os.pipe(); children=[]
for i in range(2):
    pid=os.fork()
    if pid==0:
        os.close(control[1]);os.read(control[0],1);os._exit(0)
    children.append(pid)
os.close(control[0]);print(json.dumps(children),flush=True)
sys.stdin.readline();os.close(control[1])
for child in children:
    _,status=os.waitpid(child,0)
    if status: raise SystemExit(1)
"""
        fixture = subprocess.Popen([sys.executable, '-c', fixture_code], cwd=fixture_dir,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        d = None
        try:
            pids = json.loads(fixture.stdout.readline())
            os.environ['XODB_OVERVIEW_AUDIT'] = '1'
            options = ['--overview', '--look', 'win95', '--redact', '--panel', 'galaxy']
            for pid in pids:
                options += ['--graph-pid', str(pid)]
            d = h.Display(str(root), options, stdio=False, trace=False, output_size=(1280, 720))
            until(lambda: bool(re.search(r'fdgraph sequence=[2-9].*processes=2 ', log())), 'owned descriptors published')
            d.shot('owned-galaxy')
            check('galaxy collects only the two owned processes', 'scope_count=2' in log())
            send('click', 80, 84 + 15 * 29, 'm', 2, 100)
            until(lambda: 'panel=graph' in log(), 'owned graph')
            def star_label_clear():
                """The row above the label text is plate-coloured: no link or dot runs through it."""
                shot = d.shot('owned-graph')
                stars = re.findall(r'fdgraph-star panel=graph star=0 pid=\d+ x=([\d.]+) y=([\d.]+)', log())
                if not stars:
                    return False
                x, y = (round(float(value)) for value in stars[-1])
                with Image.open(shot) as im:
                    px = im.convert('RGB').load()
                return all(px[i, y + 17] == (192, 192, 192) for i in range(x - 60, x + 60))
            until(star_label_clear, 'graph star label plate')
            check('classic graph star label is clear of the links under it', True)
            send('click', 80, 84 + 17 * 29, 'm', 2, 100)
            until(lambda: bool(re.search(r'fdinherit sequence=[1-9].*scope_count=2', log())), 'owned inheritance')
            d.shot('owned-inheritance')
            check('classic Parent/Child samples the owned scope', True)
            send('click', 80, 84 + 18 * 29, 'm', 2, 100)
            until(lambda: bool(re.search(r'fdtreemap sequence=[1-9]\d* .*fds=[1-9].*scope_count=2', log())), 'owned treemap')
            d.shot('owned-treemap')
            check('classic Treemap shows owned descriptors', True)
            d.close()
            d = h.Display(str(root), ['--overview', '--look', 'win95', '--redact', '--files-pid', str(pids[0])], stdio=False, trace=False, output_size=(1280, 720))
            until(lambda: bool(re.search(r'files collector .*filter_pid=' + str(pids[0]) + r' .*rows=[1-9]', log())), 'owned Files')
            d.shot('owned-files')
            check('Files contains owned live rows', True)
            send('tap', 18)  # E: confirmation only; never activate capture.
            until(lambda: pixel('owned-confirmation', (195, 225), (0, 0, 128)), 'classic confirmation')
            check('classic cost confirmation is visible', True)
            send('tap', 1)
        finally:
            if d:
                d.close()
            if fixture.poll() is None:
                fixture.stdin.write('done\n')
                fixture.stdin.flush()
            fixture.wait(timeout=10)
            check('owned fixture and children exit cleanly', fixture.returncode == 0)
finally:
    report = {'lane': 'periodic' if args.all_panels else 'fast', 'seconds': time.monotonic() - started, 'checks': results}
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'work': str(work), 'seconds': report['seconds']}), flush=True)
