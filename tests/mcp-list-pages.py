#!/usr/bin/env python3
"""Owned large local/source-map listings: exact pages, byte bounds and stale views."""
import argparse, importlib.util, json, os, re, subprocess, time
from pathlib import Path
from client import Client
from helpers.exact import legacy

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, default=Path('.work/mcp-list-pages'))
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True)
source = w/'locals.c'; fixture = w/'locals'
code = ['#include <stdint.h>', 'int main(void) {']
code += [f'volatile uint64_t v{i:04d} = {i};' for i in range(3000)]
code += ['__asm__ volatile("nop" ::: "memory"); /* FIRST */', 'v0000 = 99;',
         '__asm__ volatile("nop" ::: "memory"); /* SECOND */', 'return 0;', '}']
source.write_text('\n'.join(code)+'\n')
lines = {tag:next(i for i,s in enumerate(code,1) if f'/* {tag} */' in s) for tag in ('FIRST','SECOND')}
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer',str(source),'-o',str(fixture)],check=True,timeout=60)
options=[]; expected_files=[]
for i in range(3):
    s=w/f'debug{i}.c';s.write_text(f'int main(void) {{ return {i}; }}\n');exe=w/f'debug{i}';debug=w/f'debug{i}.debug'
    subprocess.run(['cc','-g','-O0','-Wl,--build-id=sha1',str(s),'-o',str(exe)],check=True,timeout=60)
    subprocess.run(['objcopy','--only-keep-debug',str(exe),str(debug)],check=True,timeout=30)
    options+=['--debug-file',str(debug)];expected_files.append(str(debug))
expected_rules=[]
for i in range(32):
    old='/owned/'+'\\'*4000+str(i);new='/resolved/'+'\\'*4000
    options+=['--source-map',old+'='+new];expected_rules.append(dict(from_=old,to=new))
expected_rules=[{'from':r['from_'],'to':r['to']} for r in expected_rules]
report=dict(status='running',transports=[])


def usage(pid):
    f=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
    rss=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
    return dict(cpu_seconds=(int(f[11])+int(f[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)


def data(reply):
    assert 'error' not in reply and not reply['result']['isError'],reply
    body=reply['result']['structuredContent'];assert json.loads(reply['result']['content'][0]['text'])==body
    size=len(json.dumps(reply,separators=(',',':')).encode());assert size<1024*1024,size
    return body,size


def error(reply, name):
    assert reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']==name,reply


def locals_pages(raw,state):
    args=dict(tid=state['pid']);rows=[];pages=[];first=None
    while True:
        page,size=data(raw('list_locals',**args));first=first or page
        assert page['generation']==state['generation'] and page['total']==3000,page
        assert len(page['locals'])<=args.get('limit',64)
        rows+=legacy(page['locals']);pages.append(dict(rows=len(page['locals']),bytes=size))
        if page['next'] is None:break
        args.update(start=page['next'],view_id=page['view_id'],limit=17 if len(pages)%2 else 128)
    names=[row['name'] for row in rows];assert len(names)==len(set(names))==3000
    assert set(names)=={f'v{i:04d}' for i in range(3000)}
    assert all(row['value']['bits']==int(row['name'][1:]) and row['value']['availability']=='available' for row in rows)
    error(raw('list_locals',tid=state['pid'],start=1),'LocalsViewRequired')
    error(raw('list_locals',tid=state['pid'],start=1,view_id='0'*64),'StaleLocalsView')
    for limit in (0,129):assert raw('list_locals',tid=state['pid'],limit=limit)['error']['code']==-32602
    return first,pages


def file_pages(raw):
    args={};files=[];rules=[];pages=[];first=None
    while True:
        page,size=data(raw('get_debug_files',**args));first=first or page
        assert len(page['files'])+len(page['source_maps'])<=args.get('limit',32)
        files+=legacy(page['files']);rules+=legacy(page['source_maps']);pages.append(dict(files=len(page['files']),rules=len(page['source_maps']),bytes=size))
        if page['next'] is None:break
        args.update(start=page['next'],view_id=page['view_id'],limit=128)
    assert len(files)==page['total_files'] and len(rules)==page['total_source_maps']
    assert [r['path'] for r in files]==expected_files,files
    assert rules==expected_rules
    assert len(pages)>1 and any(p['rules'] for p in pages)
    error(raw('get_debug_files',start=1),'DebugFilesViewRequired')
    error(raw('get_debug_files',start=1,view_id='0'*64),'StaleDebugFilesView')
    for limit in (0,129):assert raw('get_debug_files',limit=limit)['error']['code']==-32602
    return pages


def checks(raw,state,pid):
    before=usage(pid);first,locals_=locals_pages(raw,state);files=file_pages(raw)
    return first,dict(locals=locals_,debug_files=files,before=before,after=usage(pid),load=os.getloadavg())


def stale(raw,old,state):
    error(raw('list_locals',tid=state['pid'],start=old['next'],view_id=old['view_id']),'StaleLocalsView')
    error(raw('list_locals',tid=state['pid'],generation=old['generation']),'StaleSnapshot')
    now,_=data(raw('list_locals',tid=state['pid']));assert next(r for r in now['locals'] if r['name']=='v0000')['value']['bits']==99

try:
    for agent in (False,True):
        c=Client('control',str(fixture),options=[*options,*(['--runtime-agent',str(root/'zig-out/bin/xodb-agent')] if agent else [])])
        try:
            c.stopped()
            for line in lines.values():c.action('set_breakpoint',file=str(source),line=line)
            c.continue_initial_stop();state=c.stopped('breakpoint',seconds=30)
            first,result=checks(c.tool,state,c.p.pid)
            c.action('continue');state=c.stopped('breakpoint',seconds=30);stale(c.tool,first,state)
            result['name']='agent' if agent else 'native';report['transports'].append(result)
        finally:c.close()
    spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
    (w/'shared').mkdir(exist_ok=True)
    server=s.Server(root,w/'shared',root/'zig-out/bin/xodb',fixture,'control',options=options,fixture_args=())
    try:
        owner,observer=s.Client(server,'owner'),s.Client(server,'observer');owner.claim(ttl_ms=60000)
        initial=s.eventually(owner.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'],'initial stop');server.remember_target(initial)
        for line in lines.values():owner.action('set_breakpoint',file=str(source),line=line)
        owner.action('continue')
        state=s.eventually(owner.session,lambda v:v['state']=='stopped' and not v['continue_pending'] and any(t['reason']=='breakpoint' for t in v['threads']),'locals stop',timeout=30)
        first,result=checks(observer.raw,state,server.proc.pid)
        error(observer.raw('continue',generation=state['generation']),'ControlLeaseRequired')
        owner.action('continue')
        state=s.eventually(owner.session,lambda v:v['state']=='stopped' and v['generation']!=state['generation'] and not v['continue_pending'],'changed locals',timeout=30)
        stale(observer.raw,first,state);result['name']='shared observer';report['transports'].append(result)
    finally:server.close()
    report['status']='pass'
finally:(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('MCP list pages: 3000 native locals and 32 escaped source maps; exact coverage, bounded replies and stale views passed on all transports')
