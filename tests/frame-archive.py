#!/usr/bin/env python3
"""Owned archive attachments: bounded status, optional failures and lossless saves."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import time
import traceback
import zlib
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--capture', type=Path, help='reuse an owned native capture')
p.add_argument('--case', choices=['status', 'optional', 'retention', 'metadata'])
args = p.parse_args()
work = root / '.work' / ('frame-archive-' + str(time.time_ns()))
work.mkdir(parents=True)


def wait(c, tool='get_archive_status'):
    until = time.monotonic() + 30
    while True:
        s = c.inspect(tool)
        if (s['job']['done'] if tool == 'get_archive_status' else s['status'] != 'pending'):
            return s
        assert time.monotonic() < until, s
        time.sleep(.005)


def frames(c):
    return wait(c, 'get_frame_status')


def save(c, path):
    cap = c.inspect('get_profile')['capture']
    c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(path))
    s = wait(c)['job']
    assert s['error_name'] is None and s['publication']['state'] == 'published', s
    return s


def opened(path, other=None):
    c = Client('control', None, options=['--open-capture', str(path), *(['--open-frames', str(other)] if other else [])])
    return c


def sections(b):
    return [struct.unpack_from('<IIQII', b, 64 + i * 24) for i in range(struct.unpack_from('<I', b, 24)[0])]


def attach(b, payload):
    entries = [(tag, flags, b[off:off + length]) for tag, flags, off, length, _ in sections(b) if tag != 0x4d415246]
    entries.append((0x4d415246, 1, payload))
    header = bytearray(b[:64]); struct.pack_into('<H', header, 10, 7)
    struct.pack_into('<I', header, 24, len(entries))
    offset = 64 + 24 * len(entries)
    table = bytearray(); data = bytearray()
    for tag, flags, body in entries:
        table += struct.pack('<IIQII', tag, flags, offset, len(body), zlib.crc32(body))
        data += body; offset += len(body)
    struct.pack_into('<Q', header, 16, offset)
    struct.pack_into('<I', header, 56, zlib.crc32(header[:56]))
    return bytes(header + table + data)


def bundle(raw, metadata=None, copies=1):
    meta = json.dumps(metadata or {'algorithm': 'xlf-aggregate-v1'}, separators=(',', ':')).encode()
    record = struct.pack('<IIIIQ', 1, 1, len(meta), 0, len(raw)) + hashlib.sha256(raw).hexdigest().encode() + meta + raw
    body = record * copies
    return b'XODBFRAM' + struct.pack('<IIQ', 1, copies, len(body)) + hashlib.sha256(body).hexdigest().encode() + body


def native(c):
    cap = c.inspect('get_profile')['capture']; rows = []; start = 0
    while True:
        page = c.inspect('get_profile_samples', capture_id=cap['id'], revision=cap['revision'], start=start, limit=16)
        for row in page['samples']:
            row.pop('jit', None); rows.append(row)
        start += len(page['samples'])
        if start >= page['total']: return rows


# Reuse a repository-owned logical fixture; generated files remain under .work.
raw = (root / 'tests/logical-frames/regress/c05-weight-overflow.jsonl').read_bytes()
logical = work / 'input.jsonl'; logical.write_bytes(raw)
source = args.capture.resolve() if args.capture else work / 'native.xoc'
if not args.capture:
    c = Client('control', './zig-out/bin/xodb-profile-fixture', args=['2', 'threads'])
    try:
        bp = c.action('set_breakpoint', symbol='profile_ready')['id']
        c.action('continue'); c.stopped('breakpoint'); c.action('remove_breakpoint', id=bp)
        cap = c.action('start_profile', frequency_hz=199)['capture']
        c.action('continue'); time.sleep(.3)
        c.action('stop_profile', capture_id=cap['id'])
        save(c, source)
    finally: c.close()
original = source.read_bytes()
c = opened(source)
try:
    assert wait(c)['job']['error_name'] is None
    expected = native(c); assert expected
finally: c.close()
attached = work / 'attached.xoc'; attached.write_bytes(attach(original, bundle(raw, copies=2)))
results = []


def run(name, fn):
    if args.case and args.case != name: return
    try:
        fn(); result = {'case': name, 'status': 'pass'}
    except Exception as e:
        result = {'case': name, 'status': 'fail', 'reason': str(e)[:2000], 'traceback': traceback.format_exc()[-4000:]}
    results.append(result)
    print(json.dumps(result), flush=True)


def status_case():
    lines = raw.splitlines(keepends=True)
    # Bounded leading whitespace exercises the actual response ceiling.
    big = b' ' * (2 * 1024 * 1024) + raw
    path = work / 'large.xoc'; path.write_bytes(attach(original, bundle(big)))
    c = opened(path)
    try:
        status = wait(c)
        assert status['job']['error_name'] is None, status
        assert frames(c)['error_name'] is None, frames(c)
        status = c.inspect('get_archive_status')
        summary = status['frame_attachments']
        assert summary['source_count'] == 1 and summary['input_bytes'] == len(big), summary
        assert summary['sources'][0]['sha256'] == hashlib.sha256(big).hexdigest()
        assert 'frame_bundle' not in status['recorded_origin']
        assert status['recorded_origin']['frame_attachments']['bytes'] == len(bundle(big))
        assert len(json.dumps(status)) < 65536
        assert frames(c)['error_name'] is None, frames(c)
        assert native(c) == expected, 'native sample rows changed'
    finally: c.close()


def optional_case():
    payload = bundle(raw)
    variants = {'magic': (b'XODBFRAX' + payload[8:], 'FrameBundleInvalid'),
                'version': (payload[:8] + struct.pack('<I', 2) + payload[12:], 'FrameVersionUnsupported'),
                'checksum': (payload[:-1] + bytes([payload[-1] ^ 1]), 'FrameChecksum')}
    bad = bytearray(payload); struct.pack_into('<I', bad, 92, 9)
    bad[24:88] = hashlib.sha256(bad[88:]).hexdigest().encode()
    variants['stability'] = bytes(bad), 'FrameBundleInvalid'
    for name, (body, reason) in variants.items():
        path = work / (name + '.xoc'); path.write_bytes(attach(original, body))
        c = opened(path)
        try:
            assert wait(c)['job']['error_name'] is None
            assert native(c) == expected
            status = frames(c)['archive_attachment']
            assert status['error_name'] == reason, status
            assert status['state'] == ('unsupported_version' if name == 'version' else 'unavailable'), status
            copied = work / (name + '-copy.xoc')
            result = save(c, copied)['frame_attachments']
            assert result == {'retained': None, 'added': 0, 'removed': 0, 'opaque_preserved': True}, result
            assert copied.read_bytes() == path.read_bytes()
        finally: c.close()
    # Optional FRAM stays optional even with an older minor version.
    minor = bytearray(attached.read_bytes()); struct.pack_into('<H', minor, 10, 6)
    struct.pack_into('<I', minor, 56, zlib.crc32(minor[:56]))
    path = work / 'minor6.xoc'; path.write_bytes(minor)
    c = opened(path)
    try:
        assert wait(c)['job']['error_name'] is None
        assert frames(c)['error_name'] is None and native(c) == expected
        upgraded = work / 'minor6-copy.xoc'
        save(c, upgraded)
        data = upgraded.read_bytes()
        assert struct.unpack_from('<H', data, 10)[0] == 7
        # Only the version and header CRC change; section evidence stays exact.
        assert data[:10] == minor[:10] and data[12:56] == minor[12:56] and data[60:] == minor[60:]
    finally: c.close()


def refused_save(c, path):
    cap = c.inspect('get_profile')['capture']
    r = c.tool('save_capture_archive', generation=c.session()['generation'], capture_id=cap['id'], revision=cap['revision'], path=str(path))
    assert r['result'].get('isError') and r['result']['content'][0]['text'] == 'ArchiveFrameAttachmentConflict', r
    assert not path.exists()


def retention_case():
    c = opened(attached, logical)
    try:
        assert wait(c)['job']['error_name'] is None
        status = frames(c)
        assert status['source_count'] == 1, status
        assert status['archive_attachment']['state'] == 'not_loaded', status
        assert status['status'] == 'conflict' and status['error_name'] == 'ArchiveFrameAttachmentConflict', status
        # An unrelated completion must not erase the persistent reason.
        c.inspect('import_logical_frames', path=str(logical), kind='logical')
        status = frames(c)
        assert status['status'] == 'conflict' and status['error_name'] == 'ArchiveFrameAttachmentConflict', status
        assert c.inspect('get_archive_status')['frame_attachments']['error_name'] == 'ArchiveFramesNotLoaded'
        refused_save(c, work / 'conflict.xoc')
    finally: c.close()
    c = opened(attached)
    try:
        wait(c); before = frames(c); assert before['source_count'] == 2
        copy = work / 'same.xoc'; report = save(c, copy)['frame_attachments']
        assert report['retained'] == 2 and report['added'] == 0 and report['removed'] == 0, report
        assert copy.read_bytes() == attached.read_bytes()
        c.inspect('import_logical_frames', path=str(logical), kind='logical'); frames(c)
        copy = work / 'added.xoc'; report = save(c, copy)['frame_attachments']
        assert report['retained'] == 2 and report['added'] == 1 and report['removed'] == 0, report
        one = work / 'one.xof'; one.write_bytes(bundle(raw))
        c.inspect('open_frame_bundle', path=str(one))
        status = frames(c)
        assert status['status'] == 'conflict' and status['error_name'] == 'ArchiveFrameAttachmentConflict', status
        refused_save(c, work / 'dropped-duplicate.xoc')
    finally: c.close()


def metadata_case():
    metadata = {'algorithm': 'xlf-aggregate-v1', 'selected_thread': 999999, 'future_extension': {'keep': ['yes', 7]}}
    path = work / 'future.xof'; path.write_bytes(bundle(raw, metadata))
    c = Client('control', None, options=['--open-frames', str(path)])
    try:
        s = frames(c); assert s['error_name'] is None, s
        source = s['sources'][0]; assert source['selection_stale'] and source['aggregate_stale']
        out = work / 'future-copy.xof'; c.inspect('save_frames', path=str(out)); frames(c)
        assert out.read_bytes() == path.read_bytes()
        c.inspect('select_frame_aggregate', source_id=source['source_id']); assert not frames(c)['sources'][0]['selection_stale']
        out = work / 'future-updated.xof'; c.inspect('save_frames', path=str(out)); frames(c)
        b = out.read_bytes(); length = struct.unpack_from('<I', b, 96)[0]
        after = json.loads(b[176:176 + length])
        assert after['future_extension'] == metadata['future_extension'] and after['selected_thread'] is None
        bad = work / 'bad.jsonl'; bad.write_text('{"type":"no_header"}\n')
        c.inspect('import_logical_frames', path=str(bad), kind='logical')
        s = frames(c); assert s['error_name'] and s['diagnostic']['line'] == 1 and s['diagnostic']['message'], s
    finally: c.close()
    # Replacement admission charges final input size; old retained memory still
    # counts while the replacement is built. Both sources exceed half the cap.
    lines = raw.splitlines(keepends=True)
    padding = (36 * 1024 * 1024 - len(raw)) // len(lines)
    big = work / 'replacement.jsonl'
    big.write_bytes(b''.join(b' ' * padding + line for line in lines))
    c = Client('control', None, options=['--open-frames', str(big)])
    try:
        before = frames(c); assert before['error_name'] is None, before
        c.inspect('import_logical_frames', path=str(big), kind='logical', replace=0)
        after = frames(c); assert after['error_name'] is None, after
        assert after['source_count'] == 1 and after['sources'][0]['source_id'] == before['sources'][0]['source_id']
    finally: c.close()


for name, fn in [('status', status_case), ('optional', optional_case), ('retention', retention_case), ('metadata', metadata_case)]: run(name, fn)
(work / 'results.json').write_text(json.dumps({'capture': str(source), 'results': results}, indent=2))
print('Frame archive evidence:', work)
raise SystemExit(any(r['status'] != 'pass' for r in results))
