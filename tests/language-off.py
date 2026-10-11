#!/usr/bin/env python3
"""A language view turned off does nothing: its tools answer LanguageDisabled,
its tab is not offered, and the interpreter's image is never read in full.
The same stopped target with the view on reads the image and shows the stack.
Run: python3 tests/language-off.py --python /path/to/python3 --perl /path/to/perl --work out/off"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

PERL = '$| = 1; sub leaf { my $held = 42; my $line = <STDIN>; return $held } print "ready\\n"; leaf();'


def modules(client):
    regions, cursor = [], None
    while True:
        page = client.inspect('list_modules', **({'cursor': cursor} if cursor else {}))
        regions += page['regions']; cursor = page.get('next')
        if not cursor: return regions, page


def refused(client, name, **args):
    result = client.tool(name, **args)['result']
    assert result.get('isError'), (name, result)
    return result['content'][0]['text']


def tabs(client):
    deadline = time.monotonic() + 60
    while True:
        view = client.inspect('get_language_tabs')['view']
        if view['complete']: return {tab['tab']: tab for tab in view['tabs']}
        assert time.monotonic() < deadline, view
        time.sleep(.005)


def stack(client, language, **args):
    """The reply once symbol and metadata workers are done."""
    deadline = time.monotonic() + 60
    while True:
        result = client.tool('get_language_stack', language=language, **args)['result']
        why = result['content'][0]['text'] if result.get('isError') else None
        # Through the agent the native frames are short or unnamed until
        # their tables arrive, and such a stack has no interpreter frame yet.
        if not why and result['structuredContent']['segments']: return result['structuredContent']
        assert why in (None, 'SymbolDiscoveryPending', 'DebugMetadataPending'), why
        assert time.monotonic() < deadline, why
        time.sleep(.005)


def held(client, image):
    """Full-image bytes this xodb holds, and how the interpreter's file was opened."""
    regions, page = modules(client)
    sources = {r['file_source'] for r in regions if r['path'] == image}
    assert sources, (image, sorted({r['path'] for r in regions}))  # the interpreter is mapped under this name
    return page['image_bytes']['peak'], sources


def check(language, target, image, off, agent, result):
    """One stopped target, attached with the view off and then with it on."""
    tid = target.pid
    remote = ['--runtime-agent', str(agent)] if agent else []
    other = 'perl' if language == 'python' else 'python'
    for label, options in off:
        client = Client('control', None, options=[*remote, *options, '--attach', str(tid)])
        try:
            generation = client.stopped()['generation']
            before, _ = held(client, image)
            why = refused(client, 'get_language_stack', language=language, tid=tid)
            assert why == 'LanguageDisabled', why
            for name, extra in (('get_language_locals', {}), ('evaluate_language_expression', {'expression': 'held'})):
                why = refused(client, name, generation=generation, tid=tid, language=language, segment=0, frame=0, **extra)
                assert why == 'LanguageDisabled', (name, why)
            shown = tabs(client)
            assert shown[language]['status'] == 'disabled' and shown[language]['reason'] == 'LanguageDisabled' and not shown[language]['visible'], shown[language]
            # The switch is per language: the others were still looked for.
            after, sources = held(client, image)
            # No image was read in full for the view.
            assert after == before, (before, after)
            if label == 'enabled':
                # With every view off the interpreter's file is not opened at all.
                assert all(tab['status'] == 'disabled' for name, tab in shown.items() if name not in ('registers', 'native')), shown
                assert sources == {'unopened'}, sources
            else:
                # The switch is per language: the others were still looked
                # for, which reads symbols and no more.
                assert shown[other]['status'] == 'absent', shown[other]
            # Native debugging is unaffected.
            assert client.inspect('get_stack', tid=tid)['frames']
            assert client.session()['generation'] == generation
            result[f'{language}-{label}'] = {'error': why, 'tab': shown[language], 'image_bytes_peak': after, 'file_source': sorted(sources)}
        finally:
            client.close()
    client = Client('control', None, options=[*remote, '--attach', str(tid)])
    try:
        generation = client.stopped()['generation']
        before, _ = held(client, image)
        shown = tabs(client)
        assert shown[language]['status'] == 'ready' and shown[language]['visible'], shown[language]
        found = stack(client, language, tid=tid)
        names = [frame['name'] for segment in found['segments'] for frame in segment['frames']]
        assert any('leaf' in name for name in names), found
        after, sources = held(client, image)
        # The probe saw the condition: with the view on, the same calls read
        # the interpreter's image.
        assert after > before and sources != {'unopened'}, (before, after, sources)
        result[f'{language}-on'] = {'frames': names, 'tab': shown[language], 'image_bytes_peak': after, 'file_source': sorted(sources)}
    finally:
        client.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', required=True)
    p.add_argument('--perl', required=True)
    p.add_argument('--work', required=True, type=Path)
    p.add_argument('--agent', type=Path)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
    w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
    agent = a.agent.resolve() if a.agent else None
    configs = {}
    for name, value in (('python', {'python': False}), ('perl', {'perl': False}), ('enabled', {'enabled': False, 'perl': True})):
        configs[name] = w/f'{name}-off.json'
        configs[name].write_text(json.dumps({'languages': value}) + '\n')
    result = {'status': 'running'}
    started = time.monotonic()
    targets = []
    try:
        python = subprocess.Popen([a.python, 'tests/fixtures/python/budget.py'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        targets.append(python)
        assert python.stdout.readline(), python.stderr.read()
        check('python', python, os.path.realpath(a.python), (('config', ['--config', str(configs['python'])]), ('cli', ['--language-off', 'python'])), agent, result)
        perl = subprocess.Popen([a.perl, '-e', PERL], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        targets.append(perl)
        assert perl.stdout.readline() == 'ready\n', perl.stderr.read()
        check('perl', perl, os.path.realpath(a.perl), (('config', ['--config', str(configs['perl'])]), ('enabled', ['--config', str(configs['enabled'])])), agent, result)
        for target in targets:
            target.stdin.write('\n'); target.stdin.flush()
            target.wait(timeout=10); assert target.returncode == 0, target.stderr.read()
        result.update(status='pass', seconds=round(time.monotonic() - started, 2))
    finally:
        for target in targets:
            if target.poll() is None: target.kill(); target.wait()
        (w/'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Language off: Python and Perl refuse with LanguageDisabled, offer no tab and read no interpreter image (config, master switch and command line); on, the same targets show their stacks ({result["seconds"]} s)')


if __name__ == '__main__':
    main()
