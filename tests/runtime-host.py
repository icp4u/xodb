#!/usr/bin/env python3
"""The ordinary host analysis path against a standalone C agent.

Native: python3 tests/runtime-host.py
Cross ISA: add --ssh HOST --ssh-config FILE --agent PATH --fixture PATH --arch m68k
or --arch loongarch64 or --arch ppc64le. The remote fixture is tests/fixtures/runtime-isa.c
compiled with -g -O0.
"""
import argparse
import json
import os
from pathlib import Path
import time
from client import Client

p = argparse.ArgumentParser()
p.add_argument('--ssh')
p.add_argument('--ssh-config')
p.add_argument('--agent', default='./zig-out/bin/xodb-agent')
p.add_argument('--fixture', default='./zig-out/bin/xodb-m1-fixture')
p.add_argument('--arch', default='x86_64', choices=['x86_64', 'm68k', 'loongarch64', 'ppc64le'])
a = p.parse_args()
os.chdir(Path(__file__).resolve().parents[1])
options = ['--runtime-agent', a.agent]
if a.ssh: options += ['--runtime-ssh', a.ssh]
if a.ssh_config: options += ['--ssh-config', a.ssh_config]
c = Client('mutate', executable=a.fixture, options=options)
try:
    state = c.session()
    assert state['architecture'] == a.arch, state
    assert c.inspect('get_debug_view', summary_only=True)['architecture'] == a.arch
    tid = state['threads'][0]['tid']
    pc = 'rip' if a.arch == 'x86_64' else 'pc'
    symbol = c.inspect('find_symbol', name='change_value')
    bp = c.action('set_breakpoint', symbol='change_value')['id']
    c.action('continue')
    c.stopped('breakpoint')
    regs = c.inspect('get_registers', tid=tid)['registers']
    if a.arch == 'ppc64le':
        def num(v):
            return int(v, 16) if isinstance(v, str) else int(v)
        # The symbol address is the global entry. The breakpoint is the local entry.
        assert num(regs[pc]) == num(symbol['address']) + int(symbol.get('local_entry') or 0), (regs, symbol)
    else:
        assert regs[pc] == symbol['address'], (regs, symbol)
    if a.arch == 'loongarch64':
        def refused(tool_name, text, **args):
            response = c.tool(tool_name, generation=c.session()['generation'], **args)
            assert response['result']['isError'] and response['result']['content'][0]['text'] == text, response
        # The host binary records the Capstone major it was compiled with.
        # Major 6 decodes LoongArch. An older major refuses it.
        blob = Path(os.environ.get('XODB_BIN', './zig-out/bin/xodb')).read_bytes()
        marker = b'xodb-capstone-api-major:'
        at = blob.find(marker)
        assert at >= 0, 'host binary has no Capstone major marker'
        end = at + len(marker)
        while end < len(blob) and 48 <= blob[end] <= 57:
            end += 1
        major = int(blob[at + len(marker):end])
        dis = c.tool('disassemble', generation=c.session()['generation'], address=regs[pc])
        if major >= 6:
            instructions = dis['result']['structuredContent']['instructions']
            assert instructions and instructions[0]['address'] == regs[pc], dis
            disasm_note = 'disassembly decoded'
        else:
            assert dis['result']['isError'] and dis['result']['content'][0]['text'] == 'DisassemblerUnavailable', dis
            disasm_note = 'disassembly refused'
        c.action('step_instruction', tid=tid)
        c.stopped('single_step')
        stepped = c.inspect('get_registers', tid=tid)['registers']
        assert stepped[pc] != regs[pc], (stepped[pc], regs[pc])
        assert stepped['r0'] == regs['r0'], (stepped['r0'], regs['r0'])
        refused('set_watchpoint', 'UnsupportedArchitecture', address=symbol['address'], length=8)
        refused('start_profile', 'ProfilingUnsupportedArchitecture')
        refused('start_allocations', 'UnsupportedAllocationArchitecture', tids=[tid])
        refused('start_observation', 'UnsupportedObservationArchitecture', tids=[tid], mapping_address='0x1000', functions=['malloc'])
        assert c.session()['state'] == 'stopped'
        frames = c.inspect('get_stack', tid=tid)['frames']
        assert len(frames) >= 2, frames
        assert any(f.get('symbol') == 'main' for f in frames), frames
        value = c.inspect('evaluate_expression', tid=tid, expression='state.value')
        assert int(value['bits'], 16) == 7, value
        c.action('write_register', tid=tid, name='r12', value=regs['r12'])
    else:
        instructions = c.inspect('disassemble', address=regs[pc])['instructions']
        assert instructions and instructions[0]['address'] == regs[pc]
        c.action('step_instruction', tid=tid)
        c.stopped('single_step')
        frames = c.inspect('get_stack', tid=tid)['frames']
        assert len(frames) >= 2, frames
        assert any(f.get('symbol') == 'main' for f in frames), frames
        for _ in range(2):
            c.action('step_instruction', tid=tid)
            c.stopped('single_step')
        value = c.inspect('evaluate_expression', tid=tid, expression='state.value')
        assert int(value['bits'],16) == 7, value
        if a.arch == 'm68k':
            effects = c.tool('get_instruction_effects', address=regs[pc])
            assert effects['result']['isError'] and effects['result']['content'][0]['text'] == 'InstructionAnalysisUnsupportedArchitecture', effects
            assert set(['d0','a6','usp','pc','sr']).issubset(regs), regs
            c.action('write_register',tid=tid,name='d0',value=regs['d0'])
        if a.arch == 'ppc64le':
            def refused(tool_name, text, **args):
                response = c.tool(tool_name, generation=c.session()['generation'], **args)
                assert response['result']['isError'] and response['result']['content'][0]['text'] == text, response
            refused('set_watchpoint', 'UnsupportedArchitecture', address=symbol['address'], length=8)
            refused('start_profile', 'ProfilingUnsupportedArchitecture')
            refused('start_allocations', 'UnsupportedAllocationArchitecture', tids=[tid])
            refused('start_observation', 'UnsupportedObservationArchitecture', tids=[tid], mapping_address='0x1000', functions=['malloc'])
            assert set(['r0', 'r1', 'r2', 'lr', 'pc']).issubset(regs), regs
            c.action('write_register', tid=tid, name='r12', value=regs['r12'])
    c.action('remove_breakpoint', id=bp)
    c.action('continue')
    until = time.monotonic() + 5
    while c.session()['state'] != 'exited':
        assert time.monotonic() < until
        time.sleep(.002)
    if a.arch == 'loongarch64':
        print(f'C agent host integration passed (loongarch64): symbols, registers, breakpoint, stack, expression; {disasm_note}; software step; watchpoints, profile and uprobes refused')
    elif a.arch == 'ppc64le':
        print('C agent host integration passed (ppc64le): symbols, registers, local-entry breakpoint, break/step, disassembly, stack, expression; watches, profile and uprobes refused')
    else:
        print(f'C agent host integration passed ({a.arch}): target files, ELF, symbols, registers, break/step, disassembly, stack, expression and cleanup')
finally:
    c.close()
