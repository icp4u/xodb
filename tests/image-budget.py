#!/usr/bin/env python3
"""Full-image budgets: an image above the default 256 MiB is refused with a
reply that names the image, its size, the budget and the option to rerun with;
rerun with exactly that, it loads and symbolises. The same for a budget set by
option or config file, and for the total.
Run: python3 tests/image-budget.py --work out/image-budget
The image is a small shared object padded with a hole, so nothing large is
written to disk; the debugger still reads its whole extent.
--wrong-result expects a wrong frame name and must fail."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
from client import Client

MIB = 1 << 20
SIZE = 257 * MIB  # just above the default per-image budget
DEFAULTS = {'image_limit': 256 * MIB, 'total_limit': 1024 * MIB}
LIBRARY = '''
#include <unistd.h>
__attribute__((noinline)) int big_wait(int fd) {
    char byte;
    return (int)read(fd, &byte, 1);
}
'''
# Compressed debug sections: reading them takes a private copy of the image.
PACKED = '''
__attribute__((noinline)) int packed_call(int (*function)(int), int fd) {
    int result = function(fd);
    __asm__ volatile("" ::: "memory");
    return result;
}
'''
PROGRAM = '''
#include <stdio.h>
int big_wait(int);
int packed_call(int (*)(int), int);
int main(void) {
    puts("ready");
    fflush(stdout);
    return packed_call(big_wait, 0) < 0;
}
'''


def modules(client):
    regions, cursor = [], None
    while True:
        page = client.inspect('list_modules', **({'cursor': cursor} if cursor else {}))
        regions += page['regions']; cursor = page.get('next')
        if not cursor: return regions, page


def stack(client, session, tid):
    deadline = time.monotonic() + 30
    while True:
        found = client.inspect('get_stack', generation=session['generation'], tid=tid)
        if not any(f['diagnostic'] == 'DebugMetadataPending' for f in found['frames']): return found
        assert time.monotonic() < deadline, found
        time.sleep(.005)


def symbol(client, name):
    """The reply once the worker reading the large image's symbol tables is done."""
    deadline = time.monotonic() + 30
    while True:
        reply = client.tool('find_symbol', name=name)['result']
        if not reply.get('isError') or reply['content'][0]['text'] != 'SymbolDiscoveryPending': return reply
        assert time.monotonic() < deadline, reply
        time.sleep(.005)


