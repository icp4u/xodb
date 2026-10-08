#!/usr/bin/env python3
"""Clipboard/editing regression tests on an owned private Wayland compositor."""
import argparse
import csv
import io
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--focused', action='store_true', help='focused transfer bounds, Unicode, stalled source and stale-editor checks; default runs all editors and selection cases')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    out = importlib.util.module_from_spec(spec); spec.loader.exec_module(out)
    return out

h = module('private_input', root / 'tests/helpers/input.py')
work = root / '.work' / ('input-clip-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (work / name).mkdir(parents=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard'),
                  ('/usr/share/wlr-protocols/unstable/wlr-data-control-unstable-v1.xml', 'data-control')):
    for kind, suffix in (('client-header', '.h'), ('private-code', '.c')):
        subprocess.run(['wayland-scanner', kind, xml, str(work / (stem + suffix))], check=True, timeout=10)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
                str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=30)
source = str(work / 'clipboard-source')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/clipboard-source.c',
                str(work / 'data-control.c'), '-lwayland-client', '-o', source], check=True, timeout=30)
checks = []

def copy(d, text, primary=False):
    child = subprocess.Popen(['wl-copy', '--foreground', '--type', 'text/plain;charset=utf-8', *(['--primary'] if primary else [])],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=d.env)
    d.procs.append(child)
    child.stdin.write(text.encode()); child.stdin.close()
    time.sleep(.15)
    assert child.poll() is None, child.stderr.read()

def chord(d, code):
    d.keys('down', 29, 'tap', code, 'up', 29)

def field(d):
    chord(d, 46)
    return subprocess.run(['wl-paste', '--no-newline'], env=d.env, capture_output=True, check=True, timeout=3).stdout.decode()

def paste(d, text):
    copy(d, text); chord(d, 47); time.sleep(.15)

def shot(d, name):
    return ' '.join(h.ocr(d.shot(name), '--psm', '11').lower().split())

