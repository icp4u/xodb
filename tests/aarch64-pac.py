#!/usr/bin/env python3
"""Native aarch64 PAC unwind proof.

Build the profile fixture twice, once with frame pointers and once with
pac-ret. A stopped walk and a sampled walk of the signed binary must match
the frame-pointer binary: same frame names, and the same file offsets for
frames in shared objects. Fixture instruction bytes differ because paciasp
is present, so fixture file offsets are not required to match.
"""
import argparse
import ctypes
import os
import platform
import subprocess
import time
from collections import Counter
from pathlib import Path

from client import Client


def parse_addr(value):
    if isinstance(value, str):
        return int(value, 16)
    if isinstance(value, int):
        return value
    raise AssertionError(repr(value))


def require_canonical(frame):
    for key in ('pc', 'lookup_pc'):
        if frame.get(key) is None:
            continue
        value = parse_addr(frame[key])
        assert value >> 48 == 0, (key, hex(value), frame)


def frame_name(frame):
    for key in ('symbol', 'name'):
        if frame.get(key):
            return frame[key]
    return ''


def lookup_pc(frame):
    if frame.get('lookup_pc') is not None:
        return parse_addr(frame['lookup_pc'])
    return parse_addr(frame['pc'])


def classify(path, fixture):
    base = os.path.basename(path)
    if base == fixture:
        return 'fixture'
    if base.startswith(('libc.so', 'libc-', 'ld-linux', 'ld-musl')):
        return 'shared'
    return 'other'


def read_proc_maps(pid):
    rows = []
    for line in Path(f'/proc/{pid}/maps').read_text().splitlines():
        parts = line.split()
        start_s, end_s = parts[0].split('-')
        rows.append({
            'start': int(start_s, 16),
            'end': int(end_s, 16),
            'perms': parts[1],
            'offset': int(parts[2], 16),
            'path': parts[5] if len(parts) > 5 else '',
        })
    return rows


def capture_maps(client, capture):
    rows = []
    start = 0
    while True:
        page = client.inspect('get_profile_mappings', capture_id=capture['id'], revision=capture['revision'], start=start, limit=64)
        for row in page['mappings']:
            rows.append({
                'start': parse_addr(row['start']),
                'end': parse_addr(row['end']),
                'perms': 'x' if row['executable'] else '-',
                'offset': parse_addr(row['file_offset']),
                'path': row['path'],
                'id': row['id'],
            })
        if page['next'] is None:
            return rows
        start = page['next']


def mapping_for(rows, frame, pc):
    wanted = frame.get('mapping_id')
    if wanted is not None:
        for row in rows:
            if row.get('id') == wanted:
                return row
    for row in rows:
        if row['start'] <= pc < row['end'] and 'x' in row['perms']:
            return row
    return None


def identify(frames, rows, fixture):
    found = []
    for frame in frames:
        require_canonical(frame)
        pc = lookup_pc(frame)
        mapping = mapping_for(rows, frame, pc)
        assert mapping is not None, (hex(pc), frame_name(frame))
        assert mapping['start'] <= pc < mapping['end'], (hex(pc), mapping['path'])
        offset = mapping['offset'] + (pc - mapping['start'])
        kind = classify(mapping['path'], fixture)
        found.append({'name': frame_name(frame), 'kind': kind, 'offset': offset, 'base': os.path.basename(mapping['path'])})
    return found


def comparable(rows):
    """Names for every frame. File offsets only for shared objects."""
    return tuple((row['name'], row['kind'], row['offset'] if row['kind'] == 'shared' else None) for row in rows)


def require_stopped(rows, label):
    names = [row['name'] for row in rows]
    assert names, label
    assert names[0] == 'hot_mix', (label, names)
    assert names.count('recursive_mix') >= 4, (label, names)
    assert 'main' in names, (label, names)
    assert '_start' in names, (label, names)
    assert any('libc_start' in row['name'] and row['kind'] == 'shared' for row in rows), (label, names)


def require_sampled(rows, label):
    """Sampled walks stop at main.

    main keeps a local array larger than the captured stack. The capture bound
    is 8192 bytes, so the saved link register above main is outside the window.
    Both builds must still reach main through every recursive_mix frame.
    """
    names = [row['name'] for row in rows]
    assert names[0] == 'hot_mix', (label, names)
    assert names.count('recursive_mix') >= 4, (label, names)
    assert names[-1] == 'main', (label, names)


def caller_offsets(rows):
    return tuple((row['name'], row['offset']) for row in rows[1:])


