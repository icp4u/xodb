#!/usr/bin/env python3
"""Named Python bindings through MCP agree with a cooperating f_locals oracle."""
import argparse
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', required=True)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--agent', type=Path)
    p.add_argument('--strace', action='store_true')
    p.add_argument('--lua-source', type=Path)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    component = SourceFileLoader('python_component', str(root/'tests/python-component.py')).load_module()
    built = component.compile_fixture(a.python, w, lua_source=a.lua_source)
    env = dict(os.environ, PYTHONPATH=str(w), XODB_PYTHON_NAMED_READY='1', XODB_PYTHON_NAMED_EXPORT='1')
    target = subprocess.Popen([str(built) if a.lua_source else a.python, str(root/'tests/fixtures/python/named.py')], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def drain():
        for line in target.stdout: lines.put(line)
    thread = threading.Thread(target=drain, daemon=True); thread.start()
    client = None; result = {'status': 'running', 'checks': []}
    try:
        assert lines.get(timeout=10) == 'ready\n'
        options = [*(['--runtime-agent', str(a.agent.resolve())] if a.agent else []), '--attach', str(target.pid)]
        client = Client('control', None, options=options)
        tools = {tool['name']: tool for tool in client.call('tools/list')['result']['tools']}
        for name in ('get_language_locals', 'evaluate_language_expression'):
            assert tools[name]['annotations']['readOnlyHint'] and tools[name]['annotations']['xodbSessionAccess'] == 'observer'
        client.action('set_breakpoint', symbol='xodb_python_named_stop')
        client.continue_initial_stop(); target.stdin.write('go\n'); target.stdin.flush()
        previous_generation = None; bindings = 0; frames = 0
        for stop in range(8 if a.lua_source else 7):
            state = client.stopped('breakpoint'); ground = json.loads(lines.get(timeout=10))
            generation = state['generation']; tid = target.pid
            regs = client.inspect('get_registers', tid=tid)
            stack = client.inspect('get_language_stack', tid=tid, language='python')
            all_frames = [(s, f, frame) for s, segment in enumerate(stack['segments']) for f, frame in enumerate(segment['frames'])]
            if ground['label']=='mixed-lua-python':
                lua=client.inspect('get_language_stack',tid=tid,language='lua')
                assert len(stack['segments'])>=2 and any(part['frames'] for part in lua['segments']),(stack,lua)
                lua_segment, lua_frame = next((s, f) for s, part in enumerate(lua['segments']) for f, row in enumerate(part['frames']) if row['kind'] == 'Lua')
                lua_args = dict(generation=generation, tid=tid, language='lua', segment=lua_segment, frame=lua_frame)
                lua_locals = client.inspect('get_language_locals', **lua_args)
                lua_owned = client.inspect('evaluate_language_expression', **lua_args, expression='lua_owned')
                assert lua_owned['diagnostic'] is None and lua_owned['rows'][0]['value']['display'] == 'integer 73', lua_owned
                result['mixed_runtime'] = {'python': stack, 'lua': lua, 'lua_locals': lua_locals, 'lua_expression': lua_owned}
            cursor = 0; observed = []
            for expected in ground['frames']:
                match = next((i for i in range(cursor, len(all_frames)) if int(all_frames[i][2]['code'], 0) == expected['code']), None)
                assert match is not None, (expected, stack)
                cursor = match + 1; segment, frame, logical = all_frames[match]
                assert logical['name'] == expected['name'], (logical, expected)
                args = dict(generation=generation, tid=tid, language='python', segment=segment, frame=frame)
                rows = []; start = 0
                while True:
                    page = client.inspect('get_language_locals', **args, start=start, limit=3)
                    assert page['generation'] == generation and page['diagnostic'] is None, page
                    assert page['start'] == start and len(page['rows']) <= 3, page
                    rows += page['rows']; start += len(page['rows'])
                    if not page['truncated']:
                        assert len(rows) == page['total']; break
                    assert page['rows'] and len(rows) < page['total']
                seen = set()
                for row in rows:
                    assert row['name_diagnostic'] is None and row['slot_address'], row
                    want = expected['bindings'].get(row['name'])
                    if want is None:
                        assert row['value']['diagnostic'] == 'PythonUnboundLocal' and row['address'] is None, row
                        continue
                    if row['value']['diagnostic'] == 'PythonUnboundLocal': continue
                    assert row['value']['diagnostic'] is None, row
                    if row['immediate']:
                        assert row['address'] is None and want['type'] == 'int', (row, want)
                    else:
                        assert row['address'] == want['address'], (row, want)
                    if 'display' in want: assert row['value']['display'] == want['display'], (row, want)
                    if 'count' in want: assert row['value']['count'] == want['count'], (row, want)
                    found = client.inspect('evaluate_language_expression', **args, expression=row['name'])
                    assert found['diagnostic'] is None and found['rows'] == [row], (found, row)
                    seen.add(row['name']); bindings += 1
                assert seen == set(expected['bindings']), (seen, expected)
                for expression, why in [('missing_binding_xyz', 'PythonNameNotFound'), ('depth + 1', 'UnsupportedLanguageExpression'), ('print()', 'UnsupportedLanguageExpression'), ('payload[0]', 'UnsupportedLanguageExpression')]:
                    found = client.inspect('evaluate_language_expression', **args, expression=expression)
                    assert not found['rows'] and found['diagnostic'] == why, found
                frames += 1
                observed.append({'segment': segment, 'frame': frame, 'rows': rows})
            # An explicit mapping-local refusal for the module frame.
            module = next((s, f) for s, f, frame in all_frames if frame['name'] == '<module>')
            mapping = client.inspect('get_language_locals', generation=generation, tid=tid, language='python', segment=module[0], frame=module[1])
            assert mapping['diagnostic'] == 'PythonMappingLocalsUnavailable' and not mapping['rows'], mapping
            selected = observed[0]
            args = dict(generation=generation, tid=tid, language='python', segment=selected['segment'], frame=selected['frame'])
            def refusal(arguments, why):
                reply = client.tool('get_language_locals', **arguments)
                if why == 'InvalidArguments':
                    assert reply.get('error', {}).get('code') == -32602 and reply['error']['message'] == why, reply
                else:
                    assert reply.get('result', {}).get('isError') and reply['result']['content'][0]['text'] == why, reply
            for change, why in [(dict(limit=0), 'InvalidArguments'), (dict(limit=33), 'InvalidArguments'), (dict(frame=63), 'InvalidLanguageFrame'), (dict(segment=63), 'InvalidLanguageSegment'), (dict(generation=generation+1), 'StaleSnapshot'), (dict(frame_address='0x1234'), 'InvalidArguments')]:
                refusal(args | change, why)
            refusal({key: value for key, value in args.items() if key != 'generation'}, 'GenerationRequired')
            if previous_generation is not None: refusal(args | {'generation': previous_generation}, 'StaleSnapshot')
            if a.strace and stop == 0:
                adapter = SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid()), inspect=client.inspect, session=client.session)
                result['readonly'] = audit(adapter, tid, w/'locals.strace', lambda: (
                    client.inspect('get_language_locals', **args),
                    client.inspect('evaluate_language_expression', **args, expression='depth')))
            assert client.inspect('get_registers', tid=tid) == regs and client.session()['generation'] == generation
            result['checks'].append({'ground': ground, 'observed': observed, 'generation': generation})
            previous_generation = generation; client.action('continue')
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        assert bindings == (50 if a.lua_source else 46) and frames == (21 if a.lua_source else 19), (bindings, frames)
        result.update(status='pass', bindings=bindings, frames=frames)
    finally:
        if client: result['transcript'] = client.transcript; client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=5)
        (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'Python named MCP bindings: {bindings} bindings, {frames} frames, recursion, closures, cells, generator resume, coroutine, native callback and refusals passed')


if __name__ == '__main__':
    main()
