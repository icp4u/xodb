#!/usr/bin/env python3
"""Private GUI live displays: frame changes, scope loss, conversion and optional Perl."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import select
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl', help='debug Perl with DWARF for the owned array demo')
args = p.parse_args()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
work = root / '.work' / ('input-live-' + str(time.time_ns())[-10:])
work.mkdir(parents=True); h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (work / name).mkdir(parents=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True, timeout=10)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
                str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=30)
checks = []


def shot(d, name):
    time.sleep(.25)
    path = d.shot(name)
    text = subprocess.run(['tesseract', path, 'stdout', '--psm', '11'], capture_output=True, text=True, check=True, timeout=10).stdout.lower()
    Path(path + '.txt').write_text(text)
    return " ".join(text.split())


def add(d, keys, live=True):
    prefix = ['down', 42, 'tap', 18, 'up', 42] if live else ['tap', 18]
    d.keys(*prefix, *sum((['tap', key] for key in keys), []), 'tap', 28)


def next_stop(d, code=57):
    generation = d.session()['generation']
    d.keys('tap', code)
    state = d.wait(lambda s: s['state'] == 'stopped' and s['generation'] > generation)
    assert state
    return state


d = None
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--source', 'tests/fixtures/m1.c', '--', './zig-out/bin/xodb-m1-fixture', 'w'])
    d.tool('set_breakpoint', generation=d.session()['generation'], file='tests/fixtures/m1.c', line=9)
    next_stop(d)
    add(d, [30, 50, 24, 22, 49, 20])  # amount, live
    text = shot(d, 'm1-first-live')
    assert 'selected #0' in text and re.search(r'amount\s*=?\s*5\b', text), text
    add(d, [30, 50, 24, 22, 49, 20], live=False)
    # Select main (frame 1), then change_value again: no resume is needed.
    d.keys('click', 300, 658)
    text = shot(d, 'm1-main-selected')
    assert 'not in scope here' in text and re.search(r'amount\s*=?\s*5\b', text), text
    d.keys('click', 300, 630)
    text = shot(d, 'm1-frame-restored')
    assert 'not in scope here' not in text and re.search(r'amount\s*=?\s*5\b', text), text
    next_stop(d, 88)  # finish selected frame: main is now current
    text = shot(d, 'm1-frame-gone')
    assert 'not in scope here' in text and 'frame gone' in text, text
    next_stop(d)
    text = shot(d, 'm1-second-live')
    assert re.search(r'amount\s*=?\s*9\b', text) and 'frame gone' in text, text
    # E leaves watch focus on the last row; restore focus after stack clicks.
    d.keys('tap', 18, 'tap', 1, 'down', 42, 'tap', 38, 'up', 42)
    text = shot(d, 'm1-pinned-to-live')
    assert 'live display:' in text and 'frame gone' not in text, text
    d.keys('down', 42, 'tap', 38, 'up', 42)
    assert 'watch pinned to the selected frame' in shot(d, 'm1-live-to-pinned')
    add(d, [44, 44, 44, 44])  # a name never observed in any selected frame
    assert 'unknown name' in shot(d, 'm1-unknown-name')
    d.keys('tap', 18)
    assert 'up/down history' in shot(d, 'm1-editor-history')
    d.keys('tap', 1)
    text = shot(d, 'm1-watch-hints')
    assert 'v events' in text and 'scroll' in text, text
    checks.append('M1: live follows selected frame and next call; pinned activation stays gone; both conversions work')
finally:
    if d: d.close(); d = None

if args.perl:
    target = subprocess.Popen([args.perl, 'examples/perl-demo.pl'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert select.select([target.stdout], [], [], 10)[0]
        assert int(target.stdout.readline()) == target.pid
        d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(target.pid),
                                 '--break', 'Perl_av_store', '--break', 'Perl_av_delete'])
        for _ in range(3):
            next_stop(d)
            symbol = d.tool('get_stack', tid=target.pid)['frames'][0]['symbol']
            if symbol == 'Perl_av_store': break
        assert symbol == 'Perl_av_store', symbol
        add(d, [47, 30, 38])  # val
        add(d, [30, 47])      # av
        text = shot(d, 'perl-store')
        assert 'undef' in text and '3 slots' in text, text
        next_stop(d)
        assert d.tool('get_stack', tid=target.pid)['frames'][0]['symbol'] == 'Perl_av_delete'
        text = shot(d, 'perl-delete')
        assert 'not in scope here' in text and '4 slots' in text, text
        assert 'undef' not in text.split('watch', 1)[-1], text
        next_stop(d)
        assert d.tool('get_stack', tid=target.pid)['frames'][0]['symbol'] == 'Perl_av_store'
        text = shot(d, 'perl-store-again')
        assert 'undef' in text and '3 slots' in text and 'not in scope here' not in text, text
        # A pointer preview used to consume the available width before the
        # stale suffix. Check this row itself, not a nearby shorter value.
        d.keys('down', 42, 'tap', 18, 'up', 42, 'tap', 50, 'tap', 21,
               'down', 42, 'tap', 12, 'up', 42, 'tap', 25, 'tap', 18, 'tap', 19, 'tap', 38, 'tap', 28)
        for bp in d.tool('get_breakpoints')['definitions']:
            d.tool('remove_breakpoint', generation=d.session()['generation'], id=bp['id'])
        d.tool('continue', generation=d.session()['generation'])
        assert d.wait(lambda s: s['state'] == 'running')
        text = shot(d, 'perl-running-stale')
        assert re.search(r'my_perl\s+stale:\s*running', text), text
        assert d.session()['state'] == 'running'
        checks.append('Perl demo: val undef -> not in scope -> undef; av 3 -> 4 -> 3 slots, without re-adding')
    finally:
        if d: d.close()
        if target.poll() is None: target.terminate()
        try: target.wait(timeout=5)
        except subprocess.TimeoutExpired: target.kill(); target.wait()
        (work / 'perl-stderr.txt').write_bytes(target.stderr.read())
(work / 'results.json').write_text(json.dumps({'passed': checks}, indent=2))
print('Live display GUI:', len(checks), 'groups passed;', work.relative_to(root))
