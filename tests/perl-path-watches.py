#!/usr/bin/env python3
"""Perl builtin paths against cooperating PadWalker and subscription oracles."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import resource
import shlex
import signal
import subprocess
import threading
import time
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def usage(pid):
    stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'), rss_kib=rss)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--perl', required=True)
    parser.add_argument('--padwalker', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--agent', type=Path)
    parser.add_argument('--strace', action='store_true')
    parser.add_argument('--component', action='store_true')
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    work = args.work.resolve(); work.mkdir(parents=True, mode=0o755)
    cfg = json.loads(subprocess.check_output([args.perl, '-MConfig', '-MJSON::PP', '-e',
        'print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags version)})'], timeout=30))
    assert cfg['version'] == '5.44.0', cfg
    cc = shlex.split(cfg['cc']); library = work/'paths.so'
    sanitize = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else []
    sources = ['src/language/perl.c', 'src/language/perl_layout.c']
    command = [*cc, *shlex.split(cfg['ccflags']), '-U_FORTIFY_SOURCE', '-DNDEBUG', '-shared', '-fPIC', '-g3', '-O0',
        '-fno-omit-frame-pointer', '-I'+cfg['archlib']+'/CORE', *sanitize,
        *(['-DXODB_PERL_PATH_ORACLE'] if args.component else []), 'tests/fixtures/perl/paths.c',
        *([*sources, '-ldw', '-lelf'] if args.component else []), '-o', str(library)]
    build_command = command
    built = subprocess.run(command, capture_output=True, text=True, timeout=90)
    (work/'build.log').write_text(built.stdout+built.stderr); assert built.returncode == 0, built.stderr
    env = dict(os.environ, PERL5LIB=str(args.padwalker.resolve()/'blib/lib')+':'+str(args.padwalker.resolve()/'blib/arch'))
    command = [args.perl, str(root/'tests/fixtures/perl/paths.pl'), str(library)]
    if args.component:
        exe = work/'reader'
        subprocess.run([*cc, '-std=c11', '-g', '-O2', '-Wall', '-Wextra', '-Werror', *sanitize,
            *sources, 'tests/perl-reader.c', '-ldw', '-lelf', '-o', str(exe)], check=True, timeout=90)
        result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=90)
        (work/'reader.log').write_text(result.stdout+result.stderr); assert result.returncode == 0, result.stderr
        env['XODB_PERL_ORACLE_IMAGE'] = str(Path(cfg['archlib'])/'CORE/libperl.so')
        if args.sanitize:
            env['LD_PRELOAD'] = subprocess.check_output([*cc, '-print-file-name=libasan.so'], text=True).strip()
            env['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'
        result = subprocess.run(command, input='go\n', env=env, capture_output=True, text=True, timeout=90)
        (work/'oracle.log').write_text(result.stdout+result.stderr); assert result.returncode == 0, result.stderr
        records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        assert len(records) == 7 and 'done magic=0' in result.stdout
        count = sum(len(row['values']) for row in records)
        assert count == 105 and f'verified {count} path samples' in result.stderr
        bad = work/'paths-negative.so'
        negative_command = [*build_command[:-2], '-DXODB_PERL_PATH_ORACLE_NEGATIVE', '-o', str(bad)]
        negative_build = subprocess.run(negative_command, capture_output=True, text=True, timeout=90)
        (work/'negative-build.log').write_text(negative_build.stdout+negative_build.stderr)
        assert negative_build.returncode == 0, negative_build.stderr
        negative = subprocess.run([*command[:-1], str(bad)], input='go\n', env=env,
                                  capture_output=True, text=True, timeout=90)
        (work/'negative.log').write_text(negative.stdout+negative.stderr)
        assert negative.returncode != 0 and 'CHECK failed: got.sv==' in negative.stderr, (
            'wrong element address was not rejected', negative.returncode, negative.stderr)
        (work/'results.json').write_text(json.dumps(dict(status='pass', stops=len(records), oracle_paths=count, sanitized=args.sanitize, negative_control="wrong address rejected", negative_returncode=negative.returncode), indent=2)+'\n')
        print('Perl paths component: 105 public-API oracle paths, zero magic calls, malformed tables and every-read failures passed')
        return
    client = None; target = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def drain():
        for line in target.stdout: lines.put(line)
    thread = threading.Thread(target=drain, daemon=True); thread.start()
    result = dict(status='running', stops=[], resources=[]); ids = {}; last = {}
    try:
        assert lines.get(timeout=10) == 'ready\n'
        options = [*(['--runtime-agent', str(args.agent.resolve())] if args.agent else []), '--attach', str(target.pid)]
        client = Client('control', None, options=options)
        source = root/'tests/fixtures/perl/watches.c'
        line = next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'WATCH_STOP' in text)
        client.action('set_breakpoint', file=str(source), line=line)
        client.continue_initial_stop(); target.stdin.write('go\n'); target.stdin.flush()
        for index in range(7):
            state = client.stopped('breakpoint', seconds=30); generation = state['generation']
            ground = json.loads(lines.get(timeout=10))
            registers = client.inspect('get_registers', tid=target.pid)
            if index == 0:
                stack = client.inspect('get_language_stack', language='perl', tid=target.pid)
                segment, frame = next((i,j) for i,part in enumerate(stack['segments']) for j,row in enumerate(part['frames']) if row['name']=='main::watched')
                args_ = dict(language='perl', tid=target.pid, segment=segment, frame=frame)
                measured = dict(frontend=client.p.pid)
                if args.agent: measured['agent'] = client.collector_pid()
                result['resources'].append(dict(phase='metadata ready before watches', processes={k:usage(v) for k,v in measured.items()}, load=os.getloadavg()))
                for expression in ('$root()', '$root->{f()}', '$root->[01]', '$root->[-01]', '$root->[2147483648]', '$root->{"$x"}', '$root->{x}'*9):
                    for tool in ('add_language_watch', 'evaluate_language_expression'):
                        reply = client.tool(tool, generation=generation, **args_, expression=expression)['result']
                        assert reply.get('isError') and reply['content'][0]['text']=='UnsupportedPerlExpression', (tool,expression,reply)
                for expression in ('@array', '%hash', '&watched'):
                    reply = client.tool('add_language_watch', generation=generation, **args_, expression=expression)['result']
                    assert reply.get('isError') and reply['content'][0]['text']=='UnsupportedPerlExpression', reply
                assert client.inspect('get_language_watches')['watches'] == []
                for row in ground['values']:
                    expression = row['expression']
                    ids[expression] = client.action('add_language_watch', **args_, expression=expression)['added']
                filler = client.action('add_language_watch', **args_, expression='$x')['added']
                assert len(client.inspect('get_language_watches')['watches']) == 16
                for language, expression, why in (
                    ('perl', '@array', 'UnsupportedPerlExpression'),
                    ('perl', '$x()', 'UnsupportedPerlExpression'),
                    ('ruby', 'x()', 'UnsupportedRubyExpression'),
                    ('lua', 'x()', 'LuaExpressionUnsupported'),
                    ('python', 'x()', 'UnsupportedLanguageExpression'),
                    ('javascript', 'x', 'JavaScriptLexicalUnproved')):
                    reply = client.tool('add_language_watch', generation=generation, **(args_|dict(language=language)), expression=expression)['result']
                    assert reply.get('isError') and reply['content'][0]['text']==why, (language,reply)
                for language, selector in [('perl',dict(expression='$x')), ('ruby',dict(expression='x')),
                                            ('lua',dict(expression='x')), ('python',dict(expression='x')),
                                            ('javascript',dict(row=0))]:
                    reply = client.tool('add_language_watch', generation=generation, **(args_|dict(language=language)), **selector)['result']
                    assert reply.get('isError') and reply['content'][0]['text']=='LanguageWatchLimit', (language,reply)
                client.action('remove_language_watch', id=filler)
                result['full_watch_syntax_precedence'] = True
                if args.strace:
                    def observe():
                        client.inspect('evaluate_language_expression', generation=generation, **args_, expression='$root->{player}{score}')
                        extra = client.action('add_language_watch', **args_, expression='$root->{absent}')['added']
                        client.action('remove_language_watch', id=extra)
                    result['readonly'] = audit(client, target.pid, work/'paths.strace', observe)
            deadline = time.monotonic()+60
            while True:
                rows = client.inspect('get_language_watches')['watches']
                if all(row['observed_generation']==generation for row in rows): break
                assert time.monotonic()<deadline, rows; time.sleep(.01)
            byid = {row['id']:row for row in rows}
            for expected in ground['values']:
                expression = expected['expression']; row = byid[ids[expression]]
                assert row['selector']=='expression' and row['expression']==expression and row['row_name'] is None, row
                assert 'unproved' in row['identity'], row
                evaluated = client.inspect('evaluate_language_expression', generation=generation, **args_, expression=expression)
                assert evaluated['diagnostic'] is None and len(evaluated['rows'])==1, evaluated
                value = evaluated['rows'][0]
                if expected['reason']:
                    assert row['state']=='unavailable' and row['diagnostic']==expected['reason'] and not row['changed'], (ground['label'],row,expected)
                    assert value['value']['diagnostic']==expected['reason'] and value['address'] is None and value['slot_address'] is None, value
                    continue
                key = expected['kind'], expected['sample']; changed = expression in last and last[expression]!=key
                assert row['state']=='value' and row['changed']==changed, (ground['label'],row,expected)
                assert row['current']['kind']==expected['kind'] and row['current']['comparison_bytes']==len(expected['sample'])//2, row
                assert value['address']==expected['address'] and value['slot_address'], (value,expected)
                if index == 1 and expression.endswith('{text}'):
                    assert changed and row['current']['display']==row['previous']['display'], row
                last[expression] = key
            if index == 1:
                before = result['stops'][0]['ground']['values'][0]['address']
                assert ground['values'][0]['address'] != before, 'replacement did not move selected scalar'
                result['replacement_observed'] = True
            assert client.inspect('get_registers', tid=target.pid)==registers and client.session()['generation']==generation
            assert client.inspect('get_language_watches')['watches']==rows
            result['stops'].append(dict(ground=ground,watches=rows))
            result['resources'].append(dict(phase=ground['label'], processes={k:usage(v) for k,v in measured.items()}, load=os.getloadavg()))
            if index == 1:
                refused = client.tool('evaluate_language_expression', generation=result['stops'][0]['watches'][0]['observed_generation'], **args_, expression='$root->{player}{score}')['result']
                assert refused.get('isError') and refused['content'][0]['text']=='StaleSnapshot', refused
                result['stale_generation_refused'] = True
            client.action('continue')
        target.wait(timeout=10); assert target.returncode == 0 and lines.get(timeout=10)=='done magic=0\n', target.stderr.read()
        result['transcript'] = client.transcript; client.close(); client = None
        result['shared_observer'] = shared(root,work,command,env,args)
        result['stdio_observer'] = observer_stdio(command,env,args)
        result['measurement_status'] = 'not-measurable' if any(max(v['load'])>len(os.sched_getaffinity(0)) for v in result['resources']) else 'measured'
        result['measurement_phase'] = 'watch creation and seven cooperating stops including debugger run control and oracle checks'
        result['status'] = 'pass'
    finally:
        if client: result['transcript']=client.transcript; client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=5); result['target_stderr']=target.stderr.read()
        (work/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Perl paths: replacement, equality, full scalar bytes, refusal/recovery, shrink, stale generation and observer permissions passed')


def observer_stdio(command,env,args):
    target = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    client = None
    try:
        assert target.stdout.readline()=='ready\n'
        options = [*(['--runtime-agent',str(args.agent.resolve())] if args.agent else []),'--attach',str(target.pid)]
        client = Client('observe',None,options=options); generation=client.session()['generation']
        for tool,fields in [('add_language_watch',dict(language='perl',tid=target.pid,segment=0,frame=0,expression='$root->{player}{score}')),
                            ('remove_language_watch',dict(id=1))]:
            reply=client.tool(tool,generation=generation,**fields)['result']
            assert reply.get('isError') and reply['content'][0]['text']=='AgentScopeDenied',reply
        return dict(status='pass', direct_mutations_refused=True, transcript=client.transcript)
    finally:
        if client:client.close()
        if target.poll() is None:target.kill()
        target.wait(timeout=10)


def shared(root, work, command, env, args):
    spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
    s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
    (work/'run').mkdir(mode=0o700)
    server = SimpleNamespace(path=work/'run/s', clients=[]); process = None
    target = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    result = dict(status='running')
    try:
        assert target.stdout.readline() == 'ready\n'
        options = [str(root/'zig-out/bin/xodb'), '--headless', '--session-socket', str(server.path), '--agent-scope', 'control',
                   *(['--runtime-agent', str(args.agent.resolve())] if args.agent else []), '--attach', str(target.pid)]
        with (work/'server.log').open('wb') as log:
            process = subprocess.Popen(options, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+30
        while True:
            assert process.poll() is None, (work/'server.log').read_text()
            try: owner = s.Client(server, 'owner'); break
            except (FileNotFoundError, ConnectionRefusedError):
                assert time.monotonic() < deadline; time.sleep(.02)
        observer = s.Client(server, 'observer'); owner.claim(ttl_ms=60000)
        s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'], 'initial stop')
        source = root/'tests/fixtures/perl/watches.c'
        line = next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'WATCH_STOP' in text)
        owner.action('set_breakpoint', file=str(source), line=line); owner.action('continue')
        target.stdin.write('go\n'); target.stdin.flush()
        s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'] and any(t['reason']=='breakpoint' for t in v['threads']), 'path stop')
        deadline = time.monotonic()+60
        while True:
            reply = owner.raw('get_language_stack', tid=target.pid, language='perl')
            if not reply['result'].get('isError'): break
            s.expect_error(reply, 'DebugMetadataPending'); assert time.monotonic() < deadline; time.sleep(.01)
        stack = reply['result']['structuredContent']
        segment, frame = next((i,j) for i,part in enumerate(stack['segments']) for j,row in enumerate(part['frames']) if row['name']=='main::watched')
        generation = owner.session()['generation']
        call_args = dict(generation=generation, tid=target.pid, language='perl', segment=segment, frame=frame, expression='$root->{player}{score}')
        found = observer.tool('evaluate_language_expression', **call_args)
        assert found == owner.tool('evaluate_language_expression', **call_args) and found['rows'][0]['value']['display']=='IV 7', found
        s.expect_error(observer.raw('add_language_watch', **call_args), 'ControlLeaseRequired')
        created = owner.tool('add_language_watch', **call_args)['added']
        watched = owner.tool('get_language_watches'); assert watched == observer.tool('get_language_watches')
        s.expect_error(observer.raw('remove_language_watch', generation=generation, id=created), 'ControlLeaseRequired')
        owner.tool('release_session_control')
        assert observer.tool('get_language_watches') == watched
        assert observer.tool('evaluate_language_expression', **call_args) == found
        result.update(status='pass', direct_mutations_refused=True, reads_without_lease=True)
    finally:
        for client in server.clients: client.close()
        if process and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        if target.poll() is None: target.kill(); target.wait()
        result['transcripts'] = [client.transcript for client in server.clients]
    return result


if __name__ == '__main__':
    main()
