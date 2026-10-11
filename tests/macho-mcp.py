#!/usr/bin/env python3
"""get_macho_image over MCP: a Linux process maps owned Mach-O files and the
tool reports identity, slices, segments and symbols, on the native runtime,
through the runtime agent and for a shared observer. No Mac is involved."""
import argparse, importlib.util, json, os, shutil, subprocess, time
from pathlib import Path
from client import Client
from helpers import macho_fixture as mf

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, default=Path('.work/macho-mcp'))
p.add_argument('--wrong-result', action='store_true', help='plant a wrong UUID expectation; the run must fail')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
holder = w / 'hold'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror', 'tests/fixtures/macho/hold.c', '-o', str(holder)], check=True, timeout=60)
good, facts = mf.image()
intel = mf.image(cputype=mf.X86_64, subtype=3)[0]
files = {
    'thin': good,
    'universal': mf.fat([(mf.X86_64, 3, intel), (mf.ARM64, mf.ARM64E, mf.image(subtype=mf.ARM64E)[0])]),
    'hostile': good[:16] + (0xffffffff).to_bytes(4, 'little') + good[20:],
    'java': bytes.fromhex('cafebabe00000034') + bytes(200),
    'big-endian': bytes.fromhex('feedfacf') + bytes(200),
    'text': b'not an image\n' * 32,
}
# One symbol more than a call will index, and exactly as many as it will.
crowd = [(1, 0x0e, 1, 0, facts['functions'][0][1])] * (131073 - facts['symbols'])
files['crowded'] = mf.image(extra_symbols=crowd)[0]
files['full'] = mf.image(extra_symbols=crowd[1:])[0]
for name, blob in files.items(): (w / name).write_bytes(blob)
report = dict(status='running', transports=[])


def addresses(pid):
    out = {}
    for line in Path(f'/proc/{pid}/maps').read_text().splitlines():
        fields = line.split(None, 5)
        if len(fields) > 5 and Path(fields[5]).parent == w and Path(fields[5]).name in files:
            out[Path(fields[5]).name] = int(fields[0].split('-')[0], 16)
    assert set(out) == set(files), out
    return out


def error(reply, name):
    assert reply.get('result', {}).get('isError'), reply
    assert reply['result']['content'][0]['text'] == name, reply


