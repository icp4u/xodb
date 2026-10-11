#!/usr/bin/env python3
"""Fast private GUI lane: deep-map navigation and narrow text.

--evidence adds same-process live hide/reopen CPU and RSS evidence.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
from PIL import Image

p = argparse.ArgumentParser()
p.add_argument('--binary')
p.add_argument('--evidence', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-dp' + str(time.time_ns())[-5:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
checks = []
d = None
started = time.monotonic()

def check(name, ok):
    if not ok:
        raise AssertionError(name + ': ' + d.tail())
    checks.append(name)
    print('PASS ' + name, flush=True)

def log():
    return Path(d.log).read_text()

def field():
    rows = [line for line in h.complete_lines(d.log) if line.startswith('xodb: memmap deep x=')]
    if not rows: return {}
    return dict(re.findall(r'(\w+)=([^ ]+)', rows[-1]))

def until(fn, name, seconds=10):
    deadline = time.monotonic() + seconds * h.load_scale()
    while time.monotonic() < deadline:
        if not d.alive(): raise AssertionError(d.tail())
        if fn(): return
        time.sleep(.025)
    raise AssertionError(name + ': ' + d.tail())

def send(*cmd):
    if d.keys(*cmd, wait=False).wait(timeout=10 * h.load_scale()): raise AssertionError('private input failed')

def close():
    global d
    if d:
        for proc in d.procs:
            if proc.poll() is None:
                try: cwd = os.readlink(f'/proc/{proc.pid}/cwd')
                except PermissionError:
                    # A capability-bearing compositor hides its cwd; it is still our own child.
                    continue
                except FileNotFoundError: continue
                if Path(cwd) != root: raise AssertionError('owned-process cwd changed')
        d.close()
        d = None

def ocr(name, box):
    path = Path(d.shot(name))
    with Image.open(path) as im: im.crop(box).resize(((box[2]-box[0])*2,(box[3]-box[1])*2)).save(path)
    return subprocess.check_output(['tesseract',str(path),'stdout','--psm','6'],stderr=subprocess.DEVNULL,text=True,timeout=10 * h.load_scale())

base, replay = work/'base.jsonl', work/'replay.jsonl'
subprocess.run(['python3','-B','tests/fixtures/overview-synth.py',str(base),'--frames','3'],check=True)
subprocess.run(['python3','-B','tests/fixtures/memmap-synth.py',str(base),str(replay),'--viewports'],check=True)
frames = [json.loads(line) for line in replay.read_text().splitlines()]
# A Linux kernel pseudo mapping must not expand the user-space minimap.
for frame in frames:
    frame['memory_map']['vmas'].append(dict(start=0xffffffffff600000,end=0xffffffffff601000,kind='pseudo',perms='--xp',path='[vsyscall]'))
replay.write_text(''.join(json.dumps(f,separators=(',',':'))+'\n' for f in frames))
last_user_end = max(v['end'] for v in frames[-1]['memory_map']['vmas'] if v['end'] < 1<<57)
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
evidence = {}

def snapshot():
    fields = Path(f'/proc/{d.app.pid}/stat').read_text().rsplit(')',1)[1].split()
    status = Path(f'/proc/{d.app.pid}/status').read_text()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(re.search(r'VmRSS:\s+(\d+)',status).group(1))*1024,
                anon_bytes=int(re.search(r'RssAnon:\s+(\d+)',status).group(1))*1024)

def periodic():
    global d
    exe = work/'fixture'
    subprocess.run(['cc','-O2','-o',str(exe),'tests/memdefrag-fixture.c'],check=True)
    target = subprocess.Popen([str(exe),'512'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        ready,_,_ = select.select([target.stdout],[],[],20)
        if not ready or json.loads(target.stdout.readline())['rc']: raise AssertionError('owned fixture not ready')
        os.environ['XODB_MEMMAP_PERF'] = '1'
        d = h.Display(str(root),['--overview','--look','deep','--panel','memory_map','--redact','--memmap-pid',str(target.pid)],
                      stdio=False,trace=False,binary=a.binary,output_size=(1920,1080))
        until(lambda: field() and int(field()['pending']) == 0,'live sampled',20)
        # Make one partial overlap while the old exact-address sample is retained.
        before_pan = field()
        old_origin = before_pan['origin']
        send('tap',106)
        # Deliberately observe only the completed scan. Partial frames can finish
        # between polls; their evidence must survive in the latest trace row.
        until(lambda: field()['origin'] != old_origin and int(field()['pending']) == 0, 'pan publication',20)
        after_pan = field()
        def partial_reused(row):
            return (int(row.get('partial_frames', 0)) > int(before_pan.get('partial_frames', 0))
                    and row.get('partial_origin') == row['origin']
                    and row.get('partial_cell') == row['cell']
                    and int(row.get('partial_count', 0)) == int(row['count'])
                    and 0 < int(row.get('partial_pending', 0)) < int(row['count']))
        if os.getenv('XODB_TEST_WRONG_DEEPMAP_PARTIAL'):
            after_pan['partial_pending'] = after_pan['count']
        check('completed pan retains evidence of partial reuse', partial_reused(after_pan))
        check('partial-reuse oracle refuses stale, empty and wholly pending evidence', all(
            not partial_reused(dict(after_pan, **{key: wrong})) for key, wrong in (
                ('partial_frames', before_pan.get('partial_frames', '0')),
                ('partial_origin', old_origin), ('partial_cell', '0'),
                ('partial_count', '0'), ('partial_pending', '0'),
                ('partial_pending', after_pan['count']))))
        evidence['partial_reuse'] = dict(before=before_pan, after=after_pan)
        view = (field()['origin'],field()['cell'])
        samples = []
        for phase,seconds in [('visible',8),('hidden',5),('reopened',8),('hidden_again',5)]:
            if phase.startswith('hidden'):
                mark = len(log());send('tap',2)
                until(lambda: 'panel=summary ' in log()[mark:], 'panel hidden')
            elif phase == 'reopened':
                mark = len(log());send('tap',50)
                until(lambda: 'panel=memory_map ' in log()[mark:] and int(field()['pending']) == 0, 'same viewport resampled',20)
                check('reopening preserves address and cell size', (field()['origin'],field()['cell']) == view)
            before = snapshot(); begin = time.monotonic(); rows = []
            while time.monotonic()-begin < seconds:
                if not d.alive(): raise AssertionError(d.tail())
                rows.append(dict(seconds=time.monotonic()-begin,**snapshot()))
                time.sleep(.1)
            after = snapshot(); elapsed = time.monotonic()-begin
            samples.append(dict(phase=phase,seconds=elapsed,before=before,after=after,samples=rows,cpu_pct=100*(after['cpu_seconds']-before['cpu_seconds'])/elapsed))
        cpus = len(os.sched_getaffinity(0));load=os.getloadavg()
        evidence['memory'] = dict(phases=samples,allowed_cpus=cpus,load=load,status='measured' if load[0] <= cpus else 'not-measurable')
        check('same-process CPU, RSS and anonymous RSS measured across two hide cycles', all(p['samples'] for p in samples))
        close()
    finally:
        close()
        if target.poll() is None:
            if Path(os.readlink(f'/proc/{target.pid}/cwd')) != root: raise AssertionError('fixture cwd changed')
            target.terminate()
        try: target.wait(timeout=5 * h.load_scale())
        except subprocess.TimeoutExpired: target.kill(); target.wait(timeout=5 * h.load_scale())

try:
    d = h.Display(str(root),['--overview','--look','deep','--panel','memory_map','--redact','--pause','--replay',str(replay)],
                  stdio=False,trace=False,binary=a.binary,output_size=(1280,720))
    until(lambda: 'layout 1280x720 panel=memory_map' in log() and field() and int(field()['pending']) == 0, 'recorded viewport')
    g=field(); origin=g['origin'];cell=g['cell']
    # OCR polls for the presented image, rather than assuming a frame delay.
    x=int(float(g['x']));y=int(float(g['y']))
    texts=[]
    def header_ready():
        text=ocr('header',(x,50,1270,y)).lower();texts.append(text)
        return len(re.findall(r'0x[0-9a-f]{12}',text)) == 2 and 'refresh' in text and 'recorded' in text
    until(header_ready,'full range and recorded cadence presented')
    check('1280 header preserves both complete range endpoints and recorded cadence',True)
    alias_text=ocr('aliases',(max(0,x-264),50,x-20,350)).lower()
    check('1280 process column shows complete redacted aliases',len(re.findall(r'proc[- ]?[0-9a-f]{5}',alias_text)) >= 2)
    send('tap',106)
    until(lambda: field()['origin'] != origin,'pan')
    send('tap',33)
    until(lambda: field()['origin']==origin and field()['cell']==cell,'f fit')
    check('f refits the process',True)
    mx,my,mw,mh=map(float,field()['mini'].split(','))
    send('click',int(mx+mw-1),int(my+mh/2))
    until(lambda: int(field()['origin'],16)>int(origin,16),'right minimap')
    g=field()
    check('minimap right edge ends at last user VMA despite vsyscall',int(g['origin'],16)+int(g['cell'])*int(g['count']) <= last_user_end)
    mark=len(log());send('tap',11)
    until(lambda:'panel=system ' in log()[mark:],'0 System Info')
    check('0 reaches System Info from deep map',True)
    lines=[line for line in h.complete_lines(d.log) if 'overview layout ' in line]
    check('no label overlaps at 1280',bool(lines) and all('overlaps=0 ' in line for line in lines))
    evidence['header_ocr']=texts[-1];evidence['alias_ocr']=alias_text
    close()
    if a.evidence: periodic()
finally:
    close()
    (work/'results.json').write_text(json.dumps(dict(checks=checks,seconds=time.monotonic()-started,evidence=evidence),indent=2)+'\n')
print(f'deepmap-gui: {len(checks)} passed in {time.monotonic()-started:.3f}s; {work}',flush=True)
