#!/usr/bin/env python3
"""The xodbfetch overview panel in a private headless Sway, redacted.

At 1600x1000 and 950x700: N opens the panel, no two labels overlap, the CPU
sparkline moves under a synthetic load (owned busy loops, killed by PID), the
WM line names the private Sway that draws the panel (not the session's
compositor), and OCR of the redacted screen shows none of this machine's
private names, matched as src/redact.zig matches them. The title, OCR'd alone,
reads user@host. A control run without --redact must read the real user@host
and find a private name, so the check is proven able to see one. Redacted,
the card wears a mad-lib retro system (ASCII logo, OS, kernel) from the
table in src/ui/overview/fetch.zig; every card has a Network line and no
Mitigations line. The benchmarks are never started here. Screenshots stay
in .work.
"""
import importlib.util
import json
import os
import pwd
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
from PIL import Image, ImageChops, ImageOps

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

def box(fields, key):
    x, y, w, hh = (int(float(v)) for v in fields[key].split(','))
    return (x, y, x + w, y + hh) if w > 0 else None

def spark_rect():
    rows = lines('xodb: fetch lines=')
    if not rows: return None
    fields = dict(re.findall(r'(\w+)=([^ ]+)', rows[-1]))
    return fields, box(fields, 'cpu_spark')

def title_text(shot, rect):
    """OCR of the card's title alone. In a whole-screen read tesseract merges
    it with the sidebar row beside it and often reads '@' as 'g'; cropped,
    inverted to dark-on-light and scaled 3x it reads the glyphs drawn."""
    x0, y0, x1, y1 = rect[0] - 4, rect[1] - 4, rect[2] + 4, rect[3] + 4
    with Image.open(shot) as im:
        crop = ImageOps.invert(im.convert('L').crop((x0, y0, x1, y1))).resize(((x1 - x0) * 3, (y1 - y0) * 3), Image.LANCZOS)
    path = shot + '.title.png'
    ImageOps.expand(crop, 20, fill=255).save(path)
    return ''.join(h.ocr(path, '--psm', '7').lower().split())

# The names src/redact.zig hides: user (passwd, $USER, $LOGNAME, $HOME's last
# part) and host (with its first label); "localhost", "root" and one-letter
# names are no one's. The kernel release, shown as "kernel hidden", is checked
# too.
users, hosts = set(), set()
try: hosts.add(Path('/proc/sys/kernel/hostname').read_text().strip())
except OSError: pass
hosts.add(socket.gethostname())
hosts |= {n.split('.')[0] for n in hosts}
users.add(pwd.getpwuid(os.getuid()).pw_name)
for name in ('USER', 'LOGNAME'):
    if os.environ.get(name): users.add(os.environ[name])
if os.environ.get('HOME'): users.add(os.path.basename(os.environ['HOME'].rstrip('/')))
def names(group): return {n.lower() for n in group if len(n) >= 2 and n.lower() not in ('localhost', 'root')}
users, hosts = names(users), names(hosts)
private = users | hosts | {os.uname().release.lower()}
RETRO = len(re.findall(r'\.os = "', (root / 'src/ui/overview/fetch.zig').read_text()))
assert RETRO >= 8

# ASCII classes, as src/redact.zig's std.ascii: a non-ASCII letter is an edge,
# and lowering never changes the text's length.
lower_ascii = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
def is_lower(ch): return 'a' <= ch <= 'z'
def is_upper(ch): return 'A' <= ch <= 'Z'

def edge(ch, n):
    # src/redact.zig edge(): two-letter names need a non-alphanumeric, non-'_' edge.
    letter = is_lower(ch) or is_upper(ch)
    return not letter and not '0' <= ch <= '9' and ch != '_' if n < 3 else not letter

def leaks(text):
    """Private names in TEXT as src/redact.zig finds them: names of 8+
    characters anywhere, shorter ones only as a token (between edges, or at a
    camelCase step for 3+ letters). Case-insensitive; TEXT keeps its case."""
    low = text.translate(lower_ascii)
    found = set()
    for p in private:
        n = len(p)
        for m in re.finditer('(?=' + re.escape(p) + ')', low):  # every start, as redact.zig scans
            i, end = m.start(), m.start() + n
            if n >= 8: found.add(p); break
            starts = i == 0 or edge(text[i - 1], n) or (n >= 3 and is_lower(text[i - 1]) and is_upper(text[i]))
            ends = end == len(text) or edge(text[end], n) or (n >= 3 and is_lower(text[end - 1]) and is_upper(text[end]))
            if starts and ends: found.add(p); break
    return found

