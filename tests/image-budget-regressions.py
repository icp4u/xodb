#!/usr/bin/env python3
"""Periodic honest-library, compressed-debug and opt-in budget invariants.
Also checks capture release guards and stderr through repeated real stops.
"""
import argparse, importlib.util, json, os, re, select, struct, subprocess, time, traceback
from pathlib import Path
from client import Client
spec = importlib.util.spec_from_file_location('hostile', Path(__file__).with_name('image-budget-hostile.py'))
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
MIB = 1 << 20
HOT = '''
__attribute__((noinline)) unsigned long hot_inner(unsigned long x) { for (int i=0; i<20000; i++) x=x*6364136223846793005UL+1442695040888963407UL; return x; }
__attribute__((noinline)) unsigned long hot_outer(unsigned long x) { for (int i=0;i<50;i++) x^=hot_inner(x+i); __asm__ volatile("" ::: "memory"); return x; }
'''
MAIN = '''
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
 void *lib=dlopen(argv[1], RTLD_NOW); if(!lib) return 2;
 unsigned long (*hot)(unsigned long)=dlsym(lib,"hot_outer"); if(!hot) return 3;
 for(int i=2;i<argc;i++) if(!dlopen(argv[i],RTLD_NOW)) return 4;
 puts("ready"); fflush(stdout);
 unsigned long x=1; for(;;) x=hot(x);
}
'''
def cc(*args): subprocess.run(['cc', *map(str,args)], check=True, timeout=90)
def text(r): return '; '.join(x['text'] for x in r.get('content',[]))
def stats(c):
    s=Path(f'/proc/{c.p.pid}/stat').read_text().rsplit(')',1)[1].split()
    return dict(cpu_ticks=int(s[11])+int(s[12]),rss_bytes=int(s[21])*os.sysconf('SC_PAGESIZE'),load=os.getloadavg(),cpus=os.cpu_count())
def close(c):
    if c.p.poll() is None:
        c.p.stdin.close()
        try: c.p.wait(timeout=10)
        except subprocess.TimeoutExpired: c.p.kill(); c.p.wait(); raise
    return c.p.stderr.read().decode(errors='replace')
def flame(c,cap):
    rows=[]; start=0; view=None
    while True:
        r=c.inspect('get_flamegraph',capture_id=cap['id'],revision=cap['revision'],start=start,limit=64,**({'view_id':view} if view else {}))
        rows+=r['nodes'];view=r['view_id']
        if r['next'] is None: return rows
        start=r['next']
def honest(w,a):
    (w/'main.c').write_text(MAIN);(w/'hot.c').write_text(HOT)
    cc('-g','-O1',w/'main.c','-o',w/'main','-ldl')
    cc('-g','-O1','-shared','-fPIC',w/'hot.c','-o',w/'hot.so')
    libs=[w/'hot.so']
    for i in range(3):
        lib=w/f'fill{i}.so';lib.write_bytes((w/'hot.so').read_bytes());libs.append(lib)
    for lib in libs: os.truncate(lib,100*MIB)
    try:
        for mode in ('line','profile'):
            target=subprocess.Popen([str(w/'main'),*map(str,libs)],stdout=subprocess.PIPE,text=True)
            c=None
            try:
                assert target.stdout.readline()=='ready\n'
                c=client('control',None,options=['--attach',str(target.pid)],reply_seconds=60);s=c.stopped();before=stats(c)
                if mode=='line':
                    r=c.inspect('set_breakpoint',generation=s['generation'],file='hot.c',line=2)
                    assert r['ids'] and r['images_not_searched']==0,r
                else:
                    cap=c.inspect('start_profile',generation=s['generation'],duration_ms=0,frequency_hz=499,tids=[target.pid])['capture']
                    assert cap['mapping_history']['images_not_searched']==0,cap
                    c.action('continue');deadline=time.monotonic()+30
                    while c.inspect('get_profile')['capture']['stored_samples']==0:
                        assert time.monotonic()<deadline
                        time.sleep(.01)
                    cap=c.action('stop_profile',capture_id=cap['id'])['capture']
                    rows=flame(c,cap)
                    wanted=('wrong_hot',) if a.wrong_result else ('hot_inner','hot_outer')
                    assert any(n['name'] in wanted and n['self']>0 for n in rows),rows
                print(json.dumps({'case':'honest-'+mode,'before':before,'after':stats(c),'image_bytes':c.inspect('list_modules',limit=1)['image_bytes']}),flush=True)
            finally:
                if c: close(c)
                if target.poll() is None: target.kill()
                target.wait()
    finally:
        for lib in libs:lib.unlink(missing_ok=True)
