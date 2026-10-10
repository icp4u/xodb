#!/usr/bin/env python3
"""More than 6000 owned VMAs: bounded MCP pages, exact coverage, stale cursors."""
import argparse, importlib.util, json, os, re, subprocess, time
from pathlib import Path
from client import Client
from helpers.exact import legacy

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, default=Path('.work/mcp-modules'))
a = p.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True)
fixture = w/'fixture'
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',
                'tests/fixtures/mcp-modules.c','-o',str(fixture)],check=True,timeout=60)
report = dict(status='running',transports=[])


def maps(pid):
    out = []
    for line in Path(f'/proc/{pid}/maps').read_text().splitlines():
        fields = line.split(None, 5); extent, permissions, offset, device, inode = fields[:5]
        start, end = [int(x,16) for x in extent.split('-')]
        major, minor = [int(x,16) for x in device.split(':')]
        out.append(dict(start=start,end=end,offset=int(offset,16),inode=int(inode),
                        device_major=major,device_minor=minor,permissions=permissions,
                        path=fields[5] if len(fields)>5 else ''))
    return out


def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)


def expect_error(reply, name):
    assert reply.get('result',{}).get('isError'),reply
    assert reply['result']['content'][0]['text']==name,reply


def check(raw, state, frontend):
    before = usage(frontend); expected = maps(state['pid']); assert len(expected)>5000,len(expected)
    rows,failures,pages = [],[],[]; cursor = None; first_cursor = None
    while True:
        args = {} if cursor is None else dict(cursor=cursor,limit=512 if len(pages)%2 else 17)
        reply = raw('list_modules',**args)
        assert 'error' not in reply and not reply['result']['isError'],reply
        data = reply['result']['structuredContent']; text = reply['result']['content'][0]['text']
        assert json.loads(text)==data
        size = len(json.dumps(reply,separators=(',',':')).encode())
        assert size<1024*1024,size
        assert data['total_regions']==len(expected),data
        assert len(data['regions'])+len(data['load_failures'])<=args.get('limit',128)
        for row in data['regions']:
            for key in ('start','end','offset'):assert int(row[key+'_hex'],16)==row[key]
        rows+=legacy(data['regions']);failures+=legacy(data['load_failures'])
        pages.append(dict(rows=len(data['regions']),failures=len(data['load_failures']),bytes=size))
        cursor=data['next']; first_cursor=first_cursor or cursor
        if cursor is None:break
        assert isinstance(cursor,str) and len(cursor)<=128 and len(pages)<200
    sources=[row.pop('file_source') for row in rows]
    for row in rows:
        assert row.pop('full_image_deferred') is False, row
    assert set(sources)<= {'unopened','map_files','target_exe','target_root','host_path','remote_snapshot','core_path'},set(sources)
    assert any(source!='unopened' for source in sources), 'resolved breakpoint retained no module provenance'
    assert rows==expected,(len(rows),len(expected),next(((x,y) for x,y in zip(rows,expected) if x!=y),None))
    assert len(failures)==data['total_load_failures'] and first_cursor
    expect_error(raw('list_modules',cursor='invalid'),'InvalidModuleCursor')
    for limit in (0,513):
        error=raw('list_modules',limit=limit)
        assert error.get('error',{}).get('code')==-32602,error
    assert raw('list_modules',limit=1)['result']['structuredContent']['regions'][0]['start']==expected[0]['start']
    return first_cursor,dict(regions=len(rows),pages=pages,before=before,after=usage(frontend),load=os.getloadavg())


try:
    for agent in (False,True):
        c=Client('control',str(fixture),options=['--runtime-agent',str(root/'zig-out/bin/xodb-agent')] if agent else [])
        try:
            c.stopped();c.action('set_breakpoint',symbol='maps_stop');c.continue_initial_stop()
            state=c.stopped('breakpoint',seconds=30)
            cursor,result=check(c.tool,state,c.p.pid)
            # mmap removal and another stop invalidate the old snapshot cursor.
            c.action('continue');after=c.stopped('breakpoint',seconds=30)
            expect_error(c.tool('list_modules',cursor=cursor),'StaleModuleCursor')
            smaller=c.inspect('list_modules');assert smaller['total_regions']<result['regions']-5000,smaller
            assert smaller['next'] is None
            result['name']='agent' if agent else 'native';report['transports'].append(result)
        finally:c.close()
    spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py')
    shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
    (w/'shared').mkdir(exist_ok=True)
    server=shared.Server(root,w/'shared',root/'zig-out/bin/xodb',fixture,'control',fixture_args=())
    try:
        owner,observer=shared.Client(server,'owner'),shared.Client(server,'observer');owner.claim(ttl_ms=60000)
        initial=shared.eventually(owner.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'],'initial stop')
        server.remember_target(initial);owner.action('set_breakpoint',symbol='maps_stop');owner.action('continue')
        state=shared.eventually(owner.session,lambda v:v['state']=='stopped' and not v['continue_pending'] and any(t['reason']=='breakpoint' for t in v['threads']),'map stop',timeout=30)
        cursor,result=check(observer.raw,state,server.proc.pid)
        # An observer may page, but paging does not acquire the control lease.
        expect_error(observer.raw('continue',generation=observer.session()['generation']),'ControlLeaseRequired')
        owner.action('continue')
        shared.eventually(owner.session,lambda v:v['state']=='stopped' and v['generation']!=state['generation'] and not v['continue_pending'],'changed map',timeout=30)
        expect_error(observer.raw('list_modules',cursor=cursor),'StaleModuleCursor')
        result['name']='shared observer';report['transports'].append(result)
    finally:server.close()
    report['status']='pass'
finally:(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Module pages: 6000+ VMAs, exact procfs coverage, bounded replies and stale cursors passed on native, agent and shared observer')
