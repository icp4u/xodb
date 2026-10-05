#!/usr/bin/env python3
"""C04 Vulkan fault matrix on one private headless Sway per run.

usage: tests/vulkan-fault.py BINARY OUT.json [CASE-PREFIX...]

Each case launches `BINARY --frames N` (no target) with tests/vulkan-fault.c
preloaded and XODB_VKFAULT rules, then classifies the outcome. Cases that
must keep retrying are stopped with SIGINT after their duration; a clean
exit status is still required. Every case also requires: no panic/abort,
no leaked or prematurely destroyed Vulkan object, no semaphore misuse.
The private compositor socket path must fit sun_path (108 bytes); run from
a checkout whose path is short enough. XODB_VKFAULT_WORK may override the
artifact directory; its path must contain /.work/ for the private shim gate.
"""
import importlib.util, json, os, re, signal, subprocess, sys, time
from pathlib import Path

os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
binary = str(Path(sys.argv[1]).resolve())
out = Path(sys.argv[2])
prefixes = sys.argv[3:]
spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec); spec.loader.exec_module(display)
display.WORK = os.environ.get('XODB_VKFAULT_WORK', str(root / '.work' / ('vkf-' + str(time.time_ns())[-9:])))

# name, rules, frames, seconds, expectation
#   render: reaches the frame limit;  retry: never renders, keeps retrying init
#   recover: reaches the frame limit after at least one renderer recreation
INIT_CREATES = ['vkCreateInstance', 'vkCreateWaylandSurfaceKHR', 'vkCreateDevice', 'vkCreateCommandPool', 'vkAllocateCommandBuffers',
                'vkCreateSemaphore', 'vkCreateFence', 'vkCreateBuffer', 'vkAllocateMemory', 'vkBindBufferMemory', 'vkMapMemory',
                'vkCreateImage', 'vkBindImageMemory', 'vkCreateImageView', 'vkCreateSampler', 'vkCreateDescriptorSetLayout',
                'vkCreateDescriptorPool', 'vkAllocateDescriptorSets', 'vkCreatePipelineLayout', 'vkCreateSwapchainKHR',
                'vkCreateRenderPass', 'vkCreateShaderModule', 'vkCreateGraphicsPipelines', 'vkCreateFramebuffer']
CASES = [
    ('baseline', '', 20, 15, 'render'),
    ('start-devices-0', 'devices=0', 3, 3, 'retry'),
    ('start-devices-err', 'devices=err', 3, 3, 'retry'),
    ('start-devices-oversized', 'devices=5000', 3, 3, 'retry'),
    ('start-devices-incomplete', 'devices=incomplete', 3, 3, 'retry'),
    ('start-devices-repeated-40', 'devices=40', 3, 15, 'render'),
    ('start-families-0', 'families=0', 3, 3, 'retry'),
    ('start-families-oversized', 'families=5000', 3, 3, 'retry'),
    ('start-support-false-discrete', 'support=false:NVIDIA', 3, 15, 'render'),
    ('start-support-error-discrete', 'support=err:NVIDIA', 3, 6, 'render'),
    ('start-noswapchain-discrete', 'noswap=NVIDIA', 3, 6, 'render'),
    ('start-formats-0', 'formats=0', 3, 3, 'retry'),
    ('start-formats-err', 'formats=err', 3, 3, 'retry'),
    ('start-composite-alpha-0', 'alpha=0', 3, 3, 'retry'),
    ('start-min-images-max', 'minimages=4294967295', 3, 3, 'retry'),
    ('start-extent-min-gt-max', 'minextent=4000x4000;maxextent=100x100', 3, 3, 'retry'),
    ('start-memtypes-0', 'memtypes=0', 3, 3, 'retry'),
    ('start-memtypes-40', 'memtypes=40', 3, 15, 'render'),
    ('start-memtypes-40-no-match', 'memtypes=40,nodevlocal', 3, 3, 'retry'),
    ('start-memory-no-device-local', 'memtypes=nodevlocal', 3, 3, 'retry'),
    # Spec-violating on Wayland (currentExtent must be the special value); recorded, not gated.
    ('extent-fixed-current', 'curextent=640x480', 30, 15, 'observe'),
]
for fn in INIT_CREATES:
    CASES.append((f'partial-{fn}', f'fail={fn}@1:oodm', 3, 15, 'recover'))
    if fn not in ('vkAllocateCommandBuffers', 'vkAllocateDescriptorSets', 'vkCreateGraphicsPipelines', 'vkBindBufferMemory', 'vkBindImageMemory'):
        CASES.append((f'poison-{fn}', f'poison=1;fail={fn}@1:oodm', 3, 15, 'recover'))
