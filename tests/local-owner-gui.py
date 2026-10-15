"""Native-owner step/input measurements and held-ptrace repaint oracle.

Fast GUI lane; --baseline measures the old binary without claiming isolation.
--expect-blocked runs the same held-read oracle as a negative control.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('owner_test', ROOT / 'tests/remote-owner-gui.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def run(args):
    from PIL import Image, ImageChops, ImageStat
    (ROOT / '.work').mkdir(exist_ok=True)
    h, work = helper.setup(ROOT)
    if args.startup_refusal:
        child = subprocess.Popen(['/bin/sleep', '30'])
        results = []
        try:
            fields = Path('/proc', str(child.pid), 'stat').read_text().split(') ', 1)[1].split()
            cases = ([ '--attach', str(child.pid), '--expected-start-ticks', str(int(fields[19]) + 1) ],
                     [ '--', str(work / 'missing-executable') ])
            for options in cases:
                display = h.Display(str(ROOT), ['--frames', '1', *options], binary=args.binary, stdio=False)
                try:
                    code = display.app.wait(timeout=15)
                    results.append({'exit_code': code, 'target_alive': child.poll() is None})
                    assert code != 0, 'native startup refusal was reported as success'
                    assert child.poll() is None, 'rejected identity touched the owned target'
                finally:
                    display.close()
        finally:
            child.terminate()
            child.wait(timeout=5)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(results, indent=2) + '\n')
        print('native startup refusals retain failure exit status and leave rejected targets alone')
        return
    result = {'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0)),
              'baseline': args.baseline, 'step_ms': [], 'input_ms': [], 'passed': False}
    binary = str(Path(args.binary).resolve())
    if not args.baseline:
        library = work / 'hold-ptrace.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/fixtures/hold-ptrace.c'), '-ldl', '-o', str(library)], check=True, timeout=30)
        wrapper = work / 'native-wrapper'
        wrapper.write_text('#!/usr/bin/env python3\nimport os\nos.environ.update(' + repr({
            'LD_PRELOAD': str(library), 'XODB_TEST_PTRACE_DIR': str(work)}) + ')\nos.execv(' + repr(binary) + ', [' + repr(binary) + '] + __import__("sys").argv[1:])\n')
        wrapper.chmod(0o755)
        binary = str(wrapper)
    display = None
    try:
        display = h.Display(str(ROOT), ['--agent-scope', 'control', '--source', 'tests/fixtures/m1.c',
                            '--break', 'change_value', '--', './zig-out/bin/xodb-m1-fixture', 'w'], binary=binary)
        assert display.stopped(), display.tail()
        display.tool('continue', generation=display.session()['generation'])
        assert display.stopped('breakpoint'), display.tail()
        result['before'] = helper.usage(display.app.pid)
        for _ in range(4):
            generation = display.session()['generation']
            started = time.monotonic_ns()
            key = display.keys('tap', 87, wait=False)  # F11
            assert display.wait(lambda s: s['state'] == 'stopped' and s['generation'] > generation)
            key.wait(timeout=5)
            result['step_ms'].append((time.monotonic_ns() - started) / 1e6)
        crop = (650, 630, 1250, 760)

        def shot(name):
            return Image.open(display.shot(name)).convert('RGB').crop(crop)

        def distance(left, right):
            return sum(ImageStat.Stat(ImageChops.difference(left, right)).sum)

        closed = shot('closed')
        started = time.monotonic_ns()
        key = display.keys('tap', 18, wait=False)  # E watch editor
        opened = helper.wait(lambda: image if distance(image := shot('editor'), closed) > 0 else None,
                             'editor did not repaint')
        key.wait(timeout=5)
        result['input_ms'].append((time.monotonic_ns() - started) / 1e6)
        key = display.keys('tap', 1, wait=False)
        closed = helper.wait(lambda: image if distance(image := shot('closed-again'), opened) > 0 else None,
                             'editor did not close')
        key.wait(timeout=5)
        if not args.baseline:
            (work / 'arm').touch()
            key = display.keys('tap', 87, wait=False)
            held = helper.wait(lambda: json.loads((work / 'held.json').read_text()) if (work / 'held.json').exists() else None,
                               'native ptrace read did not enter the barrier')
            key.wait(timeout=5)
            result['held'] = held
            result['owner_differs_from_ui'] = held['tid'] != held['pid']
            status = Path('/proc', str(held['tracee']), 'status').read_text()
            tracer = int(re.search(r'^TracerPid:\s+(\d+)', status, re.M)[1])
            assert tracer == held['tid'], 'register reads and attach/launch have different tracer threads'
            result['tracer_matches_owner'] = True
            started = time.monotonic_ns()
            key = display.keys('tap', 18, wait=False)

            def repainted():
                assert not (work / 'release').exists()
                image = shot('held-editor')
                return distance(image, opened) < distance(image, closed) / 4

            try:
                helper.wait(repainted, 'editor blocked by native ptrace', timeout=3 * h.load_scale())
                result['repainted_while_held'] = True
            except AssertionError:
                result['repainted_while_held'] = False
                if not args.expect_blocked:
                    raise
            key.wait(timeout=5)
            result['held_input_ms'] = (time.monotonic_ns() - started) / 1e6
            assert result['repainted_while_held'] != args.expect_blocked, result
            assert result['owner_differs_from_ui'] != args.expect_blocked, result
            result['held_usage'] = helper.usage(display.app.pid)
            (work / 'release').touch()
            assert display.stopped(), display.tail()
        result['after'] = helper.usage(display.app.pid)
        result['load_after'] = os.getloadavg()
        result['performance_measurable'] = max(result['load'][0], result['load_after'][0]) <= result['cpus']
        metrics = re.findall(r'owner publication prep_ns=(\d+) copy_ns=(\d+) bytes=(\d+) queue=(\d+)', Path(display.log).read_text())
        result['publication_cost'] = [list(map(int, row)) for row in metrics] or None
        result['passed'] = True
    finally:
        (work / 'release').touch()
        if display:
            display.close()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='./zig-out/bin/xodb')
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--expect-blocked', action='store_true')
    parser.add_argument('--startup-refusal', action='store_true')
    parser.add_argument('--output', type=Path, default=Path('.work/local-owner-result.json'))
    run(parser.parse_args())
