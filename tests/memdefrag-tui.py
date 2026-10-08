#!/usr/bin/env python3
"""`xodb --memdefrag`: the DOS DEFRAG terminal view.

Synthetic replays give exact 80x25 captures (text and ANSI, rendered to PNG
with --shots); the owned fixture (tests/memdefrag-fixture.c) maps 1 GiB with
4 KiB pages under MADV_HUGEPAGE, collapses it a quarter at a time and forces
a split while `--json --stream` records each publication: coverage rises and
the split cell is marked as a PMD split, not as a page-state change.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--shots', type=Path, help='save captures (txt, ansi, png) here')
parser.add_argument('--mib', type=int, default=1024)
parser.add_argument('--no-live', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('memdefrag-tui-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
xodb = str(root / 'zig-out/bin/xodb')
results = []
shots = args.shots.resolve() if args.shots else None
if shots:
    shots.mkdir(parents=True, exist_ok=True)


def check(name, ok, detail=''):
    results.append({'check': name, 'ok': bool(ok), 'detail': str(detail)[:600]})
    print(('ok   ' if ok else 'FAIL ') + name + (': ' + str(detail)[:300] if detail else ''), flush=True)
    return ok


def run(*a, env=None, timeout=120):
    e = dict(os.environ)
    # Colour capability cases must not inherit the runner's colour preference.
    e.pop('NO_COLOR', None)
    e.pop('COLORTERM', None)
    e.update(env or {})
    return subprocess.run([xodb, '--memdefrag', *a], capture_output=True, text=True, timeout=timeout, env=e)


SGR = re.compile(r'\x1b\[([0-9;]*)m')
VGA16 = [(0, 0, 0), (0xaa, 0, 0), (0, 0xaa, 0), (0xaa, 0x55, 0), (0, 0, 0xaa), (0xaa, 0, 0xaa), (0, 0xaa, 0xaa), (0xaa, 0xaa, 0xaa)]
BRIGHT = [(0x55, 0x55, 0x55), (0xff, 0x55, 0x55), (0x55, 0xff, 0x55), (0xff, 0xff, 0x55), (0x55, 0x55, 0xff), (0xff, 0x55, 0xff), (0x55, 0xff, 0xff), (0xff, 0xff, 0xff)]


def render_png(ansi, path):
    """Paints an ANSI capture as the terminal would: 10x20 cells, VGA colours."""
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSansMono.ttf', 17)
    lines = ansi.split('\n')[:25]
    im = Image.new('RGB', (800, 500), (0, 0, 0))
    dr = ImageDraw.Draw(im)
    for y, line in enumerate(lines):
        fg, bg, x, pos = (0xaa, 0xaa, 0xaa), (0, 0, 0), 0, 0
        for m in list(SGR.finditer(line)) + [None]:
            text = line[pos:m.start() if m else len(line)]
            for ch in text:
                dr.rectangle([x * 10, y * 20, x * 10 + 9, y * 20 + 19], fill=bg)
                if ch in '█':
                    dr.rectangle([x * 10, y * 20, x * 10 + 9, y * 20 + 19], fill=fg)
                elif ch != ' ':
                    dr.text((x * 10, y * 20), ch, font=font, fill=fg)
                x += 1
            if not m:
                break
            pos = m.end()
            codes = [int(c) for c in m.group(1).split(';') if c] or [0]
            i = 0
            while i < len(codes):
                c = codes[i]
                if c == 0:
                    fg, bg = (0xaa, 0xaa, 0xaa), (0, 0, 0)
                elif c in (38, 48) and i + 4 < len(codes) and codes[i + 1] == 2:
                    rgb = tuple(codes[i + 2:i + 5])
                    fg, bg = (rgb, bg) if c == 38 else (fg, rgb)
                    i += 4
                elif 30 <= c <= 37:
                    fg = VGA16[c - 30]
                elif 90 <= c <= 97:
                    fg = BRIGHT[c - 90]
                elif 40 <= c <= 47:
                    bg = VGA16[c - 40]
                elif 100 <= c <= 107:
                    bg = BRIGHT[c - 100]
                i += 1
    im.save(path)


replays = {}
for scenario in ('process', 'fallback', 'system', 'exited'):
    replays[scenario] = work / f'{scenario}.jsonl'
    subprocess.run([sys.executable, '-B', 'tests/fixtures/memmap-synth.py', '--bare', str(replays[scenario]), '--scenario', scenario], check=True)

# 1. Replays: exact 80x25 frames.
for scenario in ('process', 'fallback', 'system'):
    r = run('--once', '--replay', str(replays[scenario]), '--redact')
    lines = r.stdout.split('\n')[:-1]
    check(f'{scenario}: --once prints 25 rows of at most 80 columns', r.returncode == 0 and len(lines) == 25 and all(len(l) <= 80 for l in lines), (r.returncode, len(lines), r.stderr[-200:]))
    text = r.stdout
    check(f'{scenario}: DOS menu bar, frame, status and legend boxes', 'Optimize  Analyze  Configure  Exit' in lines[0] and lines[1].startswith('╔') and '─ Status ─' in lines[18] and '─ Legend ─' in lines[18], lines[:2])
    if scenario == 'process':
        check('process: coverage as % complete and the cost-limited refresh shown', '% complete' in text and 'Refresh 5.2 s (cost-limited)' in text, lines[19:23])
        check('process: THP, 4K, unknown, unmovable, compressed gap and r/W glyphs', all(g in text for g in '█▓▒■≈') and re.search(r'[rW]', ''.join(lines[2:17])), lines[2:6])
        check('process: activity is system-wide vmstat, with its counter delta', 'System: Collapsing huge pages... +8' in text, lines[22])
        check('process: redacted name shows as an alias', 'browser' not in text and 'proc-' in lines[1], lines[1])
    if scenario == 'fallback':
        check('fallback: unknown coverage, never 0 %', 'coverage unknown' in text and ' 0% complete' not in text and '▒' * 20 in text, lines[21])
    if scenario == 'system':
        check('system: free memory by block size, contiguity and kcompactd', 'contiguous' in text and 'kcompactd compacting' in text and 'positions need privilege' in text, lines[19:23])
    if shots:
        (shots / f'tui-{scenario}-80x25.txt').write_text(text)
    for depth, env in (('16', {'TERM': 'xterm'}), ('truecolor', {'TERM': 'xterm', 'COLORTERM': 'truecolor'})):
        a = run('--once', '--ansi', '--replay', str(replays[scenario]), '--redact', env=env)
        if depth == 'truecolor':
            check(f'{scenario}: truecolor capture uses the VGA blue 0x0000aa', '48;2;0;0;170' in a.stdout, a.stdout[:120])
            if shots:
                (shots / f'tui-{scenario}-80x25.ansi').write_text(a.stdout)
                render_png(a.stdout, shots / f'tui-{scenario}-80x25.png')
        else:
            check(f'{scenario}: 16-colour capture maps VGA blue to ANSI 44', '\x1b[' in a.stdout and ';44m' in a.stdout, a.stdout[:80])
ex = run('--once', '--replay', str(replays['exited']))
check('exited process says so (not "unavailable") and draws no cells', 'Process 3100 exited' in ex.stdout and 'unavailable' not in ex.stdout.split('\n')[9], ex.stdout.split('\n')[9])
zero = run('--json', '--replay', str(replays['process']))
zc = [c for c in json.loads(zero.stdout)['cells'] if c.get('zero')]
check('HUGE|ZERO cells carry zero bytes and no huge bytes', zc and all(c['huge'] == 0 for c in zc), len(zc))
plain = run('--once', '--ansi', '--theme', 'plain', '--replay', str(replays['process']))
check('plain theme: no colour codes, reverse video only', '38;' not in plain.stdout and ';44m' not in plain.stdout and '\x1b[7m' in plain.stdout, plain.stdout[:120])
no_color = run('--once', '--ansi', '--replay', str(replays['process']), env={'COLORTERM': 'truecolor', 'NO_COLOR': '1'})
check('NO_COLOR suppresses colour in an ANSI capture but keeps plain attributes', '38;' not in no_color.stdout and ';44m' not in no_color.stdout and '\x1b[7m' in no_color.stdout, no_color.stdout[:120])
js = run('--json', '--replay', str(replays['process']), '--redact')
m = json.loads(js.stdout)
check('--json --redact replay: schema, no name, no file paths', m['schema'] == 'xodb-memdefrag/1' and m['process']['name'] is None and
      all(v['path'] is None or v['path'].startswith('[') for v in m['vmas']) and 'secret' not in js.stdout, [v['path'] for v in m['vmas']][:6])
bad = run('--theme', 'neon')
check('bad options are refused with usage', bad.returncode == 2 and 'usage' in bad.stderr)
nopid = run('--once', '--pid', '999999999')
check('a missing process is an error, not an empty map', nopid.returncode == 1 and 'not found' in nopid.stderr, nopid.stderr)

# 2. Live: owned 1 GiB fixture, collapse a quarter at a time, then split.
if not args.no_live:
    exe = work / 'memdefrag-fixture'
    subprocess.run(['cc', '-O2', '-o', str(exe), 'tests/memdefrag-fixture.c'], check=True)
    fx = subprocess.Popen([str(exe), str(args.mib)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    tui = None
    try:
        ready = json.loads(fx.stdout.readline())
        base = int(ready['start'], 16)
        once = run('--once', '--pid', str(fx.pid), '--redact', '--samples', '1')
        check('live --once draws the fixture with its pid', once.returncode == 0 and f'pid {fx.pid}' in once.stdout, once.stderr[-300:] or once.stdout[:200])
        tui = subprocess.Popen([xodb, '--memdefrag', '--json', '--stream', '--samples', '12', '--pid', str(fx.pid), '--redact'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        frames = []

        def next_frame():
            line = tui.stdout.readline()
            frames.append(json.loads(line) if line else None)
            return frames[-1]

        first = next_frame()
        cov = lambda f: (f['process']['coverage_numerator'], f['process']['coverage_denominator'])
        check('live first scan: THP-eligible 1 GiB with no huge pages yet', first and cov(first)[1] and cov(first)[1] >= ready['bytes'] - (2 << 20) and cov(first)[0] < ready['bytes'] // 4, first and cov(first))
        check('live: refresh period and age are reported', first['refresh_ns'] >= 1_000_000_000, first['refresh_ns'])
        nums = [cov(first)[0]]
        steps = []
        for step in range(4):
            fx.stdin.write('collapse\n')
            steps.append(json.loads(fx.stdout.readline()))
            f = next_frame()
            nums.append(cov(f)[0] if f else None)
        check('live coverage numerator rises with MADV_COLLAPSE steps', None not in nums and nums == sorted(nums) and nums[-1] > nums[0], (nums, [s['errno'] for s in steps]))
        collapsed = [c for f in frames[1:] if f for c in f['cells'] if c.get('collapsed')]
        check('live collapses are PMD changes (collapsed bytes), separate from page-state flips', collapsed and all(c['pmd_known'] for c in collapsed), len(collapsed))
        fx.stdin.write('split\n')
        fx.stdout.readline()
        split = None
        for _ in range(3):
            f = next_frame()
            if not f:
                break
            hit = [c for c in f['cells'] if c.get('split')]
            if hit:
                split = hit
                break
        check('live split: the first 2 MiB of the fixture is marked split', split and any(c['start'] <= base < c['end'] for c in split), split and [hex(c['start']) for c in split])
        if shots and split:
            # The recorded stream is a replay: draw the split poll as an 80x25 capture.
            rec = work / 'live.jsonl'
            rec.write_text(''.join(json.dumps(f) + '\n' for f in frames if f))
            a = run('--once', '--ansi', '--replay', str(rec), '--redact', env={'TERM': 'xterm', 'COLORTERM': 'truecolor'})
            (shots / 'tui-live-split-80x25.ansi').write_text(a.stdout)
            render_png(a.stdout, shots / 'tui-live-split-80x25.png')
            (shots / 'tui-live-split-80x25.txt').write_text(run('--once', '--replay', str(rec), '--redact').stdout)
        fx.stdin.write('quit\n')
        fx.stdin.flush()
        fx.wait(timeout=10)
        exited = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            f = next_frame()
            if not f: break
            if f['process']['maps']['state'] == 'exited':
                exited = f
                break
        check('live exit retains the pinned identity and reports exited', exited and exited['process']['start_ticks'] == first['process']['start_ticks'], exited and exited['process'])
        if exited:
            rec = work / 'exited.jsonl'
            rec.write_text(json.dumps(exited) + '\n')
            shown = run('--once', '--replay', str(rec), '--redact')
            check('live exit publication renders Process N exited', f'Process {fx.pid} exited' in shown.stdout, shown.stdout)

    finally:
        if tui and tui.poll() is None:
            tui.terminate()
            tui.wait(timeout=10)
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
print(f'memdefrag-tui: {len(results) - len(failed)}/{len(results)} checks passed; {work}')
sys.exit(1 if failed else 0)
