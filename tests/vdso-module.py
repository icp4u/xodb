#!/usr/bin/env python3
"""A stop inside [vdso] names a vDSO symbol and unwinds to main.

The kernel maps that ELF with no filesystem path. [vsyscall] and [vvar] stay unloaded.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import time
import zlib
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--binary', type=Path, default=Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')))
p.add_argument('--agent', type=Path)
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = args.work.resolve()
work.mkdir(parents=True, exist_ok=True)
started = time.monotonic()

# Names the kernel publishes for the routines a process actually calls.
wanted = (
    'clock_gettime', '__vdso_clock_gettime',
    '__kernel_vsyscall', '__kernel_clock_gettime',
    'gettimeofday', '__vdso_gettimeofday',
    'clock_getres', '__vdso_clock_getres',
    'time', '__vdso_time',
    'getcpu', '__vdso_getcpu',
    'getrandom', '__vdso_getrandom',
)
prefer = (
    'clock_gettime', '__vdso_clock_gettime',
    '__kernel_clock_gettime', '__kernel_vsyscall',
    'gettimeofday', '__vdso_gettimeofday',
)

(work / 'loop.c').write_text(
    '#include <time.h>\n'
    'int main(void) {\n'
    '  struct timespec ts;\n'
    '  for (;;) clock_gettime(CLOCK_MONOTONIC, &ts);\n'
    '}\n')
exe = work / 'fixture'
subprocess.run(['cc', '-O2', '-g', '-o', str(exe), str(work / 'loop.c')], check=True, timeout=30)
os.environ['XODB_BIN'] = str(args.binary.resolve())


def regions_of(client):
    rows, cursor = [], None
    while True:
        page = client.inspect('list_modules', **({'cursor': cursor} if cursor else {}))
        rows.extend(page['regions'])
        cursor = page.get('next')
        if not cursor:
            return rows


def read_bytes(client, address, size):
    out = bytearray()
    remain = size
    at = address
    while remain:
        chunk = min(remain, 4096)
        reply = client.inspect('read_memory', address=hex(at), length=chunk)
        raw = bytes.fromhex(reply['hex'])
        assert reply['bytes_read'] == len(raw) and raw, (reply['bytes_read'], chunk)
        out += raw
        at += len(raw)
        remain -= len(raw)
        if len(raw) < chunk:
            break
    return bytes(out)


def parse_elf(blob, region):
    assert blob[:4] == b'\x7fELF', blob[:4]
    elf_class, endian = blob[4], blob[5]
    assert elf_class in (1, 2) and endian in (1, 2), (elf_class, endian)
    little = endian == 1
    order = '<' if little else '>'
    half, word = ('H', 'I') if elf_class == 1 else ('H', 'Q')
    if elf_class == 2:
        e_type, e_machine, e_version = struct.unpack_from(order + 'HHI', blob, 16)
        e_entry, e_phoff, e_shoff = struct.unpack_from(order + 'QQQ', blob, 24)
        e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(order + 'HHHHH', blob, 54)
    else:
        e_type, e_machine, e_version = struct.unpack_from(order + 'HHI', blob, 16)
        e_entry, e_phoff, e_shoff = struct.unpack_from(order + 'III', blob, 24)
        e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(order + 'HHHHH', blob, 42)
    assert e_type == 3 and e_version == 1, (e_type, e_machine, e_version)
    loads = []
    for index in range(e_phnum):
        off = e_phoff + index * e_phentsize
        if elf_class == 2:
            p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(order + 'IIQQQQQQ', blob, off)
        else:
            p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = struct.unpack_from(order + 'IIIIIIII', blob, off)
        if p_type == 1 and p_flags & 1:
            loads.append((p_offset, p_vaddr, p_filesz))
    assert loads, 'no executable PT_LOAD'
    sections = []
    for index in range(e_shnum):
        off = e_shoff + index * e_shentsize
        if elf_class == 2:
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from(order + 'IIQQQQIIQQ', blob, off)
        else:
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from(order + 'IIIIIIIIII', blob, off)
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_entsize))
    symbols = []
    for sh_type, sh_offset, sh_size, sh_link, sh_entsize in sections:
        if sh_type not in (2, 11) or sh_entsize == 0 or sh_link >= len(sections):
            continue
        strings_off, strings_size = sections[sh_link][1], sections[sh_link][2]
        strings = blob[strings_off:strings_off + strings_size]
        count = sh_size // sh_entsize
        for index in range(1, count):
            ent = sh_offset + index * sh_entsize
            if elf_class == 2:
                st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(order + 'IBBHQQ', blob, ent)
            else:
                st_name, st_value, st_size, st_info, st_other, st_shndx = struct.unpack_from(order + 'IIIBBH', blob, ent)
            if st_shndx == 0 or st_info & 15 not in (1, 2):
                continue
            end = strings.find(b'\0', st_name)
            if end < 0:
                continue
            name = strings[st_name:end].decode()
            if name not in wanted:
                continue
            symbols.append((name, st_value, st_size))
    assert symbols, 'vDSO dynamic symbols were not readable'
    chosen = None
    for name in prefer:
        for symbol in symbols:
            if symbol[0] == name and symbol[2] > 0:
                chosen = symbol
                break
        if chosen:
            break
    assert chosen, symbols
    p_offset, p_vaddr, _ = next(item for item in loads if item[0] == region['offset'])
    assert region['offset'] == p_offset
    return region['start'] + chosen[1] - p_vaddr, chosen[0], symbols


def program_counter(client, tid):
    registers = client.inspect('get_registers', tid=tid)['registers']
    for name in ('rip', 'pc', 'nip', 'era'):
        if name in registers:
            return int(registers[name], 16)
    raise AssertionError(sorted(registers))


def tool_ok(client, name, **fields):
    reply = client.tool(name, generation=client.session()['generation'], **fields)
    result = reply.get('result', {})
    if result.get('isError'):
        return None
    return result.get('structuredContent')


def main():
    client = Client('control', str(exe), options=['--runtime-agent', str(args.agent.resolve())] if args.agent else [], reply_seconds=20)
    report = {}
    try:
        client.stopped()
        mapped = regions_of(client)
        vdso = next(row for row in mapped if row['path'] == '[vdso]' and row['offset'] == 0)
        blob = read_bytes(client, vdso['start'], vdso['end'] - vdso['start'])
        assert len(blob) == vdso['end'] - vdso['start'], (len(blob), vdso['end'] - vdso['start'])
        address, symbol, symbols = parse_elf(blob, vdso)
        assert vdso['start'] <= address < vdso['end'], (hex(address), vdso['start'], vdso['end'])
        # The kernel's own names resolve before any frame has loaded the image.
        own = next(item for item in symbols if item[0].startswith(('__vdso_', '__kernel_')))
        found = client.inspect('find_symbol', name=own[0])
        assert found['name'] == own[0] and vdso['start'] <= int(found['address'], 16) < vdso['end'], (own, found)
        client.action('set_breakpoint', symbol='main')
        client.continue_initial_stop()
        stopped = client.stopped('breakpoint')
        tid = stopped['pid']
        mode = 'breakpoint'
        planted = tool_ok(client, 'set_breakpoint', address=hex(address))
        if planted is None:
            mode = 'sample'
        else:
            client.continue_initial_stop()
            try:
                stopped = client.stopped('breakpoint', seconds=3)
            except AssertionError:
                mode = 'sample'
                if client.session()['state'] == 'running':
                    client.action('interrupt')
                    client.stopped()
        if mode == 'sample':
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if client.session()['state'] == 'stopped':
                    client.continue_initial_stop()
                time.sleep(0.01)
                client.action('interrupt')
                stopped = client.stopped()
                tid = stopped['pid']
                pc = program_counter(client, tid)
                if vdso['start'] <= pc < vdso['end']:
                    break
            else:
                raise AssertionError('never stopped inside [vdso]')
        stack = client.inspect('get_stack', tid=tid)
        frames = stack['frames']
        names = [frame.get('symbol') for frame in frames]
        diagnostics = [frame.get('diagnostic') for frame in frames]
        assert frames and frames[0].get('symbol') in wanted, frames[:3]
        assert 'NoBinaryImage' not in diagnostics, frames[:4]
        assert len(frames) >= 2 and 'main' in names, frames[:6]
        fresh = regions_of(client)
        sources = {row['path']: row.get('file_source') for row in fresh if row['path'] in ('[vdso]', '[vsyscall]', '[vvar]')}
        assert sources.get('[vdso]') == 'target_memory', sources
        assert sources.get('[vsyscall]') != 'target_memory'
        assert sources.get('[vvar]') != 'target_memory'
        report = {
            'status': 'pass',
            'mode': mode,
            'symbol': symbol,
            'frame': frames[0].get('symbol'),
            'frames': names,
            'file_source': sources,
            'seconds': round(time.monotonic() - started, 3),
        }
    finally:
        client.close()
        (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('vdso module: pass ' + report['mode'] + ' ' + report['frame'])
    return report


CHAIN = ('__vdso_clock_gettime', 'clock_gettime', 'spin', 'main')
MEMI = 0x494d454d


def has_chain(names):
    """Leaf-to-root order, with the vDSO symbol as the leaf."""
    if not names or names[0] != CHAIN[0]:
        return False
    at = 0
    for name in names:
        if name == CHAIN[at]:
            at += 1
            if at == len(CHAIN):
                return True
    return False


def memory_section(path):
    """Return archive bytes, embedded image bytes, and the section's size delta."""
    blob = path.read_bytes()
    assert blob[:8] == b'XODBCAPT', blob[:8]
    minor = struct.unpack_from('<H', blob, 10)[0]
    count = struct.unpack_from('<I', blob, 24)[0]
    embedded = 0
    body_len = None
    for index in range(count):
        tag, _flags, offset, length, _crc = struct.unpack_from('<IIQII', blob, 64 + index * 24)
        if tag != MEMI:
            continue
        body = blob[offset:offset + length]
        n = struct.unpack_from('<I', body, 0)[0]
        pos = 4
        for _ in range(n):
            _image_id, nbytes = struct.unpack_from('<QI', body, pos)
            pos += 12 + nbytes
            embedded += nbytes
        assert pos == len(body), (pos, len(body))
        body_len = length
    assert body_len is not None and minor >= 12 and embedded > 0, (minor, embedded, body_len)
    return len(blob), embedded, 24 + body_len


