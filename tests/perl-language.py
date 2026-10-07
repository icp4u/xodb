#!/usr/bin/env python3
"""Owned Perl 5.44 debug-build integration. No CPAN or system changes.
Run: python3 tests/perl-language.py --perl /path/to/debug/perl --work out/perl-test
The caller supplies an empty work directory; real-run evidence stays there.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import struct
import sys

from client import Client

ROOT = Path(__file__).resolve().parent.parent

def command(args, **kw):
    return subprocess.run([str(x) for x in args], check=True, timeout=60, **kw)

def records(path):
    return [json.loads(line) for line in path.read_text().splitlines()]

def logical(path):
    rows = records(path)
    functions = {r['id']: r for r in rows if r['type'] == 'function'}
    codes = {r['id']: r for r in rows if r['type'] == 'code'}
    stack = next(r for r in rows if r['type'] == 'stack')
    return [(functions[f['function']]['name'], codes[functions[f['function']]['code']]['path'], f['line']) for f in stack['frames']]

def identity_refusals(c, tid):
    """Alter and restore only this owned fixture's private stopped mappings."""
    def refused_byte(address, reason):
        old=c.inspect('read_memory',address=hex(address),length=1)['hex']
        try:
            c.action('write_memory',address=hex(address),hex=f'{int(old,16)^1:02x}')
            result=c.tool('get_language_stack',tid=tid,language='perl')
            assert result['result']['isError'] and result['result']['content'][0]['text']==reason,result
        finally:
            c.action('write_memory',address=hex(address),hex=old)
        assert c.inspect('get_language_stack',tid=tid,language='perl')['segments']
    version=c.inspect('find_symbol',name='PL_version')['address']
    refused_byte(int(version,16),'PerlVersionUnsupported')
    region=next(r for r in c.inspect('list_modules')['regions'] if r['offset']==0 and Path(r['path']).name=='libperl.so')
    data=Path(region['path']).read_bytes()
    assert data[:6]==b'\x7fELF\x02\x01'
    shoff=struct.unpack_from('<Q',data,40)[0]
    size,count,names=struct.unpack_from('<HHH',data,58)
    sections=[struct.unpack_from('<IIQQQQIIQQ',data,shoff+i*size) for i in range(count)]
    strings=data[sections[names][4]:sections[names][4]+sections[names][5]]
    note=next(s for s in sections if strings[s[0]:].split(b'\0',1)[0]==b'.note.gnu.build-id')
    phoff=struct.unpack_from('<Q',data,32)[0]
    psize,pcount=struct.unpack_from('<HH',data,54)
    headers=[struct.unpack_from('<IIQQQQQQ',data,phoff+i*psize) for i in range(pcount)]
    load=next(p for p in headers if p[0]==1 and p[2]==0)
    bias=region['start']-load[3]
    name_size,desc_size,kind=struct.unpack_from('<III',data,note[4])
    assert kind==3 and name_size==4 and desc_size>0 and data[note[4]+12:note[4]+16]==b'GNU\0'
    refused_byte(bias+note[3]+16,'PerlBuildIdMismatch')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--perl', required=True)
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    os.chdir(ROOT)
    work = args.work.resolve()
    work.mkdir(mode=0o755, parents=True, exist_ok=True)
    assert not list(work.iterdir()), 'work directory must be empty'
    config = json.loads(subprocess.check_output([args.perl, '-MConfig', '-MJSON::PP', '-e',
        'print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(version archlib cc ccflags useithreads usemultiplicity)})']))
    assert config['version'] == '5.44.0' and config['useithreads'] == 'define' and config['usemultiplicity'] == 'define', config
    (work/'config.json').write_text(json.dumps(config, indent=2)+'\n')
    reader = work/'lframes'
    command(['cc','-std=c11','-O2','-g','-Wall','-Wextra','-Werror','src/profile/logical_frames.c','src/profile/logical_frames_main.c','-o',reader])
    shared = work/'values.so'
    command([*shlex.split(config['cc']), *shlex.split(config['ccflags']), '-U_FORTIFY_SOURCE', '-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer',
             '-I'+config['archlib']+'/CORE','tests/fixtures/perl/values.c','-o',shared])
    checks = []
    def strict(path):
        command([reader,'validate',path,'--strict'], stdout=subprocess.DEVNULL)
    for mode in ['recursive','eval','thread','xs']:
        export = work/(mode+'.jsonl')
        command([args.perl,'tests/fixtures/perl/export.pl',mode,export])
        strict(export)
        frames = logical(export)
        assert frames and frames[0][0]=='main::leaf', frames
        if mode == 'recursive': assert len(frames)==7, frames
        if mode == 'xs':
            # List::Util::reduce invokes the Perl callback from XS, but caller()
            # does not expose the reduce frame. Do not invent that missing frame.
            assert any(r.get('frame_kind')=='unclassified' for r in records(export))
            assert 'can omit XS/native frames' in records(export)[0]['collection']['notes']
        checks.append('export '+mode)
    truncated = work/'truncated.jsonl'
    command([args.perl,'-e', 'require "./scripts/logical-frames/xodb_lframes.pl"; sub f { XodbLFrames::emit($ARGV[0],max_depth=>1) } f();', truncated])
    strict(truncated)
    assert next(r for r in records(truncated) if r['type']=='stack')['state']=='truncated'
    before = truncated.read_bytes()
    result = subprocess.run([args.perl,'tests/fixtures/perl/export.pl','recursive',str(truncated)], capture_output=True, timeout=30)
    assert result.returncode and truncated.read_bytes()==before and not list(work.glob('*.tmp.*'))
    result = subprocess.run([args.perl,'tests/fixtures/perl/export.pl','invalid-depth',str(work/'invalid.jsonl')], capture_output=True, timeout=30)
    assert result.returncode and not (work/'invalid.jsonl').exists()
    checks += ['export truncation', 'no overwrite or partial publication', 'invalid depth refusal']
    for mode in ['array','values','reenter','embed']:
        export = work/(mode+'-stopped.jsonl')
        p = subprocess.Popen([args.perl,'tests/fixtures/perl/stopped.pl',mode,str(shared),str(export)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        c = None
        try:
            assert select.select([p.stdout],[],[],10)[0], 'fixture ready timeout'
            assert p.stdout.readline()==b'ready\n', p.stderr.read().decode()
            strict(export)
            c = Client('mutate' if mode=='values' else 'control', None, options=['--attach', str(p.pid)])
            tools = c.call('tools/list')['result']['tools']
            definition = next(t for t in tools if t['name']=='get_language_stack')
            assert definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer'
            if mode=='array': c.action('set_breakpoint', symbol='Perl_av_store')
            else:
                source=Path('tests/fixtures/perl/values.c')
                line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if '__asm__ volatile' in s)
                c.action('set_breakpoint',file=str(source),line=line)
            c.action('continue'); p.stdin.write(b'go\n');p.stdin.flush();c.stopped('breakpoint')
            retained_generation=c.session()['generation']
            registers=c.inspect('get_registers',tid=p.pid)
            native = c.inspect('get_stack',tid=p.pid)['frames']
            result = c.inspect('get_language_stack',tid=p.pid,language='perl')
            (work/(mode+'-language.json')).write_text(json.dumps(result,indent=2)+'\n')
            segments = result['segments'];assert segments, result
            for segment in segments:
                anchor=segment['anchor'];assert anchor and native[anchor['frame']]['pc']==int(anchor['pc'],16)
                assert segment['runtime']['build_id'] and segment['runtime_instance']['kind']=='address'
                assert segment['memory_reads']<=8192 and segment['memory_bytes']<=512*1024
            if mode == 'array':
                assert len(segments)==1 and segments[0]['state']=='complete',segments
                actual=[(f['name'],f['file'],f['line']) for f in segments[0]['frames']]
                assert actual==logical(export),(actual,logical(export))
                value=c.inspect('evaluate_expression',tid=p.pid,frame=0,expression='val')['value']
                assert value['visualization']['perl']['type']=='undef' and value['display'].startswith('undef ('),value
                assert value['visualization']['perl']['refcount']==1 and value['visualization']['perl']['flags']==0,value
            else:
                values={name:c.inspect('evaluate_expression',tid=p.pid,frame=0,expression=name)['value'] for name in
                        ['integer','number','string','reference','array','hash','code','glob']}
                (work/(mode+'-values.json')).write_text(json.dumps(values,indent=2)+'\n')
                for name,kind in zip(values,['IV','NV','PV','RV','AV','HV','CV','GV']):
                    assert values[name]['visualization']['perl']['type']==kind,(name,values[name])
                    assert values[name]['diagnostic'] is None,(name,values[name])
                assert values['integer']['display'].startswith('IV 42 ('), values['integer']
                assert values['number']['display'].startswith('NV 3.25 ('),values['number']
                assert values['glob']['display'].startswith('Fixture::Nested::Widget::entry ('), values['glob']
                for name in ('reference', 'hash'):
                    assert values[name]['visualization']['perl']['class_name'] == 'Fixture::Nested::Widget', values[name]
                    assert values[name]['display'].startswith('Fixture::Nested::Widget '), values[name]
                assert 'hello\\x00bytes' in values['string']['display'],values['string']
                assert values['array']['visualization']['perl']['items'][3]['display']=='IV 42',values['array']
                assert any(i['key']=='answer' and i['display']=='IV 42' for i in values['hash']['visualization']['perl']['items']), values['hash']
                if mode=='reenter':
                    assert len(segments)==1 and segments[0]['state']=='partial' and segments[0]['additional_anchors'],segments
                    assert segments[0]['reason']=='RepeatedInterpreterAnchorBoundaryUnavailable',segments
                    # Selecting an outer frame must not forget a recovered inner
                    # runops anchor of this same interpreter instance.
                    first = max(a['frame'] for a in segments[0]['additional_anchors'])
                    outer = c.inspect('get_language_stack', tid=p.pid, language='perl', frame=first)
                    (work/'reenter-selected-language.json').write_text(json.dumps(outer, indent=2)+'\n')
                    assert len(outer['segments']) == 1, outer
                    selected = outer['segments'][0]
                    assert selected['anchor']['frame'] == first, selected
                    assert selected['state'] == 'partial' and selected['reason'] == 'RepeatedInterpreterAnchorBoundaryUnavailable', selected
                    assert any(a['frame'] == segments[0]['anchor']['frame'] for a in selected['additional_anchors']), selected

                elif mode=='embed':
                    assert len(segments)==2 and segments[0]['runtime_instance']!=segments[1]['runtime_instance'],segments
                    outer = c.inspect('get_language_stack', tid=p.pid, language='perl', frame=segments[1]['anchor']['frame'])
                    assert len(outer['segments']) == 1, outer
                    assert outer['segments'][0]['runtime_instance'] == segments[1]['runtime_instance'], outer
                    assert outer['segments'][0]['state'] == segments[1]['state'] and outer['segments'][0]['reason'] == segments[1]['reason'], outer

                else: assert len(segments)==1,segments
            stale=c.tool('get_language_stack',tid=p.pid,language='perl',generation=0)
            assert stale['result']['isError'],stale
            invalid=c.tool('get_language_stack',tid=p.pid,language='python')
            assert 'error' in invalid or invalid['result']['isError'],invalid
            assert c.inspect('get_registers',tid=p.pid)==registers and c.session()['generation']==retained_generation
            if mode=='values':
                identity_refusals(c,p.pid)
                checks.append('live version/build-id mismatch refusal and restoration')
            checks.append('stopped '+mode)
        finally:
            if c:
                (work/(mode+'-transcript.json')).write_text(json.dumps(c.transcript,indent=2)+'\n')
                c.close()
            if p.poll() is None:p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
            (work/(mode+'-stderr.txt')).write_bytes(p.stderr.read())
    for mode in ['ppentry', 'xsentry', 'deep300', 'deep5000', 'evalblock', 'evalstring', 'try', 'thread']:
        p = subprocess.Popen([args.perl, 'tests/fixtures/perl/contexts.pl', mode, str(shared)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        c = None
        try:
            assert select.select([p.stdout], [], [], 10)[0], 'context fixture ready timeout'
            assert p.stdout.readline() == b'ready\n', p.stderr.read().decode()
            c = Client('control', None, options=['--attach', str(p.pid)])
            if mode in ('ppentry', 'xsentry'):
                c.action('set_breakpoint', symbol='Perl_pp_getppid')
            else:
                source = Path('tests/fixtures/perl/values.c')
                line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if '__asm__ volatile' in text)
                c.action('set_breakpoint', file=str(source), line=line)
            c.action('continue'); p.stdin.write(b'go\n'); p.stdin.flush()
            stopped = c.stopped('breakpoint')
            tid = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'breakpoint')
            before = c.inspect('get_registers', tid=tid)
            result = c.inspect('get_language_stack', tid=tid, language='perl')
            (work/(mode+'-language.json')).write_text(json.dumps(result, indent=2)+'\n')
            segments = result['segments']
            assert segments and c.inspect('get_registers', tid=tid) == before
            if mode in ('ppentry', 'xsentry'):
                assert all(s['state'] == 'partial' and s['reason'] for s in segments), segments
                unresolved = [s for s in segments if s['anchor'] is not None and s['runtime_instance'] is None]
                assert unresolved, segments
                if mode == 'ppentry':
                    assert any(s['anchor'] is None and s['frames'] and s['runtime_instance'] for s in segments), segments
                for unknown in unresolved:
                    for outer in segments:
                        if outer['anchor'] and outer['anchor']['frame'] > unknown['anchor']['frame'] and outer['runtime_instance']:
                            assert outer['reason'] == 'InnerInterpreterAnchorUnresolved', outer
            elif mode.startswith('deep'):
                assert len(segments) == 1, segments
                segment = segments[0]
                assert segment['state'] == 'partial' and segment['reason'] == 'FrameLimit', segment
                assert len(segment['frames']) == 128 and segment['memory_reads'] < 4096, segment
            else:
                assert all(s['state'] == 'complete' and s['reason'] is None for s in segments), segments
                context_type = 'try' if mode == 'try' else 'eval'
                assert any(f['context_type'] == context_type for s in segments for f in s['frames']), segments
                if mode == 'try':
                    assert any(f['name'] == '(try)' and f['context_type'] == 'try' for s in segments for f in s['frames']), segments
            checks.append('stopped contexts '+mode)
        finally:
            if c:
                (work/(mode+'-transcript.json')).write_text(json.dumps(c.transcript, indent=2)+'\n')
                c.close()
            if p.poll() is None: p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
            (work/(mode+'-stderr.txt')).write_bytes(p.stderr.read())
    preserved = work/'preserve-exception.jsonl'
    command([args.perl, '-e', 'require "./scripts/logical-frames/xodb_lframes.pl"; $@="previous error"; XodbLFrames::emit($ARGV[0]); die "clobbered" unless $@ eq "previous error";', preserved])
    strict(preserved)
    checks.append('export preserves caller exception')
    (work/'results.json').write_text(json.dumps({'pass':checks,'fail':[],'skip':[]},indent=2)+'\n')
    print(f'{len(checks)} Perl integration checks passed')

if __name__ == '__main__':
    main()