try:
    # Control: unredacted, the same reads must see this machine's names.
    d = h.Display(str(root), ['--overview'], stdio=False, trace=False, output_size=(1600, 1000))
    until(lambda: lines('panel=summary'), 'summary drawn (control)')
    d.keys('tap', 49)  # N
    fields, _ = until(lambda: (lambda r: r if r and r[1] else None)(spark_rect()), 'fetch lines (control)')
    check('control: card drawn unredacted', fields['redacted'] == 'false')
    check('control: no mad-libs and the real logo or name', fields['madlib'] == '-1' and fields['logo'] in ('png', 'text'))
    check('control: the card has a Network line', fields['network'] == 'true')
    time.sleep(1.5)
    shot = d.shot('control')
    title = title_text(shot, box(fields, 'title'))
    seen = leaks(' '.join(h.ocr(shot).split())) & (users | hosts)
    # The unredacted capture and its OCR text hold the real names: keep none.
    for path in (shot, shot + '.txt', shot + '.title.png', shot + '.title.png.txt'):
        Path(path).unlink(missing_ok=True)
    check('control: the title OCRs as the real user@host', title in {u + '@' + n for u in users for n in hosts})
    check('control: OCR of the unredacted panel finds the user or host name', bool(seen))
    d.close()
    d = None
    for size in ((1600, 1000), (950, 700)):
        d = h.Display(str(root), ['--overview', '--redact'], stdio=False, trace=False, output_size=size)
        until(lambda: lines('panel=summary'), 'summary drawn')
        d.keys('tap', 49)  # N
        until(lambda: lines('panel=fetch'), 'N opens xodbfetch')
        check(f'{size[0]}x{size[1]}: N opens the xodbfetch panel', True)
        fields, rect = until(lambda: (lambda r: r if r and r[1] else None)(spark_rect()), 'fetch lines with a CPU sparkline')
        check(f'{size[0]}x{size[1]}: redacted card with {fields["lines"]} lines', fields['redacted'] == 'true' and int(fields['shown']) >= 8)
        check(f'{size[0]}x{size[1]}: WM is the compositor the panel is on', fields['wm'] == 'sway')
        check(f'{size[0]}x{size[1]}: a mad-lib retro system from the table, with its ASCII logo', 0 <= int(fields['madlib']) < RETRO and fields['logo'] == 'ascii')
        check(f'{size[0]}x{size[1]}: the card has a Network line', fields['network'] == 'true')
        if size[0] == 1600:
            # The CLI in this session asks $WAYLAND_DISPLAY's server, not $XDG_CURRENT_DESKTOP or /proc.
            out = subprocess.run(['zig-out/bin/xodb', '--fetch', '--json'], env=dict(d.env, XDG_CURRENT_DESKTOP='Hyprland'), capture_output=True, text=True, timeout=30)
            card = json.loads(out.stdout)['lines']
            wm = [l['value'] for l in card if l['key'] in ('WM', 'DE')]
            check('--fetch in the private session names its compositor', wm == ['sway'])
            check('--fetch has a Network line and no Mitigations line', 'Network' in [l['key'] for l in card] and 'Mitigations' not in out.stdout)
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
        check(f'{size[0]}x{size[1]}: the title OCRs as user@host', title_text(after, box(fields, 'title')) == 'user@host')
        # Names only, never printed: the failure says how many, not which.
        found = leaks(' '.join(h.ocr(after).split()))
        check(f'{size[0]}x{size[1]}: OCR of the redacted panel finds no private name ({len(found)} found)', not found)
        d.close()
        d = None
finally:
    for p in busy:
        p.send_signal(signal.SIGKILL)
        p.wait()
    if d: d.close()
print(f'fetch-gui: {len(checks)} passed in {time.monotonic() - started:.1f}s; {work}', flush=True)
