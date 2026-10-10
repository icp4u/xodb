#!/usr/bin/env python3
"""Fast GUI lane: Vulkan device listing, forcing and the one-line blank-window warning.

Runs on a private headless compositor. The forced-device checks need a second
device that can present; a host with one device reports them as not run.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

started = time.monotonic()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/xodb').resolve())
spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
(root / '.work').mkdir(exist_ok=True)
display.WORK = tempfile.mkdtemp(prefix='vulkan-device-', dir=root / '.work')
os.chmod(display.WORK, 0o755)
MARK = 'xodb: vulkan: '
ROW = re.compile(r'^([* ]) +(\d+)  (.+?)  +(discrete|integrated|virtual|cpu|other) +(drm [0-9:/]+|no drm node) +(presents|cannot present)( +display)?$')
results = []

def check(name, ok, detail=''):
    results.append({'name': name, 'ok': bool(ok)})
    if not ok:
        raise AssertionError(name + (': ' + str(detail) if detail else ''))
    print('PASS ' + name, flush=True)

def run(*args, **env):
    done = subprocess.run([binary, *args], env=dict(private.env, **env), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    return done.returncode, done.stdout, done.stderr

def warnings(text):
    return [line for line in text.splitlines() if line.startswith(MARK)]

def devices(text):
    rows = [ROW.match(line) for line in text.splitlines()]
    return [dict(chosen=m[1] == '*', index=int(m[2]), name=m[3], kind=m[4], presents=m[6] == 'presents', display=bool(m[7])) for m in rows if m]

os.environ.pop('XODB_VK_DEVICE', None)  # a gate may pin a device; this test sets its own
private = display.Display('devices')
try:
    code, out, err = run('--vk-list')
    listed = devices(out)
    check('--vk-list exits 0 and prints every device on stdout', code == 0 and listed and [d['index'] for d in listed] == list(range(len(listed))), out + err)
    header = re.search(r'^Vulkan devices \(display GPU: (drm \d+:\d+|unknown)\)$', out, re.M)
    check('--vk-list names the display GPU or says it is unknown', header, out)
    known = header[1] != 'unknown'
    chosen = [d for d in listed if d['chosen']]
    check('--vk-list marks exactly one device as the default', len(chosen) == 1 and chosen[0]['presents'], out)
    on_display = [d for d in listed if d['display']]
    check('the default is the display GPU when the compositor names one that Vulkan lists',
          not on_display or chosen[0]['display'], out)

    code, out, err = run('--frames', '3')
    check('default run uses the listed default device', code == 0 and 'Vulkan device: ' + chosen[0]['name'] + '\n' in err, err)
    check('default run on the display GPU prints no warning', not (chosen[0]['display'] and warnings(err)), err)

    others = [d for d in listed if d['presents'] and not d['display'] and not d['chosen']]
    if known and on_display and others:
        for other in others:
            code, out, err = run('--vk-device', str(other['index']), '--frames', '3')
            lines = warnings(err)
            # The probe must have used the forced device before its warning counts.
            check(f"--vk-device {other['index']} renders on {other['kind']} device", code == 0 and 'Vulkan device: ' + other['name'] + '\n' in err, err)
            check(f"forced {other['kind']} device prints exactly one warning line",
                  len(lines) == 1 and other['name'] in lines[0] and 'is not the display GPU (' + header[1] in lines[0] and '(as requested)' in lines[0], err)
        other = others[-1]
        part = other['name'].split()[0].upper()
        code, out, err = run('--frames', '3', XODB_VK_DEVICE=part)
        check('XODB_VK_DEVICE selects by a case-insensitive part of the name',
              code == 0 and any(part.lower() in line.lower() for line in warnings(err)) and len(warnings(err)) == 1, err)
        code, out, err = run('--vk-device', str(chosen[0]['index']), '--frames', '3', XODB_VK_DEVICE=part)
        check('--vk-device overrides XODB_VK_DEVICE', code == 0 and 'Vulkan device: ' + chosen[0]['name'] + '\n' in err and not warnings(err), err)
        code, out, err = run('--vk-list', XODB_VK_DEVICE=str(other['index']))
        check('--vk-list marks a requested device', code == 0 and [d['index'] for d in devices(out) if d['chosen']] == [other['index']], out + err)
        replay = Path(private.dir) / 'replay.jsonl'
        subprocess.run([sys.executable, '-B', 'tests/fixtures/overview-synth.py', str(replay), '--frames', '5'], check=True)
        code, out, err = run('--overview', '--pause', '--redact', '--replay', str(replay), '--frames', '3', '--vk-device', str(other['index']))
        check('--overview takes --vk-device and prints the same warning', code == 0 and len(warnings(err)) == 1 and other['name'] in warnings(err)[0], err)
    else:
        results.append({'name': 'forced non-display device', 'ok': None})
        print('NOT RUN forced non-display device: needs a known display GPU and a second presenting device', flush=True)

    begun = time.monotonic()
    code, out, err = run('--vk-device', 'no-such-device-name', '--frames', '3')
    check('an unknown --vk-device fails at once and lists the devices',
          code != 0 and 'no Vulkan device matches "no-such-device-name"' in err and listed[0]['name'] in err and time.monotonic() - begun < 10, err)
    code, out, err = run('--vk-device', str(len(listed)), '--frames', '3')
    check('an out-of-range --vk-device index fails', code != 0 and 'no Vulkan device matches' in err, err)

    # A driver manifest whose library cannot load, as after a mismatched driver update.
    manifest = Path(private.dir) / 'missing-driver.json'
    manifest.write_text(json.dumps({'file_format_version': '1.0.1', 'ICD': {'library_path': 'libxodb_missing_driver.so.0', 'api_version': '1.3.0'}}))
    code, out, err = run('--frames', '3', VK_ADD_DRIVER_FILES=str(manifest))
    lines = warnings(err)
    check('a driver that fails to load is reported in one line and rendering continues',
          code == 0 and len(lines) == 1 and 'driver libxodb_missing_driver.so.0 failed to load' in lines[0] and 'rendering on ' + chosen[0]['name'] in lines[0], err)
    code, out, err = run('--vk-list', VK_ADD_DRIVER_FILES=str(manifest))
    check('--vk-list reports the failed driver too', code == 0 and len(warnings(err)) == 1 and len(devices(out)) == len(listed), out + err)
finally:
    private.close()
    report = {'lane': 'fast', 'seconds': time.monotonic() - started, 'checks': results}
    (Path(display.WORK) / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'work': display.WORK, 'seconds': report['seconds']}), flush=True)
