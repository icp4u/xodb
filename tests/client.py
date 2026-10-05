"""Small synchronous test client for the shared stdio MCP endpoint."""
import json
import os
import select
import subprocess
import time
from pathlib import Path

class Client:
    def __init__(self, scope, executable='./zig-out/bin/xodb-m1-fixture', args=(), options=()):
        self.transcript = []
        agent = os.environ.get('XODB_RUNTIME_AGENT') if executable is not None else None
        if agent and '--runtime-agent' not in options:
            options = ['--runtime-agent', agent, *options]
        self.runtime_agent = '--runtime-agent' in options
        self.p = subprocess.Popen([os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp', '--agent-scope', scope, *options, *(['--', executable, *args] if executable is not None else [])], bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.id = 0
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'M1-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.p.stdin.flush()
    def collector_pid(self):
        """Kernel perf descriptors belong to the local C agent when selected."""
        if not self.runtime_agent: return self.p.pid
        children = Path(f'/proc/{self.p.pid}/task/{self.p.pid}/children').read_text().split()
        assert len(children) == 1, children
        return int(children[0])
    def call(self, method, params=None):
        self.id += 1
        self.p.stdin.write((json.dumps({'jsonrpc':'2.0','id':self.id,'method':method,'params':params or {}})+'\n').encode())
        self.p.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert select.select([self.p.stdout],[],[],max(0, deadline-time.monotonic()))[0], 'Response timeout'
            data = self.p.stdout.readline()
            assert data, self.p.stderr.read().decode()
            response = json.loads(data)
            if 'id' not in response:
                self.transcript.append({'notification':response})
                continue
            assert response['id'] == self.id
            self.transcript.append({'method':method,'params':params or {},'response':response})
            return response
        raise AssertionError('Response timeout')
    def tool(self, tool_name, **args):
        return self.call('tools/call', {'name':tool_name,'arguments':args})
    def inspect(self, tool_name, **args):
        deadline = time.monotonic() + 15
        while True:
            response = self.tool(tool_name, **args)
            if tool_name == 'export_profile' and 'result' in response and response['result'].get('isError') and response['result']['content'][0]['text'] == 'ProfileViewPending':
                assert time.monotonic() < deadline, response
                time.sleep(.002)
                continue
            assert 'error' not in response and not response['result']['isError'], response
            data = response['result']['structuredContent']
            if tool_name != 'get_flamegraph' or args.get('basis') == 'reconstructed' or not data.get('pending'): return data
            assert time.monotonic() < deadline, data
            args['view_id'] = data['view_id']
            args['revision'] = data['revision']
            time.sleep(.002)
    def session(self): return self.inspect('get_session')
    def action(self, tool_name, **args):
        return self.inspect(tool_name, generation=self.session()['generation'], **args)
    def stopped(self, reason=None):
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            session = self.session()
            if session['state']=='stopped' and (reason is None or any(t['reason']==reason for t in session['threads'])):
                return session
            assert session['state']!='exited', session
            time.sleep(.002)
        raise AssertionError(f'Stop timeout: {session}')
    def close(self):
        self.p.stdin.close()
        try: assert self.p.wait(timeout=5)==0, self.p.stderr.read().decode()
        finally:
            if self.p.poll() is None: self.p.kill(); self.p.wait()
