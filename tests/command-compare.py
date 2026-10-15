"""Same MCP command script, two binaries. Opt-in; only an owned fixture is traced.

python3 tests/command-compare.py --reference ./before/xodb --candidate ./after/xodb
Use --reference-agent and --candidate-agent together for the local-agent lane.
--gui runs the same script against the native GUI window (private headless Sway).
Raw transcripts remain in --work; only ASLR/identity-independent facts compare.
"""
import argparse
import difflib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LABELS = ['bp no generation', 'bp stale generation', 'continue extra field', 'bp symbol',
          'interrupt stale while stopped', 'continue', 'stop1',
          *[label for step in ('step_instruction', 'step_over_instruction', 'step_source', 'step_over')
            for label in (step, step + ' stop')],
          'step tid 0', 'step tid unknown', 'finish', 'finish stop', 'configure', 'configure tid 0',
          'run_to line', 'run_to stop', 'run_to no code', 'bp unprefixed hex', 'unprefixed bp at pc',
          'remove sym', 'remove addr', 'remove unknown', 'bp file line', 'continue2', 'interrupt',
          'interrupt stop', 'audit', 'restart', 'restart stop', 'detach']


def compare(before, after):
    for value in (before, after):
        assert value.get('version') == 1, 'invalid transcript version'
        rows = value.get('rows')
        assert isinstance(rows, list) and [r[0] for r in rows] == LABELS, 'incomplete or reordered transcript'
    if before != after:
        diff = ''.join(difflib.unified_diff(
            json.dumps(before, indent=2, sort_keys=True).splitlines(True),
            json.dumps(after, indent=2, sort_keys=True).splitlines(True),
            fromfile='reference', tofile='candidate'))
        raise AssertionError('command behavior differs:\n' + diff)


def gui_client(fixture):
    """The windowed native owner, driven by the same MCP calls as headless."""
    import importlib.util
    import tempfile
    from client import Client
    spec = importlib.util.spec_from_file_location('input_display', ROOT / 'tests/helpers/input.py')
    h = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(h)
    work = Path(tempfile.mkdtemp(prefix='compare-gui-', dir=ROOT / '.work'))
    work.chmod(0o755)
    for name in ('tmp', 'cache'):
        (work / name).mkdir(mode=0o755)
    h.WORK = str(work)

    class Gui(Client):
        def __init__(self):
            self.display = h.Display(str(ROOT), ['--agent-scope', 'control', '--', str(fixture), 'w'],
                                     binary=os.environ['XODB_BIN'])
            self.p, self.id, self.transcript, self.reply_seconds = self.display.app, self.display.serial, [], 10
            self.runtime_agent = False

        def close(self):
            self.display.close()
    return Gui()


