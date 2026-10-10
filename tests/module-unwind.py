#!/usr/bin/env python3
"""Native CFI: exact compiler return PCs, sparse images and cache eviction.

Fast default: 12 stripped 64 MiB DSOs in one optimized, frame-pointer-less callchain.
Fast --companions: repeated wrong-CRC companion lookups share one decision.
Periodic --large-companions and --full-dwarf exercise companion I/O and summary budgets.
Periodic --eviction: 66 small DSOs in successive stacks, cold reload, changed-file refusal.
CPU and RSS are evidence, not performance gates. --wrong-result plants a bad PC.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--binary', type=Path, default=Path('zig-out/bin/xodb'))
p.add_argument('--baseline', action='store_true')
variants = p.add_mutually_exclusive_group()
variants.add_argument('--eviction', action='store_true')
variants.add_argument('--debug-frame', action='store_true', help='fast: preserve debug_frame without debug_info')
variants.add_argument('--budget', action='store_true', help='periodic: oversized CFI working set must refuse honestly')
variants.add_argument('--companions', action='store_true')
variants.add_argument('--large-companions', action='store_true')
variants.add_argument('--full-dwarf', action='store_true')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
started = time.monotonic()
(w/'library.c').write_text('''
#include <stdint.h>
typedef void (*walk_fn)(void **, unsigned, unsigned, uintptr_t *, void (*)(uintptr_t *, unsigned));
__attribute__((noinline)) void walk(void **functions, unsigned i, unsigned count, uintptr_t *pcs, void (*stop)(uintptr_t *, unsigned)) {
    pcs[i] = (uintptr_t)__builtin_return_address(0);
    if (i + 1 < count) ((walk_fn)functions[i+1])(functions, i+1, count, pcs, stop);
    else stop(pcs, count);
    __asm__ volatile("" ::: "memory");
}
''')
companions = a.companions or a.large_companions
flags = [*(['-g'] if a.full_dwarf or companions else []), '-O2', '-fomit-frame-pointer', '-fno-optimize-sibling-calls', '-fasynchronous-unwind-tables']
subprocess.run(['cc', *flags, '-shared', '-fPIC', '-Wl,--build-id=none', str(w/'library.c'), '-o', str(w/'library.so')], check=True, timeout=30)
if a.debug_frame:
    subprocess.run(['cc', '-O2', '-g', '-fomit-frame-pointer', '-fno-optimize-sibling-calls',
                    '-fno-asynchronous-unwind-tables', '-fno-unwind-tables', '-shared', '-fPIC',
                    '-Wl,--build-id=none', str(w/'library.c'), '-o', str(w/'library.so')], check=True, timeout=30)
    subprocess.run(['objcopy', '--remove-section=.debug_info', '--remove-section=.debug_abbrev',
                    '--remove-section=.debug_aranges', '--remove-section=.debug_line',
                    '--remove-section=.debug_str', '--remove-section=.debug_line_str',
                    '--remove-section=.debug_loclists', '--remove-section=.debug_rnglists',
                    str(w/'library.so')], check=True, timeout=30)
count = 66 if a.eviction else 4 if a.debug_frame or companions else 12
for i in range(count):
    path = w/f'lib{i:02}.so'
    shutil.copyfile(w/'library.so', path)
    if companions:
        debug = path.with_suffix('.debug')
        subprocess.run(['objcopy', '--only-keep-debug', str(path), str(debug)], check=True, timeout=30)
        subprocess.run(['objcopy', '--strip-debug', '--add-gnu-debuglink='+str(debug), str(path)], check=True, timeout=30)
        # Change the companion after storing its CRC in the mapped library.
        with debug.open('ab') as f:
            f.write(b'wrong-crc')
            if a.large_companions:
                f.truncate(60*1024*1024)
    if a.budget:
        # Preserve real compiler CFI and append zero terminators in a larger
        # non-loadable file extent. The loader still maps the original segments.
        data = bytearray(path.read_bytes())
        assert data[:6] == b'\x7fELF\x02\x01'
        shoff = struct.unpack_from('<Q', data, 40)[0]
        width, sections, names = struct.unpack_from('<HHH', data, 58)
        rows = [struct.unpack_from('<IIQQQQIIQQ', data, shoff+i*width) for i in range(sections)]
        strings = data[rows[names][4]:rows[names][4]+rows[names][5]]
        index = next(i for i,h in enumerate(rows) if strings[h[0]:].split(b'\0',1)[0] == b'.eh_frame')
        h = list(rows[index]); payload = data[h[4]:h[4]+h[5]]
        h[4] = (len(data)+4095)//4096*4096; h[5] = 24*1024*1024
        struct.pack_into('<IIQQQQIIQQ', data, shoff+index*width, *h)
        with path.open('wb') as f:
            f.write(data); f.seek(h[4]); f.write(payload); f.truncate(h[4]+h[5])
    elif not a.eviction and not a.debug_frame and not companions:
        with path.open('r+b') as f:
            f.truncate(64*1024*1024)
fixture = w/'fixture'
subprocess.run(['cc', *flags, '-g', '-Itests', 'tests/fixtures/module-unwind.c', '-ldl', '-o', str(fixture)], check=True, timeout=30)
os.environ['XODB_BIN'] = str(a.binary.resolve())


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(Path(f'/proc/{pid}/statm').read_text().split()[1])*os.sysconf('SC_PAGESIZE'))


def action(client, name, **arguments):
    deadline = time.monotonic()+15
    while True:
        reply = client.tool(name, generation=client.session()['generation'], **arguments)
        result = reply.get('result', {})
        if result.get('isError') and result.get('content') == [{'type':'text','text':'StaleSnapshot'}]:
            assert time.monotonic()<deadline, reply
            continue
        assert 'error' not in reply and not result.get('isError'), reply
        return result['structuredContent']


c = Client('control', str(fixture), args=[str(w), str(w/'oracle'), str(count), 'eviction' if a.eviction else 'chain'])
report = dict(status='running', baseline=a.baseline, eviction=a.eviction, budget=a.budget, debug_frame=a.debug_frame, companions=companions, full_dwarf=a.full_dwarf, stacks=[])
try:
    c.stopped()
    action(c, 'set_breakpoint', symbol='unwind_stop')
    c.continue_initial_stop()
    stopped = c.stopped('breakpoint')
    report['before'] = usage(c.p.pid)
    original_id = None
    for index in range(count+2 if a.eviction else 20 if companions else 3 if a.full_dwarf else 1):
        expected = [int(pc,16) for pc in (w/'oracle').read_text().splitlines()]
        if a.wrong_result:
            expected[0] += 1
        deadline = time.monotonic()+20
        while True:
            stack = c.inspect('get_stack', tid=stopped['pid'])
            frames = stack['frames']
            pending = any(f.get('diagnostic')=='DebugMetadataPending' for f in frames)
            if not pending:
                break
            assert time.monotonic()<deadline, stack
            time.sleep(.002)
        metadata = c.inspect('get_debug_metadata')['jobs']
        if a.budget:
            assert any(f.get('diagnostic')=='DebugMetadataBudgetLimit' for f in frames), stack
        elif a.eviction and index == count+1:
            assert any(f.get('diagnostic') in ('BinaryChangedDuringRead', 'DebugMetadataFileChanged') for f in frames), stack
        else:
            actual = [int(f['pc'],16) if isinstance(f['pc'],str) else f['pc'] for f in frames[2:2+len(expected)]]
            assert actual == expected, (index, actual, expected, stack)
            assert all(f.get('unwind_method') is not None for f in frames[:2+len(expected)]), stack
        if not a.baseline:
            assert len(metadata) <= 64, metadata
            assert sum(j['retained_unwind_bytes'] for j in metadata) <= 128*1024*1024, metadata
            if a.debug_frame:
                assert all(f['unwind_method']=='debug_frame' for f in frames[2:2+count]), stack
                assert not any(j['image'].endswith('lib00.so') for j in metadata), metadata
            if index == 0 and not a.budget and not a.debug_frame and not a.full_dwarf:
                assert any(j['image'].endswith('lib00.so') and j['state']=='ready' for j in metadata), metadata
                original_id = next(j['id'] for j in metadata if j['image'].endswith('lib00.so'))
            if a.eviction and index == count-1:
                assert not any(j['id']==original_id for j in metadata), metadata
            if a.eviction and index == count:
                assert any(j['image'].endswith('lib00.so') and j['id']!=original_id and j['state']=='ready' for j in metadata), metadata
                assert not any(j['image'].endswith('lib01.so') for j in metadata), metadata
                changed = w/'lib01.so'
                stat = changed.stat()
                os.utime(changed, ns=(stat.st_atime_ns, stat.st_mtime_ns+1_000_000_000))
        report['stacks'].append(dict(index=index, expected=expected, stack=stack, jobs=metadata, usage=usage(c.p.pid)))
        if a.eviction and index < count+1:
            action(c, 'continue')
            stopped = c.stopped('breakpoint')
    if a.full_dwarf:
        regions, cursor = [], None
        while True:
            page = c.inspect('list_modules', **({'cursor':cursor} if cursor else {}))
            regions.extend(page['regions'])
            cursor = page['next']
            if cursor is None:
                break
        deferred = sorted({r['path'] for r in regions if r['full_image_deferred']})
        assert len(deferred) > 1, deferred
        report['deferred'] = deferred
    report.update(after=usage(c.p.pid), load=os.getloadavg(), status='pass')
finally:
    if report['status'] != 'pass':
        report['status'] = 'fail'
    report.setdefault('after', usage(c.p.pid))
    report.setdefault('load', os.getloadavg())
    c.close()
    report['diagnostics'] = c.p.stderr.read().decode(errors='replace')
    report['elapsed_seconds'] = time.monotonic()-started
    try:
        if report['status'] == 'pass' and not a.baseline:
            assert 'BinarySnapshotLimit' not in report['diagnostics'], report['diagnostics']
            if companions:
                rejections = [line for line in report['diagnostics'].splitlines() if 'debug companion rejected' in line and str(w) in line]
                assert len(rejections) == count, rejections
                for i in range(count):
                    assert sum(f'lib{i:02}.debug' in line for line in rejections) == 1, rejections
            if a.full_dwarf:
                assert report['diagnostics'].count('module budget:') == 1, report['diagnostics']
    except BaseException:
        report['status'] = 'fail'
        raise
    finally:
        (w/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({key:report[key] for key in ('status','baseline','eviction','before','after','elapsed_seconds')}))
