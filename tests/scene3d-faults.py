#!/usr/bin/env python3
"""Batch private GPU lane: partial scene creates release every owned handle."""
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

def load_scale():
    return max(1.0, os.getloadavg()[0] / len(os.sched_getaffinity(0)))

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('sf' + str(time.time_ns())[-5:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('private_display', root / 'tests/helpers/display.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
shim = work / 'fault.so'
subprocess.run(['cc', '-shared', '-fPIC', '-std=c11', '-Wall', '-Wextra', '-Werror',
                'tests/vulkan-fault.c', '-ldl', '-pthread', '-o', str(shim)], check=True)
component = work / 'accounting'
subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', 'tests/vulkan-fault-accounting.c',
                '-ldl', '-pthread', '-o', str(component)], check=True)
subprocess.run([str(component)], check=True, timeout=5 * load_scale())
d = None
rows = []

def cwd_check(proc):
    if proc.poll() is not None:
        return
    try:
        cwd = os.readlink(f'/proc/{proc.pid}/cwd')
    except PermissionError:
        # A capability-bearing compositor hides its cwd; it is still our own child.
        return
    except FileNotFoundError:
        return
    if Path(cwd) != root:
        raise AssertionError('owned-process cwd changed before cleanup')

def run(name, rule, retry=False):
    env = dict(d.env, LD_PRELOAD=str(shim), XODB_VKFAULT=rule)
    log = work / (name + '.log')
    started = time.monotonic()
    with log.open('wb') as stream:
        proc = subprocess.Popen([str(root/'zig-out/bin/xodb'), '--scene3d-probe', '--instances', '4000', '--frames', '30' if retry else '3', *(['--retry-scene'] if retry else [])],
                                cwd=root, env=env, stdout=stream, stderr=stream)
        try:
            proc.wait(timeout=15 * load_scale())
        finally:
            if proc.poll() is None:
                cwd_check(proc)
                proc.terminate()
                try:
                    proc.wait(timeout=5 * load_scale())
                except subprocess.TimeoutExpired:
                    cwd_check(proc)
                    proc.kill()
                    proc.wait()
    text = log.read_text()
    summaries = [json.loads(line[len('vkfault: summary '):]) for line in text.splitlines() if line.startswith('vkfault: summary ')]
    if not summaries:
        raise AssertionError(name + ': no active accounting summary\n' + text)
    result = summaries[-1]
    failures = [line for line in text.splitlines() if line.startswith(('vkfault: leak', 'vkfault: violation'))]
    if failures or any(result[k] for k in ('live_at_exit', 'leaks', 'violations', 'dirty_retirements')) or result['allocations']['live_bytes']:
        raise AssertionError(name + ': resources leaked or retired in flight\n' + text)
    if retry:
        refusals = re.findall(r'scene3d refused=(\w+) now=(\d+) retry=(\d+)', text)
        injections = text.count('vkfault: inject vkCreateRenderPass ')
        deadlines = {int(row[2]) for row in refusals}
        if proc.returncode != 0 or len(refusals) != 30 or injections != len(deadlines) or injections >= len(refusals):
            raise AssertionError(name + ': repeated scene allocation did not back off\n' + text)
        result['retry_evidence'] = dict(frames=len(refusals), actual_allocations=injections, retry_deadlines=sorted(deadlines))
    elif rule:
        function = rule.split('fail=', 1)[1].split('@', 1)[0]
        if f'vkfault: inject {function} ' not in text or proc.returncode != 1 or 'error: SceneVulkanFailed' not in text:
            raise AssertionError(name + ': did not observe requested scene failure\n' + text)
    elif proc.returncode != 0 or 'scene3d frame=3 ' not in text:
        raise AssertionError(name + ': no successful baseline\n' + text)
    rows.append(dict(name=name, rule=rule, returncode=proc.returncode, seconds=time.monotonic()-started, summary=result))
    print('PASS ' + name, flush=True)
    return text, result

try:
    d = h.Display('d', width=1280, height=720)
    text, baseline = run('baseline', '')
    framebuffers = int(re.search(r'scene3d base framebuffers=(\d+)', text).group(1))
    cases = [('vkCreateRenderPass', 2), ('vkCreateRenderPass', 3),
             ('vkCreatePipelineLayout', 2), ('vkCreatePipelineLayout', 3),
             ('vkCreateDescriptorSetLayout', 2), ('vkCreateDescriptorPool', 2), ('vkAllocateDescriptorSets', 2),
             ('vkCreateSampler', 2), ('vkCreateShaderModule', 5),
             ('vkCreateGraphicsPipelines', 3), ('vkCreateGraphicsPipelines', 9), ('vkCreateGraphicsPipelines', 10),
             ('vkCreateImage', 2), ('vkCreateImage', 3), ('vkCreateImage', 4), ('vkCreateImage', 5),
             ('vkAllocateMemory', 3), ('vkBindImageMemory', 2), ('vkCreateImageView', framebuffers + 2),
             ('vkCreateFramebuffer', framebuffers + 1), ('vkCreateFramebuffer', framebuffers + 2),
             ('vkCreateBuffer', 2), ('vkAllocateMemory', 7), ('vkBindBufferMemory', 2), ('vkMapMemory', 2)]
    if baseline['created'].get('query_pool', 0):
        cases.append(('vkCreateQueryPool', 1))
    for function, call in cases:
        run(function + '-' + str(call), f'poison=1;fail={function}@{call}:oodm')
    run('persistent-scene-failure', 'poison=1;fail=vkCreateRenderPass@2x*:oodm', retry=True)
    (work/'results.json').write_text(json.dumps(dict(cases=rows, query_supported=bool(baseline['created'].get('query_pool', 0))), indent=2)+'\n')
    print(f'{len(rows)} passed; evidence {work}', flush=True)
finally:
    if d:
        cwd_check(d.sway)
        d.close()
