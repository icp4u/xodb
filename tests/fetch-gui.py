#!/usr/bin/env python3
"""The xodbfetch overview panel in a private headless Sway, redacted.

At 1600x1000 and 950x700: N opens the panel, no two labels overlap, the CPU
sparkline moves under a synthetic load (owned busy loops, killed by PID), the
WM line names the private Sway that draws the panel (not the session's
compositor), and OCR of the redacted screen shows none of this machine's
private names. The benchmarks are never started here. Screenshots stay in .work.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
from PIL import Image, ImageChops

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-nf' + str(time.time_ns())[-5:])
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
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
os.environ['XODB_OVERVIEW_AUDIT'] = '1'
# No benchmark result of the user's leaks in, and none is written.
os.environ['XDG_STATE_HOME'] = str(work / 'state')
checks = []
started = time.monotonic()
d = None
busy = []

def check(name, ok):
    if not ok: raise AssertionError(name + (': ' + d.tail() if d else ''))
    checks.append(name)
    print('PASS ' + name, flush=True)

def until(fn, name, seconds=15):
    deadline = time.monotonic() + seconds * h.load_scale()
    while time.monotonic() < deadline:
        if d and not d.alive(): raise AssertionError(name + ': exited: ' + d.tail())
        value = fn()
        if value: return value
        time.sleep(.05)
    raise AssertionError(name + ': ' + (d.tail() if d else ''))

def lines(marker):
    return [l for l in h.complete_lines(d.log) if marker in l]

def spark_rect():
    rows = lines('xodb: fetch lines=')
    if not rows: return None
    fields = dict(re.findall(r'(\w+)=([^ ]+)', rows[-1]))
    x, y, w, hh = (int(float(v)) for v in fields['cpu_spark'].split(','))
    return fields, (x, y, x + w, y + hh) if w > 0 else None

private = set()
try: private.add(Path('/proc/sys/kernel/hostname').read_text().strip())
except OSError: pass
private.add(socket.gethostname())
for name in ('USER', 'LOGNAME'):
    if os.environ.get(name): private.add(os.environ[name])
private.add(os.uname().release)
private = {p.lower() for p in private if p}

try:
    for size in ((1600, 1000), (950, 700)):
        d = h.Display(str(root), ['--overview', '--redact'], stdio=False, trace=False, output_size=size)
        until(lambda: lines('panel=summary'), 'summary drawn')
        d.keys('tap', 49)  # N
        until(lambda: lines('panel=fetch'), 'N opens xodbfetch')
        check(f'{size[0]}x{size[1]}: N opens the xodbfetch panel', True)
        fields, rect = until(lambda: (lambda r: r if r and r[1] else None)(spark_rect()), 'fetch lines with a CPU sparkline')
        check(f'{size[0]}x{size[1]}: redacted card with {fields["lines"]} lines', fields['redacted'] == 'true' and int(fields['shown']) >= 8)
        check(f'{size[0]}x{size[1]}: WM is the compositor the panel is on', fields['wm'] == 'sway')
        if size[0] == 1600:
            # The CLI in this session asks $WAYLAND_DISPLAY's server, not $XDG_CURRENT_DESKTOP or /proc.
            out = subprocess.run(['zig-out/bin/xodb', '--fetch', '--json'], env=dict(d.env, XDG_CURRENT_DESKTOP='Hyprland'), capture_output=True, text=True, timeout=30)
            wm = [l['value'] for l in json.loads(out.stdout)['lines'] if l['key'] in ('WM', 'DE')]
            check('--fetch in the private session names its compositor', wm == ['sway'])
        layout = until(lambda: [l for l in lines('overview layout ') if 'panel=fetch ' in l], 'layout audited')
        time.sleep(1.5)
        layout = [l for l in lines('overview layout ') if 'panel=fetch ' in l]
        check(f'{size[0]}x{size[1]}: no overlapping text', all(' overlaps=0 ' in l for l in layout))
        before = d.shot('before-load')
        busy = [subprocess.Popen(['sh', '-c', 'while :; do :; done']) for _ in range(max(2, (os.cpu_count() or 2) // 2))]
        time.sleep(3 * h.load_scale())
        after = d.shot('under-load')
        for p in busy:
            p.send_signal(signal.SIGKILL)
            p.wait()
        busy = []
        with Image.open(before) as a, Image.open(after) as b:
            diff = ImageChops.difference(a.convert('RGB').crop(rect), b.convert('RGB').crop(rect)).getbbox()
        check(f'{size[0]}x{size[1]}: the CPU sparkline moves under a synthetic load', diff is not None)
        text = ' '.join(h.ocr(after).lower().split())
        found = [p for p in private if re.search(r'(?<![a-z0-9])' + re.escape(p) + r'(?![a-z0-9])', text)]
        check(f'{size[0]}x{size[1]}: OCR of the redacted panel finds no private name', not found and 'user@host' in text.replace(' ', ''))
        d.close()
        d = None
finally:
    for p in busy:
        p.send_signal(signal.SIGKILL)
        p.wait()
    if d: d.close()
print(f'fetch-gui: {len(checks)} passed in {time.monotonic() - started:.1f}s; {work}', flush=True)
