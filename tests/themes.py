#!/usr/bin/env python3
"""Passive startup themes and private GUI coverage in local, imported and remote views."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from PIL import Image

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('theme_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
work = root / '.work' / ('input-theme-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
path = work / 'theme.json'
config = work / 'settings.json'
config.write_text(json.dumps({'appearance': {'theme': 'theme.json'}, 'profile': {'frequency_hz': 77}}))
revision = 0
checks = []


def write_theme(value):
    global revision
    revision += 1
    if path.exists():
        path.rename(work / f'theme-{revision:02d}.before')
    next_path = work / 'next.json'
    next_path.write_text(value if isinstance(value, str) else json.dumps(value))
    next_path.replace(path)


def wait_for(predicate, timeout=8):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError('timed out waiting for theme result')


def former_theme_hotkey(d):
    d.keys('down', h.KEY['ctrl'], 'tap', 65, 'up', h.KEY['ctrl'])


def pixel(d, name, expected):
    # A mapped, focused window may not be composited yet: wait for the colour, bounded.
    deadline = time.monotonic() + 5
    while True:
        shot = d.shot(name)
        with Image.open(shot) as image:
            actual = image.convert('RGB').getpixel((2, 82))
        if max(abs(a-b) for a, b in zip(actual, expected)) <= 2 or time.monotonic() > deadline:
            break
        time.sleep(.025)  # condition polling only
    assert max(abs(a-b) for a, b in zip(actual, expected)) <= 2, (name, actual, expected, shot)
    return shot


d = None
try:
    write_theme({'version': 1, 'id': 'first', 'colors': {'background': '#123456'}})
    d = h.Display(str(root), ['--config', str(config), '--', str(root / 'zig-out/bin/xodb-m1-fixture'), 'w'])
    before = d.session()
    pixel(d, 'config-relative', (18, 52, 86))
    checks.append('config-relative path and custom palette')
    write_theme({'version': 1, 'id': 'second', 'base': 'builtin:light', 'colors': {'background': '#abcdef'}})
    former_theme_hotkey(d)
    time.sleep(.3)
    pixel(d, 'unchanged-after-edit-and-key', (18, 52, 86))
    assert d.session()['generation'] == before['generation']
    assert 'Theme ' not in Path(d.log).read_text(), 'Successful startup should be quiet'
    checks.append('file edits and former theme hotkey do not change palette or generation')
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', '720x480'], env=d.env, check=True, capture_output=True)
    time.sleep(.3)
    pixel(d, 'small-window', (18, 52, 86))
    checks.append('small window renders')
    d.close(); d = None
    d = h.Display(str(root), ['--config', str(config)])
    pixel(d, 'changed-file-at-next-startup', (171, 205, 239))
    d.close(); d = None
    checks.append('edited theme is loaded at next startup')
    for preset, expected in (('builtin:contrast', (0, 0, 0)), ('builtin:light', (233, 237, 242)), ('builtin:dark', (10, 13, 18))):
        d = h.Display(str(root), ['--theme', preset])
        pixel(d, preset.replace(':', '-'), expected)
        assert 'Theme ' not in Path(d.log).read_text()
        d.close(); d = None
    checks.append('dark, light and contrast presets load quietly at startup')
    # CLI takes precedence over preferences and is harmless in a headless service.
    d = h.Display(str(root), ['--config', str(config), '--theme', 'builtin:light'])
    pixel(d, 'cli-precedence', (233, 237, 242))
    d.close(); d = None
    write_theme({'version': 1, 'colors': {'background': '#123456'}})
    d = h.Display(str(root), ['--theme', str(path), '--open-profile', str(root / 'src/profile/imported_fixture.json')])
    pixel(d, 'imported', (18, 52, 86))
    write_theme({'version': 1, 'id': 'imported.edited', 'colors': {'background': '#abcdef'}})
    former_theme_hotkey(d)
    time.sleep(.3)
    pixel(d, 'imported-unchanged', (18, 52, 86))
    checks.append('imported profile retains startup palette')
    # Reuse the private compositor for the separate remote GUI and a loopback server.
    d.app.stdin.close()
    d.app.wait(timeout=5)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
    listener.close()
    server_log = work / 'server.log'
    with server_log.open('wb') as log:
        server = subprocess.Popen([str(root / 'zig-out/bin/xodb'), '--headless', '--mcp', '--listen', f'127.0.0.1:{port}', '--', str(root / 'zig-out/bin/xodb-m1-fixture'), 'w'], env=d.env, stdout=log, stderr=log)
    d.procs.append(server)
    wait_for(lambda: 'listening on' in server_log.read_text())
    remote_log = work / 'remote.log'
    with remote_log.open('wb') as log:
        remote = subprocess.Popen([str(root / 'zig-out/bin/xodb'), '--connect', f'127.0.0.1:{port}', '--theme', str(path)], env=d.env, stdout=log, stderr=log)
    d.procs.append(remote)
    wait_for(lambda: 'first window frame submitted' in remote_log.read_text())
    time.sleep(.25)
    pixel(d, 'remote', (171, 205, 239))
    write_theme({'version': 1, 'id': 'remote.edited', 'colors': {'background': '#123456'}})
    former_theme_hotkey(d)
    time.sleep(.3)
    pixel(d, 'remote-unchanged', (171, 205, 239))
    checks.append('remote client retains startup palette')
    d.close(); d = None
    for bad, reason in (('{', 'Theme failed:'), ({'version': 1, 'colors': {'background': '#123'}}, 'colors.background'), ({'version': 2}, 'UnsupportedThemeVersion')):
        write_theme(bad)
        d = h.Display(str(root), ['--theme', str(path)])
        assert reason in Path(d.log).read_text(), Path(d.log).read_text()
        pixel(d, 'startup-fallback-' + str(revision), (10, 13, 18))
        d.close(); d = None
    checks.append('bad startup files fall back with stderr diagnostics')
    # No display or theme-file access is required by the headless branch.
    fifo = work / 'theme.fifo'
    os.mkfifo(fifo)
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    headless = subprocess.run([str(root / 'zig-out/bin/xodb'), '--headless', '--mcp', '--theme', str(fifo)], input=b'', capture_output=True, env=env, timeout=5)
    assert headless.returncode == 0, headless.stderr
    assert b'Theme' not in headless.stderr
    checks.append('headless ignores appearance assets')
    (work / 'results.json').write_text(json.dumps(checks, indent=2) + '\n')
    print('PASS ' + '; '.join(checks))
    print('Artifacts:', work.relative_to(root))
finally:
    if d:
        d.close()
