#!/usr/bin/env python3
"""Offline USB evidence from generated Linux usbmon pcapng bytes."""
import json, os, struct, tempfile
from pathlib import Path
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work_parent = Path(os.environ.get('XODB_TEST_TMPDIR', '.work'))
work_parent.mkdir(parents=True, exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='xodb-usb-', dir=work_parent))
private = b'xquinellax-device'

def block(kind, body):
    body += b'\0' * (-len(body) % 4)
    size = 12 + len(body)
    return struct.pack('<II', kind, size) + body + struct.pack('<I', size)

def option(code, value):
    return struct.pack('<HH', code, len(value)) + value + b'\0' * (-len(value) % 4)

def usb(urb, event, transfer, endpoint, data=b'', setup=None, status=0, requested=None):
    setup_bytes = setup or b'\0' * 8
    return struct.pack('<QBBBBHBBqiiII8siiII', urb, ord(event), transfer, endpoint, 5, 3,
                       0 if setup else 1, 0 if data else 1, 0, 0, status,
                       len(data) if requested is None else requested, len(data), setup_bytes,
                       0, 0, 0, 0) + data

def setup(request_type, request, value, index, length):
    return struct.pack('<BBHHH', request_type, request, value, index, length)

device = bytes([18, 1, 0, 2, 0, 0, 0, 64, 0x34, 0x12, 0x78, 0x56, 0, 1, 1, 2, 3, 1])
string = bytes([2 + len(private) * 2, 3]) + b''.join(bytes((c, 0)) for c in private)
configuration = bytes([9, 2, 25, 0, 1, 1, 0, 0x80, 50,
                       9, 4, 0, 0, 1, 8, 6, 0x50, 0,
                       7, 5, 0x81, 2, 0x00, 0x02, 0])
packets = [
    usb(1, 'S', 2, 0x80, setup=setup(0x80, 6, 0x0100, 0, len(device))),
    usb(1, 'C', 2, 0x80, data=device),
    usb(2, 'S', 2, 0x80, setup=setup(0x80, 6, 0x0301, 0x0409, len(string))),
    usb(2, 'C', 2, 0x80, data=string),
    usb(3, 'S', 2, 0x80, setup=setup(0x80, 6, 0x0200, 0, len(configuration))),
    usb(3, 'C', 2, 0x80, data=configuration),
    b'truncated',
]

capture = block(0x0a0d0d0a, struct.pack('<IHHq', 0x1a2b3c4d, 1, 0, -1))
capture += block(1, struct.pack('<HHI', 220, 0, 65535) + option(2, b'usbmon1') + option(9, b'\x09') + option(0, b''))
for index, packet in enumerate(packets):
    when = 1_700_000_000_000_000_000 + index * 100
    capture += block(6, struct.pack('<IIIII', 0, when >> 32, when & 0xffffffff, len(packet), len(packet)) + packet)
capture += block(5, struct.pack('<III', 0, 0, 0) + option(5, struct.pack('<Q', 2)) + option(7, struct.pack('<Q', 3)) + option(0, b''))
path = work / 'synthetic-usb.pcapng'
path.write_bytes(capture)

def close_clean(client):
    client.close()
    assert private not in client.p.stderr.read(), 'private USB descriptor entered diagnostics'

observer = Client('observe', None, options=['--open-pcap', str(path)])
try:
    # The staged HTTP/DNS protocol stream is always derived (empty here).
    streams = [row for row in observer.inspect('list_streams')['streams'] if row['kind'] != 'protocol']
    assert [row['kind'] for row in streams] == ['network', 'usb'], streams
    network, stream = streams
    assert network['interfaces'][0]['link'] == 'linux_usbmon_mmapped', network
    assert stream['stream_id'] == 4 and stream['records'] == len(packets), stream
    assert stream['devices'] == 1 and stream['loss']['malformed'] == 1, stream
    assert stream['loss']['pcap_ifdrop'] == 2 and stream['loss']['pcap_osdrop'] == 3, stream
    rows = observer.inspect('query_stream', stream_id=4, include_raw=True, limit=32)['records']
    assert rows[0]['peer_record'] == 1 and rows[1]['latency_ns'] == 100, rows[:2]
    assert rows[1]['descriptors'][0]['vendor_id'] == 0x1234, rows[1]
    assert rows[3]['descriptors'][0]['text'] == private.decode(), rows[3]
    assert bytes.fromhex(rows[3]['data_hex']) == string, rows[3]
    classes = [d['class'] for d in rows[5]['descriptors']]
    assert 'mass_storage_scsi_bulk_only' in classes, rows[5]
    assert rows[-1]['undecoded'] == 'truncated_header', rows[-1]
    devices = observer.inspect('query_stream', stream_id=4, view='devices')['devices']
    endpoints = observer.inspect('query_stream', stream_id=4, view='endpoints')['endpoints']
    assert devices[0]['vendor_id'] == 0x1234 and devices[0]['product_id'] == 0x5678, devices
    assert endpoints[0]['submits'] == 3 and endpoints[0]['completions'] == 3, endpoints
    join = observer.inspect('correlate', stream_id=4, record=1)
    assert join['basis'] == 'none' and join['device_fd'] is None, join
finally:
    close_clean(observer)

controller = Client('control', None, options=['--open-pcap', str(path)])
try:
    row = controller.inspect('query_stream', stream_id=4)['records'][3]
    assert row['descriptors'][0]['text'] is None and row['private_fields'], row
    denied = controller.tool('query_stream', stream_id=4, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
    denied = controller.tool('query_stream', stream_id=1, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
finally:
    close_clean(controller)

redacted = Client('observe', None, options=['--redact', '--open-pcap', str(path)])
try:
    result = redacted.inspect('query_stream', stream_id=4)
    assert private.decode() not in json.dumps(result), result
    assert result['records'][3]['descriptors'][0]['text'] is None, result['records'][3]
    denied = redacted.tool('query_stream', stream_id=4, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'RawPayloadRedacted', denied
finally:
    close_clean(redacted)

print('USB evidence: generated usbmon pcapng, URB pairing, descriptors, lifecycle, loss and privacy pass')
