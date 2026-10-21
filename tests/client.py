"""Small synchronous test client for the shared stdio MCP endpoint."""
import json
import os
import select
import subprocess
import time
from pathlib import Path
from helpers.exact import assert_reply_exact
from helpers.tasks import children as task_children
# Tests never adopt or start the user's Ghidra sidecar; the sidecar tests set their own.
os.environ.setdefault('XODB_GHIDRA_SIDECAR', 'off')

def with_runtime_agent(options, executable):
    """Prefix options with the C agent when a lane asks for it.

    XODB_TEST_RUNTIME_AGENT is the release-check agent lane, the same switch
    tests/helpers/input.py reads for a GUI launch. It applies to a launch and
    to an attach. XODB_RUNTIME_AGENT is the older per-test switch and applies
    only to a launch. When a launch sets it, that agent wins: the test chose
    a proxy or a specific binary. A core file, a capture, an overview, a packet
    capture, a mitmproxy flow and the Redot debugger stay on the path the
    caller named. An option list that already names the agent is left alone.
    """
    options = list(options)
    if any(option in options for option in (
            '--runtime-agent', '--core', '--open-capture', '--open-profile',
            '--compare-capture', '--runtime-ssh', '--gdb-remote',
            '--overview', '--open-pcap', '--open-mitmproxy', '--redot-debugger',
            '--open-frames', '--open-observation', '--browse-observation', '--decompile')):
        return options
    agent = os.environ.get('XODB_RUNTIME_AGENT') if executable is not None else None
    if not agent:
        agent = os.environ.get('XODB_TEST_RUNTIME_AGENT')
    if not agent:
        return options
    return ['--runtime-agent', agent, *options]


def runtime_agent_args():
    """Arguments for a launcher that builds its own xodb command.

    The lane switch and the older per-test switch name the same agent. A
    caller that already put --runtime-agent in its own list should not call
    this. An empty result leaves the command in-process.
    """
    agent = os.environ.get('XODB_RUNTIME_AGENT') or os.environ.get('XODB_TEST_RUNTIME_AGENT')
    if not agent:
        return []
    return ['--runtime-agent', str(Path(agent).resolve())]


class Client:
    reply_seconds = 5  # subclasses that build their own process skip __init__
    def __init__(self, scope, executable='./zig-out/bin/xodb-m1-fixture', args=(), options=(), reply_seconds=5):
        self.transcript = []
        self.reply_seconds = reply_seconds
        options = with_runtime_agent(options, executable)
        self.runtime_agent = '--runtime-agent' in options
        self.p = subprocess.Popen([os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp', '--agent-scope', scope, *options, *(['--', executable, *args] if executable is not None else [])], bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.id = 0
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'M1-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.p.stdin.flush()
    def collector_pid(self):
        """Kernel perf descriptors belong to the local C agent when selected."""
        if not self.runtime_agent: return self.p.pid
        children = task_children(self.p.pid)
        assert len(children) == 1, children
        return children[0]
    def call(self, method, params=None):
        self.id += 1
        self.p.stdin.write((json.dumps({'jsonrpc':'2.0','id':self.id,'method':method,'params':params or {}})+'\n').encode())
        self.p.stdin.flush()
        deadline = time.monotonic() + self.reply_seconds
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
        return assert_reply_exact(self.call('tools/call', {'name':tool_name,'arguments':args}))
    def inspect(self, tool_name, **args):
        deadline = time.monotonic() + (900 if tool_name == 'get_language_stack' else 15)
        while True:
            response = self.tool(tool_name, **args)
            if tool_name == 'get_language_stack' and 'result' in response and response['result'].get('isError') and response['result']['content'][0]['text'] == 'DebugMetadataPending':
                assert time.monotonic() < deadline, response
                time.sleep(.02)
                continue
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
    def continue_initial_stop(self):
        """Discovery can revise the initial stop; retry one rejected continue."""
        for attempt in range(2):
            state = self.session()
            assert state['state'] == 'stopped', state
            response = self.tool('continue', generation=state['generation'])
            result = response.get('result', {})
            stale = (result.get('isError') and
                     result.get('content') == [{'type':'text', 'text':'StaleSnapshot'}])
            if stale and attempt == 0:
                continue
            assert 'error' not in response and result and not result['isError'], response
            return result['structuredContent']
    def stopped(self, reason=None, seconds=5):
        deadline = time.monotonic()+seconds
        while time.monotonic()<deadline:
            session = self.session()
            # A loader rendezvous is also a breakpoint stop. Remote discovery
            # may expose it across owner turns before the accepted continue
            # resumes. Wait for discovery/run-control work to settle first.
            if session['state']=='stopped' and not session['symbol_discovery_pending'] and not session['continue_pending'] and (reason is None or any(t['reason']==reason for t in session['threads'])):
                return session
            assert session['state']!='exited', session
            time.sleep(.002)
        raise AssertionError(f'Stop timeout: {session}')
    def close(self):
        self.p.stdin.close()
        try: assert self.p.wait(timeout=5)==0, self.p.stderr.read().decode()
        finally:
            if self.p.poll() is None: self.p.kill(); self.p.wait()
