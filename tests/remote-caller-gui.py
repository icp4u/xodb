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
p.add_argument('--fast-only', action='store_true', help='Run only the fast transport case')
a = p.parse_args()
os.umask(0o022)
os.chdir(root)
work = root/'.work'/('input-rc'+str(time.time_ns())[-7:])
work.mkdir(mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia', 'tree/zig-out/bin'):
    (work/name).mkdir(parents=True, exist_ok=True)
(work/'tree/zig-out/bin/xodb').symlink_to(a.binary.resolve())
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c', str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
main, library = work/'main.c', work/'caller.c'
main.write_text('''#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
static volatile unsigned char *cache_bytes;
__attribute__((noinline)) void owned_stop(int value) { asm volatile("" : : "r"(value) : "memory"); }
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    int cache = open(argv[2], O_RDONLY);
    struct stat status;
    if (cache < 0 || fstat(cache, &status) || status.st_size <= 0) return 2;
    void *hint = (void *)(uintptr_t)0x100000000ULL;
    void *mapped = mmap(hint, (size_t)status.st_size, PROT_READ,
                        MAP_PRIVATE | MAP_FIXED_NOREPLACE, cache, 0);
    if (mapped == MAP_FAILED)
        mapped = mmap(0, (size_t)status.st_size, PROT_READ, MAP_PRIVATE, cache, 0);
    close(cache);
    if (mapped == MAP_FAILED) return 3;
    cache_bytes = mapped;
    if (cache_bytes[0] != 'N') return 4;
    void *image = dlopen(argv[1], RTLD_NOW);
    if (!image) return 5;
    void (*call)(void (*)(int)) = dlsym(image, "owned_caller");
    if (!call) return 6;
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
fixture, image, nonelf = work/'fixture', work/'caller.so', work/'synthetic.cache'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-rdynamic', str(main), '-ldl', '-o', str(fixture)], check=True, timeout=60)
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-shared', '-fPIC', str(library), '-o', str(image)], check=True, timeout=60)
assert image.stat().st_size > 16*1024*1024
with nonelf.open('wb') as f:
    f.write(b'NOT-ELF synthetic cache\n')
    f.truncate(16*1024*1024)

def reason(reply):
    content = reply.get('content', []) if isinstance(reply, dict) else []
    return content[0].get('text') if content else None

reports = []
for slow in ((False,) if a.fast_only else (True, False)):
    d = None
    try:
        os.environ['XODB_DISCOVERY_AGENT'] = str(root/'zig-out/bin/xodb-agent')
        os.environ['XODB_DISCOVERY_RATE'] = str(1024*1024 if slow else 1024*1024*1024)
        d = h.Display(str(work/'tree'), ['--agent-scope', 'control', '--runtime-agent',
            str(root/'tests/fixtures/symbol-agent-proxy.py'), '--break', 'owned_stop', '--',
            str(fixture), str(image), str(nonelf)])
        # The async GUI can map while the startup breakpoint is still resolving.
        # Act on the settled stop, as the synchronous GUI implicitly did.
        ready = d.wait(lambda s: s['state'] == 'stopped' and not s['symbol_discovery_pending']
                       and not s['continue_pending'], seconds=90)
        assert ready, d.tail()
        d.tool('continue', generation=ready['generation'])
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
        # A constant watch forces WatchSource.stack to decorate every frame,
        # including the unloaded caller, without explicitly asking for its locals.
        d.keys('tap', 18, 'tap', 10, 'tap', 9, 'tap', 8, 'tap', 7,
               'tap', 6, 'tap', 5, 'tap', 4, 'tap', 3, 'tap', 2, 'tap', 28)
        text = h.ocr_until(d, 'constant-watch', lambda text: '987654321' in text and 'watch' in text)
        assert '987654321' in text and 'watch' in text, text
        row['watch_visible'] = True
        watched = d.tool('get_stack', tid=tid)['frames'][1]
        assert watched['source'] is None and watched['inline_diagnostic'] == 'DebugMetadataNotLoaded', watched
        assert d.session()['generation'] == generation
        row['after_watch'] = watched
        # Explicit caller inspection may publish Pending once. Even on the
        # throttled agent it transfers debugger ranges, never the 16 MiB
        # private padding section.
        started = time.monotonic()
        deadline = started + 90
        observed = []
        variables = None
        while True:
            reply = d.request('tools/call', {'name': 'list_locals',
                'arguments': {'tid': tid, 'frame': 1}})
            jobs = d.tool('get_debug_metadata')['jobs']
            current = [j for j in jobs if j['kind'] == 'image' and j['image'] == str(image)]
            observed += current
            if not reply.get('isError'):
                variables = reply['structuredContent']
            else:
                assert reason(reply) == 'DebugMetadataPending', (reply, jobs)
            terminal = [j for j in current if j['state'] in ('ready', 'failed', 'cancelled')]
            if variables is not None and terminal:
                assert terminal[-1]['state'] == 'ready', terminal[-1]
                break
            # Adoption releases the worker immediately, so a successful
            # caller query may observe its removal rather than `ready`.
            if variables is not None and observed and not current:
                break
            assert time.monotonic() < deadline, (reply, jobs)
            time.sleep(.01)
        assert any(v['name'] == 'retained' and v['value']['display'] == '123' for v in variables['locals']), variables
        assert observed and max(j['source_size'] for j in observed) == image.stat().st_size, observed
        transferred = max(j['source_bytes'] for j in observed)
        needed = max(j['image_total'] for j in observed)
        # A caller can adopt cached type/source metadata before the image
        # worker publishes its range plan. In that case its disappearance and
        # bounded bytes are the proof; otherwise the plan is bounded too.
        assert transferred < image.stat().st_size//8, observed
        assert needed == 0 or needed < image.stat().st_size//8, observed
        row['explicit_locals'] = variables
        row['explicit_transfer'] = {'source_bytes': transferred, 'image_total': needed,
                                    'source_size': image.stat().st_size,
                                    'seconds': time.monotonic()-started}
        refreshed = d.tool('get_stack', tid=tid)['frames'][1]
        assert refreshed['source'] is not None and refreshed['inline_diagnostic'] is None, refreshed
        row['after_explicit_inspection'] = refreshed

        # A full source sweep must examine the synthetic offset-zero mapping,
        # reject it from the four-byte probe, and never spend an image worker
        # or transport payload on its non-ELF body.
        maps = [line for line in Path(f'/proc/{stopped["pid"]}/maps').read_text().splitlines()
                if line.endswith(str(nonelf))]
        assert len(maps) == 1 and maps[0].split()[2] == '00000000', maps
        deadline = time.monotonic()+90
        while True:
            reply = d.request('tools/call', {'name': 'set_breakpoint', 'arguments': {
                'generation': d.session()['generation'], 'file': 'synthetic-no-match.c', 'line': 1}})
            jobs = d.tool('get_debug_metadata')['jobs']
            assert not any(j['kind'] == 'image' and j['image'] == str(nonelf) for j in jobs), jobs
            if reason(reply) not in ('DebugMetadataPending', 'SymbolDiscoveryPending'):
                break
            assert time.monotonic() < deadline, (reply, jobs)
            time.sleep(.01)
        assert reply.get('isError') and reason(reply) == 'NoCodeForSourceLine', reply
        row['non_elf_sweep'] = 'prefiltered'
        reports.append(row)
        (work/'results.json').write_text(json.dumps({'status': 'pass', 'cases': reports}, indent=2)+'\n')
    finally:
        if d:
            try:
                d.app.stdin.close()
                assert d.app.wait(timeout=30) == 0, d.tail()
            finally:
                d.close()
print('Remote caller CFI stays lazy; explicit locals use ranged metadata and source sweeps prefilter non-ELF mappings:', work)
