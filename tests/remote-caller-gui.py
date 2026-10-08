#!/usr/bin/env python3
"""Automatic remote caller decoration uses bounded CFI, not a whole library."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, default=root/'zig-out/bin/xodb')
a = p.parse_args()
os.umask(0o022)
os.chdir(root)
work = root/'.work'/('rc'+str(time.time_ns())[-7:])
work.mkdir(mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia', 'tree/zig-out/bin'):
    (work/name).mkdir(parents=True, exist_ok=True)
(work/'tree/zig-out/bin/xodb').symlink_to(a.binary.resolve())
main, library = work/'main.c', work/'caller.c'
main.write_text('''#include <dlfcn.h>
__attribute__((noinline)) void owned_stop(int value) { asm volatile("" : : "r"(value) : "memory"); }
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    void *image = dlopen(argv[1], RTLD_NOW);
    if (!image) return 2;
    void (*call)(void (*)(int)) = dlsym(image, "owned_caller");
    if (!call) return 3;
    call(owned_stop);
    dlclose(image);
    return 0;
}
''')
library.write_text('''__attribute__((noinline)) void owned_caller(void (*stop)(int)) {
    volatile int retained = 123;
    stop(retained);
    asm volatile("" : : "r"(retained) : "memory");
}
asm(".pushsection .debug_padding,\\"\\",@progbits\\n.skip 16777216\\n.popsection");
''')
fixture, image = work/'fixture', work/'caller.so'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-rdynamic', str(main), '-ldl', '-o', str(fixture)], check=True, timeout=60)
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-shared', '-fPIC', str(library), '-o', str(image)], check=True, timeout=60)
assert image.stat().st_size > 16*1024*1024
reports = []
for slow in (True, False):
    d = None
    try:
        os.environ['XODB_DISCOVERY_AGENT'] = str(root/'zig-out/bin/xodb-agent')
        os.environ['XODB_DISCOVERY_RATE'] = str(256*1024 if slow else 1024*1024*1024)
        d = h.Display(str(work/'tree'), ['--agent-scope', 'control', '--runtime-agent',
            str(root/'tests/fixtures/symbol-agent-proxy.py'), '--break', 'owned_stop', '--', str(fixture), str(image)])
        d.tool('continue', generation=d.session()['generation'])
        stopped = d.wait(lambda s: s['state'] == 'stopped' and not s['symbol_discovery_pending'] and
            not s['continue_pending'] and any(t['reason'] == 'breakpoint' for t in s['threads']), seconds=90)
        assert stopped
        tid = stopped['threads'][0]['tid']
        generation = stopped['generation']
        deadline = time.monotonic()+90
        while True:
            frames = d.tool('get_stack', tid=tid)['frames']
            if len(frames) >= 3 and frames[1]['cfa'] is not None:
                break
            assert time.monotonic() < deadline, frames
            time.sleep(.03)
        assert frames[0]['symbol'] == 'owned_stop', frames
        caller = frames[1]
        assert caller['source'] is None and caller['inline_diagnostic'] == 'DebugMetadataNotLoaded', caller
        assert caller['unwind_method'] is not None, caller
        jobs = d.tool('get_debug_metadata')['jobs']
        assert any(j['kind'] == 'unwind' and j['image'] == str(image) and j['state'] == 'ready' for j in jobs), jobs
        assert d.session()['generation'] == generation
        row = {'slow': slow, 'frames': frames, 'jobs': jobs, 'generation': generation}
        if not slow:
            # Explicit caller inspection still loads complete source/locals.
            variables = d.tool('list_locals', tid=tid, frame=1)
            assert any(v['name'] == 'retained' and v['value']['display'] == '123' for v in variables['locals']), variables
            row['explicit_locals'] = variables
            refreshed = d.tool('get_stack', tid=tid)['frames'][1]
            assert refreshed['source'] is not None and refreshed['inline_diagnostic'] is None, refreshed
            row['after_explicit_inspection'] = refreshed
        reports.append(row)
        (work/'results.json').write_text(json.dumps({'status': 'pass', 'cases': reports}, indent=2)+'\n')
    finally:
        if d:
            try:
                d.app.stdin.close()
                assert d.app.wait(timeout=30) == 0, d.tail()
            finally:
                d.close()
print('Remote caller CFI stays responsive; explicit caller inspection retains full debug information:', work)