def check(raw, pid):
    at = {name: hex(address) for name, address in addresses(pid).items()}
    reply = raw('get_macho_image', address=at['thin'], symbol='_helper', symbol_address=hex(facts['functions'][2][1] + 3), sections=True)
    assert 'error' not in reply and not reply['result'].get('isError'), reply
    data = reply['result']['structuredContent']
    assert json.loads(reply['result']['content'][0]['text']) == data and len(json.dumps(reply)) < 64 * 1024
    assert data['uuid'] == ('00000000-0000-0000-0000-000000000000' if a.wrong_result else facts['uuid']), data['uuid']
    assert (data['container'], data['arch'], data['file_type'], data['platform'], data['minimum_os'], data['pie'], data['in_shared_cache']) == ('thin', 'arm64', 'execute', 'macos', '13.0.0', True, False), data
    assert data['path'] == str(w / 'thin') and data['file_size'] == len(good) and data['entry'] == dict(kind='main', address=hex(facts['entry']))
    assert [(s['name'], s['vmaddr'], s['vmsize'], s['initprot']) for s in data['segments']] == [
        ('__PAGEZERO', '0x0', hex(facts['base']), '---'), ('__TEXT', hex(facts['base']), '0x1000', 'r-x'),
        ('__DATA', hex(facts['base'] + 0x1000), '0x2000', 'rw-'), ('__LINKEDIT', hex(facts['base'] + 0x3000), '0x1000', 'r--')], data['segments']
    assert {(s['segment'], s['name']): s['bytes'] for s in data['sections']}[('__TEXT', '__unwind_info')] == 'ok' and data['total_sections'] == 5
    assert data['libraries'] == [dict(kind='load', name='/usr/lib/libSystem.B.dylib')]
    assert data['symbols'] == dict(status='ok', count=facts['symbols']) and data['function_starts'] == dict(status='ok', count=4)
    assert data['debug_map']['objects'] == [dict(path='/obj/owned/fixture.o', mtime=0x65000000, source='fixture.c', functions=3)]
    name, address, size = facts['functions'][1]
    assert data['symbol'] == dict(status='ok', name=name, address=hex(address), size=None, defined=True, external=True, segment='__TEXT', section='__text'), data['symbol']
    name, address, size = facts['functions'][2]
    assert data['symbol_at'] == dict(status='ok', name=name, address=hex(address), size=hex(size), defined=True, external=False, segment='__TEXT', section='__text'), data['symbol_at']
    assert data['code_signature'] and data['fixups'] == 'none' and 'compact_unwind' in data['not_read']
    assert 0 < data['reads']['source_bytes'] < 64 * 1024 and data['reads']['retained_bytes'] < 64 * 1024
    missing = raw('get_macho_image', address=at['thin'], symbol='_absent', symbol_address='0x10')['result']['structuredContent']
    assert missing['symbol']['status'] == 'not-found' and missing['symbol_at']['status'] == 'not-found' and missing['sections'] is None
    # A universal file: the slice list, the default choice and a named one.
    first = raw('get_macho_image', address=at['universal'])['result']['structuredContent']
    assert (first['container'], first['arch']) == ('fat', 'x86_64') and [(s['arch'], s['selected']) for s in first['slices']] == [('x86_64', True), ('arm64e', False)]
    named = raw('get_macho_image', address=at['universal'], arch='arm64', symbol='_main')['result']['structuredContent']
    assert named['arch'] == 'arm64e' and named['uuid'] == facts['uuid'] and named['symbol']['address'] == hex(facts['entry'])
    # Typed refusals; a refused file leaves the session usable.
    error(raw('get_macho_image', address=at['hostile']), 'MachOMalformed')
    error(raw('get_macho_image', address=at['big-endian']), 'MachOUnsupported')
    error(raw('get_macho_image', address=at['java']), 'NotMachO')
    error(raw('get_macho_image', address=at['text']), 'NotMachO')
    error(raw('get_macho_image', address='0x10'), 'NotMachO')
    # The tool reads only what the process maps: there is no path argument.
    for bad in (dict(address=at['thin'], arch='ppc'), dict(address=at['thin'], path=str(w / 'thin')), dict(), dict(address='zz'), dict(address=at['thin'], symbol='')):
        assert raw('get_macho_image', **bad).get('error', {}).get('code') == -32602, bad
    # Lookups index the whole table inside the call: refused above the cap,
    # with the identity and the counts still reported.
    name, address, size = facts['functions'][1]
    crowded = raw('get_macho_image', address=at['crowded'], symbol=name, symbol_address=hex(address))['result']['structuredContent']
    assert crowded['uuid'] == facts['uuid'] and crowded['symbols'] == dict(status='ok', count=131073), crowded['symbols']
    assert crowded['symbol'] == crowded['symbol_at'] and crowded['symbol']['status'] == 'limit' and crowded['symbol']['name'] is None, crowded['symbol']
    full = raw('get_macho_image', address=at['full'], symbol=name, symbol_address=hex(address))['result']['structuredContent']
    assert full['symbols']['count'] == 131072 and (full['symbol']['status'], full['symbol']['address'], full['symbol_at']['status']) == ('ok', hex(address), 'ok'), (full['symbol'], full['symbol_at'])
    again = raw('get_macho_image', address=at['thin'])['result']['structuredContent']
    assert again['uuid'] == facts['uuid'] and again['symbol'] is None
    return dict(bytes_read=data['reads']['source_bytes'], reply_bytes=len(json.dumps(reply)))


try:
    arguments = [str(w / name) for name in files]
    for agent in (False, True):
        c = Client('control', str(holder), args=arguments, options=['--runtime-agent', str(root / 'zig-out/bin/xodb-agent')] if agent else [])
        try:
            c.stopped(); c.action('set_breakpoint', symbol='macho_mapped'); c.continue_initial_stop()
            state = c.stopped('breakpoint', seconds=30)
            listed = {d['name'] for d in c.call('tools/list')['result']['tools']}
            assert 'get_macho_image' in listed
            result = check(c.tool, state['pid']); result['name'] = 'agent' if agent else 'native'; report['transports'].append(result)
        finally: c.close()
    spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
    shutil.rmtree(w / 'shared', ignore_errors=True); (w / 'shared').mkdir()  # a rerun in the same work directory starts clean
    server = shared.Server(root, w / 'shared', root / 'zig-out/bin/xodb', holder, 'control', fixture_args=tuple(arguments))
    try:
        owner, observer = shared.Client(server, 'owner'), shared.Client(server, 'observer'); owner.claim(ttl_ms=60000)
        initial = shared.eventually(owner.session, lambda v: v['state'] == 'stopped' and not v['symbol_discovery_pending'], 'initial stop')
        server.remember_target(initial); owner.action('set_breakpoint', symbol='macho_mapped'); owner.action('continue')
        state = shared.eventually(owner.session, lambda v: v['state'] == 'stopped' and not v['continue_pending'] and any(t['reason'] == 'breakpoint' for t in v['threads']), 'mapped stop', timeout=30)
        result = check(observer.raw, state['pid']); result['name'] = 'shared observer'; report['transports'].append(result)
    finally: server.close()
    report['status'] = 'pass'
finally:
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    (w / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