def record(fixture):
    from client import Client
    from helpers.orphans import adopt, reap
    adopt()
    source = (ROOT / 'tests/fixtures/m1.c').read_text().splitlines()
    line_of = lambda marker: next(i + 1 for i, line in enumerate(source) if marker in line)
    rows = []
    client = gui_client(fixture) if os.environ.get('XODB_COMPARE_GUI') else Client('control', executable=str(fixture), args=('w',))
    detached_pidfd = None

    def rec(label, reply):
        if 'error' in reply:
            rows.append([label, ['rpcerror', reply['error']['code'], reply['error']['message']]])
            return reply['error']
        result = reply['result']
        if result.get('isError'):
            observation = ['error', [item['text'] for item in result['content']]]
        else:
            observation = ['ok', sorted(result['structuredContent'])]
        rows.append([label, observation])
        return result

    def action(name, label=None, **args):
        return rec(label or name, client.tool(name, generation=client.session()['generation'], **args))

    def pc_of(tid):
        regs = client.inspect('get_registers', tid=tid)['registers']
        value = regs['rip'] if 'rip' in regs else regs['pc']
        return int(value, 16) if isinstance(value, str) else value

    def where(label, anchor):
        state = client.stopped()
        threads = []
        for t in state['threads']:
            pc = pc_of(t['tid'])
            location = client.inspect('get_source_location', address=hex(pc))
            threads.append([t['reason'], pc - anchor, location['source']['line']])
        rows.append([label, [sorted(threads), state['state'], state.get('step_diagnostic')]])

    try:
        initial = client.stopped()
        generation = initial['generation']
        rec('bp no generation', client.tool('set_breakpoint', symbol='change_value'))
        rec('bp stale generation', client.tool('set_breakpoint', symbol='change_value', generation=generation + 1000))
        rec('continue extra field', client.tool('continue', generation=generation, bogus=1))
        result = action('set_breakpoint', 'bp symbol', symbol='change_value')
        bpid = result['structuredContent']['id']
        rec('interrupt stale while stopped', client.tool('interrupt', generation=generation + 1000))
        action('continue')
        state = client.stopped('breakpoint')
        tid = next(t['tid'] for t in state['threads'] if t['reason'] == 'breakpoint')
        anchor = next(b['address'] for b in client.inspect('get_breakpoints')['breakpoints'] if b['id'] == bpid)
        where('stop1', anchor)
        for name in ('step_instruction', 'step_over_instruction', 'step_source', 'step_over'):
            action(name, tid=tid)
            where(name + ' stop', anchor)
        action('step_instruction', 'step tid 0', tid=0)
        action('step_instruction', 'step tid unknown', tid=2**31 - 2)
        action('finish', tid=tid)
        where('finish stop', anchor)
        action('configure_breakpoint', 'configure', id=bpid, condition='0')
        action('configure_breakpoint', 'configure tid 0', id=bpid, tid=0)
        action('run_to', 'run_to line', tid=tid, file='m1.c', line=line_of('item->writes += 1'))
        where('run_to stop', anchor)
        action('run_to', 'run_to no code', tid=tid, file='m1.c', line=1)
        pc = pc_of(tid)
        result = action('set_breakpoint', 'bp unprefixed hex', address=format(pc, 'x'))
        address_id = result['structuredContent']['id']
        probes = client.inspect('get_breakpoints')['breakpoints']
        rows.append(['unprefixed bp at pc', next(b['address'] == pc for b in probes if b['id'] == address_id)])
        for probe in probes:
            if not probe['internal']:
                action('remove_breakpoint', 'remove sym' if probe['id'] == bpid else 'remove addr', id=probe['id'])
        action('remove_breakpoint', 'remove unknown', id=9999)
        action('set_breakpoint', 'bp file line', file='m1.c', line=line_of('SECOND_CALL'))
        action('continue', 'continue2')
        # The second call is behind us; the owned fixture is now in its wait
        # loop. Observe running before interrupt, not a wall-clock sleep.
        assert client.session()['state'] == 'running'
        action('interrupt')
        rows.append(['interrupt stop', client.stopped()['state']])
        rows.append(['audit', [[a['actor'], a['action']] for a in client.inspect('get_audit')['actions']]])
        action('restart')
        state = client.stopped()
        rows.append(['restart stop', state['state']])
        # Pin the owned restarted process before detach; never kill a reused PID.
        detached_pidfd = os.pidfd_open(state['pid'])
        action('detach')
    finally:
        try:
            client.close()
        finally:
            if detached_pidfd is not None:
                try:
                    signal.pidfd_send_signal(detached_pidfd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.close(detached_pidfd)
            assert reap(), 'comparison left an owned descendant running'
    return {'version': 1, 'rows': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference')
    parser.add_argument('--candidate', default='./zig-out/bin/xodb')
    parser.add_argument('--reference-agent')
    parser.add_argument('--candidate-agent')
    parser.add_argument('--gui', action='store_true', help='record against the native GUI window instead of --headless')
    parser.add_argument('--work', type=Path, default=Path('.work/command-compare'))
    parser.add_argument('--record', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.record:
        print(json.dumps(record(args.record)))
        return
    if not args.reference or bool(args.reference_agent) != bool(args.candidate_agent):
        parser.error('--reference required; agent paths must be provided as a pair')
    if args.gui and args.reference_agent:
        parser.error('--gui compares the native window; it does not take agent paths')
    args.work.mkdir(parents=True, exist_ok=True, mode=0o755)
    fixture = args.work.resolve() / 'm1'
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', str(ROOT / 'tests/fixtures/m1.c'), '-o', str(fixture)], check=True, timeout=30)
    observations = []
    for label, binary, agent in (('reference', args.reference, args.reference_agent),
                                 ('candidate', args.candidate, args.candidate_agent)):
        env = dict(os.environ, XODB_BIN=str(Path(binary).resolve()))
        env.pop('XODB_RUNTIME_AGENT', None)
        env.pop('XODB_TEST_RUNTIME_AGENT', None)
        env.pop('XODB_COMPARE_GUI', None)
        if args.gui:
            env['XODB_COMPARE_GUI'] = '1'
        if agent:
            env['XODB_RUNTIME_AGENT'] = str(Path(agent).resolve())
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()), '--record', str(fixture)],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        (args.work / (label + '.json')).write_text(result.stdout)
        (args.work / (label + '.stderr')).write_text(result.stderr)
        assert result.returncode == 0, label + ' recording failed: ' + result.stderr
        observations.append(json.loads(result.stdout))
    compare(*observations)
    print(f'command comparison: {len(observations[0]["rows"])} matching observations')


if __name__ == '__main__':
    main()
