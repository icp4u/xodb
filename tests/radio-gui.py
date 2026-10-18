#!/usr/bin/env python3
"""The Radio panel (burrito mode) in a private headless Sway, on SYNTHETIC
spectrum and traffic, redacted. No radio is read and no card is touched.

R2: W opens the panel; with --radio-demo microwave60 the verdict turns to
microwave-like 60 Hz pulsing within one demo cycle.

R2b, with --radio-demo kitchen (access points on 1, 6 and 11, Bluetooth, and a
60 Hz microwave 15 s of every 25): the synthetic sensor sweeps six windows;
the channel strip and traffic fill; once the microwave runs the channel
verdict names channels 6-13 blasted and 1-5 clean; a drag across the spectrum
focuses the sensor (the plan turns to one fixed window at once, the view
zooms, the pop animates and then stops: the idle rule); a double-click returns
to the sweep; a metric chip and [ ] change the strip. No two labels overlap at
1600x1000 or 950x700. Screenshots stay in .work.
"""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-rad' + str(time.time_ns())[-5:])
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
# The radio restore file, if any were written, stays in the work directory.
os.environ['XDG_STATE_HOME'] = str(work / 'state')
checks = []
started = time.monotonic()
d = None
quick = os.environ.get('XODB_RADIO_GUI_QUICK') == '1'

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
        time.sleep(.1)
    raise AssertionError(name + ': ' + (d.tail() if d else ''))

def rows(prefix):
    return [dict(re.findall(r'(\w+)=([^ ]+)', l)) for l in h.complete_lines(d.log) if prefix in l]

def radio(kind=None):
    rs = [r for r in rows('xodb: radio kind=') if kind is None or r['kind'] == kind]
    return rs[-1] if rs else None

def frames_after(t0):
    return [r for r in rows('xodb: radio-frames ') if float(r.get('_t', 0)) >= 0][t0:]

def channel_words():
    return [l.split('xodb: radio-channels ', 1)[1] for l in h.complete_lines(d.log) if 'xodb: radio-channels ' in l]

def layout_ok(tag):
    time.sleep(1.5)
    layout = [l for l in h.complete_lines(d.log) if 'overview layout ' in l and 'panel=radio ' in l]
    check(f'{tag}: no overlapping text', bool(layout) and all(' overlaps=0 ' in l for l in layout[-3:]))