def tampered(path, out):
    """Flip one byte of the embedded ELF and reseal the section CRC: only the digest can catch it."""
    blob = bytearray(path.read_bytes())
    count = struct.unpack_from('<I', blob, 24)[0]
    for index in range(count):
        entry = 64 + index * 24
        tag, _flags, offset, length, _crc = struct.unpack_from('<IIQII', blob, entry)
        if tag != MEMI:
            continue
        blob[offset + 16 + 0x200] ^= 0xff
        struct.pack_into('<I', blob, entry + 20, zlib.crc32(blob[offset:offset + length]) & 0xffffffff)
        out.write_bytes(bytes(blob))
        return out
    raise AssertionError('no MEMI section')


def archive_ready(client):
    deadline = time.monotonic() + 20
    while True:
        state = client.inspect('get_archive_status')
        job = state['job']
        if job['done']:
            assert job['error_name'] is None, state
            return state
        assert time.monotonic() < deadline, state
        time.sleep(0.05)


def opened_archive(client):
    """The open job can flip done in the same turn that publishes the capture."""
    deadline = time.monotonic() + 20
    while True:
        state = archive_ready(client)
        if state.get('recorded_origin') is not None:
            return state
        assert time.monotonic() < deadline, state
        time.sleep(0.05)


def stack_names(client, capture, ordinal):
    deadline = time.monotonic() + 15
    while True:
        result = client.inspect('get_profile_stack', capture_id=capture['id'], revision=capture['revision'], sample=ordinal)
        if not result['pending']:
            frames = (result.get('derived') or {}).get('frames') or []
            return [frame.get('name') for frame in frames]
        assert time.monotonic() < deadline, result
        time.sleep(0.02)


