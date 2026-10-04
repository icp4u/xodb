#!/usr/bin/env python3
"""Prepare (unprivileged), then explicitly run a configured T17 experiment.

--prepare compiles an isolated copy. --run PATH uses sudo for comparative credential contexts against an already
configured host. The runner itself changes no mounts, sysctls or file capabilities.
"""
from datetime import datetime
from pathlib import Path
import argparse, hashlib, json, os, pwd, re, shlex, subprocess, sys, time
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/fixtures/syscall-context'

def run_cmd(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare():
    work = ROOT / '.work' / ('t17-configured-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
    source = work / 'source'; source.mkdir(parents=True)
    (work/'tmp').mkdir()
    for name in ('build.zig', 'syscall_obs.zig', 'probe.zig', 'fixture.c'):
        text = (SOURCE/name).read_text()
        if name == 'probe.zig':
            # waitpid(WNOHANG)==0 has NOT reaped a child. Keep ownership on
            # errors; a failed timed reap must not become a successful trace.
            text = text.replace('if (err == .SUCCESS or err == .CHILD) break;',
                'if (err == .CHILD or (err == .SUCCESS and rc == @as(usize, @intCast(self.child)))) break;\n'
                '                var delay = linux.timespec{ .sec = 0, .nsec = 1_000_000 };\n'
                '                _ = linux.nanosleep(&delay, null);')
            text = text.replace('    owned.child = -1;\n    _ = linux.ioctl',
                '    if (!reaped) { print("RESULT trace status=error stage=reap\\n", .{}); return 1; }\n'
                '    owned.child = -1;\n    _ = linux.ioctl')
        (source/name).write_text(text)
    env = dict(os.environ, TMPDIR=str(work/'tmp'), ZIG_GLOBAL_CACHE_DIR=str(work/'global'))
    p = subprocess.run(['zig','build','test','probe','-Doptimize=ReleaseSafe','--cache-dir',str(work/'cache'),'--prefix',str(work/'out')], cwd=source, env=env, text=True, capture_output=True, timeout=180)
    (work/'build.log').write_text(p.stdout+p.stderr); p.check_returncode()
    p = run_cmd(['cc','-O2','-Wall','-Wextra','-Werror',str(source/'fixture.c'),'-o',str(work/'fixture')],env=env)
    (work/'cc.log').write_text(p.stdout+p.stderr); p.check_returncode()
    manifest = dict(uid=os.getuid(), user=pwd.getpwuid(os.getuid()).pw_name, namespace=os.readlink('/proc/self/ns/mnt'),
        hashes={str(p.relative_to(ROOT)):digest(p) for p in [Path(__file__),work/'fixture',work/'out/bin/probe',*source.iterdir()] if p.is_file()},
        original_hashes={name:digest(SOURCE/name) for name in ('build.zig','syscall_obs.zig','probe.zig','fixture.c')})
    (work/'prepared.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(work)

def check(work):
    work = Path(work).resolve()
    assert work.parent == ROOT/'.work' and work.name.startswith('t17-configured-')
    manifest = json.loads((work/'prepared.json').read_text())
    for name, expected in manifest['hashes'].items():
        assert digest(ROOT/name) == expected, f'Prepared file changed: {name}'
    return work, manifest

def inside(work):
    work, manifest = check(work)
    assert os.geteuid() == 0
    assert run_cmd(['findmnt','-n','-t','tracefs','/sys/kernel/tracing']).returncode == 0, 'Configure global tracefs first'
    records=[]
    try:
        formats = {}
        for kind in ('enter','exit'):
            base=Path('/sys/kernel/tracing/events/raw_syscalls')/('sys_'+kind)
            text=(base/'format').read_text(); event_id=int((base/'id').read_text())
            assert int(re.search(r'^ID:\s*(\d+)',text,re.M)[1])==event_id>0
            fields = [('long id',8,8),('unsigned long args[6]',16,48)] if kind=='enter' else [('long id',8,8),('long ret',16,8)]
            for field,offset,size in fields:
                assert re.search(r'field:'+re.escape(field)+r';\s*offset:'+str(offset)+r';\s*size:'+str(size)+r';',text), text
            formats[kind]=dict(id=event_id,format=text)
        probe=str(work/'out/bin/probe');fixture=str(work/'fixture')
        # Document actual credentials. CAP_PERFMON is process-local and expires
        # with this capsh child; no setcap or persistent privilege is installed.
        capsh=['/usr/bin/capsh','--iab=^cap_perfmon','--secbits=239','--user='+manifest['user'],'--','-c']
        credentials={}
        for context,prefix in [('user',['/usr/bin/runuser','-u',manifest['user'],'--']),('root',[]),('perfmon',capsh)]:
            def invoke(command):
                return run_cmd(prefix+[shlex.join(command)] if context=='perfmon' else prefix+command)
            command=[probe,'inventory']
            p=invoke(command);p.check_returncode()
            credentials[context]=p.stdout+p.stderr
            effective=re.search(r'CapEff:\s*([0-9a-fA-F]+)',p.stdout)
            assert effective, credentials[context]
            if context=='user': assert int(effective[1],16)==0, credentials[context]
            if context=='perfmon': assert int(effective[1],16)==1<<38, credentials[context]
            for mode in ('cpu','wait','copy'):
                for rep in range(5):
                    for traced in (False,True):
                        scratch=work/f'{context}-{mode}-{rep}-{int(traced)}';scratch.mkdir()
                        os.chown(scratch,manifest['uid'],-1)
                        cmd=[probe,'run',fixture,str(scratch),mode,str(formats['enter']['id']),str(formats['exit']['id'])] if traced else [fixture,mode,str(scratch)]
                        started=time.monotonic_ns()
                        p=invoke(cmd)
                        row=dict(context=context,mode=mode,rep=rep,traced=traced,wrapper_ns=time.monotonic_ns()-started,returncode=p.returncode,stdout=p.stdout,stderr=p.stderr)
                        records.append(row)
                        assert p.returncode==0,row
                        assert 'RESULT fixture ' in p.stdout,row
                        if traced:
                            line=next((l for l in p.stdout.splitlines() if l.startswith('RESULT trace mode=')), '')
                            values=dict(re.findall(r'(\w+)=([^ ]+)',line))
                            assert values.get('status')=='ok' and values.get('reaped')=='1',row
                            assert values.get('foreign')=='0' and int(values['complete_after'])>0,row
                            assert values.get('enter')=='ok' and values.get('exit')=='ok',row
                            assert 'RESULT cleanup closed=2' in p.stdout,row
                            if mode=='wait':
                                assert int(values['longest_nr'])==0 and 40_000_000 <= int(values['longest_elapsed']) < 250_000_000,row
        print(json.dumps(dict(formats=formats,credentials=credentials,records=records)))
    except Exception:
        print(json.dumps(dict(records=records)),flush=True)
        raise

def run_prepared(work):
    work,manifest=check(work)
    assert not (work/'configured.stdout').exists(), 'Use a fresh preparation for each run'
    before=Path('/proc/self/mountinfo').read_text()
    paranoid=Path('/proc/sys/kernel/perf_event_paranoid').read_text()
    p=subprocess.run(['sudo','-n',sys.executable,str(Path(__file__).resolve()),'--inside',str(work)],text=True,capture_output=True,timeout=120)
    (work/'configured.stdout').write_text(p.stdout)
    (work/'configured.stderr').write_text(p.stderr)
    assert Path('/proc/sys/kernel/perf_event_paranoid').read_text()==paranoid
    assert Path('/proc/self/mountinfo').read_text()==before, 'Parent mount table changed during experiment'
    p.check_returncode()
    print(work)

if __name__=='__main__':
    parser=argparse.ArgumentParser();g=parser.add_mutually_exclusive_group(required=True)
    g.add_argument('--prepare',action='store_true');g.add_argument('--run');g.add_argument('--inside')
    args=parser.parse_args()
    if args.prepare:prepare()
    elif args.run:run_prepared(args.run)
    else:inside(args.inside)
