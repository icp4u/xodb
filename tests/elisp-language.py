#!/usr/bin/env python3
"""Owned Emacs backtrace oracle through the local or C-agent debugger backend."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time
from types import SimpleNamespace
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path)
p.add_argument('--strace', action='store_true')
p.add_argument('--wrong-oracle', action='store_true')
a = p.parse_args()
os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
w = a.work.resolve()
w.mkdir(mode=0o755, parents=True, exist_ok=False)
fixture = w / 'fixtures'
shutil.copytree(root / 'tests/fixtures/elisp', fixture)
os.environ.update(XODB_ELISP_SOURCE=str(fixture / 'functions.el'), XODB_ELISP_NATIVE=str(fixture / 'functions.eln'), XDG_CACHE_HOME=str(w / 'cache'))
for key in ('XODB_ELISP_REDEFINE', 'XODB_ELISP_REPEATS', 'XODB_ELISP_WRONG_ORACLE'):
    os.environ.pop(key, None)
with (w / 'compile.log').open('w') as log:
    subprocess.run([str(a.emacs.resolve()), '-Q', '--batch', '-l', str(fixture / 'compile.el')], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
options = ['--break', 'Fdebugger_trap'] + (['--runtime-agent', str(a.agent.resolve())] if a.agent else [])

def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'), rss_kib=rss)

def compare(stack, oracle):
    segment = stack['segments'][0]
    frames = segment['frames']
    first = next(i for i, f in enumerate(frames) if f['name'] == 'xodb-elisp-mark')
    actual = [dict(name=f['name'], nargs=-1 if f['arguments_unevaluated'] else f['argument_count']) for f in frames[first:]]
    expected = json.loads(oracle.read_text())['frames']
    if a.wrong_oracle:
        expected[0]['nargs'] += 1
    assert actual == expected, ('full stable stack mismatch', actual, expected)
    assert segment['chain_complete'], segment
    assert any(c['kind'] == 'condition-case' for c in segment['controls']), segment['controls']
    assert any(c['kind'] == 'unwind cleanup' for c in segment['controls']), segment['controls']
    mode = json.loads(oracle.read_text())['mode']
    assert json.loads(oracle.read_text())['active-kind'] == mode
    own = {f['name']: f for f in frames if f['name'].startswith('xodb-elisp-')}
    expected_kind = {'interpreted': 'interpreted', 'bytecode': 'bytecode', 'native': 'native/unknown'}[mode]
    for name in ['xodb-elisp-inner', 'xodb-elisp-outer']:
        assert own[name]['kind'] == expected_kind, own
        if expected_kind != 'native/unknown':
            assert own[name]['reason'] is None and own[name]['kind_basis'] and own[name]['active_function'], own[name]
    assert segment['classification_reason'] is None, segment
    if mode == 'interpreted':
        assert own['xodb-elisp-mark']['kind'] == 'interpreted' and own['xodb-elisp-mark']['native_binding'], own
    if '-redefined-' in oracle.name or '-redefined.' in oracle.name:
        current = json.loads(oracle.read_text())['current-definition']
        assert current == ("bytecode" if mode == "interpreted" else "interpreted") and current != mode, (current, mode)
    return first

def audit(client, pid):
    observer = client.collector_pid()
    path = w / 'readonly.strace'
    regs = client.inspect('get_registers', tid=pid)
    generation = client.session()['generation']
    before = {p.name: (p / 'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
    tracer = subprocess.Popen(['strace', '-f', '-qq', '-o', str(path), '-e',
                              'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
                              '-p', str(observer)], stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not re.search(r'^TracerPid:\s*' + str(tracer.pid) + r'\s*$', Path(f'/proc/{observer}/status').read_text(), re.M):
            assert tracer.poll() is None and time.monotonic() < deadline
            time.sleep(.01)
        for _ in range(2):
            client.inspect('get_language_stack', language='elisp', tid=pid)
    finally:
        if tracer.poll() is None:
            tracer.send_signal(signal.SIGINT)
        tracer.wait(timeout=10)
        (w / 'strace.stderr').write_bytes(tracer.stderr.read())
    text = path.read_text()
    assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA', text), text
    assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b', text), text
    after = {p.name: (p / 'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
    assert after == before and client.session()['generation'] == generation and client.inspect('get_registers', tid=pid) == regs
    return {'target_runs': 0, 'target_mutations': 0, 'target_read_observed': True}

results = []
for mode, suffix, redefine in [('interpreted', 'el', False), ('bytecode', 'elc', False), ('native', 'eln', False), ('bytecode', 'elc', True), ('native', 'eln', True), ('interpreted', 'el', 'bytecode')]:
    label = mode + ('-redefined' if redefine else '')
    oracle = w / (label + '-oracle.json')
    os.environ.update(XODB_ELISP_MODE=mode, XODB_ELISP_FUNCTIONS=str(fixture / ('functions.' + suffix)), XODB_ELISP_ORACLE=str(oracle))
    if redefine:
        os.environ['XODB_ELISP_REDEFINE'] = redefine if isinstance(redefine, str) else '1'
    else:
        os.environ.pop('XODB_ELISP_REDEFINE', None)
    client = Client('control', str(a.emacs.resolve()), args=('-Q', '--batch', '-l', str(fixture / 'driver.el')), options=options)
    report = {'case': label, 'status': 'failed'}
    try:
        client.continue_initial_stop()
        stopped = client.stopped('breakpoint', seconds=180)
        pid = stopped['pid']; generation = stopped['generation']
        regs = client.inspect('get_registers', tid=pid)
        before = usage(client.p.pid)
        stack = client.inspect('get_language_stack', language='elisp', tid=pid)
        after = usage(client.p.pid)
        compare(stack, oracle)
        (w / (label + '-stack.json')).write_text(json.dumps(stack, indent=2) + '\n')
        denied = client.tool('get_language_stack', language='elisp', tid=2147483647)['result']
        assert denied.get('isError') and denied['content'][0]['text'] == 'ElispThreadAssociationUnproved', denied
        assert client.session()['generation'] == generation and client.inspect('get_registers', tid=pid) == regs
        if a.strace and not results:
            report['readonly_audit'] = audit(client, pid)
        report.update(status='pass', cpu_rss_before=before, cpu_rss_after=after,
                      frames=len(stack['segments'][0]['frames']), thread_refusal=denied['content'][0]['text'])
    finally:
        client.close()
        (w / (label + '-rpc.json')).write_text(json.dumps(client.transcript, indent=2) + '\n')
        (w / (label + '-stderr.log')).write_bytes(client.p.stderr.read())
        results.append(report)
        (w / 'results.json').write_text(json.dumps(results, indent=2) + '\n')

# A shared observer can inspect the stack, but cannot select presentation state.
spec = importlib.util.spec_from_file_location('elisp_shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
part = w / 'shared'; part.mkdir(); (part / 'run').mkdir(mode=0o700)
server = SimpleNamespace(path=part / 'run/s', clients=[], proc=None)
assert len(os.fsencode(server.path)) < 108, 'Use a shorter --work path for the shared socket'
os.environ.pop('XODB_ELISP_REDEFINE', None)
os.environ.update(XODB_ELISP_MODE='interpreted', XODB_ELISP_FUNCTIONS=str(fixture / 'functions.el'), XODB_ELISP_ORACLE=str(part / 'oracle.json'))
log = (part / 'server.log').open('wb')
try:
    server.proc = subprocess.Popen([os.environ.get('XODB_BIN', str(root / 'zig-out/bin/xodb')), '--headless', '--session-socket', str(server.path), '--agent-scope', 'control', *options,
                                   '--', str(a.emacs.resolve()), '-Q', '--batch', '-l', str(fixture / 'driver.el')], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    owner = shared.Client(server, 'elisp-owner'); observer = shared.Client(server, 'elisp-observer'); owner.claim(ttl_ms=60000)
    owner.action('continue')
    state = shared.eventually(owner.session, lambda s: s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending'] and any(t['reason'] == 'breakpoint' for t in s['threads']), 'owned Emacs stop', timeout=180)
    deadline = time.monotonic() + 180
    while True:
        reply = observer.raw('get_language_stack', language='elisp', tid=state['pid'])
        if not reply['result'].get('isError'):
            break
        assert reply['result']['content'][0]['text'] == 'DebugMetadataPending' and time.monotonic() < deadline, reply
        time.sleep(.03)
    first = compare(reply['result']['structuredContent'], part / 'oracle.json')
    for name, fields in [('select_language_tab', {'tab': 'elisp'}), ('select_language_frame', {'language': 'elisp', 'tid': state['pid'], 'segment': 0, 'frame': first})]:
        reply = observer.raw(name, generation=owner.session()['generation'], **fields)
        shared.expect_error(reply, 'ControlLeaseRequired')
    results.append({'case': 'shared-observer', 'status': 'pass', 'direct_selection_denial': 'ControlLeaseRequired'})
finally:
    for c in server.clients:
        (part / (c.label + '-rpc.json')).write_text(json.dumps(c.transcript, indent=2) + '\n'); c.close()
    if server.proc is not None:
        server.proc.terminate()
        try:
            server.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.proc.kill(); server.proc.wait(timeout=10)
    log.close()
    (w / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('elisp language: six stack oracles, thread proof, redefinitions, and shared observer PASS')