def chain_from(path, options):
    client = Client('control', None, options=['--open-capture', str(path), *options], reply_seconds=30)
    try:
        state = opened_archive(client)
        reports = state['recorded_origin']['images']
        vdso = next(item for item in reports if item['path'] == '[vdso]')
        assert vdso['status'] == 'verified', vdso
        capture = client.inspect('get_profile')['capture']
        shown = []
        for ordinal in range(min(capture['stored_samples'], 40)):
            names = stack_names(client, capture, ordinal)
            if has_chain(names):
                return names, state.get('view_basis')
            if len(shown) < 6:
                shown.append(names)
        raise AssertionError(shown)
    finally:
        client.close()


def profile_case():
    """Save a capture whose [vdso] bytes travel inside the archive.

    Reopening with --symbols and with reanalysis names
    __vdso_clock_gettime <- clock_gettime <- spin <- main
    from those bytes, with no digest file for [vdso].
    """
    source = work / 'spin.c'
    source.write_text(
        '#include <time.h>\n'
        'static void spin(void) __attribute__((noinline));\n'
        'static void spin(void) {\n'
        '  struct timespec ts;\n'
        '  for (;;) clock_gettime(CLOCK_MONOTONIC, &ts);\n'
        '}\n'
        'int main(void) { spin(); return 0; }\n')
    binary = work / 'spin'
    subprocess.run(['cc', '-O0', '-fno-inline', '-fno-optimize-sibling-calls', '-g', '-o', str(binary), str(source)], check=True, timeout=30)
    archive = work / 'vdso.xcap'
    archive.unlink(missing_ok=True)
    client = Client('control', str(binary), options=['--runtime-agent', str(args.agent.resolve())] if args.agent else [], reply_seconds=20)
    stored = 0
    try:
        client.stopped()
        client.action('start_profile', frequency_hz=499, duration_ms=0, user_stack_bytes=8192, user_stack_budget_bytes=1048576)
        client.action('continue')
        deadline = time.monotonic() + 8
        capture = None
        while True:
            capture = client.inspect('get_profile')['capture']
            if capture['stored_samples'] >= 30 or time.monotonic() > deadline:
                break
            time.sleep(0.05)
        capture = client.action('stop_profile', capture_id=capture['id'])['capture']
        rows = client.inspect('get_profile_mappings', capture_id=capture['id'], revision=capture['revision'], start=0, limit=64)['mappings']
        vdso_rows = [row for row in rows if row['path'] == '[vdso]']
        assert vdso_rows and all(row['reason'] == 'elf' for row in vdso_rows), vdso_rows
        published = client.action('save_capture_archive', capture_id=capture['id'], revision=capture['revision'], path=str(archive))
        state = archive_ready(client)
        assert state['job']['id'] == published['job_id']
        assert state['job']['publication']['state'] == 'published', state['job']
        stored = capture['stored_samples']
    finally:
        client.close()
    archive_bytes, embedded_bytes, section_delta = memory_section(archive)
    plain = Client('control', None, options=['--open-capture', str(archive)], reply_seconds=30)
    try:
        origin = opened_archive(plain)['recorded_origin']
        assert all(item['status'] == 'not_requested' for item in origin['images']), origin['images']
        assets = work / 'profile-assets'
        assets.mkdir(exist_ok=True)
        vdso_digest = None
        for image in origin['images']:
            digest = bytes(image['identity']['sha256']).hex()
            src = Path(image['path'])
            if image['path'] == '[vdso]':
                vdso_digest = digest
                continue
            if not src.is_file():
                continue
            shutil.copy2(src, assets / digest)
        assert vdso_digest and not (assets / vdso_digest).exists()
    finally:
        plain.close()
    symbols_names, _basis = chain_from(archive, ['--symbols', str(assets)])
    bad = tampered(archive, work / 'vdso-tampered.xcap')
    opened = Client('control', None, options=['--open-capture', str(bad), '--symbols', str(assets)], reply_seconds=30)
    try:
        reports = opened_archive(opened)['recorded_origin']['images']
        vdso = next(item for item in reports if item['path'] == '[vdso]')
        assert vdso['status'] == 'content_mismatch', vdso
    finally:
        opened.close()
    reanalysis_names, basis = chain_from(archive, ['--symbols', str(assets), '--resolve-capture-symbols'])
    assert basis == 'verified_assets_reanalysis', basis
    return {
        'profile_vdso_samples': stored,
        'archive_bytes': archive_bytes,
        'embedded_image_bytes': embedded_bytes,
        'memory_section_delta_bytes': section_delta,
        'symbols_chain': symbols_names,
        'reanalysis_chain': reanalysis_names,
    }