try:
    # R2: the 60 Hz verdict on the microwave-only scene (now swept across the band).
    if not quick:
        for size in ((1600, 1000), (950, 700)):
            d = h.Display(str(root), ['--overview', '--redact', '--radio-demo', 'microwave60'], stdio=False, trace=False, output_size=size)
            until(lambda: [l for l in h.complete_lines(d.log) if 'panel=summary' in l], 'summary drawn')
            d.keys('tap', 17)  # W
            until(lambda: [l for l in h.complete_lines(d.log) if 'panel=radio' in l], 'W opens the Radio panel')
            tag = f'{size[0]}x{size[1]}'
            check(f'{tag}: W opens the Radio panel', True)
            first = until(lambda: (lambda r: r if r and int(r['samples']) > 1000 else None)(radio()), 'synthetic samples arrive')
            check(f'{tag}: the demo is labelled synthetic and the waterfall has rows', first['demo'] == 'true' and int(first['rows']) >= 56 and first['spectral'] == 'false')
            hit = until(lambda: radio('microwave_pulsed'), 'the verdict turns to microwave-like pulsing', 40)
            check(f'{tag}: verdict is microwave-like 60 Hz pulsing', hit['mains'] == '60')
            layout_ok(tag)
            d.shot('radio-' + tag)
            d.close()
            d = None

    # R2b: the kitchen, the channel strip, traffic, drag-to-focus and back.
    for size in ((1600, 1000), (950, 700)):
        tag = f'kitchen {size[0]}x{size[1]}'
        d = h.Display(str(root), ['--overview', '--redact', '--radio-demo', 'kitchen', '--panel', 'radio'], stdio=False, trace=False, output_size=size)
        f0 = until(lambda: (lambda rs: rs[-1] if rs and rs[-1]['plan'] == 'sweep' and float(rs[-1]['spec'].split(',')[2]) > 100 else None)(rows('xodb: radio-frames ')), 'the panel draws and plans a sweep')
        check(f'{tag}: the synthetic sensor sweeps six windows', f0['windows'] == '6' and f0['lo'] == '2400' and f0['hi'] == '2500')
        tr = until(lambda: (lambda rs: rs[-1] if rs and int(rs[-1]['traffic'], 16) & 0x0842 == 0x0842 else None)(rows('xodb: radio-frames ')), 'traffic on channels 1, 6 and 11', 20)
        check(f'{tag}: traffic counted on channels 1, 6 and 11', True)
        # The verdict window is 12 s, so right after the switch-on it says less; wait for the full blast.
        blast = until(lambda: (lambda ws: ws[-1] if ws and 'channels 6-13 blasted' in ws[-1] and re.search(r' 1-[345]( and 14)? clean', ws[-1]) else None)(channel_words()), 'the channel verdict while the microwave runs', 60)
        check(f'{tag}: channel verdict names the blast and the clean channels', 'microwave-like 60 Hz' in blast)
        layout_ok(tag)
        if size == (1600, 1000): d.shot('radio-kitchen-sweep')
        # Drag across 2449-2466 MHz in the spectrum: one window holds it, so a fixed window on channel 10.
        last = rows('xodb: radio-frames ')[-1]
        x, y, w, hh = (float(v) for v in last['spec'].split(','))
        xa = round(x + w * (2449 - 2400) / 100)
        xb = round(x + w * (2466 - 2400) / 100)
        ym = round(y + hh / 2)
        n_before = len(rows('xodb: radio-frames '))
        d.keys('m', xa, ym, 'button', 272, 1, 'm', (xa + xb) // 2, ym, 'm', xb, ym, 'button', 272, 0)
        focused = until(lambda: (lambda rs: rs[-1] if rs and rs[-1]['plan'] == 'fixed' else None)(rows('xodb: radio-frames ')[n_before:]), 'the drag focuses the sensor')
        check(f'{tag}: the drag retunes at once to one fixed window on channel 10', focused['centre'] == '2457' and focused['windows'] == '1')
        check(f'{tag}: the focus is logged with its span', any('focus' in l and 'lo=24' in l for l in h.complete_lines(d.log) if 'radio-frames' in l))
        # The pop animates, then stops; data frames stay at or under ~10 per second.
        anim = until(lambda: [r for r in rows('xodb: radio-frames ')[n_before:] if r['animating'] == '1'], 'the pop animates', 5)
        settled = until(lambda: (lambda rs: rs if len(rs) >= 3 else None)([r for r in rows('xodb: radio-frames ')[n_before:] if r['animating'] == '0' and r['plan'] == 'fixed']), 'the pop settles', 10)
        view = settled[-1]['view'].split('-')
        check(f'{tag}: the view zoomed onto the focus', float(view[0]) > 2430 and float(view[1]) < 2485)
        check(f'{tag}: idle rule: settled frames at or under 12 per second', all(int(r['n']) <= 12 for r in settled[1:]))
        if size == (1600, 1000): d.shot('radio-kitchen-focus')
        # A metric chip and the keys change the strip.
        d.keys('tap', 27)  # ]
        until(lambda: (lambda rs: rs and rs[-1]['metric'] == 'floor')(rows('xodb: radio-frames ')), '] cycles the metric')
        check(f'{tag}: ] cycles the strip metric', True)
        # Double-click returns to the sweep.
        n_before = len(rows('xodb: radio-frames '))
        last = rows('xodb: radio-frames ')[-1]
        x, y, w, hh = (float(v) for v in last['strip'].split(','))
        cx, cy = round(x + w / 2), round(y + hh / 2)
        d.keys('click', cx, cy, 'click', cx, cy)
        back = until(lambda: (lambda rs: rs[-1] if rs and rs[-1]['plan'] == 'sweep' and rs[-1]['animating'] == '0' else None)(rows('xodb: radio-frames ')[n_before:]), 'double-click returns to the sweep', 10)
        check(f'{tag}: double-click returns to the full sweep and view', back['windows'] == '6' and back['view'] == '2400-2500')
        # A drag across the whole band (once a ReleaseSafe panic: the zoom clamps inverted) focuses and keeps drawing.
        last = rows('xodb: radio-frames ')[-1]
        x, y, w, hh = (float(v) for v in last['spec'].split(','))
        ym = round(y + hh / 2)
        d.keys('m', round(x + 1), ym, 'button', 272, 1, 'm', round(x + w / 2), ym, 'm', round(x + w - 1), ym, 'button', 272, 0)
        until(lambda: any('focus lo=2400 hi=2500' in l for l in h.complete_lines(d.log) if 'radio-frames' in l), 'a full-band drag focuses')
        n_before = len(rows('xodb: radio-frames '))
        until(lambda: (lambda rs: rs if len(rs) >= 3 else None)([r for r in rows('xodb: radio-frames ')[n_before:] if r['animating'] == '0']), 'the panel keeps drawing after a full-band drag', 10)
        check(f'{tag}: a full-band drag focuses without a crash', True)
        layout_ok(tag + ' after focus')
        d.close()
        d = None
finally:
    if d: d.close()
print(f'radio-gui: {len(checks)} passed in {time.monotonic() - started:.1f}s; {work}', flush=True)
