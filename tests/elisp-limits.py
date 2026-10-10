#!/usr/bin/env python3
"""Fast local/deep checks; the large agent preview page belongs to periodic."""
import argparse, json, os, re, resource, time
from pathlib import Path
from client import Client

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs',type=Path,required=True)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--agent',type=Path)
p.add_argument('--xodb',type=Path)
p.add_argument('--case',choices=('both','deep','budget'),default='both')
p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();os.umask(0o022);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
root=Path(__file__).resolve().parents[1];w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=False)
os.environ.update(XDG_CACHE_HOME=str(w/'cache'),XODB_ELISP_LIMIT_CASE=a.case,
                  XODB_BIN=str(a.xodb.resolve() if a.xodb else root/'zig-out/bin/xodb'))
started=time.monotonic();c=None;result={'status':'failed'}
try:
    c=Client('control',str(a.emacs.resolve()),args=('-Q','--batch','-l',str(root/'tests/fixtures/elisp/deep-bindings.el')),
             options=['--break','Fdebugger_trap']+(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),
             reply_seconds=60 if a.agent and a.case!='deep' else 5)
    def usage():
        stat=Path(f'/proc/{c.p.pid}/stat').read_text().rsplit(')',1)[1].split()
        return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),
                    rss_kib=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{c.p.pid}/status').read_text(),re.M)[1]))
    def stop():
        c.continue_initial_stop()
        state=c.stopped('breakpoint',seconds=180)
        return state,c.inspect('get_language_stack',language='elisp',tid=state['pid'])['segments'][0]
    def locals_(state,frame):
        out=c.inspect('get_language_locals',language='elisp',generation=state['generation'],
                      tid=state['pid'],segment=0,frame=frame)
        budgets=2+len(out['rows'])
        assert out['memory_reads']<=budgets*8192 and out['memory_bytes']<=budgets*2*1024*1024,out
        return out
    cases=[]
    if a.case!='budget':
        state,stack=stop();before=usage()
        assert len(stack['frames'])==128 and not stack['chain_complete'] and stack['reason']=='ElispFrameLimit',stack
        assert sum(row['kind']=='condition-case' for row in stack['controls'])>0,stack
        assert sum(row['kind']!='unwind cleanup' for row in stack['controls'])==128,stack
        frames=[i for i,row in enumerate(stack['frames']) if row['name']=='let'][:3]
        assert len(frames)==3,stack
        rows=[]
        for depth,frame in enumerate(frames):
            out=locals_(state,frame);shown={r['name']:r for r in out['rows']}
            assert out['diagnostic'] is None,out
            expected=depth+(1 if a.wrong_oracle else 0)
            assert shown['xodb-depth']['value']['display']==str(expected),('deep binding mismatch',depth,out)
            assert shown['xodb-token']['value']['display']==json.dumps(f'level-{depth}'),out
            assert 'n' not in shown,('inherited lexical binding repeated',out)
            rows.append(out)
        # The last GUI/MCP-selectable frame remains usable too (selection caps at 64).
        tail=locals_(state,63);assert tail['diagnostic'] is None,tail
        cases.append(dict(case='deep',controls=len(stack['controls']),frames=len(stack['frames']),
                          locals=rows,tail=tail,before=before,after=usage()))
    if a.case!='deep':
        state,stack=stop();before=usage()
        mark=next(i for i,row in enumerate(stack['frames']) if row['name']=='xodb-budget-mark')
        out=locals_(state,mark+1)
        rows=[r for r in out['rows'] if r['name'].startswith('xodb-budget-')]
        assert len(rows)==(31 if a.wrong_oracle else 32),('preview row mismatch',out)
        assert {r['name'] for r in rows}=={f'xodb-budget-{i:02d}' for i in range(32)},out
        assert out['memory_reads']>8192,('fixture did not exhaust the former cumulative budget',out)
        for row in rows:
            value=row['value']
            assert value['type']=='vector' and value['display'].startswith('['),('blank preview',row)
            assert value['diagnostic']!='ElispReadLimit',row
        cases.append(dict(case='budget',locals=out,before=before,after=usage()))
    c.continue_initial_stop();deadline=time.monotonic()+15
    while c.session()['state']!='exited':
        assert time.monotonic()<deadline
        time.sleep(.002)
    result=dict(status='pass',cases=cases,seconds=time.monotonic()-started,agent=bool(a.agent),load=os.getloadavg())
    print('Elisp caps, frame-local lexical bindings and independent previews PASS')
finally:
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    if c:
        try:c.close()
        finally:
            (w/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n')
            (w/'stderr.log').write_bytes(c.p.stderr.read())
