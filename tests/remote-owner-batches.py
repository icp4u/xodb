#!/usr/bin/env python3
"""Buffered MCP cancellation stays ordered without starving inspection work."""
import json
from client import Client
from inspections import await_job, pipeline


def run():
    client = Client('control', executable='./zig-out/bin/xodb-fixture')
    try:
        session = client.stopped()
        args = {'generation': session['generation'], 'tid': session['threads'][0]['tid']}
        warm = client.inspect('start_inspection', **args)
        await_job(client, warm['id'])
        client.inspect('release_inspection', id=warm['id'])
        rows = []
        for offset, fillers in enumerate((0, 7, 0), 1):
            ident = warm['id'] + offset
            requests = [('start_inspection', args)]
            # Small replies keep this a scheduling test, without filling the
            # output pipe and invoking the independent backpressure path.
            requests.extend(('get_language_watches', {}) for _ in range(fillers))
            requests.append(('cancel_inspection', {'id': ident}))
            responses = pipeline(client, requests)
            for response in responses:
                assert 'error' not in response and not response['result']['isError'], response
            assert responses[0]['result']['structuredContent']['id'] == ident, responses
            job = client.inspect('get_inspection', id=ident)
            if fillers:
                # The ninth request crosses the eight-request stdio batch.
                # Work must advance even though the client keeps sending.
                assert job['completed_items'] > 0, job
            else:
                assert job['state'] == 'cancelled' and job['completed_items'] == 0, job
            rows.append({'requests': len(requests), 'state': job['state'],
                         'completed_items': job['completed_items']})
            client.inspect('release_inspection', id=ident)
        print(json.dumps({'runtime_agent': client.runtime_agent, 'batches': rows}))
    finally:
        client.close()


if __name__ == '__main__':
    run()
