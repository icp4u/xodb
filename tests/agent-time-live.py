#!/usr/bin/env python3
"""Fast append/full equivalence and bounded-read checks; owned synthetic logs only."""
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests/helpers'))
from agent_time_wire import Receiver
spec=importlib.util.spec_from_file_location('agent_time',ROOT/'src/profile/agent_time.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def cx(t,kind,**fields):
    response=kind in ('function_call','function_call_output','message')
    return {'timestamp':t,'type':'response_item' if response else 'event_msg','payload':{'type':kind,**fields}}


class Live(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)

    def append(self,path,*rows):
        with path.open('ab') as f:
            data=b''.join(json.dumps(r).encode()+b'\n' for r in rows);f.write(data)
        return len(data)

    def equal(self,tail):
        result=tail.refresh()
        full=m.read_session(tail.agent,tail.path)
        comparable={k:v for k,v in result.items() if k not in ('source_fingerprint','live_read_bytes','live_mode')}
        self.assertEqual(comparable,full)
        return result

    def test_codex_every_record_and_unfinished_tool(self):
        path=self.root/'cx.jsonl';path.touch();tail=m.LiveTail('codex',path)
        rows=[cx(1,'task_started'),cx(2,'function_call',call_id='c',name='exec',arguments='{}'),
              cx(3,'token_count',info={'total_token_usage':{'input_tokens':10}}),
              cx(4,'function_call_output',call_id='c'),cx(5,'task_complete'),
              cx(6,'task_started'),cx(7,'token_count',info={'total_token_usage':{'input_tokens':30}}),cx(8,'task_complete')]
        for row in rows:
            size=self.append(path,row)
            result=self.equal(tail)
            self.assertGreaterEqual(result['live_read_bytes'],size)
            self.assertLessEqual(result['live_read_bytes'],size+16384)
        self.assertEqual(result['token_totals']['fresh input'],30)
        self.assertEqual(result['counts'].get('unmatched_results',0),0)
        with mock.patch.object(m,'codex_record',side_effect=AssertionError('unchanged source decoded')):
            self.assertEqual(tail.refresh(),{'unchanged':True})

    def test_claude_streamed_usage_and_resume(self):
        path=self.root/'cc.jsonl';path.touch();tail=m.LiveTail('claude',path)
        rows=[{'timestamp':1,'type':'user','uuid':'u','message':{'content':'A33-M1 work'}},
              {'timestamp':2,'type':'assistant','message':{'id':'m','usage':{'input_tokens':10},'content':[{'type':'tool_use','id':'a','name':'Read','input':{}}]}},
              {'timestamp':3,'type':'assistant','message':{'id':'m','usage':{'input_tokens':10,'output_tokens':2},'content':[]}},
              {'timestamp':4,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'a','content':'ok'}]}},
              {'timestamp':5,'type':'system','uuid':'end','subtype':'turn_duration'},
              {'timestamp':50,'type':'user','uuid':'resume','isMeta':True,'message':{'content':'harness'}},
              {'timestamp':51,'type':'user','message':{'content':'A33-M2 work'}},
              {'timestamp':52,'type':'assistant','message':{'id':'n','content':[],'stop_reason':'end_turn'}}]
        for row in rows:
            self.append(path,row);self.equal(tail)

    def test_grok_events_history_and_replaced_usage(self):
        path=self.root/'events.jsonl';path.touch();tail=m.LiveTail('grok',path)
        for row in [{'ts':1,'type':'turn_started'}, {'ts':2,'type':'permission_requested','tool_name':'bash'},
                    {'ts':3,'type':'permission_resolved','tool_name':'bash'},
                    {'ts':4,'type':'tool_completed','tool_name':'bash','tool_call_id':'a','duration_ms':1000},
                    {'ts':5,'type':'turn_ended','outcome':'completed'}]:
            self.append(path,row);self.equal(tail)
        self.append(self.root/'chat_history.jsonl',{'type':'user','content':'A33-M1 work'},
                    {'type':'assistant','tool_calls':[{'id':'a','name':'bash','arguments':{'cmd':'git diff --stat'}}]})
        self.equal(tail)
        for count in (10,30):
            (self.root/'usage.json').write_text(json.dumps({'turns':[{'turnNumber':1,'inputTokens':count}]}))
            result=self.equal(tail)
            self.assertEqual(result['token_totals']['fresh input'],count)
            self.assertEqual(result['live_read_bytes'],0)
        history=self.root/'chat_history.jsonl'
        added=self.append(history,{'type':'user','content':'A33-M2 work'},
                          {'type':'assistant','tool_calls':[{'id':'a','name':'bash','arguments':{'cmd':'git status --short'}}]})
        result=self.equal(tail)
        self.assertEqual(result['turns'][0]['task'],'A33-M2')
        self.assertLessEqual(result['live_read_bytes'],added+16384)

    def test_children_append_and_fork_metadata(self):
        path=self.root/'parent.jsonl'
        self.append(path,{'timestamp':1,'type':'user','message':{'content':'parent'}},
                    {'timestamp':2,'type':'assistant','message':{'content':[{'type':'tool_use','id':'fork','name':'Agent','input':{}}]}})
        tail=m.LiveTail('claude',path);self.equal(tail)
        child=self.root/'parent/subagents/agent-a.jsonl';child.parent.mkdir(parents=True)
        self.append(child,{'timestamp':1,'type':'user','message':{'content':'child'}},
                    {'timestamp':3,'type':'assistant','message':{'id':'a','usage':{'input_tokens':10},'content':[],'stop_reason':'end_turn'}})
        self.equal(tail)
        child.with_suffix('.meta.json').write_text(json.dumps({'toolUseId':'fork','isFork':True}))
        self.equal(tail)
        added=self.append(child,{'timestamp':4,'type':'user','message':{'content':'more'}},
                          {'timestamp':5,'type':'assistant','message':{'id':'b','usage':{'input_tokens':5},'content':[],'stop_reason':'end_turn'}})
        result=self.equal(tail)
        self.assertGreaterEqual(result['live_read_bytes'],added)
        self.assertLessEqual(result['live_read_bytes'],added+16384)
        child.unlink();self.equal(tail)

    def test_partial_line_rotation_truncation_and_failure_restore(self):
        path=self.root/'live.jsonl';self.append(path,cx(1,'task_started'))
        tail=m.LiveTail('codex',path);self.equal(tail)
        line=json.dumps(cx(2,'task_complete')).encode()
        with path.open('ab') as f:f.write(line[:12])
        result=tail.refresh();self.assertEqual(result['counts']['records'],1)
        self.assertEqual(result['counts'].get('malformed',0),0)
        with path.open('ab') as f:f.write(line[12:]+b'\n')
        self.equal(tail)
        path.write_text('');self.equal(tail)
        replacement=self.root/'replacement';self.append(replacement,cx(3,'task_started'),cx(4,'task_complete'))
        replacement.replace(path);self.equal(tail)
        missing=self.root/'missing';path.rename(missing)
        with self.assertRaises(FileNotFoundError):tail.refresh()
        missing.rename(path);self.equal(tail)

    def test_new_children_preserve_existing_checkpoints_and_only_decode_new_bytes(self):
        path=self.root/'parent.jsonl'
        self.append(path,{'timestamp':1,'type':'user','message':{'content':'parent'}})
        self.append(path,*[{'type':'progress','timestamp':2,'padding':'x'*1024} for _ in range(64)])
        directory=self.root/'parent/subagents';directory.mkdir(parents=True)
        def child(name,t):
            target=directory/('agent-'+name+'.jsonl')
            size=self.append(target,{'timestamp':t,'type':'user','message':{'content':'child '+name}},
                             {'timestamp':t+1,'type':'assistant','message':{'id':name,'usage':{'input_tokens':10},'content':[],'stop_reason':'end_turn'}})
            return target,size
        child('c',3);tail=m.LiveTail('claude',path);self.equal(tail)
        for name,t in [('a',5),('b',7)]: # insert before, then between existing names
            previous=dict(tail.files);budget=tail.files[path].session.budget
            added,size=child(name,t)
            with mock.patch.object(m,'claude_record',wraps=m.claude_record) as calls:
                result=tail.refresh()
            self.assertEqual(calls.call_count,2,'existing transcripts were decoded again')
            self.assertEqual(result['live_mode'],'append')
            for old,file in previous.items():self.assertIs(tail.files[old],file)
            self.assertIs(tail.files[added].session.budget,budget)
            self.assertGreaterEqual(result['live_read_bytes'],size)
            self.assertLessEqual(result['live_read_bytes'],size+8192)
            self.assertEqual({k:v for k,v in result.items() if k not in ('source_fingerprint','live_read_bytes','live_mode')},m.read_session('claude',path))
        # Newly discovered parent metadata must also preserve nested structure.
        nested,size=child('d',9)
        nested.with_suffix('.meta.json').write_text(json.dumps({'parentAgentId':'a'}))
        result=self.equal(tail)
        self.assertEqual(result['live_mode'],'append')
        self.assertEqual(result['children'][0]['children'][0]['title'],'child d')
        nested.unlink()
        self.assertEqual(self.equal(tail)['live_mode'],'rebuild')

    def test_small_append_does_not_read_or_decode_large_prefix(self):
        path=self.root/'large.jsonl'
        self.append(path,cx(1,'task_started'))
        with path.open('ab') as f:
            for _ in range(512):f.write(json.dumps({'type':'world_state','padding':'x'*8192}).encode()+b'\n')
        tail=m.LiveTail('codex',path);self.equal(tail)
        added=self.append(path,cx(2,'task_complete'))
        with mock.patch.object(m,'codex_record',wraps=m.codex_record) as calls:
            result=tail.refresh()
            self.assertEqual(calls.call_count,1)
        self.assertGreaterEqual(result['live_read_bytes'],added)
        self.assertLessEqual(result['live_read_bytes'],added+16384)
        self.assertLess(added,path.stat().st_size//100)
        self.assertEqual(result['turns'][0]['end'],2)

    def test_checkpoint_budget_falls_back_without_losing_totals(self):
        path=self.root/'limit.jsonl';self.append(path,cx(1,'task_started'),cx(2,'task_complete'))
        tail=m.LiveTail('codex',path)
        with mock.patch.object(m,'MAX_TURNS',1):
            result=self.equal(tail)
        self.assertEqual(result['live_mode'],'full (checkpoint limit)')
        self.assertEqual(tail.files,{})

    def test_oversize_partial_record_is_discarded_once(self):
        path=self.root/'oversize.jsonl';self.append(path,cx(1,'task_started'))
        tail=m.LiveTail('codex',path);self.equal(tail)
        with mock.patch.object(m,'MAX_LINE',128):
            with path.open('ab') as f:f.write(b'x'*200)
            result=tail.refresh();self.assertEqual(result['counts']['oversize'],1)
            with path.open('ab') as f:f.write(b'x'*200+b'\n')
            self.append(path,cx(2,'task_complete'))
            result=self.equal(tail)
            self.assertEqual(result['counts']['oversize'],1)
            self.assertEqual(result['counts']['records'],2)

    def test_length_framed_helper_lifetime_and_errors(self):
        path=self.root/'pipe.jsonl';self.append(path,cx(1,'task_started'))
        proc=subprocess.Popen([sys.executable,'-I','-B',str(ROOT/'src/profile/agent_time.py'),
                               '--agent','codex','--file',str(path),'--live'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        receiver=Receiver()
        def read_exact(size):
            data=b''
            while len(data)<size:
                self.assertTrue(select.select([proc.stdout],[],[],5)[0],'helper response timeout')
                block=os.read(proc.stdout.fileno(),size-len(data));self.assertTrue(block);data+=block
            return data
        def request():
            proc.stdin.write(b'refresh\n');proc.stdin.flush()
            size=int.from_bytes(read_exact(4),'big');self.assertLess(size,64*1024*1024)
            return receiver.accept(json.loads(read_exact(size)))
        try:
            self.assertEqual(request()['live_mode'],'rebuild')
            self.assertEqual(request(),{'unchanged':True})
            self.append(path,cx(2,'task_complete'))
            self.assertEqual(request()['live_mode'],'append')
            path.unlink();self.assertEqual(request(),{'failure':'AgentLogReadFailed'})
            proc.stdin.close();self.assertEqual(proc.wait(timeout=5),0)
        finally:
            if proc.poll() is None:proc.kill();proc.wait()
            for stream in (proc.stdin,proc.stdout,proc.stderr):stream.close()


if __name__=='__main__':unittest.main()