for fn, results in (('vkAcquireNextImageKHR', ('out_of_date', 'suboptimal', 'lost', 'surface_lost', 'oodm')),
                    ('vkQueuePresentKHR', ('out_of_date', 'suboptimal', 'lost', 'surface_lost', 'oodm')),
                    ('vkWaitForFences', ('lost',)), ('vkResetCommandBuffer', ('oodm',)), ('vkBeginCommandBuffer', ('oodm',)),
                    ('vkEndCommandBuffer', ('oodm',)), ('vkResetFences', ('oodm',)), ('vkQueueSubmit', ('lost', 'oodm'))):
    for result in results:
        expect = 'render' if result in ('out_of_date', 'suboptimal') else 'recover'
        CASES.append((f'frame-{fn}-{result}', f'fail={fn}@5:{result}', 12, 15, expect))
CASES += [
    ('frame-acquire-out-of-date-repeated', 'fail=vkAcquireNextImageKHR@5x20:out_of_date', 12, 15, 'render'),
    ('resize-swapchain-create-fails', 'fail=vkAcquireNextImageKHR@5:out_of_date;fail=vkCreateSwapchainKHR@2:oodm', 12, 15, 'recover'),
    ('resize-framebuffer-create-fails', 'fail=vkAcquireNextImageKHR@5:out_of_date;fail=vkCreateFramebuffer@5:oodm', 12, 15, 'recover'),
    ('resize-device-idle-lost', 'fail=vkAcquireNextImageKHR@5:out_of_date;fail=vkDeviceWaitIdle@1:lost', 12, 15, 'recover'),
    ('resize-poison-swapchain', 'poison=1;fail=vkAcquireNextImageKHR@5:out_of_date;fail=vkCreateSwapchainKHR@2:oodm', 12, 15, 'recover'),
    ('repeat-present-lost-every-frame', 'fail=vkQueuePresentKHR@1x*:lost', 100000, 12, 'cycle'),
    ('repeat-init-fails-late', 'fail=vkCreateFramebuffer@1x*:oodm', 100000, 12, 'cycle'),
    # Real compositor resizes with lifetime accounting; stopped by SIGINT.
    ('resize-real-output', '', 100000, 6, 'resize'),
]
if prefixes:
    CASES = [c for c in CASES if any(c[0].startswith(p) for p in prefixes)]

def run_case(d, shim, name, rules, frames, seconds, expect):
    log = Path(d.dir) / f'{name}.log'
    env = dict(d.env, LD_PRELOAD=str(shim), XODB_VKFAULT=rules)
    started = time.monotonic()
    with log.open('wb') as stream:
        app = subprocess.Popen([binary, '--frames', str(frames)], env=env, stdout=stream, stderr=stream)
        stopped = False
        rss = []
        def sample():
            try:
                rss.append(int(re.search(r'VmRSS:\s+(\d+)', Path(f'/proc/{app.pid}/status').read_text()).group(1)))
            except (OSError, AttributeError):
                pass
        try:
            if expect == 'resize':
                for size in ((1040, 720), (900, 600), (1280, 800), (720, 480)):
                    time.sleep(1.2); d.resize(*size)
                time.sleep(max(0, seconds - 4.8))
                raise subprocess.TimeoutExpired(binary, seconds)
            if expect == 'cycle':
                time.sleep(2); sample(); time.sleep(seconds - 2.5); sample()
                raise subprocess.TimeoutExpired(binary, seconds)
            app.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            stopped = True
            app.send_signal(signal.SIGINT)
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill(); app.wait()
        finally:
            # A failed resize or assertion must not orphan an application.
            if app.poll() is None:
                app.send_signal(signal.SIGINT)
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app.kill(); app.wait()
    elapsed = time.monotonic() - started
    text = log.read_text(errors='replace')
    summary = None
    for line in text.splitlines():
        if line.startswith('vkfault: summary '):
            summary = json.loads(line[len('vkfault: summary '):])
    m = re.search(r'xodb: (\d+) frames, clean shutdown \(reason=(\w+)', text)
    rendered = int(m.group(1)) if m else None
    r = dict(name=name, rules=rules, frames=frames, expect=expect, returncode=app.returncode, sigint=stopped, seconds=round(elapsed, 3),
             rendered=rendered, reason=m.group(2) if m else None, log=str(log),
             init_failures=text.count('Renderer initialization failed'), frame_failures=text.count('Frame failed'),
             swapchain_requests=text.count('vkfault: swapchain request'),
             devices=sorted(set(re.findall(r'Vulkan device: (.*)', text))),
             present_candidates=sorted(set(re.findall(r'vkfault: present candidate (.*)', text))),
             panic=bool(re.search(r'panic|Segmentation fault|reached unreachable|integer overflow|index out of bounds', text)) or (app.returncode or 0) < 0,
             violations=[l for l in text.splitlines() if l.startswith('vkfault: violation') or l.startswith('vkfault: leak')][:20],
             summary=summary, rss_kib=rss, tail=text.splitlines()[-8:])
    problems = []
    if r['panic']: problems.append('crash/panic')
    if app.returncode != 0: problems.append(f'exit {app.returncode}')
    if rendered is None: problems.append('no clean shutdown line')
    if summary is None: problems.append('no shim summary (abnormal exit)')
    else:
        if summary['leaks']: problems.append(f"{summary['leaks']} leaked objects")
        if summary['violations']: problems.append(f"{summary['violations']} lifetime violations")
        if summary['live_at_exit']: problems.append(f"{summary['live_at_exit']} live objects at exit")
        for function in re.findall(r'(?:^|;)fail=([A-Za-z0-9_]+)@', rules):
            if summary['calls'].get(function, [0, 0])[1] == 0:
                problems.append(f'{function} fault was never injected')
    if expect == 'render' and r['reason'] != 'frame_limit': problems.append('did not reach frame limit')
    if expect == 'recover':
        if r['reason'] != 'frame_limit': problems.append('did not recover to frame limit')
        if not (r['init_failures'] + r['frame_failures']): problems.append('no renderer failure occurred before recovery')
    if expect == 'retry':
        if rendered: problems.append('rendered despite unusable startup')
        if not r['init_failures']: problems.append('no init failure reported')
    if expect == 'cycle' and not (r['init_failures'] + r['frame_failures']): problems.append('fault never surfaced')
    if expect == 'cycle' and len(rss) == 2 and rss[1] - rss[0] > 65536: problems.append(f'RSS grew {rss[1] - rss[0]} KiB across renderer recreation')
    if expect == 'resize':
        if r['reason'] != 'signal' or not rendered: problems.append('did not render until stopped')
        if r['swapchain_requests'] < 5: problems.append(f"only {r['swapchain_requests']} swapchains for 4 resizes")
    if expect == 'observe':
        r['notes'] = problems + [f"{r['swapchain_requests']} swapchain creations for {frames} frames at a constant surface size"]
        problems = [p for p in problems if p in ('crash/panic',) or p.startswith(('exit', 'no clean')) or 'leaked' in p or 'violations' in p]
    r['problems'] = problems
    r['ok'] = not problems
    return r

