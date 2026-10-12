#!/usr/bin/env python3
"""GDScript call stack of an owned Godot 4 / Redot game, read from stopped
memory and checked against the stack the script itself printed.
Run: python3 tests/gdscript-stack.py --redot /path/to/engine --work out/gd
The engine must be a debug-enabled build with DWARF (an editor or a
template_debug binary). Fast lane: about 10 s with a 1.4 GB engine."""
import argparse, json, os, shutil, subprocess, sys, time
from pathlib import Path
from client import Client
from helpers.readonly import audit

CALL = '_ZN16GDScriptFunction4callE'
SINGLETON = '_ZN16GDScriptLanguage9singletonE'
DELAY = '_ZNK7OS_Unix10delay_usecEj'   # OS_Unix::delay_usec: under Worker.leaf (and other threads' sleeps)
FRAME = '_ZN2OS15add_frame_delayEbb'    # OS::add_frame_delay: the main loop between frames, no script
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', required=True, help='engine binary (debug-enabled, with DWARF)')
p.add_argument('--work', type=Path, required=True)
p.add_argument('--strace', action='store_true', help='also prove that reading the stack only reads')
a = p.parse_args(); root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True); w.chmod(0o755)
began = time.monotonic()
engine = Path(a.redot).resolve()
result = {'status': 'running', 'engine_bytes': engine.stat().st_size}

def check(condition, message):
    if not condition: raise SystemExit('FAIL: ' + str(message)[:4000])

# The engine with its DWARF, without it, and without any symbol table.
nodwarf, nosym = w / 'engine.nodwarf', w / 'engine.nosym'
subprocess.run(['objcopy', '--strip-debug', str(engine), str(nodwarf)], check=True, timeout=300)
subprocess.run(['objcopy', '--strip-all', str(engine), str(nosym)], check=True, timeout=300)
if (w / 'project').exists(): shutil.rmtree(w / 'project')
shutil.copytree(root / 'tests/fixtures/redot', w / 'project')

games = {}
def start(name, binary):
    log = open(w / (name + '.out'), 'wb')
    games[name] = (subprocess.Popen([str(binary), '--headless', '--path', str(w / 'project')], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT), log)
def oracle(name):
    """The script's own stack, and its planted wrong one, once it has run."""
    deadline = time.monotonic() + 120
    while True:
        lines = (w / (name + '.out')).read_text(errors='replace').splitlines()
        found = {l.split(' ', 2)[1]: json.loads(l.split(' ', 2)[2]) for l in lines if l.startswith('ORACLE ')}
        if 'stack' in found and 'wrong' in found: return found['stack'], found['wrong']
        check(games[name][0].poll() is None, f'{name} game exited: ' + '\n'.join(lines[-8:]))
        check(time.monotonic() < deadline, f'{name} game printed no oracle: ' + '\n'.join(lines[-8:]))
        time.sleep(.02)
