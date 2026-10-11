#!/usr/bin/env python3
"""Fast Mach-O component lane: linker-built and hand-assembled images, both
layouts, and hostile fields that must each end in a typed status.

Fixtures are built here: Zig cross-compiles the owned C sources to Mach-O, and
tests/helpers/macho_fixture.py assembles what a linker will not produce. Every case
runs under a plain and an ASan/UBSan build of the reader's test tool.
--fuzz adds the cap-sized cases and a bounded libFuzzer run (periodic).
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
from helpers import orphans
from helpers import macho_fixture as mf

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--fuzz', action='store_true')
p.add_argument('--wrong-result', action='store_true', help='plant one wrong expectation; the run must fail')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022); orphans.adopt()
w = a.work.resolve(); w.mkdir(parents=True)
started = time.monotonic(); results = []
MIB = 1 << 20


def record(name, begin, **row):
    results.append(dict(name=name, seconds=round(time.monotonic() - begin, 4), **row))
    (w / 'results.json').write_text(json.dumps(dict(checks=results, elapsed_seconds=time.monotonic() - started), indent=2) + '\n')


def command(args, name, expect=0, timeout=120):
    begin = time.monotonic()
    run = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    (w / (name + '.log')).write_text(run.stdout + run.stderr)
    record(name, begin, exit=run.returncode, expected=expect, status='pass' if run.returncode == expect else 'fail')
    assert run.returncode == expect, (name, run.returncode, run.stdout[-2000:], run.stderr[-2000:])
    return run.stdout


def rows(text):
    out = {}
    for line in text.splitlines():
        key, *rest = line.split('\t')
        out.setdefault(key, []).append(rest)
    return out


baseline = {}


def tool(name, path, *args, expect=0, sanitized=True):
    """Run the plain tool (measured) and the sanitized one; both must agree."""
    outputs = []
    for label, binary in (('plain', check), ('san', sanitizer))[:2 if sanitized else 1]:
        begin = time.monotonic()
        child = subprocess.Popen([str(binary), str(path), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try: out, err = child.communicate(timeout=60)  # a hang detector, not a speed claim
        except subprocess.TimeoutExpired: child.kill(); raise
        (w / f'{name}.{label}.log').write_text(out + err)
        code = child.returncode
        record(f'{name}.{label}', begin, exit=code, expected=expect, status='pass' if code == expect else 'fail')
        assert code == expect, (name, label, code, out[-2000:], err[-2000:])
        outputs.append(out)
    assert len(set(outputs)) == 1, (name, 'plain and sanitized builds disagree')
    return rows(outputs[0])


def rss(path, *args):
    """Peak resident KiB of one plain run."""
    child = subprocess.Popen([str(check), str(path), *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, usage = os.wait4(child.pid, 0)
    child.returncode = os.waitstatus_to_exitcode(status)
    assert child.returncode == 0, (path, child.returncode)
    return usage.ru_maxrss


def expect(name, data, load, *args, **tables):
    """A source and the status of the load and of each table."""
    if isinstance(data, (bytes, bytearray)):
        path = w / name; path.write_bytes(data)
    else: path = data
    out = tool(name, path, *args)
    got = out['load'][0][0]
    assert got == load, (name, 'load', got, load)
    for table, status in tables.items():
        assert out[table][0][0] == status, (name, table, out[table][0], status)
    if load == 'ok':
        counters = dict(item.split('=') for item in out['counters'][0])
        retained = int(counters['retained'])
    else: retained = 0
    # Flat memory: whatever a hostile file claims, the process grows only by
    # what the reader says it retained (plus allocator slack).
    peak = rss(path, *args)
    assert peak <= baseline['rss'] + retained // 1024 + 8 * 1024, (name, peak, baseline, retained)
    return out


def patched(data, *edits):
    out = bytearray(data)
    for at, blob in edits: out[at:at + len(blob)] = blob
    return bytes(out)


u32 = lambda n: struct.pack('<I', n)
u64 = lambda n: struct.pack('<Q', n)

# --- tools -----------------------------------------------------------------
check, sanitizer = w / 'check', w / 'check-san'
sources = ['tests/macho-image.c', 'src/binary/macho.c']
command(['cc', '-std=c11', '-O2', '-g', '-DNDEBUG', '-Wall', '-Wextra', '-Werror', *sources, '-o', str(check)], 'compile-check')
command(['clang', '-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
         *sources, '-o', str(sanitizer)], 'compile-sanitized')

# --- hand-assembled, every value known --------------------------------------
good, facts = mf.image()
(w / 'hand').write_bytes(good)
baseline['rss'] = rss(w / 'hand')
names = [name for name, _, _ in facts['functions']]
out = expect('hand', good, 'ok', 'memory', 'faults', *('find=' + n for n in names), 'find=_counter', 'find=_printf', 'find=_absent',
             *('at=%x' % (address + size - 1) for _, address, size in facts['functions']), 'at=%x' % facts['hidden'],
             'at=%x' % facts['text_end'], 'at=%x' % (facts['base'] + 0x7ff), 'slide=%x' % (facts['base'] + 0x4000),
             symbols='ok', starts='ok', debug='ok')
header = out['header'][0]
assert [int(x, 0) for x in header] == [mf.ARM64, 0, mf.MH_EXECUTE, facts['flags'], facts['commands'], len(good) and struct.unpack_from('<I', good, 20)[0]], header
assert out['uuid'][0][0] == ('00000000-0000-0000-0000-000000000000' if a.wrong_result else facts['uuid']), out['uuid']
assert out['version'][0] == ['1', '13.0.0', '14.2.0', 'build'] and out['entry'][0] == ['main', hex(facts['entry'])]
assert out['dysymtab'][0] == [str(x) for x in (0, facts['locals'], facts['locals'], facts['externals'], facts['locals'] + facts['externals'], facts['undefined'])]
assert [(s[1], s[2], s[3], s[4], s[5]) for s in out['segment']] == [
    ('__PAGEZERO', '0x0', hex(facts['base']), '0', '0'), ('__TEXT', hex(facts['base']), '0x1000', '0', '4096'),
    ('__DATA', hex(facts['base'] + 0x1000), '0x2000', '4096', '4096'), ('__LINKEDIT', hex(facts['base'] + 0x3000), '0x1000', '8192', str(len(good) - 0x2000))], out['segment']
sections = {(s[1], s[2]): s for s in out['section']}
assert sections[('__TEXT', '__unwind_info')][3:5] == [hex(facts['base'] + 0x900), '0x40'] and sections[('__TEXT', '__unwind_info')][7:] == ['ok', '2304']
assert sections[('__TEXT', '__eh_frame')][7:] == ['ok', '2368'] and sections[('__DATA', '__bss')][7] == 'unavailable'
assert out['dylib'] == [['1', '/usr/lib/libSystem.B.dylib', '0x54c0000', '0x10000']] and int(out['symbols'][0][1]) == facts['symbols']
assert out['tables'][0] == ['symtab=1', 'dysymtab=1', 'starts=1', 'signature=1', 'trie=0', 'fixups=0', 'encrypted=0']
found = {row[0]: row[1:] for row in out['find']}
for name, address, _ in facts['functions']: assert found[name][:2] == ['ok', hex(address)], found
assert found['_counter'][:2] == ['ok', hex(facts['counter'])] and found['_printf'] == ['ok', '0x0', '0x1', '0'] and found['_absent'][0] == 'not-found'
# The last byte of each function resolves to it with its size; _local has no
# following symbol and is sized by LC_FUNCTION_STARTS; the function that only
# function starts know has no name, and nothing past a section's end has.
at = {int(row[0], 16): row[1:] for row in out['at']}
for name, address, size in facts['functions']: assert at[address + size - 1] == ['ok', name, hex(address), str(size)], at
assert at[facts['hidden']][0] == at[facts['text_end']][0] == at[facts['base'] + 0x7ff][0] == 'not-found'
assert [int(row[0], 16) for row in out['start']] == [address for _, address, _ in facts['functions']] + [facts['hidden']]
assert out['debug'][0] == ['ok', '1', '3'] and out['object'][0] == ['0', '/obj/owned/fixture.o', str(0x65000000), '/src/owned/', 'fixture.c', '0', '3']
assert [(f[0], int(f[1], 16), int(f[2]), f[3]) for f in out['function']] == [(d['name'], d['address'], d['size'], '0') for d in facts['debug']]
assert out['slide'][0] == [hex(facts['base'] + 0x4000), 'ok', '0x4000'] and out['memory'][0][0] == 'ok' and out['faults'][0][0] == 'ok'
# Stab and plain entries are told apart; N_EXT and N_SECT are reported.
kinds = {(row[6], row[5]) for row in out['symbol']}
assert {('_local', '8'), ('_main', '10'), ('_printf', '18'), ('/obj/owned/fixture.o', '1')} <= kinds, kinds
tool('wrong-result', w / 'hand', 'wrong-result', expect=-6, sanitized=False)

variants = dict(arm64e=dict(subtype=mf.ARM64E), x86_64=dict(cputype=mf.X86_64, subtype=3), unixthread=dict(unixthread=True),
                version_min=dict(version_min=True), dylib=dict(filetype=mf.MH_DYLIB, flags=0x85))
for name, options in variants.items():
    blob, known = mf.image(**options)
    out = expect('hand-' + name, blob, 'ok', 'memory', 'faults', symbols='ok', starts='ok', debug='ok')
    assert int(out['header'][0][0], 0) == known['cputype'] and int(out['header'][0][1], 0) == known['subtype']
    if name == 'unixthread': assert out['entry'][0] == ['unixthread', hex(known['entry'])]
    if name == 'x86_64':
        blob = mf.image(cputype=mf.X86_64, subtype=3, unixthread=True)[0]
        assert expect('hand-x86_64-unixthread', blob, 'ok')['entry'][0] == ['unixthread', hex(known['entry'])]
    if name == 'version_min': assert out['version'][0] == ['1', '10.15.0', '14.0.0', 'min']
    if name == 'dylib': assert out['entry'][0][0] == 'none' and out['dylib'][0] == ['0', '@rpath/libowned.dylib', '0x20304', '0x10000']

# --- universal files ----------------------------------------------------------
intel = mf.image(cputype=mf.X86_64, subtype=3)[0]
arm64e = mf.image(subtype=mf.ARM64E)[0]
for wide in (False, True):
    label = 'fat64' if wide else 'fat'
    both = mf.fat([(mf.X86_64, 3, intel), (mf.ARM64, mf.ARM64E, arm64e)], wide=wide)
    out = expect(label + '-first', both, 'ok', 'faults', symbols='ok')
    assert out['fat'][0] == ['2', str(int(wide))] and int(out['header'][0][0], 0) == mf.X86_64
    assert [(int(s[1], 0), int(s[2], 0), int(s[3]), int(s[4])) for s in out['slice']] == [(mf.X86_64, 3, 0x1000, len(intel)), (mf.ARM64, mf.ARM64E, 0x4000, len(arm64e))]
    out = expect(label + '-arm64', both, 'ok', 'arch=arm64', 'memory', 'find=_main', symbols='ok', starts='ok')
    assert out['selected'][0] == ['16384', str(len(arm64e))] and [int(x, 0) for x in out['header'][0][:2]] == [mf.ARM64, mf.ARM64E]
    assert out['find'][0][1:3] == ['ok', hex(facts['entry'])] and sections[('__TEXT', '__eh_frame')][3] == [s for s in out['section'] if s[2] == '__eh_frame'][0][3]
    # A section's source offset includes the slice.
    assert [s for s in out['section'] if s[2] == '__eh_frame'][0][8] == str(0x4000 + 2368)
    expect(label + '-absent-arch', mf.fat([(mf.X86_64, 3, intel)], wide=wide), 'not-found', 'arch=arm64')
    expect(label + '-no-supported-arch', mf.fat([(7, 3, intel)], wide=wide), 'unsupported')
    expect(label + '-wrong-arch-in-slice', mf.fat([(mf.ARM64, 0, intel)], wide=wide), 'malformed')
    expect(label + '-in-fat', mf.fat([(mf.ARM64, 0, both)], wide=wide), 'malformed')
    expect(label + '-archive-slice', mf.fat([(mf.ARM64, 0, b'!<arch>\n' + bytes(64))], wide=wide), 'unsupported')
    expect(label + '-junk-slice', mf.fat([(mf.ARM64, 0, bytes(64))], wide=wide), 'malformed')
    magic = struct.pack('>I', 0xcafebabf if wide else 0xcafebabe)
    expect(label + '-count-zero', magic + struct.pack('>I', 0) + bytes(64), 'malformed')
    expect(label + '-count-2-31', magic + struct.pack('>I', 1 << 31) + bytes(64), 'limit')
    expect(label + '-count-33', magic + struct.pack('>I', 33) + bytes(4096), 'limit')
    expect(label + '-table-truncated', both[:8 + 20], 'malformed')
    expect(label + '-header-truncated', both[:6], 'malformed')
    row = 32 if wide else 20
    offset, size = (16, 24) if wide else (16, 20)  # second arch: offset and size fields
    pack = (lambda n: struct.pack('>Q', n)) if wide else (lambda n: struct.pack('>I', n))
    second = 8 + row
    expect(label + '-overlap', patched(both, (second + 8, pack(0x1000 + 16))), 'malformed')
    expect(label + '-offset-past-end', patched(both, (second + 8, pack(len(both) + 1))), 'malformed')
    expect(label + '-size-past-end', patched(both, (second + (16 if wide else 12), pack(len(both)))), 'malformed')
    expect(label + '-offset-in-table', patched(both, (8 + 8, pack(8))), 'malformed')
    expect(label + '-size-zero', patched(both, (second + (16 if wide else 12), pack(0))), 'malformed')
    if wide: expect(label + '-offset-overflow', patched(both, (second + 8, pack((1 << 64) - 16)), (second + 16, pack(32))), 'malformed')
# The magic a Java class file shares: version 52.0 where a slice count would be.
java = bytes.fromhex('cafebabe00000034') + bytes(200)
expect('java-class', java, 'not-macho')
expect('java-class-45-3', bytes.fromhex('cafebabe0003002d') + bytes(200), 'not-macho')

# --- hostile fields -----------------------------------------------------------
at = facts['at']
for length in (0, 1, 3): expect(f'truncated-{length}', good[:length], 'not-macho')
for length in (4, 8, 31, 32, 33, 32 + 71, 32 + struct.unpack_from('<I', good, 20)[0] - 1): expect(f'truncated-{length}', good[:length], 'malformed')
expect('not-macho', b'\x7fELF' + bytes(64), 'not-macho')
expect('big-endian', bytes.fromhex('feedfacf') + bytes(64), 'unsupported')
expect('thin-32', bytes.fromhex('cefaedfe') + bytes(64), 'unsupported')
expect('thin-32-big-endian', bytes.fromhex('feedface') + bytes(64), 'unsupported')
expect('shared-cache-file', b'dyld_v1  arm64e\0' + bytes(4096), 'unsupported')
expect('cputype-arm64-32', patched(good, (4, u32(0x0200000c))), 'unsupported')
expect('ncmds-2-32', patched(good, (at['ncmds'], u32(0xffffffff))), 'malformed')
expect('ncmds-one-more', patched(good, (at['ncmds'], u32(facts['commands'] + 1))), 'malformed')
expect('sizeofcmds-past-end', patched(good, (at['sizeofcmds'], u32(len(good)))), 'malformed')
expect('sizeofcmds-2-32', patched(good, (at['sizeofcmds'], u32(0xffffffff))), 'malformed')
expect('sizeofcmds-short', patched(good, (at['sizeofcmds'], u32(80))), 'malformed')
first = at['first_command'] + 4
for label, value in (('zero', 0), ('one', 1), ('seven', 7), ('unaligned', 76), ('past-end', 0x10000), ('2-32', 0xfffffff8)):
    expect('cmdsize-' + label, patched(good, (first, u32(value))), 'malformed')
expect('cmdsize-below-struct', patched(good, (at['uuid'] + 4, u32(16)), (at['uuid'] + 16, u32(0x32) + u32(8))), 'malformed')
text = at['text']
expect('segment-file-overflow', patched(good, (text + 40, u64((1 << 64) - 0x1000) + u64(0x2000))), 'malformed')
expect('segment-file-wraps-to-zero', patched(good, (text + 40, u64((1 << 64) - 0x1000) + u64(0x1000))), 'malformed')
expect('segment-vm-overflow', patched(good, (text + 24, u64((1 << 64) - 0x800))), 'malformed')
expect('segment-file-past-end', patched(good, (at['linkedit'] + 48, u64(len(good)))), 'malformed')
expect('segment-file-larger-than-vm', patched(good, (text + 32, u64(0x800))), 'malformed')
expect('nsects-huge', patched(good, (text + 64, u32(0xffffffff))), 'malformed')
expect('nsects-one-more', patched(good, (text + 64, u32(4))), 'malformed')
expect('section-outside-segment', patched(good, (text + 72 + 32, u64(facts['base'] + 0x2000))), 'malformed')
expect('section-size-overflow', patched(good, (text + 72 + 40, u64((1 << 64) - 1))), 'malformed')
out = expect('section-file-range-outside', patched(good, (text + 72 + 48, u32(0x7000))), 'ok')
assert [s for s in out['section'] if s[2] == '__text'][0][7] == 'unavailable'
expect('duplicate-uuid', mf.image(extra_commands=[struct.pack('<II16s', 0x1b, 24, bytes(16))])[0], 'malformed')
expect('duplicate-symtab', mf.image(extra_commands=[struct.pack('<IIIIII', 0x2, 24, 0, 0, 0, 0)])[0], 'malformed')
expect('dylib-name-outside', mf.image(extra_commands=[struct.pack('<IIIIII', 0xc, 24, 24, 0, 0, 0)])[0], 'malformed')
expect('dylib-name-before-struct', mf.image(extra_commands=[struct.pack('<IIIIII', 0xc, 32, 8, 0, 0, 0) + b'abcdefg\0'])[0], 'malformed')
expect('dylib-name-unterminated', mf.image(extra_commands=[struct.pack('<IIIIII', 0xc, 32, 24, 0, 0, 0) + b'abcdefgh'])[0], 'malformed')
expect('unixthread-count-overflow', mf.image(extra_commands=[struct.pack('<IIII', 0x5, 24, 6, 0x40000001) + bytes(8)])[0], 'malformed')
expect('build-version-tools-overflow', mf.image(extra_commands=[struct.pack('<IIIIII', 0x32, 24, 1, 0, 0, 5)])[0], 'malformed')
expect('dysymtab-range-outside', patched(good, (at['dysymtab'] + 12, u32(facts['symbols'] + 1))), 'malformed')
expect('dysymtab-range-overflow', patched(good, (at['dysymtab'] + 24, u32(0xffffffff) + u32(2))), 'malformed')
out = expect('unknown-command', mf.image(extra_commands=[struct.pack('<II', 0x7fff, 16) + bytes(8)])[0], 'ok', symbols='ok')
out = expect('chained-fixups-and-trie', mf.image(extra_commands=[struct.pack('<IIII', 0x80000034, 16, 0, 0), struct.pack('<IIII', 0x80000033, 16, 0, 0),
             struct.pack('<IIIIII', 0x2c, 24, 0, 0, 1, 0)])[0], 'ok')
assert out['tables'][0][4:] == ['trie=1', 'fixups=2', 'encrypted=1']
# Caps: one past each count is refused before anything of that size exists.
many = [mf.segment('__X%d' % i, 0x200000000 + i * 0x1000, 0x1000, 0, 0, 1) for i in range(253)]
def relocated(count):  # commands that outgrow the fixture's 2 KiB header area go to a bigger one
    body = b''.join(many[:count]); blob = bytearray(0x10000 + len(good) - 0x800)
    cmds = good[32:32 + struct.unpack_from('<I', good, 20)[0]]
    blob[:32] = good[:16] + u32(facts['commands'] + count) + u32(len(cmds) + len(body)) + good[24:32]
    blob[32:32 + len(cmds) + len(body)] = cmds + body
    return bytes(blob)
expect('segments-at-cap', relocated(252), 'ok')
expect('segments-over-cap', relocated(253), 'limit')
wide = mf.segment('__WIDE', 0x300000000, 0x100000, 0, 0, 1, [dict(name='s%d' % i, addr=0x300000000 + i, size=1, flags=1) for i in range(1024)])
def sectioned(count):
    body = wide * count; blob = bytearray(32 + len(body))
    blob[:32] = struct.pack('<IIIIIIII', 0xfeedfacf, mf.ARM64, 0, 1, count, len(body), 0, 0); blob[32:] = body
    return bytes(blob)
out = expect('sections-over-cap', sectioned(5), 'limit')
tiny = struct.pack('<II', 0x7ffe, 8)
def commanded(count):
    return struct.pack('<IIIIIIII', 0xfeedfacf, mf.ARM64, 0, 1, count, 8 * count, 0, 0) + tiny * count
expect('commands-at-cap', commanded(16384), 'ok')
expect('commands-over-cap', commanded(16385), 'limit')
expect('command-bytes-over-cap', struct.pack('<IIIIIIII', 0xfeedfacf, mf.ARM64, 0, 1, 1, MIB + 8, 0, 0) + struct.pack('<II', 0x7ffe, MIB + 8) + bytes(MIB), 'limit')
expect('no-commands', struct.pack('<IIIIIIII', 0xfeedfacf, mf.ARM64, 0, 1, 0, 0, 0, 0), 'ok', symbols='unavailable', starts='unavailable', debug='unavailable')

# Symbol and string tables: the image still loads; the table says what is wrong.
symtab = at['symtab']
expect('symoff-past-end', patched(good, (symtab + 8, u32(len(good)))), 'ok', symbols='malformed', debug='malformed')
expect('symoff-2-32', patched(good, (symtab + 8, u32(0xffffffff))), 'ok', symbols='malformed')
expect('stroff-past-end', patched(good, (symtab + 16, u32(len(good) - 8))), 'ok', symbols='malformed')
expect('strsize-2-32', patched(good, (symtab + 20, u32(0xffffffff))), 'ok', symbols='malformed')
expect('nsyms-2-31', patched(good, (symtab + 12, u32(1 << 31)), (at['dysymtab'] + 8, bytes(24))), 'ok', symbols='malformed')
expect('nsyms-2-32', patched(good, (symtab + 12, u32(0xffffffff)), (at['dysymtab'] + 8, bytes(24))), 'ok', symbols='malformed')
local = at['sym_off']  # the first symbol is _local
out = expect('strx-past-strsize', patched(good, (local, u32(facts['strings']))), 'ok', 'find=_local', 'find=_main', 'at=%x' % (facts['base'] + 0x860), symbols='ok')
assert out['symbol'][0][6] == '!malformed' and out['find'][0][1] == 'not-found' and out['find'][1][1] == 'ok' and out['at'][0][1:3] == ['ok', '!malformed']
assert 'unnamed=1' in out['counters'][0]
out = expect('strx-2-32', patched(good, (local, u32(0xffffffff))), 'ok', symbols='ok')
assert out['symbol'][0][6] == '!malformed'
# The last string runs to the end of the table with no terminator.
open_end, known = mf.image(strings_tail=b'_unterminated')
open_end = patched(open_end, (known['at']['sym_off'], u32(known['strings'] - len(b'_unterminated'))))
out = expect('string-unterminated-at-end', open_end, 'ok', 'find=_unterminated', 'find=_main', symbols='ok')
assert out['symbol'][0][6] == '!malformed' and out['find'][0][1] == 'not-found' and out['find'][1][1] == 'ok'
long_name, known = mf.image(strings_tail=b'L' * 4097 + b'\0')
out = expect('name-over-cap', patched(long_name, (known['at']['sym_off'], u32(known['strings'] - 4098))), 'ok', 'find=_main', symbols='ok')
assert out['symbol'][0][6] == '!limit' and out['find'][0][1] == 'ok'
out = expect('symbol-section-out-of-range', patched(good, (local + 5, b'\xff')), 'ok', 'at=%x' % (facts['base'] + 0x868), symbols='ok')
assert out['at'][0][1] == 'not-found' and 'outside=1' in out['counters'][0]
# One name declared many times: a lookup compares a bounded number, then refuses.
flood, known = mf.image(extra_symbols=[(2, 0x01, 0, 0, 0)] * 65)  # strx 2 is not a name start; fixed below
flood = patched(flood, *[(known['at']['sym_off'] + 16 * (known['symbols'] - 65 + i), u32(struct.unpack_from('<I', flood, known['at']['sym_off'] + 16 * (known['symbols'] - 66))[0])) for i in range(65)])
out = expect('same-name-flood', flood, 'ok', 'find=_printf', 'find=_main', symbols='ok')
assert out['find'][0][1] == 'limit' and out['find'][1][1] == 'ok'
out = expect('read-budget', good, 'ok', 'budget=994', symbols='limit', starts='limit')
out = expect('read-budget-header', good, 'limit', 'budget=512')

# Function starts.
starts = at['starts_off']
def with_starts(blob): return mf.image(starts=blob)[0]
expect('starts-uleb-11-bytes', with_starts(mf.uleb(0x800) + b'\x80' * 10 + b'\x01' + b'\0'), 'ok', starts='malformed', symbols='ok')
expect('starts-uleb-10-bytes-overflow', with_starts(mf.uleb(0x800) + b'\x80' * 9 + b'\x02' + b'\0'), 'ok', starts='malformed')
expect('starts-address-overflow', with_starts(mf.uleb(0x800) + b'\xff' * 9 + b'\x01' + b'\0'), 'ok', starts='malformed')
expect('starts-truncated-uleb', with_starts(mf.uleb(0x800) + b'\x80\x80\x80'), 'ok', starts='malformed')
out = expect('starts-never-ends', with_starts(b'\x80' * 0x10000), 'ok', 'at=%x' % (facts['base'] + 0x868), starts='malformed', symbols='ok')
assert out['at'][0][1:] == ['ok', '_local', hex(facts['base'] + 0x860), str(0xa0)], out['at']  # sized by the section end instead
out = expect('starts-uleb-10-bytes', with_starts(mf.uleb(0x800) + b'\x81' + b'\x80' * 8 + b'\0' + b'\0'), 'ok', starts='ok')
assert out['starts'][0][1] == '2'
expect('starts-range-past-end', patched(good, (at['starts'] + 8, u32(len(good)) + u32(64))), 'ok', starts='malformed')
out = expect('starts-unterminated', with_starts(mf.uleb(0x800) + mf.uleb(8) * 3), 'ok', starts='ok')
assert out['starts'][0][1] == '4'

# --- a loaded shared-cache image -----------------------------------------------
extent, ranges, cache = mf.cache_image()
mf.sparse(w / 'cache.sparse', extent, ranges)
out = expect('cache-memory', w / 'cache.sparse', 'ok', 'layout=sparse', 'faults', *('find=' + name for name, _ in cache['symbols']),
             *('at=%x' % (address + 0x3f) for _, address in cache['symbols']), 'slide=%x' % (cache['text'] + 0x20000000), symbols='ok', starts='ok')
assert int(out['header'][0][1], 0) == mf.ARM64E and int(out['header'][0][3], 0) & mf.MH_DYLIB_IN_CACHE and out['uuid'][0][0] == cache['uuid']
assert [(row[0], row[1], int(row[2], 16)) for row in out['find']] == [(name, 'ok', address) for name, address in cache['symbols']]
assert [row[1:4] for row in out['at']][:2] == [['ok', name, hex(address)] for name, address in cache['symbols']][:2]
assert out['slide'][0][2] == '0x20000000' and out['dylib'][0][1] == '/usr/lib/system/libowned_c.dylib'
assert [s[1] for s in out['segment']] == ['__TEXT', '__DATA_CONST', '__AUTH_CONST', '__DATA_DIRTY', '__LINKEDIT']
far = [s for s in out['section'] if s[2] == '__auth_got'][0]
assert far[7:] == ['ok', str(0x18000000)], far
counters = dict(item.split('=') for item in out['counters'][0])
# 400 MiB of strings are declared; only the pages three names sit in were read.
assert counters['unmapped'] == '0' and int(counters['bytes']) < 16 * cache['mapped'] < MIB and cache['string_size'] == 400 * MIB, counters
mf.sparse(w / 'cache-no-linkedit.sparse', extent, ranges[:1])
expect('cache-linkedit-unreadable', w / 'cache-no-linkedit.sparse', 'ok', 'layout=sparse', symbols='io', starts='io', debug='io')
mf.sparse(w / 'cache-short-extent.sparse', 0x8000, ranges[:1])
expect('cache-linkedit-beyond-extent', w / 'cache-short-extent.sparse', 'ok', 'layout=sparse', symbols='unavailable', starts='unavailable')
mf.sparse(w / 'fat-in-memory.sparse', 0x10000, [(0, mf.fat([(mf.ARM64, 0, good)]))])
expect('fat-in-memory', w / 'fat-in-memory.sparse', 'unsupported', 'layout=sparse')
mf.sparse(w / 'memory-truncated-commands.sparse', 0x100, [(0, good[:0x100])])
expect('memory-truncated-commands', w / 'memory-truncated-commands.sparse', 'unavailable', 'layout=sparse')

# --- files past 4 GiB (sparse on disk) -------------------------------------------
# Tables at the end: symoff and stroff are 32-bit fields just under 4 GiB, and
# the string table crosses it, so every sum must be done in 64 bits.
GIB4 = 1 << 32
tables_at_end = w / 'tables-at-4g'
gap = 0xfffff000 - 0x2000  # __LINKEDIT moves from 0x2000 to just under 4 GiB
size = GIB4 + 0x800
moved = bytearray(good[:0x2000])
for field in (at['symtab'] + 8, at['symtab'] + 16, at['starts'] + 8, at['signature'] + 8):
    moved[field:field + 4] = u32(struct.unpack_from('<I', good, field)[0] + gap)
str_off = at['str_off'] + gap
moved[at['linkedit'] + 32:at['linkedit'] + 56] = u64(0x2000) + u64(0x2000 + gap) + u64(size - (0x2000 + gap))
moved[at['symtab'] + 20:at['symtab'] + 24] = u32(size - str_off)
assert str_off < GIB4 < str_off + (size - str_off)
with open(tables_at_end, 'wb') as file:
    file.write(moved); file.seek(0x2000 + gap); file.write(good[0x2000:]); file.truncate(size)
out = expect('tables-at-4g', tables_at_end, 'ok', 'find=_main', 'at=%x' % (facts['base'] + 0x861), symbols='ok', starts='ok', debug='ok')
assert out['find'][0][1:3] == ['ok', hex(facts['entry'])] and out['at'][0][1:3] == ['ok', '_local'] and os.stat(tables_at_end).st_size > GIB4
assert os.stat(tables_at_end).st_blocks * 512 < 16 * MIB, 'the fixture must stay sparse'
# A universal file whose slice starts above 4 GiB (fat_arch_64).
slice_at_5g = w / 'slice-at-5g'
with open(slice_at_5g, 'wb') as file:
    file.write(struct.pack('>IIIIQQII', 0xcafebabf, 1, mf.ARM64, 0, 5 << 30, len(good), 12, 0)); file.seek(5 << 30); file.write(good)
out = expect('slice-at-5g', slice_at_5g, 'ok', 'find=_helper', 'memory', symbols='ok', starts='ok')
assert out['selected'][0] == [str(5 << 30), str(len(good))] and out['find'][0][1] == 'ok'
with open(slice_at_5g, 'r+b') as file: file.truncate((5 << 30) + 64)
expect('slice-at-5g-truncated', slice_at_5g, 'malformed')
# More symbols than the cap, all inside a (sparse) file: refused before any are read.
over = w / 'symbols-over-cap'
count = 2097152 + 1
with open(over, 'wb') as file:
    file.write(patched(good[:0x2000], (at['linkedit'] + 32, u64(64 * MIB) + u64(0x2000) + u64(48 * MIB)), (symtab + 8, u32(0x4000) + u32(count) + u32(40 * MIB) + u32(MIB)),
                       (at['dysymtab'] + 8, bytes(24)), (at['starts'] + 8, u32(0x3000) + u32(0))))
    file.truncate(0x2000 + 48 * MIB)
out = expect('symbols-over-cap', over, 'ok', symbols='limit', debug='limit')
assert int(dict(item.split('=') for item in out['counters'][0])['bytes']) < 8192
for path in (tables_at_end, slice_at_5g, over): path.unlink()

# --- linker-built images, checked against LLVM's readers when present -------------
target_flags = ['-O0', '-fno-sanitize=undefined', '-ffile-prefix-map=' + str(root) + '=.']
objdump, nm = shutil.which('llvm-objdump'), shutil.which('llvm-nm')
built = {}
for name, target, extra, source in (('exe-arm64-g', 'aarch64-macos', ['-g'], 'main.c'), ('exe-arm64', 'aarch64-macos', ['-g0'], 'main.c'),
                                    ('exe-x86_64-g', 'x86_64-macos', ['-g'], 'main.c'), ('dylib-arm64-g', 'aarch64-macos', ['-g', '-shared'], 'library.c'),
                                    ('dylib-x86_64', 'x86_64-macos', ['-g0', '-shared'], 'library.c')):
    path = w / name; built[name] = path
    command(['zig', 'cc', '-target', target, *target_flags, *extra, 'tests/fixtures/macho/' + source, '-o', str(path)], 'build-' + name)
    public = ['_main', '_macho_target', '_macho_counter'] if source == 'main.c' else ['_macho_exported', '_macho_other', '_macho_shared_counter']
    private = '_macho_local' if source == 'main.c' else '_macho_hidden'
    out = expect('linked-' + name, path, 'ok', 'memory', 'faults', *('find=' + n for n in public + [private]), symbols='ok', debug='ok')
    assert int(out['header'][0][0], 0) == (mf.ARM64 if 'arm64' in name else mf.X86_64) and int(out['header'][0][2]) == (mf.MH_DYLIB if 'dylib' in name else mf.MH_EXECUTE)
    assert re.fullmatch(r'[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}', out['uuid'][0][0]) and out['version'][0][0] == '1'
    assert any(row[1] == '/usr/lib/libSystem.B.dylib' for row in out['dylib']) and ('dylib' in name) == (out['dylib'][0][0] == '0')
    assert {s[1] for s in out['segment']} >= {'__TEXT', '__LINKEDIT'} and ('__TEXT', '__text') in {(s[1], s[2]) for s in out['section']}
    found = {row[0]: row[1:] for row in out['find']}
    assert all(found[n][0] == 'ok' and int(found[n][1], 16) for n in public + [private]), found
    if 'dylib' not in name: assert out['entry'][0] == ['main', found['_main'][1]], (out['entry'], found)
    # -g leaves a debug map naming the object file each function came from.
    functions = {row[0] for row in out.get('function', [])}
    if name.endswith('-g'): assert int(out['debug'][0][1]) == 1 and out['object'][0][4].endswith(source) and {n for n in public if 'counter' not in n} | {private} <= functions, out['debug']
    else: assert out['debug'][0][1:] == ['0', '0']
    if objdump and nm:
        headers = command([objdump, '--macho', '--private-headers', str(path)], 'oracle-headers-' + name)
        assert re.search(r'\buuid ([0-9A-F-]{36})', headers)[1] == out['uuid'][0][0]
        expected = re.findall(r'segname (\S+)\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize (0x[0-9a-f]+)\n\s+fileoff (\d+)\n\s+filesize (\d+)', headers)
        assert [(s[1], int(s[2], 16), int(s[3], 16), s[4], s[5]) for s in out['segment']] == [(n, int(v, 16), int(z, 16), o, f) for n, v, z, o, f in expected] and len(expected) >= 4
        listed = command([nm, str(path)], 'oracle-symbols-' + name)
        defined = dict((symbol, int(address, 16)) for address, kind, symbol in re.findall(r'^([0-9a-f]{16}) (\w) (\S+)$', listed, re.M))
        assert all(int(found[n][1], 16) == defined[n] for n in public + [private]) and len(defined) >= 5, (found, defined)
        assert int(out['symbols'][0][1]) == len(command([nm, '-a', str(path)], 'oracle-all-symbols-' + name).splitlines())
    else: record('oracle-' + name, time.monotonic(), status='skip', reason='llvm-objdump and llvm-nm not found')
# Two real slices in one universal file.
both = mf.fat([(mf.X86_64, 3, built['exe-x86_64-g'].read_bytes()), (mf.ARM64, 0, built['exe-arm64-g'].read_bytes())], align=14)
x = expect('linked-universal-x86_64', both, 'ok', 'arch=x86_64', 'find=_main', 'memory', symbols='ok')
y = expect('linked-universal-arm64', both, 'ok', 'arch=arm64', 'find=_main', 'memory', symbols='ok')
assert x['uuid'] != y['uuid'] and x['find'][0][1] == y['find'][0][1] == 'ok' and int(x['header'][0][0], 0) == mf.X86_64 and int(y['header'][0][0], 0) == mf.ARM64

if a.fuzz:
    # Work bounds that need large inputs. Every symbol names the same 4095-byte
    # string: the name index stops at its work cap instead of copying it 70,000 times over.
    heavy = w / 'name-work-cap'; count = 70000
    blob = bytearray(patched(good[:0x2000], (at['linkedit'] + 32, u64(8 * MIB) + u64(0x2000) + u64(4 * MIB)), (symtab + 8, u32(0x2000) + u32(count) + u32(0x2000 + 16 * count) + u32(4096)),
                             (at['dysymtab'] + 8, bytes(24)), (at['starts'] + 8, u32(0x2000) + u32(0))))
    blob += mf.nlist(0, 0x0f, 1, 0, facts['base'] + 0x800) * count + b'N' * 4095 + b'\0'
    blob += bytes(0x2000 + 4 * MIB - len(blob)); heavy.write_bytes(blob)
    out = expect('name-work-cap', heavy, 'ok', 'find=_main', 'rows=1', symbols='ok')
    assert out['find'][0][1] == 'limit', out['find']
    # More function starts than the cap: one-byte deltas, two million and one of them.
    crowd = w / 'starts-over-cap'; count = 2097152 + 1
    blob = bytearray(patched(good[:0x2000], (at['linkedit'] + 32, u64(8 * MIB) + u64(0x2000) + u64(4 * MIB)), (symtab + 8, u32(0x2000) + u32(0) + u32(0x2000) + u32(0)),
                             (at['dysymtab'] + 8, bytes(24)), (at['starts'] + 8, u32(0x2000) + u32(count))))
    blob += b'\x01' * count; blob += bytes(0x2000 + 4 * MIB - len(blob)); crowd.write_bytes(blob)
    expect('starts-over-cap', crowd, 'ok', 'rows=1', starts='limit')
    blob[at['starts'] + 12:at['starts'] + 16] = u32(count - 1); crowd.write_bytes(blob)
    out = expect('starts-at-cap', crowd, 'ok', 'rows=1', starts='ok')
    assert out['starts'][0][1] == str(count - 1)
    for path in (heavy, crowd): path.unlink()
    seeds = w / 'seeds'; seeds.mkdir()
    (seeds / 'file').write_bytes(b'\0' + good)
    (seeds / 'file-arm64e').write_bytes(b'\0' + arm64e)
    (seeds / 'fat').write_bytes(b'\4' + mf.fat([(mf.X86_64, 3, intel), (mf.ARM64, 0, good)], align=4))
    (seeds / 'fat64').write_bytes(b'\2' + mf.fat([(mf.X86_64, 3, intel), (mf.ARM64, 0, good)], wide=True, align=4))
    (seeds / 'memory').write_bytes(b'\1' + good[:0x2000] + bytes(0x1000) + good[0x2000:])
    (seeds / 'linked').write_bytes(b'\0' + built['dylib-arm64-g'].read_bytes()[:65535])
    fuzz = w / 'fuzz'
    command(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-g', '-O1', '-fsanitize=fuzzer,address,undefined', '-fno-sanitize-recover=all',
             'tests/macho-fuzz.c', 'src/binary/macho.c', '-o', str(fuzz)], 'compile-fuzz')
    command([str(fuzz), str(seeds), '-max_total_time=30', '-timeout=3', '-rss_limit_mb=768', '-max_len=65536', '-artifact_prefix=' + str(w) + '/'], 'fuzz', timeout=60)
assert orphans.reap(), 'a child process is still running'
assert all(row['status'] in ('pass', 'skip') for row in results)
print(json.dumps(dict(status='pass', checks=len(results), skipped=[row['name'] for row in results if row['status'] == 'skip'], elapsed_seconds=round(time.monotonic() - started, 3))))