def i386_case():
    """An interrupted -m32 syscall unwinds from __kernel_vsyscall to main."""
    if args.agent or platform.machine() != 'x86_64':
        return None
    source = work / 'pause32.c'
    source.write_text('#include <unistd.h>\nint main(void) { pause(); return 0; }\n')
    binary = work / 'pause32'
    subprocess.run(['cc', '-m32', '-O2', '-fomit-frame-pointer', '-g', '-o', str(binary), str(source)], check=True, timeout=30)
    client = Client('control', str(binary), reply_seconds=20)
    try:
        client.stopped()
        client.continue_initial_stop()
        time.sleep(0.3)
        client.action('interrupt')
        stopped = client.stopped()
        frames = client.inspect('get_stack', tid=stopped['threads'][0]['tid'])['frames']
        names = [frame.get('symbol') for frame in frames]
        assert names[0] == '__kernel_vsyscall', frames[:3]
        assert 'pause' in names and 'main' in names, frames[:6]
        return names
    finally:
        client.close()


def core_case():
    """A core has no NT_FILE row for [vdso]; NT_AUXV names it and its PT_LOAD holds the bytes."""
    # The core reader is x86-64 only.
    if args.agent or platform.machine() != 'x86_64' or not shutil.which('gdb'):
        return None
    core = work / 'fixture.core'
    core.unlink(missing_ok=True)
    with (work / 'gdb.log').open('w') as log:
        subprocess.run(['gdb', '-q', '-batch', '-nx', '-ex', 'break main', '-ex', 'run',
                        '-ex', 'break __vdso_clock_gettime', '-ex', 'continue',
                        '-ex', 'generate-core-file ' + str(core), '-ex', 'kill', '--args', str(exe)],
                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=60, check=True)
    assert core.is_file(), (work / 'gdb.log').read_text()[-2000:]
    client = Client('control', None, options=['--core', str(core), '--exe', str(exe)], reply_seconds=20)
    try:
        tid = client.session()['threads'][0]['tid']
        frames = client.inspect('get_stack', tid=tid)['frames']
        names = [frame.get('symbol') for frame in frames]
        assert frames[0].get('symbol') in wanted, frames[:3]
        assert 'main' in names, frames[:6]
        sources = {row['path']: row.get('file_source') for row in regions_of(client) if row['path'] == '[vdso]'}
        assert sources == {'[vdso]': 'target_memory'}, sources
        return names
    finally:
        client.close()


if __name__ == '__main__':
    report = main()
    report.update(profile_case())
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('vdso module profile: pass archive_bytes=' + str(report['archive_bytes'])
          + ' embedded_image_bytes=' + str(report['embedded_image_bytes'])
          + ' memory_section_delta_bytes=' + str(report['memory_section_delta_bytes']))
    print('vdso module profile symbols: ' + ' <- '.join(name or '?' for name in report['symbols_chain']))
    print('vdso module profile reanalysis: ' + ' <- '.join(name or '?' for name in report['reanalysis_chain']))
    names = i386_case()
    if names is not None:
        report['i386_frames'] = names
        (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        print('vdso module i386: pass ' + ' <- '.join(name or '?' for name in names))
    names = core_case()
    if names is not None:
        report['core_frames'] = names
        (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        print('vdso module core: pass ' + names[0])