def call_sites(path):
    """Map each call in the fixture to (function, call ordinal, callee).

    A caller frame's lookup PC is its return address minus 4: the bl itself.
    The signed build inserts paciasp/autiasp, so fixture PCs move, but each
    caller PC is still one particular call, the same in both builds.
    """
    delta = None
    for line in subprocess.check_output(['readelf', '-lW', str(path)], text=True).splitlines():
        parts = line.split()
        if parts[:1] == ['LOAD'] and 'E' in parts[6:-1]:
            delta = int(parts[2], 16) - int(parts[1], 16)
    assert delta is not None, path
    sites, function, ordinal = {}, None, 0
    for line in subprocess.check_output(['objdump', '-d', '--no-show-raw-insn', str(path)], text=True).splitlines():
        if line.endswith('>:'):
            function, ordinal = line.split('<', 1)[1][:-2], 0
            continue
        parts = line.split('\t')
        if function is None or len(parts) < 2 or not parts[0].strip().endswith(':'):
            continue
        if parts[1].strip() not in ('bl', 'blr'):
            continue
        address = int(parts[0].strip()[:-1], 16)
        callee = parts[2].split('<', 1)[1].rstrip('>') if len(parts) > 2 and '<' in parts[2] else parts[1].strip()
        sites[address - delta] = (function, ordinal, callee)
        ordinal += 1
    return sites


def fixture_sites(rows, sites):
    """Every fixture caller frame is at a known call instruction."""
    found = []
    for row in rows[1:]:
        if row['kind'] != 'fixture':
            continue
        assert row['offset'] in sites, (row['name'], hex(row['offset']))
        site = sites[row['offset']]
        assert site[0] == row['name'], (row, site)
        found.append(site)
    return tuple(found)


def symbol_has_paciasp(path, symbol):
    """Startup objects can contain paciasp even when this build does not sign returns."""
    text = subprocess.check_output(['objdump', '-d', f'--disassemble={symbol}', str(path)], text=True, errors='replace')
    return 'paciasp' in text