def click_word(d, word, index=0):
    path = d.shot('find-' + word)
    tsv = h.ocr(path, '--psm', '11', 'tsv')
    words = [row for row in csv.DictReader(io.StringIO(tsv), delimiter='\t') if row['text'].lower() == word]
    row = sorted(words, key=lambda w: (int(w['top']), int(w['left'])))[index]
    d.keys('click', int(row['left']) + int(row['width']) // 2, int(row['top']) + int(row['height']) // 2)

def bad_source(d, delay):
    child = subprocess.Popen([source, str(delay)], env=d.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    d.procs.append(child)
    assert select.select([child.stdout], [], [], 3)[0], 'test source did not start'
    assert child.stdout.readline() == b'ready\n'
    time.sleep(.1)
    return child

def passed(name):
    checks.append(name); print('PASS', name, flush=True)

print('Clipboard evidence:', work, flush=True)
d = None
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--source', 'tests/fixtures/m1.c', '--break', 'change_value', '--', './zig-out/bin/xodb-m1-fixture', 'w'])
    d.keys('tap', 57)
    assert d.stopped('breakpoint')
    generation = d.session()['generation']
    d.keys('tap', 18)
    paste(d, 'am\nou\r\x1bnt')
    assert field(d) == 'amount'
    assert d.session()['generation'] == generation
    passed('Ctrl+V strips controls and does not submit or resume')
    shot(d, '01-expression')
    chord(d, 22)
    paste(d, 'am\u202e\u2066\u200b\ufeff\U000e0061ount')
    assert field(d) == 'amount'
    assert d.session()['generation'] == generation
    passed('bidi, zero-width, BOM and tag format characters are removed from paste')
    if not args.focused:
        d.keys('tap', 105, 'tap', 105, 'tap', 105)  # cursor after amo
        paste(d, ' + ')
        assert field(d) == 'amo + unt'
        d.keys('down', 42, 'tap', 105, 'tap', 105, 'tap', 105, 'up', 42)
        assert subprocess.run(['wl-paste', '--primary', '--no-newline'], env=d.env, capture_output=True, check=True, timeout=3).stdout == b' + '
        assert field(d) == ' + '
        paste(d, '_')
        assert field(d) == 'amo_unt'
        passed('paste inserts at cursor; Shift-selection owns primary and copies/replaces selected text')
        chord(d, 22)
        paste(d, 'nv')
        assert field(d) == 'nv'
        passed('field typing/paste preserves local N and V ownership')
        copy(d, 'MID', primary=True)
        d.keys('layout', 'us', 'middle', 640, 638)  # between n and v, in the expression field
        assert field(d) == 'nMIDv'
        d.keys('layout', 'us', 'middle', 300, 638)  # outside the text field: must not paste
        assert field(d) == 'nMIDv'
        passed('middle-click inserts primary selection only inside the text field')
        chord(d, 22)
        paste(d, 'mouse')
        d.keys('layout', 'us', 'fastdrag', 630, 638, 659, 638)
        assert field(d) == 'mou'
        assert subprocess.run(['wl-paste', '--primary', '--no-newline'], env=d.env, capture_output=True, check=True, timeout=3).stdout == b'mou'
        paste(d, 'X')
        assert field(d) == 'Xse'
        passed('batched mouse drag selects, publishes primary and replaces the selection')


    chord(d, 22)
    paste(d, 'a' * 5000)
    assert 'truncated' in shot(d, '02-truncated')
    assert field(d) == 'a' * 256
    passed('transfer and field limits visibly truncate oversized paste')
    chord(d, 22)
    paste(d, 'éλ')
    d.keys('tap', 105, 'tap', 14)
    assert field(d) == 'λ'
    passed('UTF-8 cursor and Backspace preserve complete characters')
    chord(d, 22)
    paste(d, 'safe')
    bad_source(d, -1)
    # Keep the virtual keyboard alive through the deadline: destroying the
    # only keyboard is real focus loss and correctly cancels a transfer.
    keyboard = d.keys('down', 29, 'tap', 47, 'up', 29, 'tap', 105, 'tap', 106, 'w', 2400, wait=False)
    time.sleep(.6)
    start = time.monotonic(); assert d.session()['generation'] == generation
    assert time.monotonic() - start < .5
    time.sleep(.8)
    assert 'paste timed out' in shot(d, '03-timeout')
    keyboard.wait(timeout=4)
    assert field(d) == 'safe'
    passed('non-writing source times out with responsive input/MCP and unchanged text')
    bad_source(d, 600)
    d.keys('down', 29, 'tap', 47, 'up', 29, 'tap', 1, 'tap', 18, 'tap', 45, 'w', 800)
    time.sleep(.8)
    assert field(d) == 'x'
    passed('late paste cannot land in a closed and reopened editor')
    if not args.focused:
        d.keys('tap', 1, 'tap', 48, 'tap', 46)  # E cancel; B breakpoints; C condition
        paste(d, 'amount == 5')
        assert field(d) == 'amount == 5'
        assert all(p['condition'] != 'amount == 5' for p in d.tool('get_breakpoints')['policies'])
        d.keys('tap', 28)
        assert any(p['condition'] == 'amount == 5' for p in d.tool('get_breakpoints')['policies'])
        passed('breakpoint field pastes locally and applies only on Return')
        d.keys('tap', 1, 'tap', 33, 'tap', 31)  # B close; F profile; S setup
        defaults = d.tool('get_profile')['defaults']
        click_word(d, 'custom', 1)  # frequency
        chord(d, 22)
        paste(d, '2a\n50')
        assert field(d) == '250'
        assert d.tool('get_profile')['defaults']['frequency_hz'] == defaults['frequency_hz']
        d.keys('tap', 28)
        assert d.tool('get_profile')['defaults']['frequency_hz'] == 250
        click_word(d, 'custom')  # duration; rate now displays its numeric value
        chord(d, 22)
        paste(d, '2')
        d.keys('tap', 28)
        assert d.tool('get_profile')['defaults']['duration_ms'] == 2000
        passed('capture rate and duration keep numeric filtering and Return validation')
        click_word(d, 'filter')
        paste(d, 'worker' * 20)
        assert 'truncated' in shot(d, '04-filter-truncated')
        assert field(d) == ('worker' * 20)[:32]
        d.keys('tap', 28)
        passed('capture thread filter uses the same clipboard with a visible 32-byte bound')

finally:
    if d: d.close()

if not args.focused:
    # Threshold editing runs through the observation browser's separate input loop.
    fixture = module('invocation_fixture', root / 'tests/invocations-gui.py')
    archive = work / 'demo.xoi'; fixture.write_fixture(archive)
    d = None
    try:
        d = h.Display(str(root), ['--browse-observation', str(archive), '--agent-scope', 'control'])
        time.sleep(.3)
        d.keys('tap', 20)  # T threshold
        paste(d, '1250000')
        assert field(d) == '1250000'
        assert (d.tool('get_observation')['comparison_selection'] or {}).get('threshold_ns') != 1250000
        d.keys('tap', 28)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = d.tool('get_observation')['comparison_selection'] or {}
            if result.get('threshold_ns') == 1250000: break
            time.sleep(.05)
        assert result['threshold_ns'] == 1250000, result
        passed('observation threshold paste waits for explicit Return')
    finally:
        if d: d.close()
(work / 'results.json').write_text(json.dumps({'passed': checks}, indent=2))
print('Clipboard GUI:', len(checks), 'groups passed;', work.relative_to(root))
