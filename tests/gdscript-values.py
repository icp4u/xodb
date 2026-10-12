#!/usr/bin/env python3
"""GDScript locals, members and Variant values of an owned Godot 4 / Redot
game, read from stopped memory and checked against what the scripts printed:
every Variant type, containers one level at a time, object members, paths,
and a run where the engine kept no local names.
Run: python3 tests/gdscript-values.py --redot /path/to/engine --work out/gdv
The engine must be a debug-enabled build with DWARF. Fast lane: about 4 s
with a 1.4 GB engine."""
import argparse, json, os, re, shutil, subprocess, time
from pathlib import Path
from client import Client
from helpers.readonly import audit

DELAY = '_ZNK8CoreBind2OS10delay_msecEi'   # the engine function behind the script's OS.delay_msec()
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', required=True, help='engine binary (debug-enabled, with DWARF)')
p.add_argument('--work', type=Path, required=True)
p.add_argument('--strace', action='store_true', help='also prove that reading values only reads')
a = p.parse_args(); root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True); w.chmod(0o755)
began = time.monotonic()
engine = Path(a.redot).resolve()
each = (engine.stat().st_size * 11 // 10 >> 20) + 1
limits = ['--image-limit', f'{each}M', '--image-total-limit', f'{max(2 * each, 512)}M']
fixture = root / 'tests/fixtures/redot-values'
result = {'status': 'running'}

def check(condition, message):
    if not condition: raise SystemExit('FAIL: ' + str(message)[:6000])

# The same project twice: as shipped, and without the setting that makes the
# engine keep the names of local variables.
SETTING = 'settings/gdscript/always_track_local_variables=true\n'
games = {}
for name in ('named', 'unnamed'):
    project = w / name
    if project.exists(): shutil.rmtree(project)
    shutil.copytree(fixture, project)
    if name == 'unnamed':
        text = (project / 'project.godot').read_text(); check(SETTING in text, text)
        (project / 'project.godot').write_text(text.replace(SETTING, ''))
    log = open(w / (name + '.out'), 'wb')
    games[name] = (subprocess.Popen([str(engine), '--headless', '--path', str(project)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT), log)
def oracle(name):
    deadline = time.monotonic() + 120
    while True:
        lines = (w / (name + '.out')).read_text(errors='replace').splitlines()
        found = {l.split(' ', 2)[1]: json.loads(l.split(' ', 2)[2]) for l in lines if l.startswith('ORACLE ')}
        if all(key in found for key in ('text', 'ids', 'stack', 'locals', 'wrong', 'inventory')): return found
        check(games[name][0].poll() is None, f'{name} game exited: ' + '\n'.join(lines[-8:]))
        check(time.monotonic() < deadline, f'{name} game printed no oracle: ' + '\n'.join(lines[-8:]))
        time.sleep(.02)
def script_stop(name):
    """Attach and run to a stop of the main thread inside the script's sleep."""
    pid = games[name][0].pid
    client = Client('control', None, options=['--attach', str(pid), '--break', DELAY, *limits], reply_seconds=120)
    session = client.stopped(seconds=120)
    deadline = time.monotonic() + 120
    while True:
        generation = session['generation']
        while True:
            reply = client.tool('get_language_stack', language='gdscript', tid=pid, generation=generation)['result']
            if not reply.get('isError'): break
            why = reply['content'][0]['text']
            check(why.endswith('Pending') and time.monotonic() < deadline, reply); time.sleep(.005)
        stack = reply['structuredContent']
        if stack['in_script'] and any(t['tid'] == pid and t['reason'] == 'breakpoint' for t in session['threads']): return client, pid, generation, stack, session
        check(time.monotonic() < deadline, 'no stop in script')
        client.tool('continue', generation=generation); session = client.stopped('breakpoint', seconds=60)

client = None
try:
    truth = oracle('named')
    ids = truth['ids']
    client, pid, generation, stack, session = script_stop('named')
    frames = stack['segments'][0]['frames']
    check([(f['name'], f['file'], f['line']) for f in frames] == [(f['function'], f['source'], f['line']) for f in truth['stack']] and [f['name'] for f in frames] == ['take_hit', 'swing', 'act', '_process'], frames)
    base = dict(language='gdscript', tid=pid, generation=generation, segment=0)
    timing = []
    def page(frame, **more):
        started = time.monotonic()
        reply = client.tool('get_language_locals', **base, frame=frame, **more)['result']
        check(not reply.get('isError'), reply)
        timing.append(dict(frame=frame, ms=round(1000 * (time.monotonic() - started), 2), reads=reply['structuredContent']['memory_reads'], bytes=reply['structuredContent']['memory_bytes'], rows=len(reply['structuredContent']['rows'])))
        return reply['structuredContent']
    def locals_of(frame):
        """Every row of a level, by paging as a client would."""
        rows, start = [], 0
        while True:
            view = page(frame, start=start)
            check(view['start'] == start and view['language'] == 'gdscript' and view['frame'] == frame and not view['truncated'] and len(view['rows']) <= 32, view)
            rows += view['rows']; start += len(view['rows'])
            if start >= view['total']: return rows, view
            check(view['rows'], view)
    def refusal(tool, **args):
        reply = client.tool(tool, **dict(base, **args))['result']
        check(reply.get('isError'), (args, reply))
        return reply['content'][0]['text']
    def value(frame, expression):
        reply = client.tool('evaluate_language_expression', **base, frame=frame, expression=expression)['result']
        check(not reply.get('isError'), (expression, reply))
        view = reply['structuredContent']
        check(view['total'] == len(view['rows']) <= 1, view)
        return view['rows'][0] if view['rows'] else view['diagnostic']
    def brief(rows): return [(r['name'], r['scope'], r['value']['type'], r['value']['display']) for r in rows]
    node = lambda name, cls, path, script=None: f"{name}:<{cls}#{ids[name.lower()]}> {path}" + (f' ({script})' if script else '')
    PLAYER, DUMMY = node('Player', 'Node2D', '/root/Arena/Player', 'res://player.gd'), node('Dummy', 'Node2D', '/root/Arena/Dummy', 'res://dummy.gd')
    WEAPON = 'Dictionary(3) {"damage": 12, "tags": Array(2) ["sharp", "steel"], "reach": 1.5}'

    # 1. The innermost level: parameters, locals, self and its members, in
    #    the order and under the names the script declares them.
    rows0, view0 = locals_of(0)
    check(view0['diagnostic'] is None and view0['runtime_build_id'] and view0['memory_reads'] < 2000, view0)
    here = next(r for r in rows0 if r['name'] == 'here')
    check(brief(rows0) == [('from', 'parameter', 'Node2D', PLAYER), ('damage', 'parameter', 'int', '12'), ('aim', 'parameter', 'Vector2', '(6.5, -9.0)'),
                           ('dealt', 'local', 'int', '9'), ('note', 'local', 'String', '"Aria hits for 9"'), ('here', 'local', 'Array', here['value']['display']),
                           ('self', 'context', 'Node2D', DUMMY), ('armor', 'member', 'int', '3'), ('hits', 'member', 'Array', 'Array(1) ["Aria hits for 9"]'), ('announced', 'member', 'bool', 'true')], brief(rows0))
    check(here['value']['count'] == 4 and here['value']['display'].startswith('Array(4) [Dictionary(3) {"source": "res://dummy.gd", "function": "take_hit", "line": %d}, ' % truth['stack'][0]['line']) and [c['key'] for c in here['value']['children']] == ['0', '1', '2', '3'], here)
    # The script's own numbers, and its planted wrong ones.
    named = {r['name']: r['value']['display'] for r in rows0}
    seen = dict(damage=int(named['damage']), dealt=int(named['dealt']), note=json.loads(named['note']), armor=int(named['armor']),
                hp=int(value(0, 'from.hp')['value']['display']), gold=int(value(0, 'from.inventory["gold"]')['value']['display']))
    check(seen == truth['locals'] and seen != truth['wrong'], (seen, truth['locals'], truth['wrong']))
    # An object's children are its script members, by name.
    sender = rows0[0]['value']
    check(sender['count'] == 12 and [c['key'] for c in sender['children']][:5] == ['title', 'hp', 'speed', 'alive', 'velocity'] and sender['children'][1]['display'] == '90', sender)
    check(rows0[0]['address'] and rows0[0]['slot_address'] and rows0[1]['address'] is None, rows0[:2])
    # A slot address is where the Variant is: its data word holds the value.
    slot = next(r for r in rows0 if r['name'] == 'armor')['slot_address']
    check(int.from_bytes(bytes.fromhex(client.inspect('read_memory', address=hex(slot + 8), length=8, generation=generation)['hex']), 'little') == 3, slot)

    # 2. One and two calls up: a level's own names, never its callee's.
    rows1, view1 = locals_of(1)
    check(brief(rows1)[:6] == [('weapon', 'parameter', 'Dictionary', WEAPON), ('power', 'parameter', 'float', '3.0'), ('damage', 'local', 'int', '12'),
                               ('tags', 'local', 'Array', 'Array(2) ["sharp", "steel"]'), ('aim', 'local', 'Vector2', '(6.5, -9.0)'), ('self', 'context', 'Node2D', PLAYER)], brief(rows1)[:6])
    members = {r['name']: r for r in rows1 if r['scope'] == 'member'}
    declared = re.findall(r'^(?:@onready )?var (\w+)', (fixture / 'player.gd').read_text(), re.M)
    check([r['name'] for r in rows1 if r['scope'] == 'member'] == declared and len(declared) == 12, (list(members), declared))
    check(brief([members[n] for n in ('title', 'hp', 'speed', 'alive', 'velocity', 'tint', 'items', 'waypoints', 'hand', 'target')]) == [
        ('title', 'member', 'String', '"Aria"'), ('hp', 'member', 'int', '90'), ('speed', 'member', 'float', '2.5'), ('alive', 'member', 'bool', 'true'), ('velocity', 'member', 'Vector2', '(3.25, -4.5)'),
        ('tint', 'member', 'Color', '(1.0, 0.5, 0.25, 1.0)'), ('items', 'member', 'Array', 'Array(3) ["sword", "shield", "bow"]'), ('waypoints', 'member', 'PackedVector2Array', 'PackedVector2Array(2) [(0.0, 0.0), (10.0, 2.5)]'),
        ('hand', 'member', 'Node2D', node('Hand', 'Node2D', '/root/Arena/Player/Hand')), ('target', 'member', 'Node2D', DUMMY)], members)
    check(members['inventory']['value']['display'] == 'Dictionary(4) {"sword": Dictionary(3) {"damage": 12, "tags": Array(2), "reach": 1.5}, "potions": Array(3) [3, 5, 8], "gold": 250, 7: "lucky"}' and members['inventory']['value']['count'] == 4, members['inventory'])
    check([(c['key'], c['type'], c['display']) for c in members['inventory']['value']['children']] == [('"sword"', 'Dictionary', 'Dictionary(3) {"damage": 12, "tags": Array(2), "reach": 1.5}'), ('"potions"', 'Array', 'Array(3) [3, 5, 8]'), ('"gold"', 'int', '250'), ('7', 'String', '"lucky"')], members['inventory'])
    rows2, view2 = locals_of(2)
    check(brief(rows2)[:5] == [('frame', 'parameter', 'int', rows2[0]['value']['display']), ('dummy', 'parameter', 'Node2D', DUMMY), ('weapon', 'local', 'Dictionary', WEAPON), ('reach', 'local', 'float', '1.5'), ('self', 'context', 'Node2D', PLAYER)], brief(rows2)[:5])

    # 3. Every Variant type, as members of the outermost level's object. The
    #    math types must read exactly as the engine itself printed them.
    rows3, view3 = locals_of(3)
    check(brief(rows3)[:2] == [('delta', 'parameter', 'float', rows3[0]['value']['display']), ('self', 'context', 'Node', node('Arena', 'Node', '/root/Arena', 'res://arena.gd'))], brief(rows3)[:2])
    arena = {r['name']: r for r in rows3 if r['scope'] == 'member'}
    check(list(arena) == re.findall(r'^var (\w+)', (fixture / 'arena.gd').read_text(), re.M) and len(arena) == 50 and view3['total'] == 52, list(arena))
    TYPES = dict(v_int='int', v_float='float', v_whole='float', v_vec2='Vector2', v_vec2i='Vector2i', v_rect='Rect2', v_recti='Rect2i', v_vec3='Vector3', v_vec3i='Vector3i', v_xform2d='Transform2D', v_vec4='Vector4',
                 v_vec4i='Vector4i', v_plane='Plane', v_quat='Quaternion', v_aabb='AABB', v_basis='Basis', v_xform3d='Transform3D', v_color='Color')
    check(set(TYPES) == set(truth['text']), truth['text'])
    expected = {name: (TYPES[name], text) for name, text in truth['text'].items()}
    expected.update({
        'v_nil': ('Nil', 'null'), 'v_bool': ('bool', 'true'), 'v_string': ('String', '"héllo wörld"'), 'v_name': ('StringName', '&"beta_name"'),
        'v_path': ('NodePath', '^"/root/Arena/Player:position:x"'), 'v_relative': ('NodePath', '^"Player/Hand"'),
        'v_proj': ('Projection', '[(1.0, 0.0, 0.0, 0.0), (0.0, 1.0, 0.0, 0.0), (0.0, 0.0, 1.0, 0.0), (5.0, 6.0, 7.0, 1.0)]'), 'v_rid': ('RID', 'RID(77)'),
        'v_node': ('Node2D', PLAYER), 'v_ref': ('RefCounted', f"<RefCounted#{ids['ref']}>"), 'v_null': ('Nil', 'null'), 'v_freed': ('Object', f"<Freed Object#{ids['freed']}>"),
        'v_callable': ('Callable', f"Callable(noted on #{ids['arena']})"), 'v_lambda': ('Callable', 'Callable(custom)'), 'v_signal': ('Signal', f"Signal(tree_exiting on #{ids['arena']})"),
        'v_dict': ('Dictionary', 'Dictionary(4) {"k_int": 4, "k_str": "alpha", 7: 2.5, &"k_name": (1, 2)}'),
        'v_array': ('Array', 'Array(7) [4, 1.5, "alpha", (3.25, -4.5), Array(2) [1, Array(1)], Dictionary(1) {"a": 1}, null]'),
        'v_bytes': ('PackedByteArray', 'PackedByteArray(3) [1, 2, 255]'), 'v_i32': ('PackedInt32Array', 'PackedInt32Array(3) [10, 20, -30]'), 'v_i64': ('PackedInt64Array', 'PackedInt64Array(2) [1099511627776, -5]'),
        'v_f32': ('PackedFloat32Array', 'PackedFloat32Array(2) [1.5, -0.25]'), 'v_f64': ('PackedFloat64Array', 'PackedFloat64Array(2) [2.718281828, 0.001]'), 'v_strings': ('PackedStringArray', 'PackedStringArray(2) ["a", "bc"]'),
        'v_vec2s': ('PackedVector2Array', 'PackedVector2Array(2) [(1.0, 2.0), (3.0, 4.0)]'), 'v_vec3s': ('PackedVector3Array', 'PackedVector3Array(1) [(1.0, 2.0, 3.0)]'),
        'v_colors': ('PackedColorArray', 'PackedColorArray(1) [(1.0, 0.0, 0.0, 1.0)]'), 'v_vec4s': ('PackedVector4Array', 'PackedVector4Array(1) [(1.0, 2.0, 3.0, 4.0)]'),
        'v_big': ('Array', 'Array(100) [0, 1, 2, 3, 4, 5, 6, 7, …]'), 'v_long': ('String', '"' + 'x' * 96 + '…"'), 'v_empty': ('Array', 'Array(0)'), 'v_none': ('Dictionary', 'Dictionary(0)'),
    })
    got = {name: (row['value']['type'], row['value']['display']) for name, row in arena.items() if name != 'frames'}
    check(got == expected, sorted((n, got.get(n), expected.get(n)) for n in set(got) | set(expected) if got.get(n) != expected.get(n)))
    reasons = {name: row['value']['diagnostic'] for name, row in arena.items() if row['value']['diagnostic']}
    check(reasons == {'v_freed': 'GDScriptObjectFreed'}, reasons)
    check(arena['v_big']['value']['truncated'] and arena['v_big']['value']['count'] == 100 and len(arena['v_big']['value']['children']) == 12, arena['v_big'])
    check(arena['v_long']['value']['truncated'] and arena['v_long']['value']['count'] == 300 and not arena['v_dict']['value']['truncated'], arena['v_long'])
    check(arena['v_ref']['address'] and arena['v_freed']['address'] is None and arena['v_null']['address'] is None, arena['v_ref'])
    # Paging with a small limit gives the same rows.
    small = page(3, start=20, limit=5)
    check(small['total'] == 52 and small['start'] == 20 and small['rows'] == rows3[20:25], small)
    check(page(3, start=52)['rows'] == [] and page(3, start=4096)['start'] == 52, 'past the end')

    # 4. Paths: one step at a time through members, containers and objects.
    def shown(frame, expression):
        row = value(frame, expression)
        check(isinstance(row, dict) and row['name'] == expression, (expression, row))
        return row['value']['display']
    for frame, expression, display in ((1, 'inventory["sword"].damage', '12'), (1, "inventory['sword']['tags'][1]", '"steel"'), (1, 'items[2]', '"bow"'), (1, 'items[-1]', '"bow"'), (1, 'inventory.potions[-1]', '8'),
                                       (1, 'inventory[7]', '"lucky"'), (1, 'self.hp', '90'), (1, 'hp', '90'), (1, 'target.armor', '3'), (1, 'hand', node('Hand', 'Node2D', '/root/Arena/Player/Hand')),
                                       (1, 'velocity.x', '3.25'), (1, 'tint.g', '0.5'), (1, 'waypoints[1]', '(10.0, 2.5)'), (1, 'waypoints[1].y', '2.5'), (1, 'weapon.reach', '1.5'), (1, 'damage', '12'),
                                       (0, 'from.inventory.sword.tags[0]', '"sharp"'), (0, 'here[1].function', '"swing"'), (0, 'self', DUMMY), (2, 'dummy.hits[0]', '"Aria hits for 9"'),
                                       (3, 'v_big[57]', '57'), (3, 'v_array[4][1][0]', '2'), (3, 'v_dict.k_name', '(1, 2)'), (3, 'v_dict.k_name.y', '2'), (3, 'v_dict[7]', '2.5'), (3, 'v_bytes[2]', '255'),
                                       (3, 'v_i32[-1]', '-30'), (3, 'v_strings[1]', '"bc"'), (3, 'v_rect.size', '(30.0, 40.0)'), (3, 'v_vec3i.z', '3'), (3, 'v_node.target.hits', 'Array(1) ["Aria hits for 9"]')):
        check(shown(frame, expression) == display, (frame, expression, shown(frame, expression), display))
    # A local shadows a member of the same name; the caller's own is its own.
    check(shown(1, 'damage') == '12' and value(0, 'weapon') == 'GDScriptNameNotFound' and value(1, 'dealt') == 'GDScriptNameNotFound', 'scopes')
    # The whole inventory, rebuilt from one-level expansions, is what the script printed.
    def rebuild(expression):
        row = value(1, expression); check(isinstance(row, dict), (expression, row))
        kind, text, items = row['value']['type'], row['value']['display'], row['value']['children']
        check(not row['value']['truncated'] and row['value']['diagnostic'] is None, row)
        if kind == 'Dictionary': return {str(json.loads(item['key'])): rebuild(f"{expression}[{item['key']}]") for item in items}
        if kind == 'Array': return [rebuild(f"{expression}[{item['key']}]") for item in items]
        check(kind in ('int', 'float', 'String'), row)
        return json.loads(text)
    check(rebuild('inventory') == truth['inventory'], (rebuild('inventory'), truth['inventory']))
    # Past the children a row carries, an index reaches every element.
    check([int(shown(3, f'v_big[{i}]')) for i in (0, 12, 31, 99)] == [0, 12, 31, 99], 'v_big')
    check(len(value(3, 'v_big')['value']['children']) == 32 and value(3, 'v_big')['value']['truncated'], value(3, 'v_big')['value'])

    # 5. Typed answers for what is not there, and for what is not supported.
    for frame, expression, why in ((1, 'nothing', 'GDScriptNameNotFound'), (1, 'items[3]', 'GDScriptIndexOutOfRange'), (1, 'items[-4]', 'GDScriptIndexOutOfRange'), (1, 'inventory["shield"]', 'GDScriptKeyNotFound'),
                                   (1, 'inventory[8]', 'GDScriptKeyNotFound'), (1, 'hp[0]', 'GDScriptPathNotContainer'), (1, 'hp.x', 'GDScriptPathNotContainer'), (1, 'items.first', 'GDScriptPathNeedsIndex'),
                                   (1, 'hand.grip', 'GDScriptObjectHasNoScript'), (1, 'target.shield', 'GDScriptMemberNotFound'), (1, 'self[0]', 'GDScriptPathNotIndexable'),
                                   (3, 'v_null.x', 'GDScriptPathNotContainer'), (3, 'v_freed.x', 'GDScriptObjectFreed'), (3, 'v_empty[0]', 'GDScriptIndexOutOfRange')):
        check(value(frame, expression) == why, (frame, expression, value(frame, expression), why))
    for expression in ('hp + 1', 'items[', 'take_hit()', '7', 'a.b.c.d.e.f.g.h.i.j', 'items[1.5]'):
        check(refusal('evaluate_language_expression', frame=1, expression=expression) == 'GDScriptExpressionUnsupported', expression)
    check(refusal('get_language_locals', frame=4) == 'InvalidLanguageFrame' and refusal('evaluate_language_expression', frame=9, expression='hp') == 'InvalidLanguageFrame', 'frame')
    check(client.tool('get_language_locals', **dict(base, segment=1), frame=0)['result']['content'][0]['text'] == 'InvalidLanguageSegment', 'segment')
    # A thread that runs no script has no level to read.
    other = next(t['tid'] for t in session['threads'] if t['tid'] != pid)
    check(client.tool('get_language_locals', **dict(base, tid=other), frame=0)['result']['content'][0]['text'] == 'InvalidLanguageFrame', other)
    # A stale generation is refused before anything is read.
    check(client.tool('get_language_locals', **dict(base, generation=generation + 1), frame=0)['result'].get('isError'), 'generation')
    # Reading changed nothing, and (with --strace) only read.
    check(client.session()['generation'] == generation, 'generation moved')
    if a.strace: result['readonly'] = audit(client, pid, w / 'readonly.strace', lambda: (page(1), value(1, 'inventory["sword"].damage')))
    first = [t for t in timing if t['rows']][:4]
    result['named'] = {'frames': [f['name'] for f in frames], 'rows': [len(rows0), len(rows1), len(rows2), len(rows3)], 'variant_types': len(expected), 'paths': 31, 'refusals': 14,
                       'locals_ms': [t['ms'] for t in first], 'locals_reads': [t['reads'] for t in first], 'locals_bytes': [t['bytes'] for t in first],
                       'slowest_ms': max(t['ms'] for t in timing), 'most_reads': max(t['reads'] for t in timing), 'load': os.getloadavg()[0]}
    client.tool('detach', generation=generation); client.close(); client = None

    # 6. The engine kept no local names: parameters keep theirs from the
    #    function's signature, other slots are listed by position, members
    #    are unaffected, and the view says so.
    oracle('unnamed')
    client, pid, generation, stack, session = script_stop('unnamed')
    base = dict(language='gdscript', tid=pid, generation=generation, segment=0)
    rows, view = locals_of(0)
    check(view['diagnostic'] == 'GDScriptLocalNamesNotTracked', view['diagnostic'])
    check(brief(rows)[:3] == [('from', 'parameter', 'Node2D', rows[0]['value']['display']), ('damage', 'parameter', 'int', '12'), ('aim', 'parameter', 'Vector2', '(6.5, -9.0)')], brief(rows)[:3])
    slots = [r for r in rows if r['scope'] == 'local']
    check(slots and all(re.fullmatch(r'stack\[\d+\]', r['name']) for r in slots) and {'9', '"Aria hits for 9"'} <= {r['value']['display'] for r in slots}, brief(slots))
    check(brief([r for r in rows if r['scope'] in ('context', 'member')])[1:] == [('armor', 'member', 'int', '3'), ('hits', 'member', 'Array', 'Array(1) ["Aria hits for 9"]'), ('announced', 'member', 'bool', 'true')], brief(rows))
    check(value(0, 'damage')['value']['display'] == '12' and value(0, 'dealt') == 'GDScriptNameNotFound' and value(0, 'from.hp')['value']['display'] == '90', 'unnamed paths')
    result['unnamed'] = {'diagnostic': view['diagnostic'], 'rows': [r['name'] for r in rows]}
    client.tool('detach', generation=generation); client.close(); client = None
    result['status'] = 'passed'
finally:
    if client is not None:
        client.p.kill(); client.p.wait()
    for name, (game, log) in games.items():
        if game.poll() is None: game.kill()
        game.wait(timeout=30); log.close()
    result['seconds'] = round(time.monotonic() - began, 2)
    (w / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
check(result['status'] == 'passed', result)