def packed(w,a):
    (w/'host.c').write_text(h.HOST);(w/'lib.c').write_text(h.LIB)
    (w/'pad.s').write_text('.section .debug_ranges,"",@progbits\n.zero 314572800\n.section .note.GNU-stack,"",@progbits\n')
    cc('-g','-O1',w/'host.c','-o',w/'host','-ldl')
    lib=w/'packed.so'
    cc('-g','-O1','-fno-optimize-sibling-calls','-shared','-fPIC',w/'lib.c',w/'pad.s','-Wl,--compress-debug-sections=zlib','-o',lib)
    r=h.Run(w,w/'host',[lib])
    try:
        before=stats(r.client)
        if r.client.runtime_agent:
            reply=r.client.tool('set_breakpoint',generation=r.client.session()['generation'],file='lib.c',line=4)['result']
            assert reply['isError'] and 'images not searched' in text(reply),reply
        found=r.stack(select=(lib,));notice=found['image_budget']
        wanted='302 MiB' if a.wrong_result else '301 MiB'
        assert notice and 'decompressed debug data' in notice and wanted in notice and '--image-limit 400M' in notice,found
        failures=h.load_failures(r.client)
        assert any(f['diagnostic']=='CompressedDebugBudget' and f['detail']==notice for f in failures),failures
        reply=r.client.tool('set_breakpoint',generation=r.client.session()['generation'],file='lib.c',line=4)['result']
        assert reply['isError'] and 'images not searched' in text(reply) and 'decompressed debug data' in text(reply),reply
        assert r.held()['held']<8*MIB,r.held()
        print(json.dumps({'case':'compressed','before':before,'after':stats(r.client),'notice':notice.replace(str(w),'.')}),flush=True)
        r.close()
    finally:r.kill()
    # A target can declare UINT64_MAX inflated bytes in a tiny section. Its
    # diagnostic must remain bounded and must not overflow while rounding MiB.
    image=h.Elf(lib);section=image.sh(image.index('.debug_ranges'))
    assert section['flags'] & h.SHF_COMPRESSED,section
    struct.pack_into('<Q',image.b,section['offset']+8,(1<<64)-1);image.save(lib)
    r=h.Run(w,w/'host',[lib])
    try:
        if r.client.runtime_agent:r.client.tool('set_breakpoint',generation=r.client.session()['generation'],file='lib.c',line=4)
        found=r.stack(select=(lib,));notice=found['image_budget']
        assert notice and 'decompressed debug data' in notice and 'no accepted --image-limit is that large' in notice,found
        assert r.held()['held']<8*MIB,r.held()
        print(json.dumps({'case':'compressed-saturated','notice':notice.replace(str(w),'.')}),flush=True)
        r.close()
    finally:r.kill()
    lib.unlink()
def converge(w,a):
    (w/'host.c').write_text(h.HOST);(w/'lib.c').write_text(h.LIB)
    cc('-g','-O1',w/'host.c','-o',w/'host','-ldl')
    cc('-g','-O1','-shared','-fPIC',w/'lib.c','-o',w/'big.so')
    lib=w/'big.so';os.truncate(lib,500*MIB)
    advice=re.compile(r'; rerun with ((?:--image-(?:total-)?limit \d+[MG] ?)+) or set')
    # Start at the old total: a per-image-only suggestion would disable sweeps.
    options={'--image-total-limit':'512M'};observed=[]
    try:
        for attempt in range(4):
            r=h.Run(w,w/'host',[lib],options=[v for pair in options.items() for v in pair])
            try:
                found=r.stack();notice=found.get('image_budget')
                if notice:
                    match=advice.search(notice);assert match,notice
                    args=match.group(1).split();options.update(zip(args[::2],args[1::2]));observed.append(notice)
                    if attempt==0:assert '--image-total-limit' in args,notice
                else:
                    reply=r.client.tool('set_breakpoint',generation=r.client.session()['generation'],file='host.c',line=5)['result']
                    assert not reply['isError'] and reply['structuredContent']['ids'],reply
                    assert reply['structuredContent']['images_not_searched']==0,reply
                    assert r.held()['sweep_limit']>0,r.held()
                    r.close();break
                r.close()
            finally:r.kill()
        else:raise AssertionError(observed)
        print(json.dumps({'case':'advice','options':options,'attempts':len(observed)}),flush=True)
    finally:lib.unlink(missing_ok=True)
def stderr(w,a):
    # The target blocks in one library; repeated interrupt/continue stops must
    # retain structured refusals without producing one long line per stop.
    (w/'host.c').write_text(h.HOST);(w/'lib.c').write_text(h.LIB)
    cc('-g','-O1',w/'host.c','-o',w/'host','-ldl')
    cc('-g','-O1','-shared','-fPIC',w/'lib.c','-o',w/'refused.so')
    lib=w/'refused.so';os.truncate(lib,300*MIB)
    r=h.Run(w,w/'host',[lib])
    try:
        start=time.monotonic();before=stats(r.client)
        for i in range(220):
            r.session=r.client.stopped()
            r.client.tool('set_breakpoint',generation=r.session['generation'],file='no_file.c',line=1)
            found=r.stack()
            assert r.modules()['image_budget'],found
            r.client.action('continue');r.client.action('interrupt')
        # No pipe draining during the burst. Data remains available in silence.
        r.session=r.client.stopped()
        r.client.tool('set_breakpoint',generation=r.session['generation'],file='no_file.c',line=1)
        r.stack();assert r.modules()['image_budget']
        assert r.modules()['image_budget']
        after=stats(r.client);err,_=r.close();count=err.count(b'module budget:')
        assert count<=2,count
        print(json.dumps({'case':'stderr','stops':220,'lines':count,'before':before,'after':after,'seconds':time.monotonic()-start}),flush=True)
    finally:r.kill();lib.unlink(missing_ok=True)
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);p.add_argument('--only',default='honest,packed,converge,stderr');p.add_argument('--agent');p.add_argument('--wrong-result',action='store_true');a=p.parse_args()
os.umask(0o022);w=a.work.resolve();w.mkdir(parents=True,exist_ok=True,mode=0o755)
def client(scope,executable=None,**kwargs):
    if a.agent:kwargs['options']=['--runtime-agent',str(Path(a.agent).resolve()),*kwargs.get('options',[])]
    return Client(scope,executable,**kwargs)
h.Client=client
failures=[]
for case in a.only.split(','):
    try:globals()[case](w,a)
    except Exception as error:
        if not (a.agent or os.environ.get('XODB_TEST_RUNTIME_AGENT')):raise
        failures.append(case)
        print(json.dumps({'case':case,'status':'failed','error':str(error)}),flush=True)
        traceback.print_exc()
if failures:raise SystemExit('image budget regressions failed: '+', '.join(failures))
print('image budget regressions: pass')
