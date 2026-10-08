#!/usr/bin/env python3
"""Two static Lua runtimes must be refused even when their layouts agree."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', required=True, type=Path)
p.add_argument('--library', required=True, type=Path)
p.add_argument('--side-source', type=Path, help='Internal headers for an optional different embedded Lua copy')
p.add_argument('--side-library', type=Path, help='Static library for that embedded copy')
p.add_argument('--work', required=True, type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = a.work.resolve()
work.mkdir(parents=True, mode=0o755)
source, library = a.source.resolve(), a.library.resolve()
if bool(a.side_source) != bool(a.side_library):
    p.error('--side-source and --side-library must be used together')
side_source = (a.side_source or a.source).resolve()
side_library = (a.side_library or a.library).resolve()

def run(args, cwd=work):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True, timeout=90)

objects = work / 'objects'
objects.mkdir()
run(['ar', 'x', side_library], objects)
run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-I'+str(side_source), '-c',
     root/'tests/fixtures/lua/dual-side.c', '-o', objects/'wrapper.o'])
run(['ld', '-r', '-o', work/'side-linked.o', *sorted(objects.glob('*.o'))])
run(['objcopy', '--keep-global-symbol=side_run', '--keep-global-symbol=side_stop',
     work/'side-linked.o', work/'side-hidden.o'])
data = (work/'side-hidden.o').read_bytes()
prefix = next((b'$LuaVersion: Lua '+v+b' ' for v in (b'5.4.9', b'5.2.4')
               if b'$LuaVersion: Lua '+v+b' ' in data), None)
assert prefix and data.count(prefix) == 1, 'expected one exact version object'
(work/'side-different.o').write_bytes(data.replace(prefix, prefix[:-2]+b'6 '))
evidence = []
for name, side in [('original-side', 'side-hidden.o'), ('altered-side-version', 'side-different.o')]:
    exe = work/name
    run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-I'+str(source),
         root/'tests/fixtures/lua/dual.c', work/side, library, '-lm', '-ldl', '-o', exe])
    target = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    thread = threading.Thread(target=lambda: [lines.put(line) for line in target.stdout], daemon=True)
    thread.start()
    client = None
    try:
        assert lines.get(timeout=10) == 'ready\n'
        client = Client('control', None, options=['--attach', str(target.pid)])
        client.action('set_breakpoint', symbol='main_stop')
        client.action('set_breakpoint', symbol='side_stop')
        client.action('continue')
        target.stdin.write('go\n')
        target.stdin.flush()
        for stop in range(3):
            client.stopped('breakpoint', seconds=10)
            before = client.inspect('get_registers', tid=target.pid)
            generation = client.session()['generation']
            for tool, args in [('get_language_stack', {'language':'lua'}),
                               ('evaluate_expression', {'frame':1, 'expression':'L'})]:
                result = client.tool(tool, tid=target.pid, **args)['result']
                if tool == 'get_language_stack':
                    assert result.get('isError') and result['content'][0]['text'] == 'LuaRuntimeMultiple', result
                else:
                    value = result['structuredContent']['value']
                    assert value['diagnostic'] == 'LuaRuntimeMultiple' and value['visualization'] is None, result
            assert client.inspect('get_registers', tid=target.pid) == before
            assert client.session()['generation'] == generation
            evidence.append({'case':name, 'stop':stop, 'reason':'LuaRuntimeMultiple', 'session_usable':True})
            client.action('continue')
    finally:
        if client:
            (work/(name+'-transcript.json')).write_text(json.dumps(client.transcript, indent=2)+'\n')
            client.close()
        if target.poll() is None:
            target.kill()
        target.wait(timeout=5)
        thread.join(timeout=5)
        (work/(name+'-stderr.txt')).write_text(target.stderr.read())
        target.stdin.close()
        target.stdout.close()
        target.stderr.close()
(work/'results.json').write_text(json.dumps({'status':'pass', 'cases':evidence}, indent=2)+'\n')
print('Lua duplicate runtimes refused at all six stops; sessions usable')
