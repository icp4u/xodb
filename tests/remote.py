#!/usr/bin/env python3
"""Real single-client TCP lifecycle and bounded remote view, using owned fixtures."""
import argparse, json, os, select, socket, subprocess, time, signal
from pathlib import Path

root = Path.cwd() if __file__ == '<stdin>' else Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='.work/remote-build/bin')
args = parser.parse_args()
bin = Path(args.bin).resolve()

def wait_for(fn, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = fn()
        if result: return result
        time.sleep(.02)
    raise AssertionError('Timed out')

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]

class Server:
    def __init__(self, scope='control', attach=None):
        self.port = free_port()
        argv = [str(bin/'xodb'),'--headless','--mcp','--listen',f'127.0.0.1:{self.port}',
                '--source','tests/fixtures/m1.c','--agent-scope',scope]
        argv += ['--attach',str(attach)] if attach else ['--',str(bin/'xodb-m1-fixture'),'w']
        self.p = subprocess.Popen(argv, stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        ready = select.select([self.p.stderr],[],[],10)[0]
        assert ready, 'Listener did not start'
        line = self.p.stderr.readline().decode()
        assert 'listening on' in line, line + self.p.stderr.read().decode()
        self.sock = socket.create_connection(('127.0.0.1',self.port),timeout=10)
        self.f = self.sock.makefile('rb')
        self.seq = 0
        self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'remote-test','version':'1'}},fragment=True)
        self.sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def call(self,method,params=None,fragment=False):
        self.seq += 1
        data=(json.dumps({'jsonrpc':'2.0','id':self.seq,'method':method,'params':params or {}})+'\n').encode()
        if fragment:
            for start in range(0,len(data),7): self.sock.sendall(data[start:start+7])
        else: self.sock.sendall(data)
        while True:
            line=self.f.readline(); assert line, 'EOF'
            response=json.loads(line)
            if 'id' not in response: continue
            assert response['id']==self.seq,response
            return response
    def tool(self,tool_name,**arguments): return self.call('tools/call',{'name':tool_name,'arguments':arguments})
    def inspect(self,tool_name,**arguments):
        response=self.tool(tool_name,**arguments)
        assert 'error' not in response and not response['result']['isError'],response
        return response['result']['structuredContent']
    def session(self): return self.inspect('get_session')
    def action(self,name,**arguments): return self.inspect(name,generation=self.session()['generation'],**arguments)
    def stopped(self):
        def check():
            state=self.session()
            return state if state['state']=='stopped' else None
        return wait_for(check)
    def close(self):
        self.f.close(); self.sock.close()
        assert self.p.wait(timeout=10)==0,self.p.stderr.read().decode()
        self.p.stdout.close();self.p.stderr.close()

server=Server(); owned=None
try:
    initial=server.session(); owned=initial['pid']
    summary=server.inspect('get_debug_view',summary_only=True)
    assert summary['session_id']==initial['session_id'] and summary['threads']==[] and summary['frames']==[] and summary['source'] is None
    tools={t['name'] for t in server.call('tools/list')['result']['tools']}
    assert {'get_debug_view','detach','continue'} <= tools
    try: extra=socket.create_connection(('127.0.0.1',server.port),timeout=1)
    except OSError: pass
    else: extra.close(); raise AssertionError('Listener remained open')
    probe=server.action('set_breakpoint',file='m1.c',line=10)['id']
    server.action('continue'); stopped=server.stopped()
    tid=stopped['threads'][0]['tid']
    view=server.inspect('get_debug_view',tid=tid,generation=stopped['generation'])
    assert view['schema']==1 and view['architecture'] in ('x86_64','aarch64')
    assert view['frames'][0]['symbol']=='change_value',view['frames']
    assert view['source']['text'].find('WATCH_WRITE')>=0
    assert view['registers'] and view['instructions']
    assert {v['name']:v['display'] for v in view['locals']}['next']=='12',view['locals']
    stale=server.tool('continue',generation=initial['generation'])
    assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot',stale
    frame=server.inspect('get_debug_view',tid=tid,frame=1,generation=stopped['generation'])
    assert frame['frame']==1 and frame['frames'][1]['symbol']=='main'
    invalid=server.tool('get_debug_view',frame=64)
    assert 'error' in invalid
    server.action('remove_breakpoint',id=probe)
    server.action('step_source',tid=tid);server.stopped()
    value=server.inspect('evaluate_expression',tid=tid,expression='item->value')
    assert value['value']['display']=='12',value
    server.action('continue');time.sleep(.05);server.action('interrupt');server.stopped()
finally: server.close()
assert not Path(f'/proc/{owned}').exists(),'Owned target survived disconnect'

fixture=subprocess.Popen([str(bin/'xodb-m1-fixture'),'w'])
try:
    server=Server(attach=fixture.pid)
    try:
        symbol=server.inspect('find_symbol',name='change_value')
        address=hex(symbol['address']) if isinstance(symbol['address'],int) else symbol['address']
        original=server.inspect('read_memory',address=address,length=4)['hex']
        server.action('set_breakpoint',symbol='change_value')
    finally: server.close()
    assert fixture.poll() is None,'Attached target killed on disconnect'
    status=Path(f'/proc/{fixture.pid}/status').read_text()
    assert 'TracerPid:\t0' in status,status
    server=Server(attach=fixture.pid)
    try:
        assert server.inspect('read_memory',address=address,length=4)['hex']==original,'EOF left a breakpoint in the attached process'
        server.action('set_breakpoint',symbol='change_value')
        server.p.send_signal(signal.SIGHUP)
        assert server.p.wait(timeout=10)==0
    finally: server.close()
    assert fixture.poll() is None,'Attached target killed on SSH-style hangup'
    server=Server(attach=fixture.pid)
    try:
        assert server.inspect('read_memory',address=address,length=4)['hex']==original,'Hangup left a breakpoint in the attached process'
        server.action('detach')
        assert server.session()['state']=='idle'
    finally: server.close()
    assert fixture.poll() is None
finally: fixture.terminate();fixture.wait(timeout=5)

server=Server(scope='observe')
try:
    session=server.session()
    denied=server.tool('continue',generation=session['generation'])
    assert denied['result']['isError'],denied
    names={t['name'] for t in server.call('tools/list')['result']['tools']}
    assert 'get_debug_view' in names and 'detach' not in names
finally: server.close()
print('Remote TCP passed: fragmented handshake, one client, source/stack/locals/registers, stale rejection, stepping, interrupt, owned cleanup, attach preservation, hangup/probe restoration, detach and scope')
