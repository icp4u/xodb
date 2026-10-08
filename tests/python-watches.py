#!/usr/bin/env python3
"""Stopped Python watches compared with a cooperating f_locals byte oracle."""
import argparse
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import threading
import time
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'), rss_kib=rss)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', required=True)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--agent', type=Path)
    p.add_argument('--strace', action='store_true')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    component = SourceFileLoader('python_component', str(root/'tests/python-component.py')).load_module()
    component.compile_fixture(a.python, w)
    target = subprocess.Popen([a.python, str(root/'tests/fixtures/python/watches.py')],
                              env=dict(os.environ, PYTHONPATH=str(w)), stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def drain():
        for line in target.stdout: lines.put(line)
    thread = threading.Thread(target=drain, daemon=True); thread.start()
    client = None; result = dict(status='running', stops=[], resources=[])
    watches = {}; baselines = {}; retired = set(); locations = {}
    try:
        assert lines.get(timeout=10) == 'ready\n'
        client = Client('control', None, options=[*(['--runtime-agent', str(a.agent.resolve())] if a.agent else []), '--attach', str(target.pid)])
        client.action('set_breakpoint', symbol='xodb_python_named_stop')
        measured = dict(frontend=client.p.pid)
        if a.agent: measured['runtime_agent'] = client.collector_pid()
        before = {k: usage(pid) for k, pid in measured.items()}; started = time.monotonic()
        client.continue_initial_stop(); target.stdin.write('go\n'); target.stdin.flush()
        for stop in range(16):
            state = client.stopped('breakpoint'); generation = state['generation']
            ground = json.loads(lines.get(timeout=10)); label = ground['label']
            registers = client.inspect('get_registers', tid=target.pid)
            stack = client.inspect('get_language_stack', tid=target.pid, language='python')
            if label in ('initial', 'generator-first', 'coroutine-first'):
                name = 'outer.<locals>.watched' if label == 'initial' else 'generator' if label == 'generator-first' else 'coroutine'
                expected = next(f for f in ground['frames'] if f['name'] == name)
                segment, frame, logical = next((s, f, row) for s, part in enumerate(stack['segments']) for f, row in enumerate(part['frames']) if int(row['code'], 0) == expected['code'])
                assert logical['identity_proved'], logical
                args = dict(generation=generation, tid=target.pid, language='python', segment=segment, frame=frame)
                rows = client.inspect('get_language_locals', **args, limit=32)['rows']
                names = ['x', 'captured', 'cell_local', 'text', 'blob', 'huge', 'object_value', 'number', 'zero', 'nan', 'deleted'] if label == 'initial' else ['value']
                for binding in names:
                    row = next(row for row in rows if row['name'] == binding)
                    key = name + ':' + binding
                    added = client.inspect('add_language_watch', **args, row=row['ordinal'])['added']
                    watches[key] = dict(id=added, name=binding, frame=name, selector='binding')
                    locations[key] = logical['frame_address']
                if label == 'initial':
                    watches['x-expression'] = dict(id=client.inspect('add_language_watch', **args, expression='x')['added'], name='x', frame=name, selector='expression')
                    if a.strace:
                        def observe():
                            extra = client.inspect('add_language_watch', **args, expression='x')['added']
                            client.inspect('remove_language_watch', generation=generation, id=extra)
                        result['readonly'] = audit(SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid() if a.agent else client.p.pid), inspect=client.inspect, session=client.session), target.pid, w/'watches.strace', observe)
            deadline = time.monotonic() + 60
            while True:
                current = client.inspect('get_language_watches')['watches']
                if all(row['observed_generation'] == generation or row['state'] in ('gone', 'context_changed') for row in current): break
                assert time.monotonic() < deadline, current
                time.sleep(.01)
            byid = {row['id']: row for row in current}
            for key, watch in watches.items():
                row = byid[watch['id']]
                comparison = 'not_compared' if row['state'] != 'value' or row['previous'] is None else 'same_slot_different' if row['changed'] else 'same_slot_equal'
                assert row['comparison'] == comparison and 'unproved' in row['identity'], row
                assert row['language'] == 'python' and row['selector'] == watch['selector'], row
                if key in retired:
                    assert row['state'] == 'gone' and not row['changed'], row
                    continue
                frame = next((f for f in ground['frames'] if f['name'] == watch['frame']), None)
                if frame is None:
                    if watch['frame'] == 'outer.<locals>.watched':
                        assert row['state'] == 'gone' and not row['changed'], row
                        retired.add(key)
                    else:
                        assert row['state'] == 'unavailable' and row['diagnostic'] == 'PythonWatchGeneratorNotObserved', row
                    continue
                want = frame['bindings'].get(watch['name'])
                reason = 'PythonUnboundLocal' if want is None else want.get('reason')
                if want and 'sample' in want and len(want['sample']) // 2 > 4096: reason = 'PythonWatchSampleLimit'
                if reason:
                    assert row['state'] == 'unavailable' and row['diagnostic'] == reason and not row['changed'], (label, key, row, reason)
                else:
                    complete = want['kind'], want['sample']
                    changed = key in baselines and baselines[key] != complete
                    assert row['state'] == 'value' and row['changed'] == changed, (label, key, row, changed)
                    assert row['current']['kind'] == want['kind'] and row['current']['comparison_bytes'] == len(want['sample']) // 2, (key, row, want)
                    if label == 'changed' and watch['name'] in ('text', 'blob', 'number', 'nan'):
                        assert row['changed'] and row['previous']['display'] == row['current']['display'], row
                    baselines[key] = complete
            assert client.inspect('get_language_watches')['watches'] == current
            assert client.inspect('get_registers', tid=target.pid) == registers and client.session()['generation'] == generation
            after = {k: usage(pid) for k, pid in measured.items()}
            result['resources'].append(dict(before=before, after=after, elapsed_seconds=time.monotonic()-started,
                load=os.getloadavg(), allowed_cpus=len(os.sched_getaffinity(0)),
                phase='completed inspection to completed inspection, including run control and fixture interval; not isolated watch cost'))
            result['stops'].append(dict(generation=generation, ground=ground, watches=current))
            before = after; started = time.monotonic(); client.action('continue')
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        assert len(retired) == 12 and len(watches) == 14, (retired, watches)
        result['status'] = 'pass'
    finally:
        if client: result['transcript'] = client.transcript; client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=5)
        result['target_stderr'] = target.stderr.read()
        (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Python watches: 16 stops, scalar byte oracle, cells/free variables, unbound recovery, GC, generators/coroutines and frame retirement passed')


if __name__ == '__main__': main()
