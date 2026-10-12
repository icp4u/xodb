#!/usr/bin/env python3
"""GDScript named locals on a private compositor: the parameters, locals and
members of a selected script level with their Variant previews, scrolling,
an expression path, and the same expression in another level (fast lane;
GUI <= ~15 s).
Run: python3 tests/gdscript-values-gui.py --redot /path/to/engine --work out/gdvg"""
import argparse, importlib.util, json, os, re, shutil, subprocess, time
from pathlib import Path
from PIL import Image, ImageOps
p = argparse.ArgumentParser(description=__doc__); p.add_argument('--redot', required=True); p.add_argument('--work', type=Path, required=True); a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
# The input helper only acts inside a private test display under .work/input-*.
w = (a.work / '.work/input-gdv').resolve()
if w.exists(): shutil.rmtree(w)
w.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py'); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (w / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w / (stem + '.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w / (stem + '.c'))], check=True, timeout=10)
h.HELPER = str(w / 'vinput'); subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c', str(w / 'virtual-pointer.c'), str(w / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
started = time.monotonic()
engine = Path(a.redot).resolve()
DELAY = '_ZNK8CoreBind2OS10delay_msecEi'   # the engine function behind the script's OS.delay_msec()
each = (engine.stat().st_size * 11 // 10 >> 20) + 1
limits = ['--image-limit', f'{each}M', '--image-total-limit', f'{max(2 * each, 512)}M']
shutil.copytree(root / 'tests/fixtures/redot-values', w / 'project')
log = open(w / 'game.out', 'wb')
game = subprocess.Popen([str(engine), '--headless', '--path', str(w / 'project')], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
d = None
try:
    deadline = time.monotonic() + 120
    while True:
        lines = (w / 'game.out').read_text(errors='replace').splitlines()
        truth = {l.split(' ', 2)[1]: json.loads(l.split(' ', 2)[2]) for l in lines if l.startswith('ORACLE ')}
        if 'locals' in truth: break
        assert game.poll() is None and time.monotonic() < deadline, lines[-8:]
        time.sleep(.02)
    h.Display.reply_seconds = 120  # the first read of a gigabyte image on a busy host
    # A taller view than the default: the pane below the script stack shows several bindings.
    d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(game.pid), '--break', DELAY, *limits], output_size=(1920, 1200))
    def stack(generation):
        deadline = time.monotonic() + 120
        while True:
            reply = d.request('tools/call', {'name': 'get_language_stack', 'arguments': {'tid': game.pid, 'language': 'gdscript', 'generation': generation}})
            if not reply.get('isError'): return reply['structuredContent']
            assert reply['content'][0]['text'].endswith('Pending') and time.monotonic() < deadline, reply
            time.sleep(.02)
    deadline = time.monotonic() + 120
    while True:
        s = d.wait(lambda s: s['state'] == 'stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'], seconds=120)
        assert s, d.tail()
        generation = s['generation']
        found = stack(generation)
        if found['in_script'] and any(t['tid'] == game.pid and t['reason'] == 'breakpoint' for t in s['threads']): break
        assert time.monotonic() < deadline, found
        d.tool('continue', generation=generation)
        d.wait(lambda s: s['generation'] != generation and s['state'] == 'stopped', seconds=60)
    assert [f['name'] for f in found['segments'][0]['frames']] == ['take_hit', 'swing', 'act', '_process'], found
    regs = d.tool('get_registers', tid=game.pid)
    deadline = time.monotonic() + 60
    while True:
        tabs = d.tool('get_language_tabs')['view']['tabs']
        if next(t for t in tabs if t['tab'] == 'gdscript')['status'] == 'ready': break
        assert time.monotonic() < deadline, tabs
        time.sleep(.02)
    d.tool('select_language_tab', generation=generation, tab='gdscript')
    args = dict(generation=generation, tid=game.pid, language='gdscript', segment=0)
    d.tool('select_language_frame', **args, frame=1)
    rows = d.tool('get_language_locals', **args, frame=1)
    assert [r['name'] for r in rows['rows'][:5]] == ['weapon', 'power', 'damage', 'tags', 'aim'] and rows['total'] == 18, rows
    normalize = lambda t: re.sub(r'[^a-z0-9]', '', t.lower())
    def visible(label, wanted, absent=()):
        deadline = time.monotonic() + 20
        while True:
            shot = d.shot(label); crop = shot + '.side.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((1522, 590, 1908, 862)).convert('L')); pane.resize((pane.width * 3, pane.height * 3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
            Path(shot + '.side.txt').write_text(text)
            if all(part in normalize(text) for part in wanted) and all(part not in normalize(text) for part in absent): return text
            assert time.monotonic() < deadline, (label, text)
            time.sleep(.05)
    # The selected level's parameters and locals, with previews and scopes.
    first = visible('gdscript-locals', ['namedlocals', 'weapondictionary3', 'damage', 'parameter', 'power30', 'damage12', 'tagsarray2sharpsteel', 'local', 'aim6590', 'more'])
    # Scrolling reaches self and the members; the hint counts what is left.
    for _ in range(3): d.keys('scroll', 1700, 760, 1)
    members = visible('gdscript-members', ['titlearia', 'hp90', 'speed25', 'member'], ['weapon'])
    for _ in range(3): d.keys('scroll', 1700, 760, -1)
    # E, a path, Return: the value is read from this stop, nothing is evaluated.
    d.keys('tap', 18, 'tap', 35, 'tap', 25, 'tap', 28)
    typed = visible('gdscript-expression', ['ehp90', 'weapondictionary3'])
    value = d.tool('evaluate_language_expression', **args, frame=1, expression='inventory["sword"].damage')
    assert value['rows'][0]['value']['display'] == '12', value
    # Another level, the same name: the innermost level's object has no hp,
    # and the pane says so with the reader's own reason.
    d.tool('select_language_frame', **args, frame=0)
    visible('gdscript-inner-locals', ['fromplayernode2d', 'damage12', 'dealt9'])
    d.keys('tap', 18, 'tap', 35, 'tap', 25, 'tap', 28)
    inner = visible('gdscript-inner', ['ehpgdscriptnamenotfound', 'fromplayernode2d', 'damage12'])
    assert str(truth['locals']['dealt']) == next(r for r in d.tool('get_language_locals', **args, frame=0)['rows'] if r['name'] == 'dealt')['value']['display'], truth
    # Rendering, scrolling and the expression are presentation only.
    assert d.session()['generation'] == generation and d.tool('get_registers', tid=game.pid) == regs
    (w / 'results.json').write_text(json.dumps(dict(status='pass', ocr=dict(locals=first, members=members, expression=typed, inner=inner), display_dir=d.dir, seconds=round(time.monotonic() - started, 1)), indent=2) + '\n')
finally:
    if d: d.close()
    if game.poll() is None: game.kill()
    game.wait(timeout=30); log.close()
print(f'GDScript GUI: named locals, members, scrolling and an expression path rendered ({time.monotonic() - started:.1f}s)')