if not CASES:
    raise SystemExit('No Vulkan fault cases matched')

d = display.Display('vkfault')
results = []
baseline = None
capabilities = None
try:
    os.chmod(display.WORK, 0o755); os.chmod(d.dir, 0o755)
    shim = Path(d.dir) / 'vkfault.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', 'tests/vulkan-fault.c', '-ldl', '-lpthread', '-o', str(shim)], check=True)
    # The named fallback cases require two actual graphics+present candidates.
    # Keep this probe even for prefix selections, and record its result separately.
    baseline = run_case(d, shim, 'baseline', '', 20, 15, 'render')
    roster = baseline['present_candidates']
    capabilities = dict(healthy_baseline=baseline['ok'], present_candidates=roster,
                        nvidia=any('NVIDIA' in name for name in roster),
                        alternate=any('NVIDIA' not in name for name in roster))
    dependent = {'start-support-false-discrete', 'start-support-error-discrete', 'start-noswapchain-discrete'}
    for case in CASES:
        if case[0] in dependent and not all((capabilities['healthy_baseline'], capabilities['nvidia'], capabilities['alternate'])):
            missing = [label for key, label in (('healthy_baseline', 'healthy baseline'), ('nvidia', 'NVIDIA graphics+present adapter'), ('alternate', 'alternative graphics+present adapter')) if not capabilities[key]]
            r = dict(name=case[0], rules=case[1], expect=case[4], ok=None, skipped=True,
                     skip_reason='baseline did not establish ' + ', '.join(missing))
            results.append(r)
            print('SKIP ' + r['name'] + ': ' + r['skip_reason'], flush=True)
            continue
        r = baseline if case[0] == 'baseline' else run_case(d, shim, *case)
        results.append(r)
        print(('PASS ' if r['ok'] else 'FAIL ') + r['name'] + ('' if r['ok'] else ': ' + '; '.join(r['problems'])) + (' [' + '; '.join(r['notes']) + ']' if r.get('notes') else ''), flush=True)
finally:
    d.close()
passed = sum(r['ok'] is True for r in results)
skipped = sum(r.get('skipped', False) for r in results)
out.write_text(json.dumps(dict(binary=binary, work=d.dir, capabilities=capabilities, baseline=baseline,
                               cases=results, passed=passed, skipped=skipped, total=len(results)), indent=1) + '\n')
print(f"{passed}/{len(results)} passed; {skipped} skipped; {out}")
sys.exit(0 if baseline['ok'] and all(r['ok'] or r.get('skipped', False) for r in results) else 1)
