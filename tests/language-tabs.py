#!/usr/bin/env python3
"""Shared language-tab identity and selection on owned stopped programs."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
from types import SimpleNamespace
from helpers.readonly import audit

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--agent', type=Path)
p.add_argument('--strace', action='store_true', help='Audit tab reads/selections on the local owned debugger')
p.add_argument('--python', type=Path)
p.add_argument('--perl', type=Path)
p.add_argument('--lua', action='append', type=Path, default=[])
p.add_argument('--node', type=Path)
a = p.parse_args()
if a.strace and a.agent:
    p.error('--strace currently audits local targets only')
os.umask(0o022)
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
cache = w / 'cache'
cache.mkdir(mode=0o700)
os.environ['XDG_CACHE_HOME'] = str(cache)
if a.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(a.agent.resolve())
binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
main = '''
#include <unistd.h>
__attribute__((noinline)) void marker(void) { __asm__ volatile("" ::: "memory"); }
int main(void) { marker(); marker(); return 0; }
'''
(w / 'native.c').write_text(main)
names = dict(re.findall(r'XJS_FIELD\((\w+), "([^"]+)"\)', (root / 'src/language/javascript_fields.inc').read_text()))
values = dict(re.findall(r'META\((\w+), (-?\d+)\)', (root / 'tests/fixtures/javascript/metadata.inc').read_text()))
source = '\n'.join(f'int f_{key} __asm__("{names[key]}") = {value};' for key, value in values.items())
for name, value in zip(('major', 'minor', 'build', 'patch'), (14, 6, 202, 34)):
    source += f'\nint version_{name} __asm__("_ZN2v88internal7Version{len(name)+1}{name}_E") = {value};'
source += '''
const char version_text[64] = "14.6.202.34-node.28";
const char *version_pointer __asm__("_ZN2v88internal7Version15version_string_E") = version_text;
'''
(w / 'metadata.c').write_text(source + main)
for name in ('native', 'metadata'):
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wl,--build-id=sha1',
                    str(w / (name + '.c')), '-o', str(w / (name + '-fixture'))], check=True, timeout=60)

results = []

def ready(client):
    return s.eventually(lambda: client.tool('get_language_tabs'), lambda result: result['view']['complete'],
                        'runtime discovery completes', timeout=900)

def case(label, executable, language=None, args=()):
    part = w / label
    part.mkdir(mode=0o755)
    server = s.Server(root, part, binary, executable, 'control', options=('--break', 'main'), fixture_args=args)
    report = {'case': label, 'status': 'running'}
    start = time.monotonic()
    try:
        owner, observer = s.Client(server, 'owner'), s.Client(server, 'observer')
        initial = s.eventually(owner.session, lambda x: x['state'] == 'stopped', 'launch stop')
        server.remember_target(initial)
        owner.claim(ttl_ms=60000)
        owner.action('continue')
        stopped = s.eventually(owner.session, lambda x: x['state'] == 'stopped' and any(
            t['reason'] == 'breakpoint' for t in x['threads']), 'main breakpoint', timeout=30)
        generation, tid = stopped['generation'], next(t['tid'] for t in stopped['threads'] if t['state'] == 'stopped')
        registers = observer.tool('get_registers', tid=tid)
        before = ready(observer)
        # Cold metadata discovery may outlive the control lease. Claim it for
        # the following controller assertions, not for a guessed duration.
        owner.claim(ttl_ms=60000)
        visible = [t['tab'] for t in before['view']['tabs'] if t['visible']]
        assert visible == ['registers', 'native'] + ([language] if language else []), before
        assert before['view']['selected'] == 'native', before
        s.expect_error(observer.raw('select_native_frame', generation=generation, tid=tid, frame=0), 'ControlLeaseRequired')
        s.expect_error(observer.raw('select_language_frame', generation=generation, tid=tid, language=language or 'lua', segment=0, frame=0), 'ControlLeaseRequired')
        assert 'select_native_frame' not in s.listed_tools(observer) and 'select_language_frame' not in s.listed_tools(observer)
        s.expect_error(owner.raw('select_native_frame', tid=tid, frame=0), 'GenerationRequired')
        s.expect_error(owner.raw('select_native_frame', generation=generation + 1, tid=tid, frame=0), 'StaleSnapshot')
        owner.tool('select_native_frame', generation=generation, tid=tid, frame=0)
        selection = observer.tool('get_language_tabs')['view']['native_selection']
        assert selection == {'generation':generation, 'tid':tid, 'frame':0}, selection
        s.expect_error(owner.raw('select_native_frame', generation=generation, tid=tid, frame=63), 'InvalidFrame')

        for tab in before['view']['tabs']:
            if tab['visible'] and tab['tab'] not in ('registers', 'native'):
                assert tab['version'] and tab['build_id'] and tab['basis'] and tab['proof_generation'] == generation, tab
        s.expect_error(observer.raw('select_language_tab', generation=generation, tab='registers'), 'ControlLeaseRequired')
        assert 'select_language_tab' not in s.listed_tools(observer)
        owner.claim(ttl_ms=60000)
        selected = language or 'registers'
        owner.tool('select_language_tab', generation=generation, tab=selected)
        assert observer.tool('get_language_tabs')['view']['selected'] == selected
        assert observer.session()['generation'] == generation
        assert observer.tool('get_registers', tid=tid) == registers
        s.expect_invalid(owner.raw('select_language_tab', generation=generation, tab='missing'))
        absent = next(x for x in ('lua', 'perl', 'python', 'javascript') if x != language)
        s.expect_error(owner.raw('select_language_tab', generation=generation, tab=absent), 'LanguageTabUnavailable')
        s.expect_error(owner.raw('select_language_tab', tab='native'), 'GenerationRequired')
        s.expect_error(owner.raw('select_language_tab', generation=generation + 123, tab='native'), 'StaleSnapshot')
        owner.action('step_instruction', tid=tid)
        stepped = s.eventually(owner.session, lambda x: x['state'] == 'stopped' and x['generation'] != generation, 'instruction stop')
        after = ready(observer)
        owner.claim(ttl_ms=60000)
        assert after['view']['selected'] == selected, after
        assert after['view']['native_selection'] is None and after['view']['logical_selection'] is None, after
        if language:
            tab = next(t for t in after['view']['tabs'] if t['tab'] == language)
            assert tab['proof_generation'] == stepped['generation'], tab
        if a.strace:
            pc = observer.tool('get_stack', tid=tid)['frames'][0]['pc']
            def observe():
                owner.tool('select_language_tab', generation=stepped['generation'], tab='native')
                observer.tool('get_language_tabs')
                owner.tool('select_language_tab', generation=stepped['generation'], tab=selected)
                observer.tool('read_memory', address=hex(pc), length=1)
            adapter = SimpleNamespace(p=server.proc, inspect=observer.tool, session=observer.session)
            report['readonly_audit'] = audit(adapter, server.target_pid, part/'tabs.strace', observe)
        if label == 'synthetic-v8':
            job = next(j for j in owner.tool('get_debug_metadata')['jobs'] if j['kind'] == 'javascript')
            owner.tool('cancel_debug_metadata', id=job['id'])
            cancelled = s.eventually(lambda: observer.tool('get_language_tabs'), lambda v:
                v['view']['tabs'][-1]['reason'] == 'DebugMetadataCancelled', 'cancel withdraws proof')
            assert cancelled['view']['selected'] == 'javascript'
            owner.tool('retry_debug_metadata', id=job['id'])
            after = s.eventually(lambda: observer.tool('get_language_tabs'), lambda v:
                v['view']['complete'] and v['view']['tabs'][-1]['status'] == 'ready', 'retry refreshes proof', timeout=60)
            assert after['view']['selected'] == 'javascript'
        report.update(status='pass', before=before, after=after, seconds=time.monotonic()-start)
    except BaseException as exc:
        report.update(status='fail', error=repr(exc), seconds=time.monotonic()-start)
        raise
    finally:
        for client in server.clients:
            (part / (client.label + '.json')).write_text(json.dumps(client.transcript, indent=1)+'\n')
        server.close()
        results.append(report)
        (w / 'results.json').write_text(json.dumps(results, indent=2)+'\n')

case('native', w / 'native-fixture')
case('synthetic-v8', w / 'metadata-fixture', 'javascript')
for label, executable, language, args in [
    ('python', a.python, 'python', ('-c', 'print(1)')),
    ('perl', a.perl, 'perl', ('-e', 'print 1')),
    ('node', a.node, 'javascript', ('-e', 'console.log(1)')),
]:
    if executable:
        case(label, executable.resolve(), language, args)
for i, lua in enumerate(a.lua):
    case('lua-' + str(i), lua.resolve(), 'lua', ('-e', 'print(1)'))
print('Language tab shared-session checks passed:', len(results), 'owned targets')

# Presentation state routes by stable debugger process ID, independent of
# either client's default process and the GUI's selection.
(w/'fork.c').write_text('#include <unistd.h>\n#include <sys/wait.h>\nint main(void) { if (!fork()) _exit(0); wait(0); return 0; }\n')
subprocess.run(['cc', '-g', '-O0', str(w/'fork.c'), '-o', str(w/'fork-fixture')], check=True, timeout=60)
part = w/'processes'
part.mkdir(mode=0o755)
server = s.Server(root, part, binary, w/'fork-fixture', 'control', options=('--follow-forks',), fixture_args=())
report = {'case': 'process-routing', 'status': 'running'}
owned = {}
try:
    owner, observer = s.Client(server, 'owner'), s.Client(server, 'observer')
    initial = s.eventually(owner.session, lambda state: state['state'] == 'stopped', 'launch stop')
    server.remember_target(initial)
    owner.claim(ttl_ms=60000)
    owner.tool('select_language_tab', generation=initial['generation'], tab='registers')
    owner.action('continue')
    tree = s.eventually(lambda: observer.tool('get_processes'), lambda tree: tree['total'] == 2, 'fork')
    for row in tree['processes']:
        owned[row['pid']] = s.process_identity(row['pid'])
    parent = observer.tool('get_language_tabs', process_id=1)
    child = observer.tool('get_language_tabs', process_id=2)
    assert parent['view']['selected'] == 'registers', parent
    assert child['view']['selected'] == 'native', child
    owner.tool('select_language_tab', process_id=2, generation=child['generation'], tab='registers')
    owner.tool('select_language_tab', process_id=1, generation=parent['generation'], tab='native')
    assert observer.tool('get_language_tabs', process_id=1)['view']['selected'] == 'native'
    assert observer.tool('get_language_tabs', process_id=2)['view']['selected'] == 'registers'
    # An adopted fork child is detached, not owned as a new launch, when the
    # debugger shuts down. Let the fixture parent reap it before ending xodb.
    for process in (2, 1):
        state = observer.tool('get_session', process_id=process)
        owner.tool('detach_process_family', process_id=process, generation=state['generation'])
    s.eventually(lambda: [pid for pid in owned if (identity := s.process_identity(pid)) and identity[1] != 'Z'],
                 lambda pids: not pids, 'detached fixture completion')
    server.stop_and_check()
    s.eventually(lambda: [pid for pid in owned if s.process_identity(pid) is not None],
                 lambda pids: not pids, 'fork fixture reaping')
    report.update(status='pass', tree=tree, cleanup='both owned processes reaped')
except BaseException as exc:
    report.update(status='fail', error=repr(exc))
    raise
finally:
    for client in server.clients:
        (part/(client.label+'.json')).write_text(json.dumps(client.transcript, indent=1)+'\n')
    server.close()
    for pid, birth in reversed(list(owned.items())):
        identity = s.process_identity(pid)
        if birth and identity and identity[0] == birth[0] and identity[1] != 'Z':
            os.kill(pid, signal.SIGKILL)
    results.append(report)
    (w/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print('Language tab process routing passed')
