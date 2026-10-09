#!/usr/bin/env python3
"""Python container-path watches against owned public subscription oracles."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'), rss_kib=rss)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--agent', type=Path)
    parser.add_argument('--strace', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    work = args.work.resolve(); work.mkdir(parents=True, mode=0o755)
    spec = importlib.util.spec_from_file_location('component', root/'tests/python-component.py')
    component = importlib.util.module_from_spec(spec); spec.loader.exec_module(component)
    component.compile_fixture(args.python, work)
    command = [args.python, str(root/'tests/fixtures/python/path-watches.py')]
    env = dict(os.environ, PYTHONPATH=str(work))
    target = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def drain():
        for line in target.stdout: lines.put(line)
    thread = threading.Thread(target=drain, daemon=True); thread.start()
    client = None; result = dict(status='running', stops=[], resources=[]); ids = {}; last = {}
    try:
        assert lines.get(timeout=10) == 'ready\n'
        options = [*(['--runtime-agent', str(args.agent.resolve())] if args.agent else []), '--attach', str(target.pid)]
        client = Client('control', None, options=options)
        client.action('set_breakpoint', symbol='xodb_python_named_stop')
        client.continue_initial_stop(); target.stdin.write('go\n'); target.stdin.flush()
        for stop in range(13):
            state = client.stopped('breakpoint'); generation = state['generation']
            ground = json.loads(lines.get(timeout=10)); label = ground['label']
            registers = client.inspect('get_registers', tid=target.pid)
            if stop == 0:
                stack = client.inspect('get_language_stack', tid=target.pid, language='python')
                segment, frame = next((s, f) for s, part in enumerate(stack['segments']) for f, row in enumerate(part['frames']) if int(row['code'], 0) == ground['code'])
                call_args = dict(generation=generation, tid=target.pid, language='python', segment=segment, frame=frame)
                measured = dict(frontend=client.p.pid)
                if args.agent: measured['runtime_agent'] = client.collector_pid()
                result['resources'].append(dict(phase='metadata ready before watches', processes={k:usage(v) for k,v in measured.items()}, load=os.getloadavg()))
                invalid = ('root()', 'root.a', 'root[0:1]', 'root[2147483648]', 'root[0][0][0][0][0]')
                for expression in invalid:
                    refused = client.tool('add_language_watch', **call_args, expression=expression)['result']
                    assert refused.get('isError') and refused['content'][0]['text']=='UnsupportedLanguageExpression', refused
                assert client.inspect('get_language_watches')['watches']==[]
                temporary = client.inspect('add_language_watch', **call_args, expression='root["absent"]')['added']
                missing = client.inspect('get_language_watches')['watches'][0]
                assert missing['state']=='unavailable' and missing['diagnostic']=='PythonPathKeyNotFound', missing
                client.inspect('remove_language_watch', generation=generation, id=temporary)
                result['syntax_refused_before_add'] = list(invalid)
                for expression in ground['values']:
                    ids[expression] = client.inspect('add_language_watch', **call_args, expression=expression)['added']
                evaluated = client.inspect('evaluate_language_expression', **call_args, expression='root["player"]["score"]')
                assert evaluated['diagnostic'] is None and evaluated['rows'][0]['value']['display'] == 'int 7', evaluated
                if args.strace:
                    def observe():
                        extra = client.inspect('add_language_watch', **call_args, expression='root["player"]["score"]')['added']
                        client.inspect('evaluate_language_expression', **call_args, expression='root["absent"]')
                        client.inspect('remove_language_watch', generation=generation, id=extra)
                    adapter = SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid() if args.agent else client.p.pid), inspect=client.inspect, session=client.session)
                    result['readonly'] = audit(adapter, target.pid, work/'paths.strace', observe)
            deadline = time.monotonic()+60
            while True:
                rows = client.inspect('get_language_watches')['watches']; byid = {row['id']: row for row in rows}
                if all(row['state'] in ('gone', 'context_changed') or row['observed_generation'] == generation for row in rows): break
                assert time.monotonic() < deadline, rows
                time.sleep(.01)
            for expression, id in ids.items():
                row = byid[id]
                assert row['selector'] == 'expression' and row['expression'] == expression and row['row_name'] is None, row
                assert 'unproved' in row['identity'], row
                if stop >= 10:
                    assert row['state'] == 'gone' and not row['changed'], (label, row)
                    continue
                expected = ground['values'][expression]
                if 'reason' in expected:
                    assert row['state'] == 'unavailable' and row['diagnostic'] == expected['reason'] and not row['changed'], (label, row, expected)
                    continue
                complete = expected['kind'], expected['sample']
                changed = expression in last and last[expression] != complete
                assert row['state'] == 'value' and row['changed'] == changed, (label, row, expected)
                assert row['current']['kind'] == expected['kind'] and row['current']['comparison_bytes'] == len(expected['sample'])//2, row
                if label == 'changed' and expression.endswith('["text"]'):
                    assert changed and row['previous']['display'] == row['current']['display'], row
                if expression.endswith('["score"]'):
                    assert row['current']['display'] == ('int 7' if stop == 0 else 'int 8'), row
                last[expression] = complete
            if stop == 1:
                assert ground['root'] != result['stops'][0]['ground']['root']; result['root_replacement_observed'] = True
            assert client.inspect('get_language_watches')['watches'] == rows
            assert client.inspect('get_registers', tid=target.pid) == registers and client.session()['generation'] == generation
            result['stops'].append(dict(ground=ground, watches=rows))
            result['resources'].append(dict(phase=f'completed stop {stop}', processes={k:usage(v) for k,v in measured.items()}, load=os.getloadavg()))
            client.action('continue')
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        result['transcript'] = client.transcript; client.close(); client = None
        result['shared_observer'] = shared(root, work, command, env, args)
        result['status'] = 'pass'
    finally:
        if client: result['transcript'] = client.transcript; client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=5)
        result['target_stderr'] = target.stderr.read()
        (work/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Python paths: 13 stops, complete scalar oracle, replacement/GC, missing/refusal/recovery, shadow, retirement and shared observers passed')


def shared(root, work, command, env, args):
    spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
    s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
    (work/'run').mkdir(mode=0o700)
    server = SimpleNamespace(path=work/'run/s', clients=[]); process = None
    target = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    result = dict(status='running')
    try:
        assert target.stdout.readline() == 'ready\n'
        options = [str(root/'zig-out/bin/xodb'), '--headless', '--session-socket', str(server.path), '--agent-scope', 'control',
                   *(['--runtime-agent', str(args.agent.resolve())] if args.agent else []), '--attach', str(target.pid)]
        with (work/'server.log').open('wb') as log:
            process = subprocess.Popen(options, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+30
        while True:
            assert process.poll() is None, (work/'server.log').read_text()
            try: owner = s.Client(server, 'owner'); break
            except (FileNotFoundError, ConnectionRefusedError):
                assert time.monotonic() < deadline; time.sleep(.02)
        observer = s.Client(server, 'observer'); owner.claim(ttl_ms=60000)
        s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'], 'initial stop')
        owner.action('set_breakpoint', symbol='xodb_python_named_stop'); owner.action('continue')
        target.stdin.write('go\n'); target.stdin.flush()
        s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'] and any(t['reason']=='breakpoint' for t in v['threads']), 'path stop')
        deadline = time.monotonic()+60
        while True:
            reply = owner.raw('get_language_stack', tid=target.pid, language='python')
            if not reply['result'].get('isError'): break
            s.expect_error(reply, 'DebugMetadataPending'); assert time.monotonic() < deadline; time.sleep(.01)
        stack = reply['result']['structuredContent']
        segment, frame = next((i,j) for i,part in enumerate(stack['segments']) for j,row in enumerate(part['frames']) if row['name']=='watched')
        generation = owner.session()['generation']
        call_args = dict(generation=generation, tid=target.pid, language='python', segment=segment, frame=frame, expression='root["player"]["score"]')
        found = observer.tool('evaluate_language_expression', **call_args)
        assert found == owner.tool('evaluate_language_expression', **call_args) and found['rows'][0]['value']['display']=='int 7', found
        s.expect_error(observer.raw('add_language_watch', **call_args), 'ControlLeaseRequired')
        created = owner.tool('add_language_watch', **call_args)['added']
        watched = owner.tool('get_language_watches'); assert watched == observer.tool('get_language_watches')
        s.expect_error(observer.raw('remove_language_watch', generation=generation, id=created), 'ControlLeaseRequired')
        owner.tool('release_session_control')
        assert observer.tool('get_language_watches') == watched
        assert observer.tool('evaluate_language_expression', **call_args) == found
        result.update(status='pass', direct_mutations_refused=True, reads_without_lease=True)
    finally:
        for client in server.clients: client.close()
        if process and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if target.poll() is None: target.kill(); target.wait()
        result['transcripts'] = [client.transcript for client in server.clients]
    return result


if __name__ == '__main__':
    main()
