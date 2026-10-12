#!/usr/bin/env python3
"""Replay a recorded Apple debugserver session, then hostile variants of it.

No Mac is needed: tests/fixtures/debugserver-arm64.json holds the packets of a
real launch session (tests/macos-debugserver.py --record), and a loopback stub
plays them back to xodb. The same scenario code drives the live test. The
hostile cases change single replies and expect a typed refusal within the
link's deadlines: never a hang, a crash or an unbounded read.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client
from helpers import debugserver_scenario as scenario
from helpers.fake_debugserver import Fake

ROOT = Path(__file__).resolve().parents[1]
IMAGES = 'jGetLoadedDynamicLibrariesInfos:'
REGION = 'qMemoryRegionInfo:'


def error(client, tool, **args):
    result = client.tool(tool, **args)['result']
    assert result['isError'], (tool, result)
    return result['content'][0]['text']


class Replace:
    """Swap the replies of matching requests, and count them: a hostile case that never served its reply proves nothing."""
    def __init__(self, match, make, once=False):
        self.match, self.make, self.once, self.served = match, make, once, 0

    def __call__(self, request, replies):
        if not self.match(request, replies) or (self.once and self.served): return replies
        self.served += 1
        return [self.make(request, replies)]


def session(exchanges, mutate=None):
    fake = Fake(exchanges, mutate); fake.start()
    return fake, Client('mutate', executable=None, options=('--gdb-remote', fake.endpoint), reply_seconds=20)


def finish(client, broken=False):
    """A dead link leaves a detach that cannot be confirmed; the process must still end by itself."""
    client.p.stdin.close()
    code = client.p.wait(timeout=10)
    assert broken or code == 0, client.p.stderr.read().decode()


def replay(exchanges, static, log):
    fake, client = session(exchanges)
    try: scenario.run(client, static, None, log)
    finally:
        (log.directory / 'replay-mcp.json').write_text(json.dumps(client.transcript, indent=1) + '\n')
    finish(client)
    assert not fake.unexpected, f'requests the recording does not hold (re-record it): {fake.unexpected[:5]}'
    assert fake.at == len(exchanges), f'{len(exchanges) - fake.at} recorded exchanges were never asked for'
    assert fake.requests[-1] == 'D'


def images_too_large(exchanges, static, log):
    row = '{"load_address":4294967296,"mod_date":0,"pathname":"/tmp/xodb-fixture/' + 'a' * 200 + '"},'
    huge = '{"images":[' + row * 4000 + row[:-1] + ']}'
    assert len(huge) > 524288
    hostile = Replace(lambda request, replies: request.startswith(IMAGES), lambda request, replies: huge)
    fake, client = session(exchanges, hostile)
    regions, images = scenario.modules(client)
    assert hostile.served == 1
    assert regions and len(images) == 1 and images[0]['diagnostic'] == 'GdbListTooLarge', images
    assert 'packet limit' in images[0]['detail'], images
    # The oversized frame was discarded with its checksum verified: the link still works.
    assert client.inspect('get_registers', tid=client.session()['threads'][0]['tid'])['registers']['pc']
    assert client.session()['gdb_remote']['memory_regions'] == 'available'
    client.action('detach'); finish(client)


def malformed_images(text):
    def case(exchanges, static, log):
        hostile = Replace(lambda request, replies: request.startswith(IMAGES), lambda request, replies: text)
        fake, client = session(exchanges, hostile)
        assert error(client, 'list_modules') == 'ProtocolError' and hostile.served == 1
        assert client.session()['gdb_remote']['images'] == 'failed'
        # A reply that breaks the grammar ends the connection, as for every other packet.
        assert error(client, 'read_memory', address='0x100000000', length=4) in ('ProtocolError', 'TransportFailed')
        finish(client, broken=True)
    return case


def region_reply(make, expected, alive):
    def case(exchanges, static, log):
        hostile = Replace(lambda request, replies: request.startswith(REGION), lambda request, replies: make(int(request[len(REGION):], 16)))
        fake, client = session(exchanges, hostile)
        started = time.monotonic()
        assert error(client, 'list_modules') == expected and hostile.served >= 1
        assert time.monotonic() - started < 12
        if alive:
            assert client.inspect('get_registers', tid=client.session()['threads'][0]['tid'])['registers']['pc']
            client.action('detach')
        finish(client, broken=not alive)
    return case


def region_oversized(exchanges, static, log):
    pages = ','.join('%x' % (0x100000000 + 0x4000 * n) for n in range(30000))
    hostile = Replace(lambda request, replies: request.startswith(REGION) and 'permissions' in replies[0],
                      lambda request, replies: replies[0] + 'dirty-pages:' + pages + ';')
    baseline, client = session(exchanges); expected = scenario.modules(client)[0]; client.action('detach'); finish(client)
    fake, client = session(exchanges, hostile)
    assert scenario.modules(client)[0] == expected, 'a region reply above the packet limit keeps its leading fields'
    assert hostile.served == len(expected) >= 4
    client.action('detach'); finish(client)


def frame_fault(raw, expected):
    def case(exchanges, static, log):
        hostile = Replace(lambda request, replies: request.startswith('m'), lambda request, replies: raw, once=True)
        fake, client = session(exchanges, hostile)
        started = time.monotonic()
        assert error(client, 'read_memory', address='0x100000000', length=4) in expected and hostile.served == 1
        assert time.monotonic() - started < 12, 'bounded by the request deadline'
        assert error(client, 'get_registers', tid=client.session()['threads'][0]['tid']) in ('ProtocolError', 'TransportFailed')
        finish(client, broken=True)
    return case


def absurd_registers(exchanges, static, log):
    document = '<target><feature name="hostile">' + ''.join(f'<reg name="r{n}" bitsize="64"/>' for n in range(5000)) + '</feature></target>'
    def mutate(request, replies):
        if not request.startswith('qXfer:features:read:target.xml:'): return replies
        offset, size = (int(part, 16) for part in request.rsplit(':', 1)[1].split(','))
        piece = document[offset:offset + size]
        return [('m' if offset + size < len(document) else 'l') + piece]
    fake = Fake(exchanges, mutate); fake.start()
    done = subprocess.run([os.environ['XODB_BIN'], '--headless', '--mcp', '--gdb-remote', fake.endpoint],
                          stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    assert done.returncode != 0 and b'register layout exceeds limits' in done.stderr, done.stderr


def long_register(exchanges, static, log):
    # A register of the wrong size refuses the read; it is never copied into the bank.
    hostile = Replace(lambda request, replies: request == 'p0', lambda request, replies: '00' * 4000)
    fake, client = session(exchanges, hostile)
    assert error(client, 'get_registers', tid=client.session()['threads'][0]['tid']) == 'UnexpectedRegisterSize'
    assert hostile.served >= 1
    client.action('detach'); finish(client)


def unknown_signal(exchanges, static, log):
    # The recorded stop also carries a Mach exception. Remove that independent
    # cause so this case continues to exercise an unmapped signal itself.
    hostile = Replace(lambda request, replies: request == 'vCont;c',
                      lambda request, replies: re.sub(r'(?:metype|mecount|medata):[^;]*;', '', 'T40' + replies[0][3:]), once=True)
    fake, client = session(exchanges, hostile)
    client.action('continue')
    stopped = client.stopped('signal', seconds=10)
    assert hostile.served == 1
    # Darwin has no signal 64. It is shown as a signal stop and never forwarded by default.
    assert error(client, 'continue', generation=stopped['generation']) == 'UnsupportedControl'
    assert 'unmapped GDB signal' in client.session()['gdb_remote']['last_reason']
    client.action('detach'); finish(client)


def planted(exchanges, static, log):
    """The oracle must notice a wrong answer: SIGUSR2 (31) reported where the fixture raised SIGUSR1 (30)."""
    hostile = Replace(lambda request, replies: bool(replies) and replies[0].startswith('T1e'), lambda request, replies: 'T1f' + replies[0][3:])
    fake, client = session(exchanges, hostile)
    try: scenario.run(client, static, None, log)
    except AssertionError as caught:
        assert hostile.served == 1 and "'signal': 31" in str(caught) and 'SIGUSR2' in str(caught), caught
    else: raise AssertionError('a wrong signal number passed the scenario')
    finally: client.p.kill(); client.p.wait()


CASES = {
    'replay': replay,
    'planted-wrong-signal': planted,
    'images-too-large': images_too_large,
    'images-deep': malformed_images('{"images":[{"load_address":1,"extra":' + '[' * 40 + ']' * 40 + '}]}'),
    'images-truncated': malformed_images('{"images":[{"load_address":4294967296,"pathname":"/tmp/xodb-fix'),
    'images-negative': malformed_images('{"images":[{"load_address":-1,"pathname":"/tmp/xodb-fixture/a"}]}'),
    'region-flood': region_reply(lambda asked: f'start:{asked:x};size:4000;permissions:r;', 'GdbListTooLarge', True),
    'region-backwards': region_reply(lambda asked: f'start:{asked + 0x4000:x};size:4000;permissions:r;', 'ProtocolError', False),
    'region-zero': region_reply(lambda asked: f'start:{asked:x};size:0;permissions:r;', 'ProtocolError', False),
    'region-oversized': region_oversized,
    # debugserver keeps acknowledgements on: a bad frame is asked for again three times, then refused.
    'bad-checksum': frame_fault(b'$00000000#00', ('ProtocolError',)),
    # Half a frame and silence: the five-second request deadline ends the wait.
    'truncated-packet': frame_fault(b'$0000', ('TransportFailed',)),
    'absurd-registers': absurd_registers,
    'long-register': long_register,
    'unknown-signal': unknown_signal,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, help='Evidence directory')
    parser.add_argument('--xodb', default='zig-out/bin/xodb')
    parser.add_argument('--cases', nargs='+', default=list(CASES), choices=list(CASES))
    parser.add_argument('--skip', nargs='+', default=[], choices=list(CASES), help='Cases to leave to another step')
    args = parser.parse_args(); os.umask(0o022)
    work = Path(args.work).resolve(); work.mkdir(mode=0o755, parents=True, exist_ok=True)
    os.environ['XODB_BIN'] = str(Path(args.xodb).resolve())
    recording = json.loads((ROOT / 'tests/fixtures/debugserver-arm64.json').read_text())
    results = []
    for name in [name for name in args.cases if name not in args.skip]:
        lines = []
        def log(text): lines.append(text)
        log.directory = work
        started = time.monotonic()
        try:
            CASES[name](recording['exchanges'], recording['static'], log)
            result = dict(case=name, status='pass')
        except Exception as failure:
            result = dict(case=name, status='fail', reason=f'{type(failure).__name__}: {failure}'[:2000])
        result['seconds'] = round(time.monotonic() - started, 2)
        if lines: result['log'] = lines
        results.append(result); print(json.dumps({k: v for k, v in result.items() if k != 'log'}), flush=True)
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return int(any(result['status'] != 'pass' for result in results))


if __name__ == '__main__': raise SystemExit(main())
