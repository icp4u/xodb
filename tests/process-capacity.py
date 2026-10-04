#!/usr/bin/env python3
"""Real MCP capacity boundaries and 129 owned prefork workers, no existing server."""
from datetime import datetime, timezone
import json, os, subprocess, threading, time
from pathlib import Path
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = Path('.work') / ('process-capacity-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
run.mkdir()
exe = os.environ.get('XODB_BIN', './zig-out/bin/xodb')
fixture = run / 'prefork'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror', 'tests/fixtures/process-capacity.c', '-o', str(fixture)], check=True, env=dict(os.environ, TMPDIR=str(root / '.work/tmp')))
checks = {}

def rejected(c, name, error, **args):
    value = c.tool(name, **args)
    if error == 'InvalidArguments':
        assert value.get('error') == {'code': -32602, 'message': error}, value
    else:
        assert value['result']['isError'] and value['result']['content'][0]['text'] == error, value

def page_all(c):
    rows = []
    start = 0
    while True:
        page = c.inspect('get_processes', start=start, limit=128)
        rows.extend(page['processes'])
        if page['next'] is None:
            assert len(rows) == page['total'], page
            return rows
        assert page['next'] > start, page
        start = page['next']

def wait(c, name, predicate, **args):
    deadline = time.monotonic() + 8
    while True:
        value = c.inspect(name, **args)
        if predicate(value): return value
        assert time.monotonic() < deadline, value
        time.sleep(.002)

def process_action(c, process, name, **args):
    session = c.inspect('get_session', process_id=process)
    return c.inspect(name, process_id=process, generation=session['generation'], **args)

for limit in ('0', '1025'):
    result = subprocess.run([exe, '--headless', '--process-limit', limit], capture_output=True, timeout=5)
    assert result.returncode != 0 and b'InvalidProcessLimit' in result.stderr, result
checks['cli_rejects_out_of_range'] = True
c = Client('observe', executable=None)
try:
    assert c.inspect('get_processes')['process_limit'] == 32
    checks['default_32'] = True
finally:
    c.close()
    (run / 'default.stderr').write_bytes(c.p.stderr.read())

c = Client('control', str(fixture), options=('--follow-forks', '--process-limit', '1024', '--break', 'capacity_ready'))
# Many admission diagnostics must not fill the subprocess stderr pipe.
def drain_stderr():
    with (run / 'prefork.stderr').open('wb') as output:
        while chunk := c.p.stderr.read(4096): output.write(chunk)
reader = threading.Thread(target=drain_stderr, daemon=True)
reader.start()
start_time = time.monotonic()
try:
    tools = c.call('tools/list')['result']['tools']
    schemas = 0
    for tool in tools:
        props = tool['inputSchema']['properties']
        for key in ('process_id', 'process_limit'):
            if key in props:
                assert props[key]['maximum'] == 1024, (tool['name'], key, props[key])
                schemas += 1
        if tool['name'] == 'get_processes': assert props['limit']['maximum'] == 128
    assert schemas > 50
    checks['mcp_schema_capacity_fields'] = schemas
    assert c.inspect('get_processes')['process_limit'] == 1024
    c.action('set_process_following', enabled=True, process_limit=32)
    assert c.inspect('get_processes')['process_limit'] == 32
    c.action('set_process_following', enabled=True, process_limit=1024)
    generation = c.session()['generation']
    for limit in (0, 1025):
        rejected(c, 'set_process_following', 'InvalidProcessLimit', generation=generation, enabled=True, process_limit=limit)
        assert c.session()['generation'] == generation
        assert c.inspect('get_processes')['process_limit'] == 1024
    checks['mcp_limit_bounds_and_atomic_refusal'] = True
    c.action('continue')
    c.stopped('breakpoint')
    # Each fork holds the parent and newly admitted child. Leave all children
    # stopped while resuming the parent to create the next prefork worker.
    for total in range(2, 131):
        c.action('continue')
        page = wait(c, 'get_processes', lambda value: value['total'] == total, start=total-2, limit=2)
        child = page['processes'][-1]
        assert child['process_id'] == total and child['parent_process_id'] == 1 and child['state'] == 'stopped', child
    rows = page_all(c)
    assert [row['process_id'] for row in rows] == list(range(1, 131))
    assert all(row['state'] == 'stopped' for row in rows)
    assert len({row['pid'] for row in rows}) == 130
    checks['simultaneously_held_processes'] = len(rows)
    status = Path('/proc', str(c.p.pid), 'status').read_text().splitlines()
    checks['xodb_memory_at_130_processes'] = {line.split(':', 1)[0]: line.split(':', 1)[1].strip() for line in status if line.startswith(('VmRSS:', 'VmHWM:'))}
    checks['all_processes_paged_without_gaps'] = True
    # Exercise actual process routing, execution, a breakpoint and registers
    # above the previous maximum process ID.
    child = c.inspect('get_session', process_id=130)
    probe = process_action(c, 130, 'set_breakpoint', symbol='capacity_worker')['id']
    process_action(c, 130, 'continue')
    child = wait(c, 'get_session', lambda value: value['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in value['threads']), process_id=130)
    registers = c.inspect('get_registers', process_id=130, tid=child['pid'])
    assert registers['process_id'] == 130 and int(registers['registers']['rip'], 16)
    process_action(c, 130, 'remove_breakpoint', id=probe)
    checks['process_130_breakpoint_and_registers'] = True
    assert c.session()['process_id'] == 1 and c.session()['state'] == 'stopped'
    generation = c.session()['generation']
    rejected(c, 'set_process_following', 'InvalidProcessLimit', generation=generation, enabled=True, process_limit=129)
    assert c.session()['generation'] == generation
    checks['cannot_lower_below_retained_count'] = True
    rejected(c, 'get_processes', 'InvalidArguments', limit=129)
    checks['page_bound_128'] = True
    # Normal completion proves the parent reaps every worker; shutdown is not
    # the success path for this fixture.
    for process in range(130, 1, -1): process_action(c, process, 'continue')
    process_action(c, 1, 'continue')
    deadline = time.monotonic() + 10
    while True:
        rows = page_all(c)
        if all(row['state'] == 'exited' for row in rows): break
        assert time.monotonic() < deadline, rows
        for row in rows:
            if row['state'] == 'stopped': process_action(c, row['process_id'], 'continue')
        time.sleep(.003)
    for process in (1, 129, 130):
        events = []
        after = 0
        while True:
            page = c.inspect('query_events', process_id=process, after=after)
            events.extend(page['events'])
            if not page['has_more']: break
            assert page['events'] and page['events'][-1]['sequence'] > after
            after = page['events'][-1]['sequence']
        assert [event for event in events if event['kind'] == 'exit'][-1]['detail'] == 0, events
    assert all(not Path('/proc', str(row['pid'])).exists() for row in rows)
    checks['all_130_exited_and_reaped'] = True
    checks['elapsed_seconds'] = time.monotonic() - start_time
finally:
    try: c.close()
    finally:
        reader.join(timeout=2)
        (run / 'transcript.json').write_text(json.dumps(c.transcript, indent=2) + '\n')
        (run / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
print(json.dumps(checks, indent=2))
print(run)
