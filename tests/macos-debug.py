#!/usr/bin/env python3
"""Source and locals from owned Apple dSYMs and recorded stopped state.

The recorded argument register is an independent value oracle. No unrecorded
stack or global memory is fabricated to make a local readable.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import time

from client import Client

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('macos_names', ROOT/'tests/macos-names.py')
names = importlib.util.module_from_spec(spec)
spec.loader.exec_module(names)

# llvm-dwarfdump --lookup at the recorded PC, against each matching dSYM.
CASES = {
    'c-O2-basic': ('c/main.c', 31, None),
    'cxx-basic': ('cxx/main.cpp', 7, 'unavailable'),
    'cxx-O2-basic': ('cxx/main.cpp', 7, 'register'),
    'objc-basic': ('objc/main.m', 6, 'unavailable'),
    'objc-O2-basic': ('objc/main.m', 6, 'register'),
    'swift-basic': ('swift/main.swift', 5, 'unavailable'),
    'swift-O-basic': ('swift/main.swift', 5, 'missing-type'),
}


def case(name, work, wrong=False, objects=False):
    recording = json.loads((names.FIXTURES/'transcripts'/f'{name}.json').read_text())
    stops = names.phases(recording)
    stub = names.Replay(recording, stops)
    stub.start()
    binary = names.FIXTURES/'corpus'/recording['program']
    if objects:
        directory = work/(name+'-objects')
        directory.mkdir()
        local = directory/binary.name
        shutil.copyfile(binary, local)
        for object_ in binary.parent.glob('*.o'):
            shutil.copyfile(object_, directory/object_.name)
        binary = local
    client = Client('mutate', executable=None, options=('--gdb-remote', stub.endpoint,
                    '--exe', str(binary)), reply_seconds=30)
    try:
        before = names.resources(client.p.pid)
        tid = client.session()['threads'][0]['tid']
        frames = names.wait_stack(client, tid)
        source = client.inspect('get_source_location', address=hex(stops[0].pc))['source']
        path, line, argument = CASES[name]
        assert source['path'] == '/xodb-corpus/src/'+path, source
        assert source['line'] == line+(1 if wrong else 0), source
        assert frames[0]['source']['path'] == source['path'], frames[0]
        if name == 'c-O2-basic':
            assert frames[0]['unwind_method'] == 'macho_compact', frames[0]
            assert frames[1]['pc'] == int.from_bytes(bytes.fromhex(stops[0].registers[30]), 'little'), frames[1]
            assert frames[1]['registers'][31] == int.from_bytes(bytes.fromhex(stops[0].registers[31]), 'little'), frames[1]
        locals_ = client.inspect('list_locals', tid=tid)['locals']
        marker = 'cxx_marker' if name.startswith('cxx') else 'objc_marker' if name.startswith('objc') else 'marker' if name.startswith('c-') else None
        if marker:
            global_ = next(local for local in locals_ if local['name']==marker)
            expected = recording['static']['symbols'][marker]+int(recording['notes']['slide'], 0)
            address = global_['value']['address']
            assert (int(address, 0) if isinstance(address, str) else address) == expected, global_
            assert global_['value']['availability'] == 'unavailable' and global_['value']['diagnostic'] == 'MemoryUnreadable', global_
        if argument:
            total = next((local for local in locals_ if local['name']=='total'), None)
            assert total and total['parameter'], locals_
            assert total['value']['size'] == 8, total
            if argument == 'register':
                expected = int.from_bytes(bytes.fromhex(stops[0].registers[0]), 'little')
                assert total['value']['availability'] == 'available', total
                bits = total['value']['bits']
                assert (int(bits, 0) if isinstance(bits, str) else bits) == expected, total
            elif argument == 'missing-type':
                assert 0 in stops[0].registers, 'recorded argument register absent'
                assert total['value']['availability'] == 'unavailable', total
                assert total['value']['kind'] == 'unknown' and total['diagnostic'] == 'SwiftTypeLayoutUnavailable', total
            else:
                assert total['value']['availability'] != 'available', total
                assert total['diagnostic'] or total['value'].get('diagnostic'), total
        assert not stub.extra, stub.extra
        return dict(case=name, mode='objects' if objects else 'dsym', status='pass', source=source, locals=locals_, frames=frames,
                    resources_before=before, resources_after=names.resources(client.p.pid))
    finally:
        (work/f'{name}-calls.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        names.close(client, stub, work, name)


def refused(result, expected):
    assert result['isError'] and result['content'][0]['text'] == expected, result


def hostile(name, work):
    recording = json.loads((names.FIXTURES/'transcripts/cxx-O2-basic.json').read_text())
    stops = names.phases(recording)
    original = names.FIXTURES/'corpus'/recording['program']
    directory = work/name
    directory.mkdir()
    binary = directory/original.name
    shutil.copyfile(original, binary)
    original_debug = original.with_name(original.name+'.dSYM')/'Contents/Resources/DWARF'/original.name
    debug = binary.with_name(binary.name+'.dSYM')/'Contents/Resources/DWARF'/binary.name
    debug.parent.mkdir(parents=True)
    shutil.copyfile(original_debug, debug)
    expected = 'MachODsymUuidMismatch'
    if name == 'dsym-uuid':
        data = bytearray(debug.read_bytes())
        at = 32
        changed = False
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 0x1b:
                data[at+8] ^= 1
                changed = True
            at += size
        assert changed
        debug.write_bytes(data)
    elif name == 'dsym-symlink':
        debug.unlink()
        debug.symlink_to(original_debug)
        expected = 'MachODebugFileRefused'
    elif name == 'dsym-directory-symlink':
        debug.unlink()
        debug.parent.rmdir()
        debug.parent.symlink_to(original_debug.parent, target_is_directory=True)
        expected = 'MachODebugFileRefused'
    elif name == 'dsym-changed':
        expected = 'MachODebugFileChanged'
    else:
        raise AssertionError(name)
    stub = names.Replay(recording, stops)
    stub.start()
    client = Client('mutate', executable=None, options=('--gdb-remote', stub.endpoint,
                    '--exe', str(binary)), reply_seconds=30)
    try:
        tid = client.session()['threads'][0]['tid']
        frames = names.wait_stack(client, tid)
        assert frames[0]['symbol'] == 'cxxprog!bp_target+0x0', frames[0]
        if name == 'dsym-changed':
            initial = client.inspect('get_source_location', address=hex(stops[0].pc))
            assert initial['source']['line'] == 7, initial
            with debug.open('ab') as f:
                f.write(b'changed')
        reply = client.tool('get_source_location', address=hex(stops[0].pc))['result']
        refused(reply, expected)
        assert not stub.extra, stub.extra
        return dict(case=name, status='pass', diagnostic=expected, fault_observed=True)
    finally:
        (work/f'{name}-calls.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        names.close(client, stub, work, name)


def object_hostile(name, work):
    recording = json.loads((names.FIXTURES/'transcripts/cxx-O2-basic.json').read_text())
    stops = names.phases(recording)
    original = names.FIXTURES/'corpus'/recording['program']
    directory = work/name
    directory.mkdir()
    binary = directory/original.name
    shutil.copyfile(original, binary)
    for obj in original.parent.glob('*.o'):
        shutil.copyfile(obj, directory/obj.name)
    obj = directory/'main.o'
    expected = 'MachOObjectDebugUnavailable'
    if name == 'object-symlink':
        obj.unlink()
        obj.symlink_to(original.parent/'main.o')
    elif name in ('object-mtime', 'object-traversal'):
        data = bytearray(binary.read_bytes())
        at = 32
        symbols = None
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 2:
                symbols = struct.unpack_from('<4I', data, at+8)
            at += size
        assert symbols
        symoff, count, stroff, _ = symbols
        changed = False
        for i in range(count):
            at = symoff+16*i
            strx, type_ = struct.unpack_from('<IB', data, at)
            end = data.index(0, stroff+strx)
            path = bytes(data[stroff+strx:end])
            if type_ == 0x66 and path.endswith(b'/main.o'):
                if name == 'object-mtime':
                    struct.pack_into('<Q', data, at+8, 1)
                    expected = 'MachOObjectChanged'
                else:
                    data[stroff+strx:stroff+strx+4] = b'/../'
                changed = True
        assert changed
        binary.write_bytes(data)
    elif name == 'object-relocation':
        data = bytearray(obj.read_bytes())
        at = 32
        changed = False
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 0x19:
                for i in range(struct.unpack_from('<I', data, at+64)[0]):
                    section = at+72+80*i
                    if not bytes(data[section:section+16]).startswith(b'__debug_'):
                        continue
                    reloc, count = struct.unpack_from('<II', data, section+56)
                    if not count:
                        continue
                    flags = struct.unpack_from('<I', data, reloc+4)[0]
                    struct.pack_into('<I', data, reloc+4, flags | (1<<24))
                    changed = True
            at += size
        assert changed
        obj.write_bytes(data)
        expected = 'MachOObjectDebugUnsupported'
    elif name == 'object-changed':
        expected = 'MachOObjectChanged'
    elif name == 'object-symbol-section':
        # A defined data symbol whose n_sect names no section (0, or past the
        # section table). The worker must skip it, not dereference a missing
        # section: code stays mapped, that one global stays unmapped.
        data = bytearray(obj.read_bytes())
        at = 32
        symbols = None
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 2:
                symbols = struct.unpack_from('<4I', data, at+8)
            at += size
        symoff, count, stroff, _ = symbols
        changed = False
        for i in range(count):
            at = symoff+16*i
            strx, type_ = struct.unpack_from('<IB', data, at)
            if bytes(data[stroff+strx:data.index(0, stroff+strx)]) == b'_cxx_marker' and type_ & 0x0e == 0x0e:
                data[at+5] = 0
                changed = True
        assert changed
        obj.write_bytes(data)
        expected = None
    elif name == 'object-extern-relocation':
        # Not hostile: the same address written the other legal way. The
        # compiler relocates this global's DWARF address against its section
        # (addend = address). Rewrite it against the symbol (addend = 0); the
        # global must resolve to the same runtime address.
        data = bytearray(obj.read_bytes())
        at = 32
        symbols = None
        sections = []
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == 2:
                symbols = struct.unpack_from('<4I', data, at+8)
            if cmd == 0x19:
                sections = [at+72+80*i for i in range(struct.unpack_from('<I', data, at+64)[0])]
            at += size
        symoff, count, stroff, _ = symbols
        index, value, sect = next((i, struct.unpack_from('<Q', data, symoff+16*i+8)[0], data[symoff+16*i+5]) for i in range(count)
            if bytes(data[stroff+struct.unpack_from('<I', data, symoff+16*i)[0]:data.index(0, stroff+struct.unpack_from('<I', data, symoff+16*i)[0])]) == b'_cxx_marker')
        section = next(s for s in sections if bytes(data[s:s+16]).rstrip(b'\0') == b'__debug_addr')
        offset, = struct.unpack_from('<I', data, section+48)
        reloc, relocs = struct.unpack_from('<II', data, section+56)
        changed = False
        for i in range(relocs):
            where, bits = struct.unpack_from('<II', data, reloc+8*i)
            if bits >> 27 & 1 or bits & 0xffffff != sect or struct.unpack_from('<Q', data, offset+where)[0] != value:
                continue
            struct.pack_into('<I', data, reloc+8*i+4, bits & 0xff000000 | 1 << 27 | index)
            struct.pack_into('<Q', data, offset+where, 0)
            changed = True
        assert changed
        obj.write_bytes(data)
        expected = None
    else:
        raise AssertionError(name)
    stub = names.Replay(recording, stops)
    stub.start()
    client = Client('mutate', executable=None, options=('--gdb-remote', stub.endpoint, '--exe', str(binary)), reply_seconds=30)
    try:
        tid = client.session()['threads'][0]['tid']
        frames = names.wait_stack(client, tid)
        assert frames[0]['symbol'] == 'cxxprog!bp_target+0x0', frames[0]
        if name == 'object-changed':
            source = client.inspect('get_source_location', address=hex(stops[0].pc))
            assert source['source']['line'] == 7, source
            with obj.open('ab') as out:
                out.write(b'changed')
        if expected is None:
            source = client.inspect('get_source_location', address=hex(stops[0].pc))
            assert source['source']['line'] == 7, source
            marker = next(v for v in client.inspect('list_locals', tid=tid)['locals'] if v['name'] == 'cxx_marker')
            diagnostic = marker['diagnostic'] or marker['value']['diagnostic']
            if name == 'object-extern-relocation':
                address = marker['value']['address']
                assert (int(address, 0) if isinstance(address, str) else address) == recording['static']['symbols']['cxx_marker']+int(recording['notes']['slide'], 0), marker
                assert diagnostic == 'MemoryUnreadable', marker
            else:
                assert marker['value']['availability'] != 'available' and marker['value']['address'] is None, marker
                assert diagnostic == 'MachOObjectAddressUnavailable', marker
            assert client.p.poll() is None, 'xodb exited'
            return dict(case=name, status='pass', diagnostic=diagnostic, fault_observed=True)
        reply = client.tool('get_source_location', address=hex(stops[0].pc))['result']
        refused(reply, expected)
        assert not stub.extra, stub.extra
        return dict(case=name, status='pass', diagnostic=expected, fault_observed=True)
    finally:
        (work/(name+'-calls.json')).write_text(json.dumps(client.transcript, indent=2)+'\n')
        names.close(client, stub, work, name)


def missing_frame(work):
    recording = json.loads((names.FIXTURES/'transcripts/cxx-O2-basic.json').read_text())
    stops = names.phases(recording)
    # Refuse every instruction/stack read while still supplying the recorded
    # registers and image list, and the local UUID-matched symbol/dSYM files.
    stops[0].memory = []
    seen = []
    def mutate(request, replies):
        if request.startswith('m') and replies == ['E01']:
            seen.append(request)
        return replies
    stub = names.Replay(recording, stops, mutate)
    stub.start()
    binary = names.FIXTURES/'corpus'/recording['program']
    client = Client('mutate', executable=None, options=('--gdb-remote', stub.endpoint, '--exe', str(binary)), reply_seconds=30)
    try:
        names.wait_label(client, stops[0].pc)
        frames = names.wait_stack(client, client.session()['threads'][0]['tid'])
        assert len(frames) == 2 and seen, (frames, seen)
        assert frames[0]['unwind_method'] == 'macho_compact', frames
        assert frames[-1]['symbol'] == 'cxxprog!main+0x10c', frames
        assert frames[0]['symbol'] == 'cxxprog!bp_target+0x0', frames
        assert frames[-1]['diagnostic'] == 'MemoryUnreadable', frames
        return dict(case='missing-frame-memory', status='pass', refused_reads=len(seen), frames=frames)
    finally:
        names.close(client, stub, work, 'missing-frame-memory')


def main():
    os.umask(0o022)
    os.chdir(ROOT)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--only', choices=CASES)
    p.add_argument('--wrong-result', action='store_true')
    p.add_argument('--objects', action='store_true')
    p.add_argument('--hostile', action='store_true')
    args = p.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    result = dict(status='running', rows=[], load=os.getloadavg())
    start = time.monotonic()
    try:
        if args.hostile:
            result['rows'].append(missing_frame(work))
            for name in ('dsym-uuid', 'dsym-symlink', 'dsym-directory-symlink', 'dsym-changed'):
                result['rows'].append(hostile(name, work))
                print(json.dumps(dict(case=name, status='pass')), flush=True)
            for name in ('object-symlink', 'object-mtime', 'object-traversal', 'object-relocation', 'object-changed', 'object-symbol-section', 'object-extern-relocation'):
                result['rows'].append(object_hostile(name, work))
                print(json.dumps(dict(case=name, status='pass')), flush=True)
        else:
            for name in CASES:
                if args.only and args.only != name:
                    continue
                row = case(name, work, args.wrong_result, args.objects)
                result['rows'].append(row)
                print(json.dumps(dict(case=name, status='pass')), flush=True)
        result['status'] = 'pass'
    finally:
        if result['status'] == 'running':
            result['status'] = 'fail'
        result['seconds'] = time.monotonic()-start
        (work/'results.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
