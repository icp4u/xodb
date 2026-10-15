"""Owned Wine metadata/GUI checks, invoked by periodic pe-wine.py --ux."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def metadata(client, pid, wrong=False):
    deadline = time.monotonic() + 20
    while True:
        state = client.session()
        labels = state.get('thread_labels', [])
        names = {row['name'] for row in labels}
        if 'GameRender' in names and 'wine_threadpool' in names:
            break
        assert time.monotonic() < deadline, state
        time.sleep(.01)
    assert state['compatibility']['kind'] == 'wine', state['compatibility']
    expected = 'WrongRender' if wrong else 'GameRender'
    assert expected in names, (expected, names)
    rows = {row['tid']: row for row in state['threads']}
    for label in labels:
        assert label['id'] == rows[label['tid']]['id'], label
        if label['name'] is not None:
            raw = Path('/proc', str(pid), 'task', str(label['tid']), 'comm').read_text().rstrip('\n')
            assert label['name'] == raw, (label, raw)
    worker = next(row for row in labels if row['name'] == 'wine_threadpool')
    assert worker['wine_internal_name'] and worker['possibly_truncated'], worker
    assert not next(row for row in labels if row['name'] == 'GameRender')['wine_internal_name']
    return dict(compatibility=state['compatibility'], labels=labels)


def gui(root, work, pid):
    spec = importlib.util.spec_from_file_location('wine_gui_input', root/'tests/helpers/input.py')
    h = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(h)
    h.WORK = str(root/'.work'/('input-wux-'+work.name))
    folder = Path(h.WORK)
    for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
        (folder/name).mkdir(parents=True, exist_ok=True)
    for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
        for mode, suffix in (('client-header', '.h'), ('private-code', '.c')):
            subprocess.run(['wayland-scanner', mode, xml, str(folder/(stem+suffix))], check=True, timeout=10)
    h.HELPER = str(folder/'vinput')
    subprocess.run(['cc', '-I', str(folder), str(root/'tests/helpers/vinput.c'), str(folder/'virtual-pointer.c'),
                    str(folder/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=30)

    def shot(display, name, region, predicate):
        path = str(Path(display.dir)/(name+'.png'))
        deadline = time.monotonic() + 20
        while True:
            subprocess.run(['grim', '-g', region, path], env=display.env, check=True, timeout=10)
            text = ' '.join(h.ocr(path, '--psm', '6').lower().split())
            if predicate(text):
                return text
            assert time.monotonic() < deadline, (name, text)
            time.sleep(.02)

    ticks = Path('/proc', str(pid), 'stat').read_text().rsplit(') ', 1)[1].split()[19]
    prefs = folder/'preferences.json'
    prefs.write_text(json.dumps({'wine': {'hide_internal_threads': True}}))
    display = h.Display(str(root), ['--attach', str(pid), '--expected-start-ticks', ticks,
                                    '--config', str(prefs), '--wine-threads', 'show'])
    try:
        report = metadata(display, pid)
        report['gui_work'] = str(folder)
        shot(display, 'wine-header', '270,0 660x44', lambda t: 'windows process under wine' in t)
        shot(display, 'threads-shown', '0,584 222x185', lambda t: 'wine' in t)
        before = display.session()
        identities = [(t['id'], t['tid']) for t in before['threads']]
        display.keys('tap', 35)
        shot(display, 'hidden', '0,770 1280x30', lambda t: 'wine internal names hidden' in t)
        shot(display, 'threads-hidden', '0,584 222x185', lambda t: 'wine' not in t and '1 hidden' in t)
        after = display.session()
        assert [(t['id'], t['tid']) for t in after['threads']] == identities
        assert after['generation'] == before['generation'] and after['state'] == 'stopped'
        display.keys('tap', 35)
        shot(display, 'shown', '0,770 1280x30', lambda t: 'all threads shown' in t)
        shot(display, 'threads-restored', '0,584 222x185', lambda t: 'wine' in t)
        # Real key navigation reaches the named application thread in the group.
        for _ in range(len(identities)):
            display.keys('tap', 36)
            # The pixels, rather than source text elsewhere in the GUI, prove the label.
            path = str(Path(display.dir)/'threads.png')
            subprocess.run(['grim', '-g', '0,584 222x185', path], env=display.env, check=True, timeout=10)
            if 'gamerender' in ''.join(h.ocr(path, '--psm', '6').lower().split()):
                break
        else:
            raise AssertionError('named application thread did not appear in thread pane')
        report['inventory_preserved'] = True
        report['cli_overrides_config'] = True
    finally:
        display.close()

    # Reuse the existing identity-bound, confirmed overview attach picker.
    replay = folder/'picker.jsonl'
    subprocess.run([sys.executable, '-B', 'tests/fixtures/overview-synth.py', str(replay), '--frames', '1'], check=True, timeout=10)
    sample = json.loads(replay.read_text().splitlines()[0])
    rows = sample['processes']['rows'][:2]
    for row, name in zip(rows, ('owned-game.exe', 'ordinary-native')):
        row['comm'] = name
        row['cmdline'] = name
    sample['processes']['rows'] = rows
    replay.write_text(json.dumps(sample)+'\n')
    picker = h.Display(str(root), ['--attach-exe', '--replay', str(replay), '--pause'], stdio=False)
    try:
        # OCR may split the name at its dot ("owned-game. exe"); compare without spaces.
        text = shot(picker, 'exe-picker', '0,40 1280x700',
                    lambda t: '1shown' in t.replace(' ', '') and 'owned-game.exe' in t.replace(' ', '')
                    and 'ordinary-native' not in t.replace(' ', ''))
        report['picker_filtered'] = True
        report['picker_text'] = text
    finally:
        picker.close()
    return report
