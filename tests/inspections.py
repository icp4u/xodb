#!/usr/bin/env python3
"""Retained inspection identity, ownership, cancellation and bounds over real MCP."""
import json
import os
import sys
import time
from client import Client


def error(response, message):
    assert response['result']['isError'], response
    assert response['result']['content'][0]['text'] == message, response


def pipeline(client, requests):
    # One server pump observes the whole batch before session.poll can advance
    # a job. This makes resume/cancel-before-capture deterministic.
    ids = []
    lines = []
    for name, args in requests:
        client.id += 1
        ids.append(client.id)
        lines.append(json.dumps({'jsonrpc': '2.0', 'id': client.id, 'method': 'tools/call',
                                 'params': {'name': name, 'arguments': args}}))
    client.p.stdin.write(('\n'.join(lines) + '\n').encode())
    client.p.stdin.flush()
    result = []
    for expected in ids:
        while True:
            value = json.loads(client.p.stdout.readline())
            if 'id' in value:
                break
        assert value['id'] == expected, value
        result.append(value)
    return result


def await_job(client, ident):
    deadline = time.monotonic() + 5
    while True:
        job = client.inspect('get_inspection', id=ident)
        if job['state'] not in ('pending', 'running'):
            return job
        assert time.monotonic() < deadline, job
        time.sleep(.002)


def run():
    client = Client('control', executable='./zig-out/bin/xodb-fixture')
    try:
        session = client.stopped()
        tid = session['threads'][0]['tid']
        registers = client.inspect('get_registers', tid=tid)['registers']
        pc = registers['rip']
        started = time.monotonic()
        job = client.inspect('start_inspection', generation=session['generation'], tid=tid,
                             locals=True, expressions=['$rip', 'missing_variable'],
                             memory=[{'address': pc, 'length': 32},
                                     {'address': '0x1', 'length': 32},
                                     {'address': '0xfffffffffffff000', 'length': 16}])
        done = await_job(client, job['id'])
        elapsed = time.monotonic() - started
        assert done['state'] == 'completed', done
        assert done['completed_items'] == 8, done
        items = []
        for index in range(0, 8, 2):
            items.extend(client.inspect('get_inspection', id=job['id'], start=index, limit=2)['items'])
        assert items[0]['data']['values'] == registers, items[0]
        assert int(items[3]['data']['value']['bits'], 16) == int(pc, 16), items[3]
        assert items[4]['data'] is None and items[4]['diagnostic'], items[4]
        expected = client.inspect('read_memory', address=pc, length=32)['hex']
        assert items[5]['data']['hex'] == expected, items[5]
        assert items[5]['data']['readable'] == 32
        assert items[6]['data']['readable'] == items[7]['data']['readable'] == 0
        assert items[6]['data']['hex'] == '?' * 64
        assert done['identity']['generation'] == session['generation']
        assert done['stopped_threads'] == [{'id': session['threads'][0]['id'], 'tid': tid}]
        error(client.tool('start_inspection', generation=session['generation'] + 1, tid=tid), 'StaleSnapshot')
        for options in ({'frame': 64}, {'expressions': ['x'] * 17}, {'memory': [{'address': pc, 'length': 4097}]},
                        {'memory': [{'address': '0xffffffffffffffff', 'length': 1}]}):
            result = client.tool('start_inspection', generation=session['generation'], tid=tid, **options)
            assert result.get('error', {}).get('code') == -32602, result

        # Both cancellation and release are available to read-only observers;
        # they act on retained host evidence, never target execution.
        next_id = job['id'] + 1
        results = pipeline(client, [('start_inspection', {'generation': session['generation'], 'tid': tid}),
                                    ('cancel_inspection', {'id': next_id})])
        assert results[1]['result']['structuredContent']['state'] == 'cancelled', results
        assert client.inspect('get_inspection', id=next_id)['completed_items'] == 0
        client.inspect('release_inspection', id=next_id)
        error(client.tool('get_inspection', id=next_id), 'UnknownInspection')

        next_id += 1
        results = pipeline(client, [('start_inspection', {'generation': session['generation'], 'tid': tid}),
                                    ('continue', {'generation': session['generation']})])
        assert not results[1]['result']['isError'], results
        changed = await_job(client, next_id)
        assert changed['state'] == 'failed' and changed['diagnostic'] == 'InspectionContextChanged', changed
        for index in range(0, 8, 2):
            assert client.inspect('get_inspection', id=job['id'], start=index, limit=2)['items'] == items[index:index + 2]
        assert client.inspect('get_inspection', id=job['id'])['identity'] == done['identity']
        client.inspect('release_inspection', id=job['id'])
        print(json.dumps({'runtime_agent': client.runtime_agent, 'items': len(items),
                          'capture_ms': round(elapsed * 1000, 2), 'retained_json_bytes': len(json.dumps(items)),
                          'peak_job_bytes': done['peak_bytes'], 'checks': 'coherence, resume, immutable evidence, inaccessible memory, bounds, cancel, release'}))
    finally:
        client.close()


if __name__ == '__main__':
    run()
