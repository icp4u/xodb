#!/usr/bin/env python3
"""Owned CPU captures -> removed executable -> production comparison, optionally GUI."""
import argparse,importlib.util,json,os,subprocess,time
from pathlib import Path
from client import Client
parser=argparse.ArgumentParser();parser.add_argument('--gui',action='store_true');options=parser.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root)
work=root/'.work'/('comparison-'+str(time.time_ns())[-10:]);work.mkdir();(work/'tmp').mkdir()
fixture=work/'fixture'
subprocess.run(['cc','-g','-O2','-fno-omit-frame-pointer','-fno-optimize-sibling-calls','-Wall','-Wextra','-Werror','tests/fixtures/comparison.c','-o',str(fixture)],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
paths=[work/'before.xoc',work/'after.xoc']
for side,path in enumerate(paths):
    c=Client('control',str(fixture),args=[str(side)])
    try:
        ready=c.action('set_breakpoint',symbol='comparison_ready')['id']
        c.action('set_breakpoint',symbol='comparison_done')
        c.action('continue');state=c.stopped('breakpoint');c.action('remove_breakpoint',id=ready)
        opened=c.action('start_profile',duration_ms=5000,frequency_hz=499,tids=[state['pid']])['capture']
        c.action('continue');c.stopped('breakpoint')
        cap=c.action('stop_profile',capture_id=opened['id'])['capture']
        assert cap['stored_samples']>100 and not cap['lost_samples'],cap
        c.action('save_capture_archive',capture_id=cap['id'],revision=cap['revision'],path=str(path))
        deadline=time.monotonic()+15
        while True:
            job=c.inspect('get_archive_status')['job']
            if job['done']:break
            assert time.monotonic()<deadline,job
            time.sleep(.005)
        assert job['publication']['state']=='published',job
    finally:
        (work/f'capture-{side}.json').write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
fixture.rename(work/'fixture-removed')
def query(c,mode='functions'):
    deadline=time.monotonic()+15;rows=[];start=0;latencies=[]
    while True:
        before=time.monotonic();data=c.inspect('get_profile_comparison',view=mode,start=start,limit=3);latencies.append(time.monotonic()-before)
        if data.get('pending'):
            assert time.monotonic()<deadline,data
            time.sleep(.005);continue
        rows+=data['rows']
        if data['next'] is None:break
        start=data['next']
    assert len(rows)==data['total'] and max(latencies)<.5,(data,latencies)
    return dict(data,rows=rows,max_query_ms=max(latencies)*1000)
for identical in (True,False):
    c=Client('observe',None,options=['--compare-capture',str(paths[0]),'--open-capture',str(paths[0 if identical else 1])])
    try:
        initial=c.session();rank=query(c)
        if identical:assert all(abs(r['self_delta_pp'])<1e-9 for r in rank['rows']),rank
        else:
            named={r['name']:r for r in rank['rows'] if r['match']=='symbol'}
            assert named['hot_before']['self_delta_pp']<-60,named
            assert named['hot_after']['self_delta_pp']>60,named
        graph=query(c,'flames')
        if not identical:
            hot=next(n for n in graph['rows'] if n['name']=='hot_after')
            assert all(hot['counts']['self']) and hot['delta_pp']>60,hot
        for side in (0,1):
            assert sum(n['counts']['self'][side] for n in graph['rows'])==graph['rows'][0]['counts']['inclusive'][side]
        assert c.session()['generation']==initial['generation'] and c.session()['pid']==0
        bad=c.tool('get_profile_comparison',view='elapsed_time');assert bad['error']['code']==-32602,bad
        (work/('same.json' if identical else 'changed.json')).write_text(json.dumps(dict(ranking=rank,graph=graph),indent=2)+'\n')
    finally:c.close()
if options.gui:
    spec=importlib.util.spec_from_file_location('input_repro',root/'tests/helpers/input.py')
    h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
    # Unix sockets need the established short private-display artifact prefix.
    display_work=root/'.work'/('input-functional-'+str(time.time_ns())[-10:]);display_work.mkdir();h.WORK=str(display_work)
    for name in ('tmp','cache','cache/mesa','cache/nvidia'):(display_work/name).mkdir(parents=True,exist_ok=True)
    for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
        subprocess.run(['wayland-scanner','client-header',xml,str(display_work/(stem+'.h'))],check=True)
        subprocess.run(['wayland-scanner','private-code',xml,str(display_work/(stem+'.c'))],check=True)
    h.HELPER=str(display_work/'vinput')
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(display_work),str(root/'tests/helpers/vinput.c'),str(display_work/'virtual-pointer.c'),str(display_work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
    d=h.Display(str(root),['--compare-capture',str(paths[0]),'--open-capture',str(paths[1])])
    try:
        deadline=time.monotonic()+15
        while d.tool('get_profile_comparison').get('pending'):
            assert time.monotonic()<deadline
            time.sleep(.02)
        time.sleep(.2);d.shot('01-rankings')
        d.keys('tap',33);time.sleep(.2);d.shot('02-flames')
        d.keys('click',400,248);d.shot('03-zoom')
        d.keys('tap',14);d.keys('tap',47);d.shot('04-after-capture')
        d.keys('tap',47);d.shot('05-comparison')
        shown=d.tool('get_profile')['displayed_view']
        assert shown is None or not shown['visible'],shown
        subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
        time.sleep(.3);d.shot('06-small')
        d.app.stdin.close();assert d.app.wait(timeout=5)==0,d.tail()
        (work/'gui.txt').write_text(str(display_work)+'\n')
    finally:d.close()
print(work,flush=True)
