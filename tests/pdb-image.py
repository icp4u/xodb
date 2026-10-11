#!/usr/bin/env python3
"""Fast minimal PDB component lane; --fuzz adds periodic ASan/UBSan coverage."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time
from helpers import orphans

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--fuzz', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
orphans.adopt()
w = a.work.resolve()
w.mkdir(parents=True)
started = time.monotonic()
checks = []


def run(argv, name, expect=0, timeout=30):
    begin = time.monotonic()
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    (w / (name + '.log')).write_text(result.stdout + result.stderr)
    checks.append(dict(name=name, status='passed' if result.returncode == expect else 'failed',
                       exit_code=result.returncode, expected=expect, seconds=time.monotonic() - begin))
    (w / 'results.json').write_text(json.dumps(dict(checks=checks, seconds=time.monotonic() - started), indent=2) + '\n')
    assert result.returncode == expect, (name, result.returncode, result.stdout, result.stderr)
    return result.stdout


check = w / 'check'
run(['cc', '-std=c11', '-O2', '-g', '-DNDEBUG', '-Wall', '-Wextra', '-Werror', '-Wswitch-enum',
     'tests/pdb-image.c', 'src/binary/pdb.c', 'src/binary/pe.c', '-o', str(check)], 'build-check')


def fixture(opt):
    stem = w / ('fixture-' + opt)
    run(['clang', '--target=x86_64-pc-windows-msvc', '-' + opt, '-g', '-gcodeview',
         '-c', 'tests/fixtures/pe/pdb-lines.c', '-o', str(stem) + '.obj'], 'compile-' + opt)
    run(['lld-link', '/dll', '/noentry', '/debug', '/pdb:' + str(stem) + '.pdb',
         '/pdbaltpath:' + stem.name + '.pdb', '/out:' + str(stem) + '.dll', str(stem) + '.obj'], 'link-' + opt)
    actual = run([str(check), str(stem) + '.dll', str(stem) + '.pdb'], 'read-' + opt)
    run([str(check), str(stem) + '.dll', str(stem) + '.pdb', 'budget'], 'peak-budget-' + opt)
    oracle = run(['llvm-pdbutil', 'dump', '-summary', '-publics', '-l', '-section-headers', str(stem) + '.pdb'], 'llvm-' + opt)
    sections = {int(i): int(rva, 16) for i, rva in re.findall(
        r'SECTION HEADER #(\d+)\s+[^\n]+\n\s+[0-9a-fA-F]+ virtual size\s+([0-9a-fA-F]+) virtual address', oracle)}
    assert sections, oracle
    public = sorted((sections[int(segment)] + int(offset), name) for name, segment, offset in re.findall(
        r'S_PUB32[^\n]*`([^`]+)`\s+flags = [^\n]+, addr = (\d+):(\d+)', oracle))
    found = sorted((int(fields[1]), fields[3]) for line in actual.splitlines()
                   if (fields := line.split('\t'))[0] == 'public')
    assert found == public and len(found) == 3, (found, public)
    assert any(name == 'pdb_twice' for _, name in found)
    expected = []
    filename = None
    base = end = None
    group = []

    def flush():
        if not group:
            return
        for i, (line, offset) in enumerate(group):
            expected.append((base + offset, base + (group[i + 1][1] if i + 1 < len(group) else end), line, filename))

    for line in oracle.split('Public Symbols')[0].splitlines():
        name = re.match(r'(.+) \((?:MD5|SHA1|SHA256):', line)
        if name:
            flush()
            group = []
            filename = name[1]
        contribution = re.match(r'\s+([0-9A-Fa-f]{4}):([0-9A-Fa-f]{8})-([0-9A-Fa-f]{8}),', line)
        if contribution:
            flush()
            group = []
            base = sections[int(contribution[1], 16)]
            end = int(contribution[3], 16)
        elif base is not None and re.match(r'\s+\d+ [0-9A-Fa-f]{8}', line):
            group.extend((int(number), int(offset, 16)) for number, offset in re.findall(r'(\d+) ([0-9A-Fa-f]{8})', line))
    flush()
    found_lines = [(int(f[1]), int(f[2]), int(f[3]), f[5]) for line in actual.splitlines()
                   if (f := line.split('\t'))[0] == 'line']
    assert found_lines == expected and len(expected) >= 6, (found_lines, expected)
    return stem


for opt in ('O0', 'O2'):
    stem = fixture(opt)
run([str(check), str(stem) + '.dll', str(stem) + '.pdb', 'wrong-result'], 'planted-wrong-result', expect=-6)
original = Path(str(stem) + '.pdb').read_bytes()
u32 = lambda n: struct.pack('<I', n)
u16 = lambda n: struct.pack('<H', n)
get32 = lambda b, at: struct.unpack_from('<I', b, at)[0]


class Msf:
    """Mutation locator only. The semantic oracle above is llvm-pdbutil."""
    def __init__(self, data):
        self.data = bytearray(data)
        self.page = get32(data, 32)
        directory_size = get32(data, 44)
        directory_map = get32(data, 52) * self.page
        self.directory_pages = [get32(data, directory_map + i * 4) for i in range((directory_size + self.page - 1) // self.page)]
        directory = b''.join(data[p * self.page:(p + 1) * self.page] for p in self.directory_pages)[:directory_size]
        count = get32(directory, 0)
        at = 4 + count * 4
        self.streams = []
        for i in range(count):
            size = get32(directory, 4 + i * 4)
            pages = 0 if size == 0xffffffff else (size + self.page - 1) // self.page
            blocks = [get32(directory, at + j * 4) for j in range(pages)]
            self.streams.append((size, blocks, at))
            at += pages * 4

    def physical(self, stream, offset):
        return self.streams[stream][1][offset // self.page] * self.page + offset % self.page

    def read(self, stream):
        size, blocks, _ = self.streams[stream]
        return b''.join(self.data[p * self.page:(p + 1) * self.page] for p in blocks)[:size]

    def put(self, stream, offset, data):
        for i, byte in enumerate(data):
            self.data[self.physical(stream, offset + i)] = byte


model = Msf(original)
dbi = model.read(3)
public_stream = struct.unpack_from('<H', dbi, 20)[0]
public_map = struct.unpack_from('<H', dbi, 16)[0]
public_addresses = 28 + get32(model.read(public_map), 0)
module_stream = struct.unpack_from('<H', dbi, 64 + 34)[0]
c13 = get32(dbi, 64 + 36)
optional = 64 + sum(get32(dbi, at) for at in (24, 28, 32, 36, 40, 52))
section_stream = struct.unpack_from('<H', dbi, optional + 10)[0]
module = model.read(module_stream)
at = c13
line_sections = []
while at < c13 + get32(dbi, 64 + 44):
    kind, size = struct.unpack_from('<II', module, at)
    if kind == 0xf2:
        line_sections.append(at + 8)
    at += 8 + ((size + 3) & ~3)
assert len(line_sections) == 2
corpus = w / 'corpus'
corpus.mkdir()
(corpus / 'compiler.pdb').write_bytes(original)


def mutation(name, stream, at, data, status=2):
    candidate = Msf(original)
    if stream is None:
        candidate.data[at:at + len(data)] = data
    else:
        candidate.put(stream, at, data)
    path = corpus / name
    path.write_bytes(candidate.data)
    run([str(check), str(stem) + '.dll', str(path), 'status=' + str(status)], name)


mutation('magic', None, 0, b'!x', 1)
mutation('block-size', None, 32, u32(1), 3)
mutation('file-size', None, 40, u32(0xffffffff))
mutation('directory-map-range', None, 52, u32(0xffffffff))
mutation('reserved-directory-page', None, get32(original, 52) * model.page, u32(1))
mutation('directory-budget', None, 44, u32(0xffffffff), 5)
mutation('version', 1, 0, u32(0), 3)
mutation('guid', 1, 12, b'bad-identity!!!!', 4)
mutation('age', 1, 8, u32(2), 4)
mutation('dbi-age', 3, 8, u32(2), 4)
mutation('dbi-machine', 3, 58, u16(0x14c), 3)
mutation('dbi-size', 3, 24, u32(0x7fffffff))
mutation('omap-refusal', 3, optional + 6, u16(4), 3)
mutation('section-mismatch', section_stream, 12, u32(0x9000), 4)
mutation('public-map-interior', public_map, public_addresses, u32(1))
mutation('public-map-range', public_map, public_addresses, u32(0xffffffff))
mutation('public-record-size', public_stream, 0, u16(0))
mutation('public-section', public_stream, 12, u16(97))
mutation('public-offset', public_stream, 8, u32(0xffffffff))
record_size = struct.unpack_from('<H', model.read(public_stream))[0] + 2
mutation('public-no-terminator', public_stream, 14, b'A' * (record_size - 14))
mutation('c11-refusal', 3, 64 + 40, u32(4), 3)
mutation('c13-range', 3, 64 + 44, u32(0x7fffffff))
mutation('line-range', module_stream, line_sections[0] + 8, u32(0xffffffff))
mutation('line-checksum-interior', module_stream, line_sections[0] + 12, u32(1))
mutation('line-count-overflow', module_stream, line_sections[0] + 16, u32(0xffffffff))
mutation('line-offset', module_stream, line_sections[0] + 24, u32(0xffffffff))

# Incremental linking can leave unreferenced public records. They must not
# appear merely because their S_PUB32 bytes remain in the symbol stream.
stale = Msf(original)
stale.put(public_map, 4, u32(8))
directory_offset = 4 + public_map * 4
physical = stale.directory_pages[directory_offset // stale.page] * stale.page + directory_offset % stale.page
stale.data[physical:physical + 4] = u32(stale.streams[public_map][0] - 4)
path = corpus / 'unreferenced-public'
path.write_bytes(stale.data)
actual = run([str(check), str(stem) + '.dll', str(path)], 'unreferenced-public')
assert 'pdb_value' not in actual and 'pdb_twice' in actual, actual

# A missing/hidden source row must make a gap, not extend its predecessor.
hidden = Msf(original)
hidden.put(module_stream, line_sections[0] + 24 + 8 + 4, u32(0xfeefee))
path = corpus / 'hidden-row'
path.write_bytes(hidden.data)
actual = run([str(check), str(stem) + '.dll', str(path)], 'hidden-row')
rows = [tuple(map(int, line.split('\t')[1:4])) for line in actual.splitlines() if line.startswith('line\t')]
assert rows[0][1] < rows[1][0] and all(line != 4 for _, _, line in rows), rows

if a.fuzz:
    # Periodic cap evidence: ordinary aliases, then a real allocation-bound
    # refusal. Rebuild the MSF pages rather than only planting an oversized
    # count. CPU and RSS describe the parser child, not the Python generator.
    def large_publics(count):
        streams = [model.read(i) if size != 0xffffffff else None
                   for i, (size, _, _) in enumerate(model.streams)]
        symbols = bytearray(streams[public_stream])
        address_map = [24]  # compiler's pdb_twice, at the start of .text
        for i in range(count - 3):
            address_map.append(len(symbols))
            symbols += struct.pack('<HHIIH', 30, 0x110e, 2, 0, 1) + ('a%08x' % i).encode() + b'\0' * 9
        address_map += [0, 48]  # compiler's outer function and data public
        streams[public_stream] = symbols
        streams[public_map] = struct.pack('<7I', 0, count * 4, 0, 0, 0, 0, 0) + struct.pack('<' + 'I' * count, *address_map)
        block_size = 4096
        blocks = [bytearray(block_size) for _ in range(4)]

        def block(data):
            while len(blocks) % block_size in (1, 2):
                blocks.append(bytearray(block_size))
            index = len(blocks)
            blocks.append(data + b'\0' * (block_size - len(data)))
            return index

        directory = bytearray(u32(len(streams)))
        directory += b''.join(u32(0xffffffff if s is None else len(s)) for s in streams)
        for data in streams:
            if data is not None:
                for offset in range(0, len(data), block_size):
                    directory += u32(block(data[offset:offset + block_size]))
        directory_pages = [block(directory[i:i + block_size]) for i in range(0, len(directory), block_size)]
        blocks[3][:len(directory_pages) * 4] = struct.pack('<' + 'I' * len(directory_pages), *directory_pages)
        blocks[0][:56] = original[:32] + struct.pack('<6I', block_size, 1, len(blocks), len(directory), 0, 3)
        return b''.join(blocks)

    limits = w / 'limits'
    limits.mkdir()
    costs = []
    for count, expected in ((131072, 'count=131072'), (1048576, 'status=5')):
        path = limits / ('publics-' + str(count) + '.pdb')
        path.write_bytes(large_publics(count))
        log = os.open(limits / (str(count) + '.log'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        argv = ['timeout', '30', str(check), str(stem) + '.dll', str(path), expected]
        begin = time.monotonic()
        pid = os.posix_spawn('/usr/bin/timeout', argv, os.environ,
                             file_actions=[(os.POSIX_SPAWN_DUP2, log, 1), (os.POSIX_SPAWN_DUP2, log, 2)])
        _, status, usage = os.wait4(pid, 0)
        os.close(log)
        samples = {phase: dict(cpu_seconds=float(cpu), rss_bytes=int(rss), peak_rss_bytes=int(peak))
                   for phase, cpu, rss, peak in re.findall(r'usage\t(\w+)\t([0-9.]+)\t(\d+)\t(\d+)',
                       (limits / (str(count) + '.log')).read_text())}
        result = dict(publics=count, status=os.waitstatus_to_exitcode(status), seconds=time.monotonic() - begin,
                      before=samples['before'], after=samples['after'],
                      spawn_cpu_seconds=usage.ru_utime + usage.ru_stime, spawn_peak_rss_bytes=usage.ru_maxrss * 1024,
                      source_bytes=path.stat().st_size, load=os.getloadavg(), cpus=len(os.sched_getaffinity(0)))
        costs.append(result)
        (limits / 'cost.json').write_text(json.dumps(costs, indent=2) + '\n')
        assert result['status'] == 0, result
    fuzz = w / 'fuzz'
    run(['clang', '-std=c11', '-O1', '-g', '-fsanitize=fuzzer,address,undefined', '-fno-omit-frame-pointer',
         'tests/pdb-fuzz.c', 'src/binary/pdb.c', 'src/binary/pe.c', '-o', str(fuzz)], 'build-fuzz')
    run([str(fuzz), '--pe=' + str(stem) + '.dll', str(corpus), '-max_total_time=30',
         '-timeout=3', '-rss_limit_mb=512', '-max_len=131072', '-artifact_prefix=' + str(w) + '/'], 'fuzz', timeout=60)
print('PDB: compiler publics/lines at O0/O2, identity/placement, source ownership, malformed MSF/C13 and hidden-line gaps passed')