def insn_mask(fixture):
    """NT_ARM_PAC_MASK from one stopped pac-ret process. The kernel writes the data mask, then the insn mask."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.ptrace.restype = ctypes.c_long
    libc.ptrace.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]

    class Iovec(ctypes.Structure):
        _fields_ = [('iov_base', ctypes.c_void_p), ('iov_len', ctypes.c_size_t)]

    pid = os.fork()
    if pid == 0:
        if libc.ptrace(0, 0, None, None) != 0:
            os._exit(127)
        os.execv(str(fixture), [str(fixture), '3'])
        os._exit(127)
    data = insn = None
    try:
        _, status = os.waitpid(pid, 0)
        assert os.WIFSTOPPED(status), status
        masks = (ctypes.c_uint64 * 2)()
        io = Iovec(ctypes.cast(masks, ctypes.c_void_p), ctypes.sizeof(masks))
        rc = libc.ptrace(0x4204, pid, ctypes.c_void_p(0x406), ctypes.byref(io))
        err = ctypes.get_errno()
        assert rc == 0, (rc, err)
        assert io.iov_len == ctypes.sizeof(masks), io.iov_len
        data, insn = int(masks[0]), int(masks[1])
    finally:
        libc.ptrace(17, pid, None, None)
        os.kill(pid, 9)
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    assert insn not in (None, 0), hex(data or 0)
    return data, insn


def stopped_walk(client, fixture_name):
    breakpoint_id = client.action('set_breakpoint', symbol='hot_mix')['id']
    client.action('continue')
    session = client.stopped('breakpoint', seconds=30)
    tid = next(thread['tid'] for thread in session['threads'] if thread.get('reason') == 'breakpoint')
    frames = client.inspect('get_stack', tid=tid)['frames']
    rows = identify(frames, read_proc_maps(session['pid']), fixture_name)
    return breakpoint_id, rows


def sampled_walk(client, fixture_name):
    capture = client.action('start_profile', frequency_hz=499, duration_ms=0, user_stack_bytes=8192, user_stack_budget_bytes=1048576)['capture']
    client.action('continue')
    deadline = time.monotonic() + 4
    current = capture
    while time.monotonic() < deadline:
        current = client.inspect('get_profile')['capture']
        if current['stored_samples'] >= 30:
            break
        time.sleep(0.2)
    current = client.action('stop_profile', capture_id=current['id'])['capture']
    assert current['stored_samples'] >= 30, current
    maps = capture_maps(client, current)
    hot = []
    seen = Counter()
    examples = []
    limit = min(current['stored_samples'], 48)
    for ordinal in range(limit):
        end = time.monotonic() + 60
        result = None
        while True:
            result = client.inspect('get_profile_stack', capture_id=current['id'], revision=current['revision'], sample=ordinal)
            if not result['pending']:
                break
            assert time.monotonic() < end, result
            time.sleep(0.05)
        assert result['job']['error_name'] is None, result
        derived = result['derived']
        assert derived is not None, result
        frames = derived.get('frames') or []
        leaf = frame_name(frames[0]) if frames else ''
        names = [frame_name(frame) for frame in frames[:8]]
        reason = derived.get('terminal_reason')
        detail = derived.get('detail') or ''
        seen[(leaf, reason, detail)] += 1
        if len(examples) < 4:
            examples.append((leaf, reason, detail, names))
        if detail == 'PointerAuthenticationUnsupported' or (leaf == 'hot_mix' and reason == 'unsupported_cfi'):
            raise AssertionError((leaf, reason, detail, names))
        if leaf != 'hot_mix' or not names or names[-1] != 'main':
            continue
        if reason != 'stack_window' or detail != 'ReturnAddressUnavailable':
            continue
        hot.append(identify(derived['frames'], maps, fixture_name))
    assert len(hot) >= 8, (len(hot), current['stored_samples'], seen.most_common(6), examples)
    counts = Counter(comparable(rows) for rows in hot)
    modal_key, modal_count = counts.most_common(1)[0]
    assert modal_count >= 8, (modal_count, len(hot))
    modal = next(rows for rows in hot if comparable(rows) == modal_key)
    return modal


def prove(xodb, fixture, label):
    os.environ['XODB_BIN'] = str(xodb)
    client = Client('control', str(fixture), args=('60',), reply_seconds=60)
    try:
        breakpoint_id, stopped = stopped_walk(client, fixture.name)
        print(label, 'stopped', [row['name'] for row in stopped], flush=True)
        # The breakpoint is still planted. Sampling must see the running loop.
        client.action('remove_breakpoint', id=breakpoint_id)
        sampled = sampled_walk(client, fixture.name)
    finally:
        client.close()
    require_stopped(stopped, label + ' breakpoint')
    require_sampled(sampled, label + ' sampled')
    # The sampled walk is the prefix of the stopped walk that fits in the window.
    assert [row['name'] for row in stopped[:len(sampled)]] == [row['name'] for row in sampled], label
    assert caller_offsets(stopped[:len(sampled)]) == caller_offsets(sampled), (label, caller_offsets(stopped[:len(sampled)]), caller_offsets(sampled))
    print(label, 'breakpoint', len(stopped), 'sampled', len(sampled), flush=True)
    return stopped, sampled


def main():
    if platform.system() != 'Linux' or platform.machine() != 'aarch64':
        raise SystemExit('this proof runs on Linux aarch64')
    parser = argparse.ArgumentParser()
    parser.add_argument('--xodb', required=True)
    args = parser.parse_args()
    xodb = Path(args.xodb).resolve()
    assert xodb.is_file(), xodb
    work = Path('proof-work')
    work.mkdir(exist_ok=True)
    source = 'tests/fixtures/profile.c'
    common = ['gcc', '-O2', '-g', '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls', '-pthread']
    fp = work / 'fixture-fp'
    pac = work / 'fixture-pac'
    # The toolchain may sign returns unless branch protection is turned off.
    # main and recursive_mix save a link register. hot_mix does not.
    subprocess.run([*common, '-mbranch-protection=none', source, '-o', str(fp)], check=True)
    subprocess.run([*common, '-mbranch-protection=pac-ret', source, '-o', str(pac)], check=True)
    for symbol in ('main', 'recursive_mix'):
        assert not symbol_has_paciasp(fp, symbol), (symbol, fp)
        assert symbol_has_paciasp(pac, symbol), (symbol, pac)
    data, insn = insn_mask(pac)
    print('pac mask data', hex(data), 'insn', hex(insn), flush=True)
    fp_stopped, fp_sampled = prove(xodb, fp, 'frame-pointer')
    pac_stopped, pac_sampled = prove(xodb, pac, 'pac-ret')
    assert comparable(fp_stopped) == comparable(pac_stopped), (comparable(fp_stopped), comparable(pac_stopped))
    assert comparable(fp_sampled) == comparable(pac_sampled), (comparable(fp_sampled), comparable(pac_sampled))
    # Fixture caller PCs: the same call site in both builds, not only the same name.
    fp_sites, pac_sites = call_sites(fp), call_sites(pac)
    for fp_rows, pac_rows, label in ((fp_stopped, pac_stopped, 'stopped'), (fp_sampled, pac_sampled, 'sampled')):
        left, right = fixture_sites(fp_rows, fp_sites), fixture_sites(pac_rows, pac_sites)
        assert left and left == right, (label, left, right)
        print(label, 'call sites', left, flush=True)
    print('PASS aarch64 pac walks match', flush=True)


if __name__ == '__main__':
    main()
