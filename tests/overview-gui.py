#!/usr/bin/env python3
"""`xodb --overview` on a private headless display against synthetic replay data.

Checks every panel renders, theme switching, sorting, search, redaction (OCR),
unavailable reasons, the attach request and a 1280x720 layout. With --shots DIR
it also saves every panel in dark and green phosphor at 1920x1080, redacted.
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
parser.add_argument('--shots', type=Path, help='save the redacted panel screenshots here')
parser.add_argument('--keep', action='store_true', help='keep the work directory')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-overview-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('overview_input', root / 'tests/helpers/input.py')
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
replay = work / 'replay.jsonl'
subprocess.run([sys.executable, '-B', 'tests/fixtures/overview-synth.py', str(replay), '--frames', '150'], check=True)
unmeasured = work / 'unavailable.jsonl'
subprocess.run([sys.executable, '-B', 'tests/fixtures/overview-synth.py', str(unmeasured), '--frames', '20', '--unavailable'], check=True)
results = []
KEY = dict(h.KEY, n1=2, n2=3, n3=4, n4=5, n5=6, n6=7, n7=8, n8=9, n9=10, n0=11, s=31, t=20, p=25, x=45, r=19, v=47,
           slash=53, enter=28, down=108, up=103, b=48, u=22, n=49, l=38)
PANELS = ['summary', 'performance', 'processes', 'memory', 'disk', 'disk_space', 'network', 'connections', 'power', 'system', 'users', 'services', 'apps']


def check(name, ok, detail=''):
    results.append({'check': name, 'ok': bool(ok), 'detail': str(detail)})
    print(('ok   ' if ok else 'FAIL ') + name + (': ' + str(detail) if detail else ''), flush=True)
    return ok


class Overview:
    """A private headless Sway (no input devices) running one overview window."""
    count = 0

    def __init__(self, options, size=(1920, 1080), source=None, env_extra=None):
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
        app_env = dict(env, **(env_extra or {}))
        self.app = subprocess.Popen([str(root / 'zig-out/bin/xodb'), '--overview', '--replay', str(source or replay), *options], cwd=root, env=app_env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(self.log, 'wb'))
        self.procs.append(self.app)
        h.Display.wait_focused(self)
        time.sleep(0.6)

    def keys(self, *commands):
        script = ['layout', 'us', *[str(c) for c in commands]]
        with open(self.dir / 'injected.jsonl', 'a') as f:
            f.write(json.dumps({'unix_time': round(time.time(), 3), 'script': script}) + '\n')
        helper = subprocess.run([h.HELPER, str(self.size[0]), str(self.size[1]), *script], env=self.env, timeout=60)
        if helper.returncode != 0:
            raise RuntimeError(f'input helper exited {helper.returncode}')
        time.sleep(0.45)

    def tap(self, *names):
        cmds = []
        for n in names:
            cmds += ['tap', KEY[n]]
        self.keys(*cmds)

    def shot(self, name):
        path = self.dir / (name + '.png')
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(path)], env=self.env, check=True, timeout=10)
        return path

    def text(self):
        return self.log.read_text(errors='replace')

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
    """OCR, optionally of a region enlarged 2x: dense UI text reads better large."""
    if box:
        crop = Path(str(path) + f'.{box[0]}-{box[1]}.png')
        with Image.open(path) as im:
            im.convert('RGB').crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.LANCZOS).save(crop)
        path = crop
    return re.sub(r'\s+', ' ', h.ocr(str(path)))


def colorful(path, region=None):
    """Distinct colors in a region: a blank or failed frame has very few."""
    with Image.open(path) as im:
        im = im.convert('RGB')
        if region:
            im = im.crop(region)
        return len(set(im.resize((320, 180)).getdata()))


def mean(path, region):
    with Image.open(path) as im:
        px = list(im.convert('RGB').crop(region).resize((64, 36)).getdata())
    return tuple(sum(c[i] for c in px) / len(px) for i in range(3))


shots = args.shots.resolve() if args.shots else None
if shots:
    shots.mkdir(parents=True, exist_ok=True)

# 1. Every panel renders (dark), with OCR anchors; pausing keeps the frame still.
d = Overview(['--pause'])
try:
    anchors = {'summary': ['CPU', 'Memory'], 'performance': ['Total CPU'], 'processes': ['burner'], 'memory': ['composition'],
               'disk': ['Queue depth'], 'disk_space': ['Filesystems'], 'network': ['Receive'], 'connections': ['ESTABLISHED'],
               'power': ['Sensors'], 'system': ['Collector'], 'users': ['Sessions'], 'services': ['Observed daemon', 'PID', 'Uptime', 'RSS'],
               'apps': ['packages']}
    keys = ['n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8', 'n9', 'n0', 'tab', 'tab', 'tab']
    for panel, key in zip(PANELS, keys):
        d.tap(key)
        shot = d.shot('dark-' + panel)
        text = ocr(shot, (240, 52, 1920, 1052)) + ocr(shot, (240, 52, 1920, 260))
        missing = [a for a in anchors[panel] if a.lower() not in text.lower()]
        check(f'panel {panel} renders', colorful(shot) > 40 and not missing, f'missing {missing}' if missing else '')
    check('no draw failures in log', 'Draw failed' not in d.text() and 'frame failed' not in d.text(), d.text()[-300:])
    # Unavailable reasons are visible, not zeros.
    d.tap('n9')
    text = ocr(d.shot('power-reasons'), (240, 52, 700, 280))
    check('CPU package power shows its reason', 'needs privilege' in text.lower(), text[:200])
    d.tap('n1')
    text = ocr(d.shot('summary-honesty'), (1360, 540, 1920, 1052))
    check('summary lists unmeasured items', 'not measured' in text.lower() and 'privilege' in text.lower(), text[:300])
    # Theme cycle: dark -> light changes the background brightness.
    before = mean(d.shot('theme-before'), (300, 600, 600, 700))
    d.tap('t')
    after = mean(d.shot('theme-light'), (300, 600, 600, 700))
    check('t cycles to the light theme', sum(after) > sum(before) + 200, f'{before} -> {after}')
    d.tap('t')
    green = mean(d.shot('theme-green'), (0, 0, 1920, 1080))
    check('t cycles to green phosphor', green[1] > green[0] * 1.5 and green[1] > green[2] * 1.5, green)
    for _ in range(4):
        d.tap('t')
    # Processes: sort and search.
    d.tap('n3')
    text = ocr(d.shot('sorted-cpu'))
    first_rows = text[:900]
    check('CPU sort puts the burner near the top', 'burner' in first_rows, first_rows[:300])
    d.tap('s')  # memory
    text = ocr(d.shot('sorted-memory'))
    check('s cycles sort to memory', 'Memory ▼' in text or 'Memory v' in text or 'browser' in text[:900], text[:300])
    d.keys('tap', KEY['slash'], 'tap', KEY['w'], 'tap', 19, 'tap', 23, 'tap', 20, 'tap', 18, 'tap', 19)  # "writer"
    d.tap('enter')
    text = ocr(d.shot('search-writer'))
    check('search filters to the writer and its ancestors', 'writer' in text and 'burner' not in text, text[:400])
    # Open in debugger: select the match and press Enter.
    children_path = Path(f'/proc/{d.app.pid}/task/{d.app.pid}/children')
    children_before = children_path.read_text()
    d.tap('down', 'down', 'down', 'down', 'enter')
    time.sleep(0.3)
    log = d.text()
    text = ocr(d.shot('replay-action-refused'), (0, 1052, 1050, 1080))
    check('replay refuses process actions', 'process actions require a live process' in text and children_path.read_text() == children_before, text)
finally:
    d.close()

# 2. Redaction hides private text (OCR), without and with --redact.
d = Overview(['--pause', '--panel', 'system'])
try:
    plain = ocr(d.shot('system-plain'), (240, 52, 1080, 400))
    check('unredacted System Info shows the synthetic hostname', 'demo-host' in plain, plain[:300])
    d.tap('n3')
    proc_plain = ocr(d.shot('processes-plain'), (1560, 100, 1920, 940))
    check('unredacted processes show arguments', 'api-tok' in proc_plain, proc_plain[:300])
finally:
    d.close()
d = Overview(['--pause', '--redact', '--panel', 'system'])
try:
    text = ocr(d.shot('system-redacted'), (240, 52, 1080, 400))
    check('redaction hides the hostname', 'demo-host' not in text and 'redac' in text, text[:300])
    check('redaction hides kernel release and distribution', '6.12.0' not in text and 'Example Linux' not in text and 'kernel hidden' in text, text[:300])
    leaks = []
    for panel, key in zip(PANELS, ['n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8', 'n9', 'n0']):
        d.tap(key)
        t = ocr(d.shot('redacted-' + panel))
        for secret in ('demo-host', 'SECRET', 'api-token', '192.0.2.10', '198.51.100', '2001:db8', '::1234', 'CAMERA', '/home/demo', '02:00:5e', 'burner', 'writer', 'browser', '6.12.0', 'Example Linux'):
            if secret in t:
                leaks.append((panel, secret))
    check('redaction hides hosts, addresses, arguments and private mounts on every panel', not leaks, leaks)
    d.tap('n0', 'tab', 'tab')
    service_text = ocr(d.shot('services-redacted'), (240, 52, 1920, 1052))
    check('Services redacts init, names, users and cgroups', 'redacted' in service_text and
          all(secret not in service_text for secret in ('uid:0', 'udevd', '/system.slice', 'init: init')), service_text[:450])
finally:
    d.close()

# 2b. Unmeasured topology and sockets show reasons, never package 0 or tcp 0.
d = Overview(['--pause', '--panel', 'performance'], source=unmeasured)
try:
    text = ocr(d.shot('topology-unavailable'), (240, 280, 1920, 340))
    check('unmeasured topology shows its reason, not package 0', 'topology unavailable' in text.lower() and 'package 0' not in text.lower(), text[:200])
    d.tap('n1')
    text = ocr(d.shot('ratios-unavailable'), (240, 52, 1920, 1052))
    check('unmeasured memory total gives no ratio and no "of 0 B"', 'of 0 B' not in text and 'parse error' in text, text[:300])
    d.tap('n8')
    text = ocr(d.shot('connections-unavailable'), (240, 52, 1920, 200))
    check('unmeasured connections show the reason, not zero counts', 'permission denied' in text.lower() and 'tcp 0' not in text.lower(), text[:200])
finally:
    d.close()

# A failed optional backend must remain explained while other sensors work.
nvml_missing = work / 'nvml-missing.jsonl'
frame = json.loads(replay.read_text().splitlines()[0])
frame['groups']['power']['detail'] = 'RAPL permission denied; NVML: libnvidia-ml.so.1 not loadable'
nvml_missing.write_text(json.dumps(frame) + '\n')
d = Overview(['--pause', '--panel', 'power', '--redact'], source=nvml_missing)
try:
    text = ocr(d.shot('nvml-missing'))
    check('optional NVML failure explanation stays visible', 'NVML' in text and 'not loadable' in text, text[-600:])
finally:
    d.close()

# 2c. No two labels collide, at 1920x1080 and 1280x720 (layout audit in the binary).
for size in ((1920, 1080), (1600, 900), (1280, 720)):
    for extra in ([], ['--redact']):
        d = Overview(['--pause', *extra], size=size, env_extra={'XODB_OVERVIEW_LAYOUT': '1'})
        try:
            for key in ['n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8', 'n9', 'n0', 'tab', 'tab', 'tab']:
                d.tap(key)
            d.tap('n1')
            lines = [l for l in d.text().splitlines() if 'overview layout' in l]
            bad = [l for l in lines if 'overlaps=0 ' not in l]
            seen = {re.search(r'panel=(\w+)', l).group(1) for l in lines}
            check(f'no overlapping labels at {size[0]}x{size[1]}{" redacted" if extra else ""}', not bad and len(seen) == len(PANELS), bad[:3] or sorted(set(PANELS) - seen))
        finally:
            d.close()

# 3. Small window stays usable.
d = Overview(['--pause'], size=(1280, 720))
try:
    for panel, key in (('summary', 'n1'), ('processes', 'n3'), ('performance', 'n2')):
        d.tap(key)
        shot = d.shot('small-' + panel)
        check(f'1280x720 {panel} renders', colorful(shot) > 30)
    d.tap('n0', 'tab', 'tab')
    for theme in ('dark', 'green'):
        if theme == 'green':
            d.tap('t', 't')
        shot = d.shot('small-services-' + theme)
        text = ocr(shot, (200, 52, 1280, 680))
        check('1280x720 Services fields in ' + theme, all(x.lower() in text.lower() for x in ('Observed daemon', 'PID', 'User', 'State', 'Uptime', 'CPU', 'RSS', 'udevd')), text[:450])
    check('1280x720 no draw failures', 'Draw failed' not in d.text() and 'frame failed' not in d.text())
finally:
    d.close()

# 4. Live replay animation: unpaused, samples advance and the view reports its overhead.
d = Overview(['--interval-ms', '250', '--frames', '0'])
try:
    time.sleep(2.5)
    text = ocr(d.shot('running'))
    check('overhead indicator is visible', 'overhead' in text.lower() and 'view' in text.lower(), text[-200:])
    d.tap('q')
    try:
        d.app.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    check('q quits cleanly', d.app.poll() == 0 and 'clean shutdown' in d.text(), d.text()[-200:])
finally:
    d.close()

# 5. Screenshot set: every panel, dark and green phosphor, redacted.
if shots:
    for theme in ('dark', 'green'):
        d = Overview(['--pause', '--redact', '--theme', theme])
        try:
            for panel in PANELS:
                index = PANELS.index(panel)
                if index < 9:
                    d.tap(f'n{index + 1}')
                elif index == 9:
                    d.tap('n0')
                else:
                    d.tap('tab')
                path = d.shot(f'{theme}-{panel}')
                target = shots / f'{index + 1:02d}-{panel}-{theme}.png'
                target.write_bytes(path.read_bytes())
            check(f'{theme} screenshots saved', len(list(shots.glob(f'*-{theme}.png'))) == len(PANELS))
        finally:
            d.close()

(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
failed = [r for r in results if not r['ok']]
print(f'overview: {len(results) - len(failed)}/{len(results)} checks passed; {work}')
sys.exit(1 if failed else 0)
