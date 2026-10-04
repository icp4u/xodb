#!/usr/bin/env python3
"""Demonstrate real ARM64 source debugging through the ordinary stdio MCP API."""
import argparse
import os
from pathlib import Path
from client import Client

args = argparse.ArgumentParser(description=__doc__)
args.add_argument('--pause', action='store_true', help='wait for Enter between demo steps')
args = args.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)

def stage(text):
    print('\n' + text, flush=True)
    if args.pause:
        input('Press Enter to continue... ')

client = Client('control')
pid = None
try:
    session = client.session()
    pid = session['pid']
    tid = session['threads'][0]['tid']
    assert session['architecture'] == 'aarch64', session
    print('xodb ARM64 demo: real process {}, controlled through MCP'.format(pid))
    stage('1. Set a symbol breakpoint at change_value and run to it.')
    probe = client.action('set_breakpoint', symbol='change_value')['id']
    client.action('continue')
    client.stopped('breakpoint')
    regs = client.inspect('get_registers', tid=tid)['registers']
    print('Stopped: PC={}, SP={}, LR={}'.format(regs['pc'], regs['sp'], regs['x30']))
    frames = client.inspect('get_stack', tid=tid)['frames']
    assert len(frames) >= 2 and frames[0]['symbol'] == 'change_value' and frames[1]['symbol'] == 'main'
    for frame in frames:
        print('  #{} {}'.format(frame['index'], frame['symbol'] or '[unknown]'))
    stage('2. Stop at the assignment, after the parameters and local are initialized.')
    client.action('remove_breakpoint', id=probe)
    source = root / 'tests/fixtures/m1.c'
    line = next(i for i, s in enumerate(source.read_text().splitlines(), 1) if 'WATCH_WRITE' in s)
    probes = client.action('set_breakpoint', file='m1.c', line=line)['ids']
    client.action('continue')
    client.stopped('breakpoint')
    print('m1.c:{}: {}'.format(line, source.read_text().splitlines()[line-1].strip()))
    for expression, expected in [('item->value', '7'), ('amount', '5'), ('next', '12'), ('item->value + amount', '12')]:
        value = client.inspect('evaluate_expression', tid=tid, expression=expression)['value']
        assert value['availability'] == 'available' and value['display'] == expected, value
        print('  {} = {}'.format(expression, value['display']))
    stage('3. Step over the source assignment and inspect its result.')
    for probe in probes:
        client.action('remove_breakpoint', id=probe)
    client.action('step_source', tid=tid)
    stopped = client.stopped()
    assert not stopped['source_stepping'] and not stopped['step_diagnostic'], stopped
    value = client.inspect('evaluate_expression', tid=tid, expression='item->value')['value']
    assert value['display'] == '12', value
    print('  item->value = {}'.format(value['display']))
finally:
    client.close()
    assert pid is None or not Path('/proc/{}'.format(pid)).exists(), 'Owned target was not reaped'
print('\nDemo passed. Owned fixture cleaned up. GUI, profiling and hardware watches follow later.')
