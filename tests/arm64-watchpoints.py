#!/usr/bin/env python3
"""Native xodb/MCP acceptance, on owned ARM64 fixtures only. No system changes."""
import argparse,json,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root);sys.path.insert(0,str(root/'tests'))
from client import Client
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin');args=p.parse_args()
binary=Path(args.bin).resolve();reports=[]
class Debugger(Client):
    def __init__(self,mode='range',length=8,offset=0,scope='control',attach=None,fixture=None):
        self.transcript=[];self.id=0
        command=[str(binary/'xodb'),'--headless','--mcp','--agent-scope',scope]
        command+=['--attach',str(attach)] if attach else ['--',str(fixture or binary/'arm64-watch-fixture'),mode,str(length),str(offset)]
        self.p=subprocess.Popen(command,bufsize=0,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'ARM64-watch-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
        self.pid=self.session()['pid'];self.owned=attach is None
    def symbol(self,name):return int(self.inspect('find_symbol',name=name)['address'],16)
    def rendezvous(self):
        probe=self.action('set_breakpoint',symbol='ready')['id'];self.action('continue');s=self.stopped('breakpoint');self.action('remove_breakpoint',id=probe);return s
    def hit(self):
        s=self.stopped('watchpoint');events=self.inspect('query_events')['events'];return s,[e for e in events if e['kind']=='watchpoint_hit'][-1]
    def exited(self):
        end=time.monotonic()+5
        while time.monotonic()<end:
            s=self.session()
            if s['state']=='exited':
                events=self.inspect('query_events')['events'];assert any(e['kind']=='exit' and e['detail']==0 for e in events),events;return
            time.sleep(.002)
        raise AssertionError(s)
    def close(self):
        try:super().close()
        finally:
            reports.append({'transcript':self.transcript})
            if self.owned:assert not Path('/proc/'+str(self.pid)).exists(),self.pid

def check_hit(d,before,after):
    s,e=d.hit();assert e['before_valid'] and e['after_valid'],e
    assert (e['before'],e['after'],e['watch_phase'],e['watch_attribution'])==(before,after,'completed','single_armed_watch'),e
    assert e['trap_pc']+4==e['pc'] and e['trap_code']==4,e
    view=d.inspect('get_debug_view');assert view['watch_slots']==4 and len(view['watchpoints'])==1,view
    assert view['watch_hits'][0]['after']==after,view
    return s,e
try:
    for length in [1,2,4,8]:
        for offset in range(0,8,length):
            d=Debugger(length=length,offset=offset)
            try:
                d.rendezvous();addr=d.symbol('data')+offset
                probe=d.action('set_watchpoint',address=hex(addr),length=length)['id']
                d.action('continue');check_hit(d,3,7)
                d.action('continue');check_hit(d,7,11)
                d.action('remove_watchpoint',id=probe);d.action('continue');d.exited()
                reports.append({'case':'range','length':length,'offset':offset,'passed':True})
            finally:d.close()
    for mode,offset,length,values,kind in [('range',0,8,[(3,3),(3,7),(7,11)],'read_write'),('wide',4,4,[(3,7),(7,11)],'write'),('pair',8,8,[(3,11)],'write'),('clone',0,8,[(3,7),(7,11)],'write'),('same',0,8,[(3,3),(3,7)],'write')]:
        d=Debugger(mode)
        try:
            d.rendezvous();probe=d.action('set_watchpoint',address=hex(d.symbol('data')+offset),length=length,kind=kind)['id']
            for before,after in values:
                d.action('continue');s,e=check_hit(d,before,after)
                if mode=='clone':assert e['tid']!=d.pid and all(t['state']=='stopped' for t in s['threads']),s
                if mode=='wide':assert e['trap_address']==d.symbol('data'),e
            d.action('remove_watchpoint',id=probe);d.action('continue');d.exited()
            reports.append({'case':mode+'/'+kind,'passed':True})
        finally:d.close()
    d=Debugger('slots')
    try:
        d.rendezvous();addr=d.symbol('data');ids=[d.action('set_watchpoint',address=hex(addr+8*i),length=8)['id'] for i in range(4)]
        bad=d.tool('set_watchpoint',address=hex(addr+32),length=8,generation=d.session()['generation']);assert bad['result']['isError'] and bad['result']['content'][0]['text']=='WatchpointLimit',bad
        for i in range(4):
            d.action('continue');d.hit()
            events=[e for e in d.inspect('query_events')['events'] if e['kind']=='watchpoint_hit'][-4:]
            assert {e['detail'] for e in events}==set(ids) and all(e['watch_attribution']=='candidate' for e in events),events
            assert next(e['after'] for e in events if e['address']==addr+8*i)==7+i,events
        for ident in ids:d.action('remove_watchpoint',id=ident)
        d.action('continue');d.exited();reports.append({'case':'four slots/fifth rejected/ambiguous candidates','passed':True})
    finally:d.close()
    d=Debugger()
    try:
        d.rendezvous();addr=d.symbol('data');probe=d.action('set_watchpoint',address=hex(addr),length=8)['id']
        code=d.symbol('watch_store');bp=d.action('set_breakpoint',address=hex(code))['id'];d.action('continue');s=d.stopped('breakpoint')
        d.action('step_instruction',tid=s['threads'][0]['tid']);_,e=check_hit(d,3,7);assert e['trap_pc']==code,e
        d.action('continue');d.stopped('breakpoint');d.action('continue');check_hit(d,7,11)
        d.action('remove_watchpoint',id=probe);d.action('remove_breakpoint',id=bp);d.action('continue');d.exited()
        reports.append({'case':'software breakpoint at watch instruction/step/rearm','passed':True})
    finally:d.close()
    d=Debugger(fixture=binary/'xodb-m1-fixture')
    try:
        probe=d.action('set_breakpoint',file='m1.c',line=10)['id'];d.action('continue');s=d.stopped('breakpoint');tid=s['threads'][0]['tid']
        investigation=d.action('investigate_write',tid=tid,expression='item->value',question='Which store changed this field?')['id'];d.action('remove_breakpoint',id=probe)
        d.action('continue');check_hit(d,7,12)
        record=d.inspect('get_investigation',id=investigation);o=record['observations'][-1]
        assert o['access_instruction']['address']==o['event']['trap_pc'] and o['access_instruction']['source']['line']==10 and o['preceding_instruction'] is None,o
        assert o['value']['display']=='12',o
        d.action('continue');check_hit(d,12,21);reports.append({'case':'DWARF write investigation/raw instruction/source/before-after','passed':True})
    finally:d.close()
    d=Debugger('exec')
    try:
        d.rendezvous();d.action('set_watchpoint',address=hex(d.symbol('data')),length=8);d.action('continue');d.stopped('exec')
        assert all(w is None for w in d.inspect('get_breakpoints')['watchpoints']);d.action('continue');d.exited();reports.append({'case':'exec clears watches','passed':True})
    finally:d.close()
    fixture=subprocess.Popen([str(binary/'arm64-watch-fixture'),'attach'])
    try:
        d=Debugger(attach=fixture.pid)
        try:
            addr=d.symbol('data');d.action('set_watchpoint',address=hex(addr),length=8);d.action('continue');d.hit();d.action('detach')
        finally:d.close()
        time.sleep(.05);assert fixture.poll() is None
        assert 'TracerPid:\t0' in Path('/proc/'+str(fixture.pid)+'/status').read_text()
        d=Debugger(attach=fixture.pid)
        try:
            d.action('set_watchpoint',address=hex(d.symbol('data')),length=8);d.action('continue');d.hit()
        finally:d.close()
        time.sleep(.05);assert fixture.poll() is None;reports.append({'case':'attach/detach/reattach/EOF clearing watches','passed':True})
    finally:fixture.terminate();fixture.wait(timeout=3)
    d=Debugger(scope='observe')
    try:
        denied=d.tool('set_watchpoint',address=hex(d.symbol('data')),length=8,generation=d.session()['generation']);assert denied['result']['isError'] and denied['result']['content'][0]['text']=='AgentScopeDenied',denied
        reports.append({'case':'observe scope rejects watch control','passed':True})
    finally:d.close()
    print('PASS',sum(1 for r in reports if r.get('passed')),'ARM64 xodb watch cases',flush=True)
finally:
    print(json.dumps({'reports':reports}),flush=True)