def refused(client, tid, library, budget, knobs):
    """Every surface names the image, its size, the budget and how to raise it."""
    session = client.stopped()
    found = stack(client, session, tid)
    notice = found['image_budget']
    assert notice and notice.startswith(f'{library} is {SIZE // MIB} MiB; '), found
    assert budget in notice and all(knob in notice for knob in knobs), notice
    assert not any(f['symbol'] == 'big_wait' for f in found['frames']), found  # the probe saw the image unread
    assert any(f['inline_diagnostic'] == 'BinarySnapshotLimit' for f in found['frames']), found
    regions, page = modules(client)
    assert page['image_budget'] == notice, page
    failure = [f for f in page['load_failures'] if f['path'] == str(library)]
    assert len(failure) == 1 and failure[0]['diagnostic'] == 'BinarySnapshotLimit' and failure[0]['detail'] == notice, page['load_failures']
    assert any(r['path'] == str(library) and r['full_image_deferred'] for r in regions), regions
    # A name that is nowhere may be in the unread image: say so instead of "not found".
    reply = symbol(client, 'xodb_no_such_symbol')
    assert reply['isError'] and [c['text'] for c in reply['content']] == ['ImageBudgetExceeded', notice], reply
    # The small symbol tables are still read without the full image.
    reply = symbol(client, 'big_wait')
    assert not reply['isError'] and reply['structuredContent']['name'] == 'big_wait', reply
    return notice


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--wrong-result', action='store_true')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    xodb = os.environ.get('XODB_BIN', './zig-out/bin/xodb')
    result = {'status': 'running'}; started = time.monotonic()

    # Nonsense is refused before any target is touched, with the accepted range.
    for option in ('--image-limit', '--image-total-limit'):
        for value in ('0', '1', '4096', '-1', '2GB', '1.5G', 'lots', '', '2000000000000000000000', '2048G'):
            run = subprocess.run([xodb, '--headless', '--mcp', option, value], input=b'', capture_output=True, timeout=10)
            assert run.returncode != 0 and f'xodb: {option} {value}: expected a size from 1M to'.encode() in run.stderr, (option, value, run)
    for text, why in (('{"symbols":{"image_bytes":0}}', 'InvalidImageBudget'), ('{"symbols":{"image_total_bytes":4096}}', 'InvalidImageBudget'),
                      ('{"symbols":{"image_bytes":"2G"}}', 'InvalidCharacter'), ('{"symbols":{"image_byte":1048576}}', 'UnknownField')):
        (w/'bad.json').write_text(text)
        run = subprocess.run([xodb, '--headless', '--mcp', '--config', str(w/'bad.json')], input=b'', capture_output=True, timeout=10)
        assert run.returncode != 0 and f'xodb: preferences failed: {why};'.encode() in run.stderr, (text, run)
        assert (b'symbols.image_bytes and symbols.image_total_bytes take bytes from' in run.stderr) == (why == 'InvalidImageBudget'), run
    result['refused_values'] = 'pass'

    (w/'big.c').write_text(LIBRARY); (w/'packed.c').write_text(PACKED); (w/'main.c').write_text(PROGRAM)
    library, packed = w/'libbig.so', w/'libpacked.so'
    subprocess.run(['cc', '-g', '-O1', '-shared', '-fPIC', str(w/'big.c'), '-o', str(library)], check=True, timeout=60)
    subprocess.run(['cc', '-g', '-gz=zlib', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', str(w/'packed.c'), '-o', str(packed)], check=True, timeout=60)
    subprocess.run(['cc', '-g', '-O1', '-fno-optimize-sibling-calls', str(w/'main.c'), '-o', str(w/'main'), f'-L{w}', '-lbig', '-lpacked', f'-Wl,-rpath,{w}'], check=True, timeout=60)
    os.truncate(library, SIZE)  # a hole, not data
    assert packed.stat().st_size < MIB; os.truncate(packed, MIB)
    target = subprocess.Popen([str(w/'main')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    client = None
    try:
        assert target.stdout.readline() == 'ready\n', target.stderr.read()
        tid = target.pid; attach = ['--attach', str(tid)]

        # Default budgets: 256 MiB an image, 1 GiB in all, and the refusal
        # says what to rerun with for this image.
        client = Client('control', None, options=attach)
        figures = client.inspect('list_modules', limit=1)['image_bytes']
        assert {k: figures[k] for k in DEFAULTS} == DEFAULTS, figures
        notice = refused(client, tid, library, 'image budget 256 MiB', ('--image-limit', 'symbols.image_bytes'))
        err = close(client); client = None
        assert err.count(b'module budget:') == 1 and notice.encode() in err, err
        advice = re.search(r'; rerun with ((?:--image-(?:total-)?limit \d+[MG] ?)+) or set symbols\.image_bytes', notice)
        assert advice and advice.group(1) == '--image-limit 300M', notice
        result['option'] = notice

        # Rerun with the sentence's own words: read in full, named, with source.
        client = Client('control', None, options=[*attach, *advice.group(1).split()])
        t0 = time.monotonic()
        found = stack(client, client.stopped(), tid)
        frame = next((f for f in found['frames'] if f['symbol'] == ('big_wrong' if a.wrong_result else 'big_wait')), None)
        assert frame and frame['source'] and frame['source']['path'].endswith('big.c') and frame['diagnostic'] is None, found
        assert any(f['symbol'] == 'main' for f in found['frames']) and found['image_budget'] is None, found
        through = next(f for f in found['frames'] if f['symbol'] == 'packed_call')
        assert through['source']['path'].endswith('packed.c') and through['diagnostic'] is None, found  # inflated and read
        regions, page = modules(client)
        assert page['image_budget'] is None and page['total_load_failures'] == 0 and not any(r['full_image_deferred'] for r in regions), page
        assert symbol(client, 'big_wait')['structuredContent']['module_id'] == frame['module_id']
        rss = int(Path(f'/proc/{client.p.pid}/statm').read_text().split()[1]) * os.sysconf('SC_PAGESIZE')
        assert rss < 2 * SIZE, rss  # one copy of the image, not two
        result['advised'] = {'options': advice.group(1), 'frames': [f['symbol'] for f in found['frames']], 'seconds': round(time.monotonic() - t0, 3), 'rss_bytes': rss, 'image_bytes': SIZE}
        assert b'module budget' not in close(client); client = None

        # The same value given on the command line: the same words.
        client = Client('control', None, options=[*attach, '--image-limit', '256M'])
        assert refused(client, tid, library, 'image budget 256 MiB', ('--image-limit', 'symbols.image_bytes')) == notice
        close(client); client = None

        # Raised in the config file: it loads. Set in the file to the default: the same words.
        (w/'high.json').write_text(json.dumps({'symbols': {'image_bytes': 300 * MIB}}))
        client = Client('control', None, options=[*attach, '--config', str(w/'high.json')])
        found = stack(client, client.stopped(), tid)
        assert found['image_budget'] is None and any(f['symbol'] == 'big_wait' for f in found['frames']), found
        close(client); client = None
        (w/'low.json').write_text(json.dumps({'symbols': {'image_bytes': 256 * MIB}}))
        client = Client('control', None, options=[*attach, '--config', str(w/'low.json')])
        assert refused(client, tid, library, 'image budget 256 MiB', ('--image-limit', 'symbols.image_bytes')) == notice
        close(client); client = None

        # The command line wins over the file.
        client = Client('control', None, options=[*attach, '--config', str(w/'low.json'), '--image-limit', '1G'])
        found = stack(client, client.stopped(), tid)
        assert found['image_budget'] is None and any(f['symbol'] == 'big_wait' for f in found['frames']), found
        close(client); client = None

        # The total is a budget too, and says what is left of it.
        client = Client('control', None, options=[*attach, '--image-limit', '1G', '--image-total-limit', '200M'])
        total = refused(client, tid, library, 'MiB left of the 200 MiB total image budget; rerun with --image-total-limit 2G', ('--image-total-limit', 'symbols.image_total_bytes'))
        close(client); client = None
        result['total'] = total

        # An image that fits exactly leaves nothing for the copy its compressed
        # debug sections need: refused by name before anything is allocated.
        client = Client('control', None, options=[*attach, '--image-limit', '1M'])
        found = stack(client, client.stopped(), tid)
        last = found['frames'][-1]
        assert last['symbol'] == 'packed_call' and last['diagnostic'] == 'CompressedDebugBudget', found
        close(client); client = None
        result['compressed'] = last['diagnostic']
        target.stdin.write('\n'); target.stdin.flush()
        target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        result['status'] = 'pass'
    finally:
        if client: result['transcript'] = client.transcript; client.p.kill(); client.p.wait()
        if target.poll() is None: target.kill(); target.wait()
        library.unlink(missing_ok=True)
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        (w/'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"image budget: defaults are 256 MiB an image and 1 GiB in all; a {SIZE // MIB} MiB image is refused with: {result['option'].replace(str(w), '.')}; "
          f"rerun with {result['advised']['options']} it loads and symbolises ({result['advised']['rss_bytes'] >> 20} MiB resident)")


def close(client):
    """Close and return what the debugger wrote to stderr."""
    client.p.stdin.close()
    err = client.p.stderr.read()
    assert client.p.wait(timeout=10) == 0, err
    return err


if __name__ == '__main__':
    main()
