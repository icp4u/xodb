#!/usr/bin/env python3
"""Exercise recreation leak detection using owned private shim mutants."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('binary', type=Path)
p.add_argument('--work', required=True, type=Path, help='Fresh short path containing /.work/')
p.add_argument('--load', action='store_true', help='Four busy loops share two CPUs with the owned test')
p.add_argument('--rounds', type=int, default=1)
p.add_argument('--mode', action='append', choices=('honest', 'heap16', 'heap1', 'small', 'fd', 'thread', 'peak'))
a = p.parse_args()
assert 1 <= a.rounds <= 4
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
w = a.work.resolve()
assert '/.work/' in str(w)
w.mkdir(parents=True, mode=0o755)
source = w / 's'
(source / 'tests/helpers').mkdir(parents=True)
for name in ('tests/vulkan-fault.c', 'tests/vulkan-fault.py', 'tests/helpers/display.py', 'tests/helpers/vptr.c'):
    shutil.copy2(root / name, source / name)
original = (source / 'tests/vulkan-fault.c').read_text()
loads, rows = [], []
load_at_start = os.getloadavg()
cpus = sorted(os.sched_getaffinity(0))[:2]
assert len(cpus) == 2
os.sched_setaffinity(0, cpus)
helpers = r'''
#include <fcntl.h>
/* Deliberately leaked resources, confined to this owned test process. Volatile
 * page writes prevent optimized builds from deleting the heap controls. */
static void *parked(void *unused) { (void)unused; for (;;) pause(); return NULL; }
static void plant_host_leak(void) {
    const char *mode = getenv("XODB_TEST_HOST_LEAK");
    if (!mode) return;
    size_t bytes = 0, count = 1;
    if (!strcmp(mode, "heap16")) bytes = 16u << 20;
    if (!strcmp(mode, "heap1")) bytes = 1u << 20;
    if (!strcmp(mode, "small")) { bytes = 4096; count = 256; }
    for (size_t i = 0; i < count && bytes; ++i) {
        volatile unsigned char *p = malloc(bytes);
        if (!p) abort();
        for (size_t j = 0; j < bytes; j += 4096) p[j] = 0x5a;
    }
    if (!strcmp(mode, "fd") && open("/dev/null", O_RDONLY | O_CLOEXEC) < 0) abort();
    if (!strcmp(mode, "thread")) {
        pthread_t t;
        if (pthread_create(&t, NULL, parked, NULL) || pthread_detach(t)) abort();
    }
}
'''
needle = '    untrack(K_INSTANCE, (uint64_t)h); real(h, a);\n'
assert original.count(needle) == 1
mutant = original.replace('static pthread_mutex_t lock', helpers + '\nstatic pthread_mutex_t lock', 1)
mutant = mutant.replace(needle, needle + '    if (h && active()) plant_host_leak();\n', 1)
# Grow actual VkDeviceMemory allocations, still freeing every allocation at
# teardown. Lifetime balance alone cannot detect this peak-growth control.
allocation = '    r = real(d, i, a, out); if (r == VK_SUCCESS) track_bytes'
assert mutant.count(allocation) == 1
mutant = mutant.replace(allocation, r'''    VkMemoryAllocateInfo bigger = *i;
    const char *mode = getenv("XODB_TEST_HOST_LEAK");
    if (mode && !strcmp(mode, "peak")) {
        pthread_mutex_lock(&lock);
        bigger.allocationSize += retired_instances * (1u << 20);
        pthread_mutex_unlock(&lock);
        i = &bigger;
    }
''' + allocation, 1)
(source / 'tests/vulkan-fault.c').write_text(mutant)
try:
    if a.load:
        for _ in range(4):
            loads.append(subprocess.Popen([sys.executable, '-c', 'while True: pass'],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for round_ in range(a.rounds):
        for mode in a.mode or ('honest', 'heap16', 'heap1', 'small', 'fd', 'thread', 'peak'):
            label = str(round_) + '-' + mode
            result = w / (label + '.json')
            env = dict(os.environ, XODB_VKFAULT_WORK=str(w / ('d' + str(len(rows)))))
            env.pop('XODB_TEST_HOST_LEAK', None)
            if mode != 'honest': env['XODB_TEST_HOST_LEAK'] = mode
            with (w / (label + '.log')).open('w') as log:
                run = subprocess.run([sys.executable, '-B', 'tests/vulkan-fault.py',
                    str(a.binary.resolve()), str(result), 'repeat-'], cwd=source,
                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=100)
            data = json.loads(result.read_text())
            cases = data['cases'] if 'cases' in data else data['results']
            assert len(cases) == 2 and all(c['returncode'] == 0 and not c.get('skipped') for c in cases), data
            if mode == 'honest':
                assert run.returncode == 0 and all(c['ok'] for c in cases), data
            else:
                expected = ('Vulkan allocation peak grew' if mode == 'peak' else
                    'RSS at retirement grew' if mode in ('heap16', 'heap1', 'small') else mode + 's grew')
                assert run.returncode != 0 and all(any(expected in error for error in c['problems']) for c in cases), data
            rows.append({'mode': mode, 'round': round_, 'load': a.load, 'status': 'pass',
                'test_exit': run.returncode, 'cases': cases})
            (w / 'results.json').write_text(json.dumps({'checks': rows, 'cpus': cpus, 'host_cpu_count': os.cpu_count(),
                'load_at_start': load_at_start, 'load_now': os.getloadavg()}, indent=2) + '\n')
            print(label, 'detected' if mode != 'honest' else 'passed', flush=True)
finally:
    for child in loads:
        if child.poll() is None: child.terminate()
    for child in loads: child.wait(timeout=10)
    (w / 'cleanup.json').write_text(json.dumps({'load_exit_codes': [p.returncode for p in loads]}) + '\n')
print('Owned recreation leak controls passed:', len(rows) * 2, 'cases')
