#!/usr/bin/env python3
"""Stopped interpreter identity: fast twin regressions, periodic policy matrix."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time

from client import Client
from helpers.input import load_scale
from helpers import orphans


def check(condition, detail):
    if not condition:
        raise AssertionError(detail)


def build_id(path):
    output = subprocess.check_output(['readelf', '-n', str(path)], text=True)
    for line in output.splitlines():
        if 'Build ID:' in line:
            return line.split()[-1]
    raise AssertionError('fixture image has no build ID')


def twin(source, target):
    data = bytearray(source.read_bytes())
    ident = bytes.fromhex(build_id(source))
    offset = data.find(ident)
    check(offset > 0 and data.find(ident, offset + 1) < 0, 'unique build ID')
    data[offset + len(ident) - 1] ^= 0xff
    target.write_bytes(data)
    target.chmod(0o755)


def inside(pc, ranges):
    return any(int(lo, 0) <= pc < int(hi, 0) and 'x' in permissions
               for lo, hi, permissions in ranges)


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().split(')', 1)[1].split()
    rss = int(Path(f'/proc/{pid}/statm').read_text().split()[1]) * os.sysconf('SC_PAGE_SIZE')
    return dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'), rss_bytes=rss)


def native_stack(client, tid, scale):
    # A process-level ambiguity now returns before any thread walk. The agent
    # can therefore still be loading metadata when the oracle asks for frames.
    deadline = time.monotonic() + 90*scale
    while True:
        result = client.inspect('get_stack', tid=tid)
        if not any((frame.get('diagnostic') or '').endswith('Pending') for frame in result['frames']):
            return result
        check(time.monotonic() < deadline, ('native metadata did not settle', result))
        time.sleep(.005)


NO_RUNTIME = r"""/* Owned synthetic program without any interpreter: one executable memfd
 * mapping, as a JIT would make, then it blocks on stdin. */
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
int main(void) {
    int fd = memfd_create("jit", 0);
    if (fd < 0 || ftruncate(fd, 8192)) return 2;
    if (mmap(NULL, 8192, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0) == MAP_FAILED) return 2;
    puts("ready"); fflush(stdout);
    char line[8]; return fgets(line, sizeof line, stdin) ? 0 : 1;
}
"""


def no_runtime(a, w, scale, rows):
    """An unexaminable mapping in a program with no interpreter is not a
    detected runtime: both tabs stay absent, while a direct request refuses."""
    (w/'no-runtime.c').write_text(NO_RUNTIME)
    subprocess.run(['cc', '-g', '-O1', str(w/'no-runtime.c'), '-o', str(w/'no-runtime')], check=True, timeout=60*scale)
    target = subprocess.Popen([str(w/'no-runtime')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    row = dict(language='none', mode='memfd', decoy='none', status='running')
    rows.append(row)
    client = None
    try:
        check(target.stdout.readline() == 'ready\n', 'plain fixture readiness')
        maps = Path(f'/proc/{target.pid}/maps').read_text().splitlines()
        check(any('memfd:jit' in line and 'x' in line.split()[1] for line in maps), 'executable memfd mapping observed')
        options = ['--attach', str(target.pid)]
        if a.agent:
            options += ['--runtime-agent', str(a.agent.resolve())]
        client = Client('control', None, options=options, reply_seconds=90*scale)
        client.stopped(seconds=60*scale)
        deadline = time.monotonic()+90*scale
        while True:
            view = client.inspect('get_language_tabs')['view']
            if view['complete']:
                break
            check(time.monotonic() < deadline, ('discovery did not finish', view))
            time.sleep(.005)
        for language in ('python', 'perl'):
            tab = next(item for item in view['tabs'] if item['tab'] == language)
            row[language] = tab
            wanted = ('unavailable', language.title()+'ModuleIdentityUnavailable') if a.wrong_result else ('absent', 'RuntimeNotDetected')
            check((tab['status'], tab['reason']) == wanted and not tab['visible'] and tab['identity'] is None, tab)
            refused = client.tool('get_language_stack', language=language, tid=target.pid)['result']
            check(refused.get('isError') and refused['content'][0]['text'] == language.title()+'ModuleIdentityUnavailable', refused)
        row['status'] = 'pass'
    finally:
        if row['status'] == 'running':
            row['status'] = 'fail'
        if client:
            client.close()
        if target.poll() is None:
            target.kill()
        target.wait(timeout=30*scale)


def early_exit(a, w, scale, rows, exe, source, prefix):
    """The thread pass stops once its answer is fixed. With the same parked
    threads, an executing sole runtime settles without walking them all, while
    an idle one (no witness anywhere) must visit every thread."""
    parked = 96
    calls = {}
    row = dict(language='python', mode='early-exit', decoy='none', status='running', parked=parked)
    rows.append(row)
    for mode in ('idle', 'none'):
        own = w/f'early-{mode}'
        own.mkdir()
        real = own/source.name
        shutil.copyfile(source, real)
        real.chmod(0o755)
        target = subprocess.Popen([str(exe), 'python', mode, str(real), '-', str(parked)], env=dict(os.environ, PYTHONHOME=prefix),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        client = None
        try:
            for _ in range(2):
                check(target.stdout.readline(), 'early-exit fixture readiness')
            options = ['--attach', str(target.pid)]
            if a.agent:
                options += ['--runtime-agent', str(a.agent.resolve())]
            client = Client('control', None, options=options, reply_seconds=90*scale)
            client.stopped(seconds=60*scale)
            check(len(client.session()['threads']) > parked, 'parked threads observed')
            deadline = time.monotonic()+120*scale
            count = 0
            while True:  # no sleep: about one discovery poll per call
                view = client.inspect('get_language_tabs')['view']
                count += 1
                if view['complete']:
                    break
                check(time.monotonic() < deadline, ('discovery did not finish', view))
            tab = next(item for item in view['tabs'] if item['tab'] == 'python')
            check(tab['status'] == ('unwitnessed' if mode == 'idle' else 'ready'), tab)
            calls[mode] = count
        finally:
            if client:
                client.close()
            if target.poll() is None:
                target.kill()
            target.wait(timeout=30*scale)
    row.update(calls=calls)
    if a.wrong_result:
        calls['none'] = calls['idle']
    # Under heavy load several polls fit in one call and the idle pass is too
    # short to compare: not measurable, rather than a failure.
    row['measurable'] = calls['idle'] >= parked // 4
    if row['measurable']:
        check(calls['none'] * 4 <= calls['idle'] * 3, ('an executing sole runtime walked every thread', calls))
    row['status'] = 'pass'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--perl', required=True)
    p.add_argument('--python', default=sys.executable, help='Shared-library Python for the embedder')
    p.add_argument('--agent', type=Path)
    p.add_argument('--matrix', action='store_true')
    p.add_argument('--only', help='language:mode:decoy, for example python:anon:twin')
    p.add_argument('--wrong-result', action='store_true')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    os.umask(0o022)
    orphans.adopt()
    w = a.work.resolve()
    w.mkdir(parents=True, mode=0o755)
    scale = load_scale()
    prefix, libdir, soname = json.loads(subprocess.check_output([
        a.python, '-c', 'import sys,sysconfig,json; print(json.dumps([sys.prefix,sysconfig.get_config_var("LIBDIR"),sysconfig.get_config_var("LDLIBRARY")]))'], text=True))
    libraries = {'python': Path(libdir)/soname,
                 'perl': Path(subprocess.check_output([a.perl, '-MConfig', '-e', 'print "$Config{archlibexp}/CORE/$Config{libperl}"'], text=True))}
    for language, library in libraries.items():
        check(library.is_file() and '.so' in library.name, (language, 'shared runtime required'))
    exe = w/'embedder'
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wl,--build-id',
                    'tests/fixtures/pe/runtime-binding.c', '-ldl', '-pthread', '-o', str(exe)], check=True, timeout=60*scale)
    rows = []
    began = time.monotonic()
    # The fast lane covers cooperative targets: ordinary JIT mappings beside
    # one runtime, and two loaded runtimes whose stopped threads identify the
    # instance they use. Hostile mapping/return-address cases stay periodic.
    cases = [('memfdextra', 'none'), ('deletedextra', 'none'), ('none', 'twin'), ('both', 'twin')]
    if a.matrix:
        cases += [('pehdr', 'twin'), ('anon', 'twin'), ('forged', 'twin'), ('leafra', 'twin'),
                  ('none', 'none'), ('idle', 'none'), ('idle', 'twin'),
                  ('threads', 'none'), ('stripped', 'none'), ('transition', 'none')]
    if a.only:
        requested_language, mode, decoy = a.only.split(':')
        cases = [(mode, decoy)]
    else:
        requested_language = None
    result = dict(status='running', rows=rows, load=os.getloadavg(), cpus=os.cpu_count())
    try:
        if not a.only:
            no_runtime(a, w, scale, rows)
        if a.matrix and not a.only:
            early_exit(a, w, scale, rows, exe, libraries['python'], prefix)
        for language, source in libraries.items():
            if requested_language and language != requested_language:
                continue
            for mode, kind in cases:
                if mode == 'stripped' and language != 'python':
                    continue  # Only CPython publishes its layout without DWARF.
                own = w/f'{language}-{mode}-{kind}'
                own.mkdir()
                real = own/source.name
                shutil.copyfile(source, real)
                real.chmod(0o755)
                if mode == 'stripped':
                    subprocess.run(['strip', '--strip-debug', str(real)], check=True, timeout=30*scale)
                real_id = build_id(real)
                bait = own/('twin-'+source.name)
                bait_id = None
                if kind == 'twin':
                    twin(source, bait)
                    bait_id = build_id(bait)
                    check(real_id != bait_id, 'twin must have a distinct build ID')
                target = subprocess.Popen([str(exe), language, 'none' if mode == 'stripped' else mode, str(real), str(bait) if bait_id else '-'],
                                          env=dict(os.environ, PYTHONHOME=prefix), stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                lines = queue.Queue()
                def drain(stream=target.stdout):
                    for line in stream:
                        lines.put(line)
                reader = threading.Thread(target=drain, daemon=True)
                reader.start()
                client = None
                row = dict(language=language, mode=mode, decoy=kind, status='running')
                rows.append(row)
                try:
                    ranges = json.loads(lines.get(timeout=30*scale))
                    check(json.loads(lines.get(timeout=30*scale)) == {'ready': 1}, 'runtime readiness')
                    if mode in ('forged', 'leafra'):
                        check(json.loads(lines.get(timeout=30*scale)) == {'blinded': 1}, 'real interpreter read truncated its frame record')
                        check(ranges['twin'] and (mode == 'leafra' or ranges['forged_tid'] > 0), 'forged return target exists')
                    if mode == 'both':
                        check(json.loads(lines.get(timeout=30*scale)) == {'ready': 1}, 'second runtime readiness')
                    check(ranges['real'], 'recorded real-runtime mappings')
                    maps = Path(f'/proc/{target.pid}/maps').read_text().splitlines()
                    if mode == 'pehdr':
                        check(real.read_bytes()[:2] == b'MZ' and real.read_bytes()[64:68] == b'PE\0\0', 'PE header mutation happened')
                    if mode == 'anon':
                        check(not any(str(real) in line for line in maps), 'real image lost every file mapping')
                        for lo, hi, perms in ranges['real']:
                            if 'x' not in perms:
                                continue
                            matching = [line.split() for line in maps if int(line.split('-')[0], 16) <= int(lo, 0) < int(line.split()[0].split('-')[1], 16)]
                            check(matching and all(fields[4] == '0' for fields in matching), 'executing real image is anonymous')
                    if mode == 'memfdextra':
                        check(any('memfd:jit' in line and 'x' in line.split()[1] for line in maps), 'executable JIT memfd observed beside runtime')
                    if mode == 'deletedextra':
                        check(any('xodb-jit-' in line and '(deleted)' in line and 'x' in line.split()[1] for line in maps), 'deleted executable mapping observed beside runtime')
                    options = ['--attach', str(target.pid)]
                    if a.agent:
                        options += ['--runtime-agent', str(a.agent.resolve())]
                    client = Client('control', None, options=options, reply_seconds=90*scale)
                    client.stopped(seconds=60*scale)
                    measured = {'frontend': client.p.pid}
                    if a.agent:
                        measured['agent'] = client.collector_pid()
                    before = {name: usage(pid) for name, pid in measured.items()}
                    deadline = time.monotonic()+90*scale
                    worst_call = 0
                    calls = 0
                    while True:
                        started = time.monotonic()
                        tabs = client.inspect('get_language_tabs')
                        worst_call = max(worst_call, time.monotonic()-started)
                        calls += 1
                        if tabs['view']['complete']:
                            break
                        check(time.monotonic() < deadline, ('discovery did not finish', tabs))
                        time.sleep(.005)
                    tab = next(item for item in tabs['view']['tabs'] if item['tab'] == language)
                    native = native_stack(client, target.pid, scale)
                    frames = native['frames']
                    pcs = [int(frame['lookup_pc'], 0) if isinstance(frame['lookup_pc'], str) else frame['lookup_pc'] for frame in frames]
                    real_seen = any(inside(pc, ranges['real']) for pc in pcs)
                    twin_seen = any(inside(pc, ranges['twin']) for pc in pcs)
                    check(twin_seen == (mode == 'leafra'), 'the planted leaf return diverts the executing thread into the twin')
                    if mode == 'leafra':
                        row['main_frames'] = frames
                        row['real_frame_seen'] = real_seen
                        row['twin_frame_seen'] = twin_seen
                        if language == 'python':
                            check(not real_seen, 'forged leaf return hides the executing runtime')
                        check(any(str(real) in line and 'x' in line.split()[1] for line in maps), 'real runtime still discoverable')
                        check(any(str(bait) in line and 'x' in line.split()[1] for line in maps), 'twin still discoverable')
                        row['forged_twin_frame_seen'] = True
                        row['main_frames'] = frames
                        row['forged_leaf_return_observed'] = True
                        if language == 'perl' and real_seen:
                            refused = client.tool('get_language_stack', language=language, tid=target.pid)['result']
                            check(refused.get('isError') and refused['content'][0]['text'] == 'PerlValueRuntimeAmbiguous', refused)
                        else:
                            specific = client.inspect('get_language_stack', language=language, tid=target.pid)
                            check(specific['identity'] == 'witnessed' and specific['segments'], specific)
                            check(all(seg['runtime']['build_id'] == bait_id for seg in specific['segments']), 'thread follows its witnessed runtime image')
                    if mode == 'forged':
                        forged_frames = native_stack(client, ranges['forged_tid'], scale)['frames']
                        forged_pcs = [int(f['lookup_pc'], 0) if isinstance(f['lookup_pc'], str) else f['lookup_pc'] for f in forged_frames]
                        row['forged_frames'] = forged_frames
                        check(any(inside(pc, ranges['twin']) for pc in forged_pcs), 'forged twin frame observed by the unwinder')
                        check(not real_seen, 'real interpreter unwind was actually blinded')
                        check(any(str(real) in line and 'x' in line.split()[1] for line in maps), 'real runtime still discoverable')
                        check(any(str(bait) in line and 'x' in line.split()[1] for line in maps), 'twin still discoverable')
                        row['forged_twin_frame_seen'] = True
                        refused = client.tool('get_language_stack', language=language, tid=target.pid)['result']
                        expected = language.title()+'InterpreterFrameUnavailable'
                        check(refused.get('isError') and refused['content'][0]['text'] == expected, refused)
                    if mode == 'both':
                        other_pcs = []
                        for thread in client.session()['threads']:
                            frames_ = native_stack(client, thread['tid'], scale)['frames']
                            other_pcs += [int(f['lookup_pc'], 0) if isinstance(f['lookup_pc'], str) else f['lookup_pc'] for f in frames_]
                        check(any(inside(pc, ranges['twin']) for pc in other_pcs), 'second runtime is actually executing')
                        thread_stacks = []
                        for thread in client.session()['threads']:
                            native_ = native_stack(client, thread['tid'], scale)['frames']
                            pcs_ = [int(f['lookup_pc'], 0) if isinstance(f['lookup_pc'], str) else f['lookup_pc'] for f in native_]
                            owns_twin = any(inside(pc, ranges['twin']) for pc in pcs_)
                            owns_real = any(inside(pc, ranges['real']) for pc in pcs_)
                            if not owns_twin and not owns_real:
                                continue
                            expected_id = bait_id if owns_twin else real_id
                            specific = client.inspect('get_language_stack', language=language, tid=thread['tid'])
                            check(specific['identity'] == 'witnessed' and specific['segments'], specific)
                            check(all(seg['runtime']['build_id'] == expected_id for seg in specific['segments']), 'thread binds its own executing image')
                            thread_stacks.append(expected_id)
                        check(set(thread_stacks) == {real_id, bait_id}, 'both distinct runtime bindings observed')
                    if mode == 'threads':
                        check(len(client.session()['threads']) >= 33, 'many-thread condition observed')
                    if mode != 'leafra':
                        check(real_seen == (mode not in ('idle', 'forged')), ('fixture execution evidence', mode, pcs, ranges))
                    if a.wrong_result:
                        ambiguous_tab = mode in ('both', 'idle') or (mode == 'leafra' and language == 'perl')
                        tab = dict(tab, status='ready', identity='witnessed', reason=None, build_id=real_id) if ambiguous_tab else dict(tab, status='unavailable', reason=language.title()+'RuntimeAmbiguous')
                    row.update(tab=tab, real_frame_seen=real_seen, twin_frame_seen=twin_seen,
                               calls=calls, worst_call_seconds=worst_call,
                               resources_before=before, resources_after={name: usage(pid) for name, pid in measured.items()})
                    if (mode in ('both', 'idle') and kind == 'twin') or (mode == 'leafra' and language == 'perl'):
                        check(tab['status'] == 'unavailable' and tab['reason'].endswith('Ambiguous'), tab)
                    elif mode in ('forged', 'leafra') and kind == 'twin':
                        check(tab['status'] == 'ready' and tab['identity'] == 'witnessed' and tab['build_id'] == bait_id, tab)
                    elif mode in ('pehdr', 'anon', 'idle'):
                        check(tab['status'] == 'unwitnessed' and tab['identity'] == 'unwitnessed' and tab['reason'] == 'RuntimeNotSeenExecuting', tab)
                        check(tab['visible'] and tab['proof_generation'] is None, tab)
                        check(tab['build_id'] == (bait_id if kind == 'twin' else real_id), tab)
                        stack = client.tool('get_language_stack', language=language, tid=target.pid)['result']
                        check(stack.get('isError') and stack['content'][0]['text'] == language.title()+'InterpreterFrameUnavailable', stack)
                    else:
                        check(tab['status'] == 'ready' and tab['identity'] == 'witnessed' and tab['build_id'] == real_id, tab)
                        stack = client.inspect('get_language_stack', language=language, tid=target.pid)
                        check(stack['identity'] == 'witnessed' and stack['segments'], stack)
                        check(all(segment['runtime']['build_id'] == real_id for segment in stack['segments']), stack)
                    if mode == 'idle' and kind == 'none':
                        frame_index = next(i for i, f in enumerate(frames) if f['symbol'] == 'dormant_checkpoint')
                        value = client.inspect('evaluate_expression', tid=target.pid, frame=frame_index,
                                               expression='fixture_'+language+'_value')['value']
                        check(value['visualization']['identity'] == 'unwitnessed', value)
                        check(value['visualization'][language]['runtime_build_id'] == real_id, value)
                        check('42' in value['display'] or (language == 'python' and value['visualization']['python']['type'] == 'dict'), value)
                        row['dormant_preview'] = value
                    if mode == 'transition':
                        segment_index, frame_index = next((si, fi) for si, segment in enumerate(stack['segments'])
                                                         for fi, frame in enumerate(segment['frames']) if 'definer_checkpoint' in frame['name'])
                        added = client.action('add_language_watch', language=language, tid=target.pid,
                                              segment=segment_index, frame=frame_index,
                                              expression='held' if language == 'python' else '$held')['added']
                        initial_watch = next(item for item in client.inspect('get_language_watches')['watches'] if item['id'] == added)
                        check(initial_watch['runtime']['identity'] == 'witnessed' and '42' in initial_watch['current']['display'], initial_watch)
                        old_epoch = client.session()['image_epoch']
                        client.continue_initial_stop()
                        running = client.inspect('get_language_tabs')['view']
                        check(next(t for t in running['tabs'] if t['tab'] == language)['status'] != 'ready', running)
                        target.stdin.write('go\n'); target.stdin.flush()
                        check(json.loads(lines.get(timeout=30*scale)) == {'ready': 1}, 'dormant transition reached')
                        client.action('interrupt'); dormant_stop = client.stopped()
                        deadline = time.monotonic()+60*scale
                        while True:
                            view = client.inspect('get_language_tabs')['view']
                            watched = next(item for item in client.inspect('get_language_watches')['watches'] if item['id'] == added)
                            if view['complete'] and watched['observed_generation'] == dormant_stop['generation'] and watched.get('runtime'):
                                break
                            check(time.monotonic() < deadline, (view, watched))
                            time.sleep(.005)
                        dormant_tab = next(t for t in view['tabs'] if t['tab'] == language)
                        check(dormant_tab['status'] == 'unwitnessed' and dormant_tab['identity'] == 'unwitnessed', dormant_tab)
                        check(watched['runtime']['identity'] == 'unwitnessed' and watched['diagnostic'] == 'RuntimeNotSeenExecuting', watched)
                        check(watched['current'] == initial_watch['current'], 'dormant watch retains history without an unproved fresh read')
                        refused = client.tool('get_language_stack', language=language, tid=target.pid)['result']
                        check(refused.get('isError') and refused['content'][0]['text'] == language.title()+'InterpreterFrameUnavailable', refused)
                        client.continue_initial_stop(); target.stdin.write('exec\n'); target.stdin.flush()
                        after_exec = client.stopped()
                        check(after_exec['image_epoch'] != old_epoch, 'exec image epoch changed')
                        client.continue_initial_stop()
                        ranges_after = json.loads(lines.get(timeout=30*scale))
                        check(json.loads(lines.get(timeout=30*scale)) == {'ready': 1}, 'runtime executing after exec')
                        client.action('interrupt'); client.stopped()
                        deadline = time.monotonic()+60*scale
                        while True:
                            view = client.inspect('get_language_tabs')['view']
                            if view['complete']:
                                break
                            check(time.monotonic() < deadline, view)
                            time.sleep(.005)
                        rebound = next(t for t in view['tabs'] if t['tab'] == language)
                        check(rebound['status'] == 'ready' and rebound['identity'] == 'witnessed' and rebound['build_id'] == real_id, rebound)
                        current_native = client.inspect('get_stack', tid=target.pid)['frames']
                        check(any(inside(int(f['lookup_pc'], 0) if isinstance(f['lookup_pc'], str) else f['lookup_pc'], ranges_after['real']) for f in current_native), 'new image execution observed')
                        row['transition'] = dict(dormant=dormant_tab, watch=watched, rebound=rebound)
                    row['status'] = 'pass'
                finally:
                    if row['status'] == 'running':
                        row['status'] = 'fail'
                    if client:
                        client.close()
                    if target.poll() is None:
                        target.kill()
                    target.wait(timeout=30*scale)
                    reader.join(timeout=5*scale)
                    row['fixture_stderr'] = target.stderr.read()
        result['status'] = 'pass'
    except BaseException as exc:
        result.update(status='fail', error=repr(exc))
        raise
    finally:
        result['seconds'] = time.monotonic()-began
        (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
        check(orphans.reap(), 'owned fixture descendants remain')
    print(json.dumps(dict(status='pass', checks=len(rows), seconds=result['seconds'])))


if __name__ == '__main__':
    main()