def limits(path):
    """Budgets that hold this image: its size plus a tenth, and twice that."""
    each = (path.stat().st_size * 11 // 10 >> 20) + 1
    return ['--image-limit', f'{each}M', '--image-total-limit', f'{max(2 * each, 512)}M']
def language_stack(client, **args):
    deadline = time.monotonic() + 120
    while True:
        reply = client.tool('get_language_stack', language='gdscript', **args)['result']
        if not reply.get('isError'): return reply['structuredContent'], None
        why = [item['text'] for item in reply['content']]
        if why[0] not in ('SymbolDiscoveryPending', 'DebugMetadataPending'): return None, why
        check(time.monotonic() < deadline, why); time.sleep(.005)
def tab(client):
    deadline = time.monotonic() + 120
    while True:
        view = client.inspect('get_language_tabs')['view']
        if view['complete']: return next(t for t in view['tabs'] if t['tab'] == 'gdscript')
        check(time.monotonic() < deadline, view); time.sleep(.01)
def shown(stack):
    return [(f['name'], f['file'], f['line']) for f in stack['segments'][0]['frames']]
def matches(stack, truth):
    return shown(stack) == [(f['function'], f['source'], f['line']) for f in truth]

client = None
try:
    for name, binary in (('full', engine), ('nodwarf', nodwarf), ('nosym', nosym)): start(name, binary)
    truth, wrong = oracle('full')
    check([f['function'] for f in truth] == ['leaf', 'step', 'plan', '_process'] and truth != wrong, truth)
    pid = games['full'][0].pid

    # 1. Breakpoint stops of the main thread: in OS_Unix::delay_usec under
    #    Worker.leaf (in script) and in the engine's frame delay (not in
    #    script). Both must be seen; other threads hit the first one too.
    client = Client('control', None, options=['--attach', str(pid), '--break', DELAY, '--break', FRAME, *limits(engine)], reply_seconds=120)
    session = client.stopped(seconds=120)
    scripted = idle = None
    deadline = time.monotonic() + 120
    while scripted is None or idle is None:
        check(time.monotonic() < deadline, 'no stop in both states')
        generation = session['generation']
        stack, why = language_stack(client, tid=pid, generation=generation)
        check(stack, why)
        segment = stack['segments'][0]
        check(len(stack['segments']) == 1 and segment['reason'] is None and segment['state'] == 'complete', segment)
        at_break = any(t['tid'] == pid and t['reason'] == 'breakpoint' for t in session['threads'])
        if stack['in_script'] and scripted is None and at_break:
            scripted = stack
            native = client.inspect('get_stack', tid=pid, generation=generation)['frames']
            check(native[0]['symbol'] == DELAY, native[0])
            # The engine's own answer, taken on the line where it now sleeps.
            check(matches(stack, truth), (shown(stack), truth))
            check(not matches(stack, wrong), 'the planted wrong oracle was accepted')
            check(segment['depth'] == segment['call_stack_size'] == 4 and segment['chain_complete'] and not segment['top_in_transition'] and not segment['truncated'], segment)
            check(segment['max_call_stack'] >= 4 and stack['memory_reads'] < 200 and stack['memory_bytes'] < 16384, stack)
            # The native join: one GDScriptFunction::call frame per level, in
            # order, each holding its level's CallLevel record.
            calls = [f['index'] for f in native if (f['symbol'] or '').startswith(CALL)]
            bound = [f['native_binding'] for f in segment['frames']]
            check(all(bound) and [b['frame'] for b in bound] == calls and len(calls) == 4, (bound, calls))
            check(segment['native_call_frames'] == 4 and segment['native_call_frame_without_level'] is None and not stack['native_stack_incomplete'], segment)
            check(segment['anchor'] == bound[0], segment['anchor'])
            for frame, binding in zip(segment['frames'], bound):
                level = int(frame['call_level'], 16); index = binding['frame']
                check(binding['symbol'] == native[index]['symbol'] and int(binding['pc'], 16) == native[index]['pc'], binding)
                check(index > 0 and native[index - 1]['cfa'] <= level < native[index]['cfa'], (hex(level), native[index - 1]['cfa'], native[index]['cfa']))
                check(frame['instance'] and frame['owner_id'] and frame['script_path'] == frame['file'], frame)
            check(bound[0]['frame'] < bound[1]['frame'] < bound[2]['frame'] < bound[3]['frame'], bound)
            # The thread pointer the walk starts from is shown with the registers.
            registers = client.inspect('get_registers', tid=pid)['registers']
            check(int(registers['fs_base'], 16) != 0 and 'gs_base' in registers, registers)
            # The tab, and the shared selection through the join in both directions.
            listed = tab(client)
            check(listed['visible'] and listed['status'] == 'ready' and listed['title'] == 'GDScript' and listed['build_id'], listed)
            view = client.inspect('select_native_frame', tid=pid, frame=bound[1]['frame'], generation=generation)['view']
            chosen = view['logical_selection']
            check(chosen and chosen['language'] == 'gdscript' and chosen['frame'] == 1 and chosen['native_anchor'] == bound[1]['frame'], view)
            check(view['offers']['items'][0]['basis'] == bound[1]['proof'], view['offers'])
            view = client.inspect('select_language_frame', tid=pid, language='gdscript', segment=0, frame=2, generation=generation)['view']
            check(view['native_selection']['frame'] == bound[2]['frame'] and view['logical_selection']['native_pc'] == int(bound[2]['pc'], 16), view)
            # A native frame that holds no level offers nothing.
            view = client.inspect('select_native_frame', tid=pid, frame=0, generation=generation)['view']
            check(view['logical_selection'] is None and view['offers']['items'] == [], view)
            # Another thread of the same stop runs no script.
            others = [t['tid'] for t in session['threads'] if t['tid'] != pid]
            check(others, session['threads'])
            other, why = language_stack(client, tid=others[0], generation=generation)
            check(other and not other['in_script'] and other['segments'][0]['frames'] == [] and other['segments'][0]['state'] == 'complete', (other, why))
            if a.strace: result['readonly'] = audit(client, pid, w / 'readonly.strace', lambda: language_stack(client, tid=pid, generation=generation))
            result['script'] = {'frames': shown(stack), 'native_frames': calls, 'memory_reads': stack['memory_reads'], 'memory_bytes': stack['memory_bytes'], 'other_thread_in_script': other['in_script']}
        elif not stack['in_script'] and idle is None and at_break:
            idle = stack
            native = client.inspect('get_stack', tid=pid, generation=generation)['frames']
            # The probe saw the condition: the same native function, no script above it.
            check(native[0]['symbol'] in (DELAY, FRAME) and not any((f['symbol'] or '').startswith(CALL) for f in native), [f['symbol'] for f in native[:6]])
            check(segment['frames'] == [] and segment['depth'] == 0 and segment['call_stack_size'] == 0 and segment['anchor'] is None and segment['native_call_frames'] == 0, segment)
            check(segment['title'] == 'Not in script code', segment['title'])
            result['idle'] = {'title': segment['title'], 'native_top': [f['symbol'] for f in native[:3]]}
        client.tool('continue', generation=generation)
        session = client.stopped('breakpoint', seconds=60)
    client.tool('detach', generation=client.session()['generation']); client.close(); client = None

    # 2. A budget the engine image does not fit: the refusal says so.
    if engine.stat().st_size > 256 << 20:
        client = Client('control', None, options=['--image-limit', '256M', '--attach', str(pid)], reply_seconds=120)
        generation = client.stopped(seconds=120)['generation']
        stack, why = language_stack(client, tid=pid, generation=generation)
        check(stack is None and why[0] == 'GDScriptImageBudgetExceeded' and len(why) == 2, (stack, why))
        check(' MiB; image budget 256 MiB; rerun with --image-limit ' in why[1] and engine.name in why[1], why)
        listed = tab(client)
        check(not listed['visible'] and listed['status'] in ('absent', 'unavailable'), listed)
        result['budget'] = {'error': why[0], 'detail_has_path': True, 'tab': listed['status']}
        client.tool('detach', generation=generation); client.close(); client = None
    else:
        result['budget'] = 'not applicable: the engine fits the default image budget'

    # 3. No DWARF: the runtime is detected and refused; no layout is guessed.
    #    No symbols at all: nothing is detected. (An engine linked with its
    #    symbols exported keeps them in .dynsym, and is then the first case.)
    exported = SINGLETON in subprocess.run(['nm', '-D', '--defined-only', str(nosym)], capture_output=True, text=True, timeout=120).stdout
    result['nosym_exports_singleton'] = exported
    for name, binary, expected, status in (('nodwarf', nodwarf, 'GDScriptDwarfUnavailable', 'unavailable'),
                                           ('nosym', nosym, *(('GDScriptDwarfUnavailable', 'unavailable') if exported else ('GDScriptRuntimeUnavailable', 'absent')))):
        oracle(name)
        client = Client('control', None, options=['--attach', str(games[name][0].pid), *limits(binary)], reply_seconds=120)
        generation = client.stopped(seconds=120)['generation']
        stack, why = language_stack(client, tid=games[name][0].pid, generation=generation)
        check(stack is None and why == [expected], (name, stack, why))
        listed = tab(client)
        check(not listed['visible'] and listed['status'] == status and listed['build_id'] is None, (name, listed))
        if status == 'unavailable': check(listed['reason'] == expected, listed)
        result[name] = {'error': why[0], 'tab': listed['status'], 'tab_reason': listed['reason']}
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
