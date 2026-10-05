#!/usr/bin/env python3
"""Bounded retained jobs survive real remap/exec/exit, with wire cost measurements."""
from datetime import datetime
import json
import os
from pathlib import Path
import select
import subprocess
import time
from client import Client


class CountedIO:
    def __init__(self, wrapped):
        self.wrapped = wrapped
        self.bytes = 0

    def write(self, data):
        n = self.wrapped.write(data)
        self.bytes += n
        return n

    def readline(self, *args):
        data = self.wrapped.readline(*args)
        self.bytes += len(data)
        return data

    def __getattr__(self, name):
        return getattr(self.wrapped, name)


class MeasuredClient(Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.p.stdin = CountedIO(self.p.stdin)
        self.p.stdout = CountedIO(self.p.stdout)

    def mark(self):
        return self.id, self.p.stdin.bytes, self.p.stdout.bytes, time.monotonic()

    def since(self, mark):
        return {'requests': self.id - mark[0], 'request_bytes': self.p.stdin.bytes - mark[1],
                'response_bytes': self.p.stdout.bytes - mark[2],
                'elapsed_ms': round((time.monotonic() - mark[3]) * 1000, 3)}


def exact_inspection_value(value):
    # Inspection exports machine words as exact hexadecimal strings while the
    # legacy expression endpoint keeps its older numeric representation.
    keys = {'pc', 'lookup_pc', 'cfa', 'address', 'data_address', 'bits'}
    if isinstance(value, dict):
        return {key: hex(item) if key in keys and isinstance(item, int) and not isinstance(item, bool)
                else exact_inspection_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [exact_inspection_value(item) for item in value]
    return value


def expect_error(response, name):
    assert response.get('result', {}).get('isError'), response
    assert response['result']['content'][0]['text'] == name, response


def batch(client, requests):
    """One pipe write: server handles this bounded batch before owner poll."""
    ids, lines = [], []
    for name, args in requests:
        client.id += 1
        ids.append(client.id)
        lines.append(json.dumps({'jsonrpc': '2.0', 'id': client.id, 'method': 'tools/call',
                                 'params': {'name': name, 'arguments': args}}))
    data = ('\n'.join(lines) + '\n').encode()
    assert len(data) < 4096, 'Batch must fit one atomic pipe write'
    assert client.p.stdin.write(data) == len(data)
    client.p.stdin.flush()
    replies = []
    for ident in ids:
        deadline = time.monotonic() + 5
        while True:
            assert select.select([client.p.stdout], [], [], max(0, deadline-time.monotonic()))[0], 'Batch response timeout'
            line = client.p.stdout.readline()
            assert line, 'MCP closed while reading batch'
            reply = json.loads(line)
            if 'id' in reply:
                assert reply['id'] == ident, reply
                replies.append(reply)
                break
    return replies


def await_job(client, ident):
    deadline = time.monotonic() + 10
    while True:
        job = client.inspect('get_inspection', id=ident, limit=2)
        if job['state'] not in ('pending', 'running'):
            return job
        assert time.monotonic() < deadline, job
        time.sleep(.005)


def rows(client, ident):
    result = []
    start = 0
    while True:
        page = client.inspect('get_inspection', id=ident, start=start, limit=2)
        result.extend(page['items'])
        if page['next'] is None:
            return page, result
        assert page['next'] > start, page
        start = page['next']


def main():
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    run = root / '.work' / ('inspection-lifecycle-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
    run.mkdir(parents=True, mode=0o755)
    source = run / 'fixture.c'
    source.write_text(r"""
#define _GNU_SOURCE
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
unsigned char *region;
__attribute__((noinline)) void before_remap(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void after_remap(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv) {
    if (argc > 1) return 0;
    region = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) return 10;
    memset(region, 0x11, 4096);
    before_remap();
    void *old = region;
    if (munmap(region, 4096)) return 11;
    region = mmap(old, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (region != old) return 12;
    memset(region, 0x22, 4096);
    after_remap();
    execl(argv[0], argv[0], "child", (char *)0);
    return 13;
}
""")
    binary = run / 'fixture'
    subprocess.run(['gcc', '-g', '-O0', '-fno-omit-frame-pointer', '-fno-pie', '-no-pie',
                    '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True,
                   env=dict(os.environ, TMPDIR=str(run)))
    client = MeasuredClient('control', str(binary))
    report = {'runtime_agent': client.runtime_agent, 'artifact': str(run), 'measurement': 'actual stdio bytes including status polls; no speed or bandwidth claim'}
    try:
        client.action('set_breakpoint', symbol='before_remap')
        client.action('set_breakpoint', symbol='after_remap')
        client.action('continue')
        stopped = client.stopped('breakpoint')
        tid = stopped['threads'][0]['tid']
        pointer = client.inspect('find_symbol', name='region')['address']
        address = int.from_bytes(bytes.fromhex(client.inspect('read_memory', address=pointer, length=8)['hex']), 'little')
        assert client.inspect('read_memory', address=hex(address), length=64)['hex'] == '11' * 64
        # Same stopped context and underlying requests for both measurements.
        expressions = ['$rip + ' + str(i) for i in range(10)]
        ranges = [{'address': hex(address + 64*i), 'length': 64} for i in range(4)]
        request = {'generation': stopped['generation'], 'tid': tid,
                   'expressions': expressions, 'memory': ranges}
        # Warm the ordinary stack/expression path before recording either cost.
        client.inspect('get_stack', tid=tid)
        client.inspect('evaluate_expression', tid=tid, expression=expressions[0])
        mark = client.mark()
        registers = client.inspect('get_registers', tid=tid)['registers']
        client.inspect('get_stack', tid=tid)
        expected = [client.inspect('evaluate_expression', tid=tid, expression=e) for e in expressions]
        for memory in ranges:
            client.inspect('read_memory', **memory)
        report['legacy'] = client.since(mark)
        mark = client.mark()
        retained = client.inspect('start_inspection', **request)
        complete = await_job(client, retained['id'])
        page, saved = rows(client, retained['id'])
        report['retained'] = client.since(mark)
        assert complete['state'] == 'completed', complete
        assert len(saved) == 16, saved
        assert saved[0]['data']['values'] == registers
        for index, value in enumerate(expected):
            assert saved[index+2]['data']['value'] == exact_inspection_value(value['value']), (saved[index+2], value)
        for item in saved[-4:]:
            assert item['data']['hex'] == '11' * 64 and item['data']['readable'] == 64
        identity = complete['identity']

        # Retention has a real eight-job bound; completed jobs consume slots.
        ids = [retained['id']]
        for _ in range(7):
            job = client.inspect('start_inspection', generation=stopped['generation'], tid=tid,
                                 registers=True, stack=False)
            ids.append(job['id'])
        assert len(set(ids)) == 8 and ids == sorted(ids), ids
        expect_error(client.tool('start_inspection', generation=stopped['generation'], tid=tid), 'InspectionLimit')
        released = ids.pop()
        client.inspect('release_inspection', id=released)
        expect_error(client.tool('get_inspection', id=released), 'UnknownInspection')
        # IDs cannot alias a released handle. Cancellation is deterministic at
        # the request boundary before any item is captured.
        next_id = released + 1
        replies = batch(client, [('start_inspection', {'generation': stopped['generation'], 'tid': tid}),
                                 ('cancel_inspection', {'id': next_id})])
        cancelled = replies[1]['result']['structuredContent']
        assert cancelled['id'] == next_id and cancelled['state'] == 'cancelled', replies
        assert cancelled['completed_items'] == 0, cancelled
        client.inspect('release_inspection', id=next_id)
        for ident in ids[1:]:
            client.inspect('release_inspection', id=ident)
        assert rows(client, retained['id'])[1] == saved

        # A queued capture cannot continue through the resume/remap boundary.
        replies = batch(client, [('start_inspection', request),
                                 ('continue', {'generation': stopped['generation']})])
        pending = replies[0]['result']['structuredContent']['id']
        changed = await_job(client, pending)
        assert changed['state'] == 'failed' and changed['diagnostic'] == 'InspectionContextChanged', changed
        after = client.stopped('breakpoint')
        assert after['generation'] > stopped['generation']
        assert client.inspect('read_memory', address=hex(address), length=64)['hex'] == '22' * 64
        assert rows(client, retained['id'])[1] == saved, 'Retained bytes changed after real unmap/remap'
        assert client.inspect('get_inspection', id=retained['id'])['identity'] == identity

        client.action('continue')
        replaced = client.stopped('exec')
        assert replaced['image_epoch'] > stopped['image_epoch'], (stopped, replaced)
        assert rows(client, retained['id'])[1] == saved, 'Retained evidence changed after exec'
        assert client.inspect('get_inspection', id=retained['id'])['identity'] == identity
        client.action('continue')
        deadline = time.monotonic() + 5
        while client.session()['state'] != 'exited':
            assert time.monotonic() < deadline
            time.sleep(.002)
        assert rows(client, retained['id'])[1] == saved, 'Retained evidence changed after exit'
        assert client.inspect('get_inspection', id=retained['id'])['identity'] == identity
        client.inspect('release_inspection', id=retained['id'])
        expect_error(client.tool('get_inspection', id=retained['id']), 'UnknownInspection')
        report.update(checks='capacity, cancellation, monotonic IDs, release, remap, exec, exit, immutable data/identity',
                      retained_items=len(saved), peak_job_bytes=complete['peak_bytes'])
        (run/'results.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report))
    finally:
        (run/'transcript.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        client.close()


if __name__ == '__main__':
    main()
