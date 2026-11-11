#!/usr/bin/env python3
"""Fast offline transcript/summarizer oracles; only synthetic content."""
import importlib.util
import io
import json
import os
from pathlib import Path
import random
import tempfile
import unittest
import sys
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('agent_time', ROOT/'src/profile/agent_time.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Commands(unittest.TestCase):
    def test_corpus(self):
        corpus = [
            ('cd /srv/project && git diff --stat', 'git', 'git diff --stat'),
            ('FOO=1 timeout 90 nice -n 5 zig build -Doptimize=ReleaseSafe -j2', 'build', 'zig build -Doptimize=ReleaseSafe'),
            ('env FOO=1 scripts/release-check all --only lsof-top > out', 'gate', 'scripts/release-check all --only lsof-top'),
            ('gate-slot.sh task scripts/release-check periodic-gui', 'gate', 'scripts/release-check periodic-gui'),
            ('python3 tests/fdactivity.py --work /srv/scratch', 'test', 'python3 tests/fdactivity.py'),
            ('rg needle src/ | head -20', 'search', 'rg needle src/'),
            ('rg ";" src/', 'search', 'rg ; src/'),
            ('rg "a|b" src/ # read only', 'search', 'rg a|b src/'),
            ('cd src\nmake', 'build', 'make'),
            ('ssh machine "git diff --stat"', 'ssh/remote', 'ssh remote: git diff --stat'),
            ('sudo -n env FOO=1 kl-run x86_64-orc', 'lab/qemu', 'kl-run x86_64-orc'),
            ('(cd build && make -j2) > build.log', 'build', 'make'),
            ('bash -lc "cd src && git status --short"', 'git', 'git status --short'),
            ('python3 -c \'import json; json.load(open("results.json"))\'', 'other', 'python3 inline (1 lines): json parse of results.json'),
            ('python3 <<\'PY\'\nimport json\njson.load(open("results.json"))\nPY', 'other', 'python3 inline (2 lines): json parse of results.json'),
            ('python3 <<EOF\nfrom client import Client\nc = Client()\nEOF', 'other', 'python3 inline (2 lines): MCP client'),
            # Shapes seen in real logs (sanitized): bodies on later lines, file
            # writes, remote scripts, pipeline filters and bare assignments.
            ("B=/srv/w; cat > $B/notes/reply.md <<'EOF'\nbody text\nEOF", 'edit', 'write reply.md (1 lines)'),
            ('umask 022\npython3 - <<\'PY\'\nimport json\njson.load(open("a.json"))\nPY\nrm -f /srv/x', 'other', 'python3 inline (2 lines): json parse of a.json'),
            ("ssh -o BatchMode=yes machine 'bash -s' <<'EOF'\nls /srv\nEOF", 'ssh/remote', 'ssh remote: ls srv (1 lines)'),
            ("ssh machine 'cd w && python3 - <<EOF\nimport re\nEOF\n'", 'ssh/remote', 'ssh remote: python3 inline (1 lines): uses re'),
            ('make -j2 2>&1 | tail -3', 'build', 'make'),
            ('cd /srv && find . -maxdepth 1 -type d | wc -l', 'search', 'find .'),
            ('B=/srv/w; $B/tool --flag', 'other', 'tool'),
            ('x=1 && git clone -q u d && rm -rf d', 'git', 'git clone'),
            ('python3 -c "print(1<<4)"', 'other', 'python3 inline (1 lines): inline script'),
        ]
        for source,cls,label in corpus:
            with self.subTest(source=source):
                got=m.summarizeCommand(source)
                self.assertEqual((got['class'],got['label']),(cls,label))

    def test_stable_bounded(self):
        rng=random.Random(25)
        for _ in range(500):
            source='rg '+''.join(rng.choice('abc /;$\'"<>') for _ in range(rng.randrange(500)))
            a=m.summarizeCommand(source)
            self.assertEqual(a,m.summarizeCommand(source))
            self.assertLessEqual(len(a['label']),60)
            self.assertLessEqual(len(a['full']),240)

    def test_temp_names_merge(self):
        for a,b in (('cd ~/tmp/hgA.XyZ && python3 -B tests/x.py','cd ~/tmp/hgB.Q12 && python3 -B tests/x.py'),
                    ("cat > /srv/aa.Q1/f.md <<E\none\nE","cat > /srv/bb.R2/f.md <<E\ntwo\nE"),
                    ('T=/srv/t1; $T/zig-out/bin/xodb --version','T=/srv/t2; $T/zig-out/bin/xodb --version')):
            self.assertEqual(m.summarizeCommand(a)['label'],m.summarizeCommand(b)['label'])

    def test_redact_hides_search_patterns(self):
        m.REDACT=True
        try: self.assertEqual(m.summarizeCommand('rg -n "person@example" src/')['label'],'rg … src/')
        finally: m.REDACT=False

    def test_injected_prompt_is_not_title(self):
        self.assertEqual(m.prompt_text([{'type':'input_text','text':'<environment_context> <cwd>/srv</cwd>'},{'type':'input_text','text':'fix the build'}]),'fix the build')
        self.assertEqual(m.prompt_text('<system-reminder>x</system-reminder>'),'')
        self.assertEqual(m.prompt_text('# AGENTS.md instructions for /srv'),'')

    def test_credentials_and_bodies(self):
        for source in ('TOKEN_KEY=not-public git diff', 'curl --token not-public', 'rg "Authorization: Bearer not-public" src', 'ssh -i /srv/not-public remote git status', 'python3 <<EOF\nprint("not-public")\nEOF'):
            self.assertNotIn('not-public',json.dumps(m.summarizeCommand(source)))

    def test_orchestrated(self):
        result=m.tool_detail('exec','text(await tools.exec_command({cmd:"git diff --stat"})); text(await tools.exec_command({cmd:"ls"}));')
        self.assertEqual(result['label'],'git diff --stat (+1 commands)')
        self.assertEqual(m.tool_detail('exec',"await tools.exec_command({cmd:'git diff --stat'})")['label'],'git diff --stat')
        self.assertEqual(m.tool_detail('exec',r'tools.exec_command({cmd:"rg \q src/"})')['label'],'rg q src/')
        self.assertEqual(m.tool_detail('exec','tools.exec_command({cmd:"git diff\n--stat"})')['label'],'git diff')
        self.assertEqual(m.tool_detail('exec','await tools.apply_patch("opaque body")')['class'],'edit')
        self.assertEqual(m.tool_detail('read_file',{'target_file':'src/example.zig'})['label'],'src/example.zig')
        # JS string escapes that JSON rejects must not fail the whole import.
        self.assertEqual(m.tool_detail('exec','text(await tools.exec_command({cmd:"rg \\$x src"}))')['label'],'rg $x src')


class Adapters(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='agent-time-')
        self.root=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def write(self,name,rows):
        path=self.root/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text('\n'.join(json.dumps(r) for r in rows)+'\n')
        return path
    def cx(self,t,kind,**fields):return {'timestamp':t,'type':'event_msg' if kind not in ('function_call','function_call_output','message') else 'response_item','payload':{'type':kind,**fields}}

    def test_claude_handback_resume_is_wait_not_model(self):
        for gap in (2, 14*3600):
            with self.subTest(gap=gap):
                rows=[
                    {'uuid':'prompt','timestamp':1,'type':'user','message':{'content':'synthetic child task'}},
                    {'uuid':'call','timestamp':2,'type':'assistant','message':{'id':'m1','usage':{'input_tokens':10,'output_tokens':2},'content':[{'type':'tool_use','id':'handback','name':'SubagentHandback','input':{}}]}},
                    {'uuid':'returned','timestamp':3,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'handback','content':'handed back'}]}},
                    {'uuid':'resume','timestamp':3+gap,'type':'user','isMeta':True,'message':{'content':'resume the synthetic task'}},
                    {'uuid':'end','timestamp':6+gap,'type':'assistant','message':{'id':'m2','usage':{'input_tokens':20,'output_tokens':3},'content':[],'stop_reason':'end_turn'}},
                ]
                doc=m.claude(self.write('idle.jsonl',rows),False).document()
                waits=[s for s in doc['spans'] if s['activity']=='waiting for resume']
                self.assertEqual(len(waits),1)
                self.assertEqual((waits[0]['start'],waits[0]['end']),(3,3+gap))
                self.assertEqual((waits[0]['start_record_id'],waits[0]['end_record_id']),('returned','resume'))
                self.assertEqual(sum(s['end']-s['start'] for s in doc['spans'] if s['activity']=='model (inferred)'),4)
                self.assertEqual(doc['agent_seconds'],5)
                self.assertEqual(doc['wall_seconds'],5+gap)
                self.assertEqual(sum(doc['token_totals'].values()),35)
                self.assertEqual(len(doc['turns']),2)
                self.assertEqual(doc['counts']['handbacks'],1)
                self.assertEqual(doc['counts']['resumes'],1)

    def test_claude_metadata_during_work_does_not_end_tool(self):
        rows=[{'timestamp':1,'type':'user','message':{'content':'task'}},
              {'timestamp':2,'type':'assistant','message':{'content':[{'type':'tool_use','id':'a','name':'Bash','input':{'command':'make'}}]}},
              {'timestamp':3,'type':'user','isMeta':True,'message':{'content':'<system-reminder>context'}},
              {'timestamp':7200,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'a','content':'done'}]}},
              {'timestamp':7201,'type':'assistant','message':{'content':[],'stop_reason':'end_turn'}}]
        doc=m.claude(self.write('busy.jsonl',rows),False).document()
        self.assertEqual(len(doc['turns']),1)
        self.assertEqual(doc['turns'][0]['tool_seconds'],7198)
        self.assertFalse(any(s['activity'].startswith('waiting for ') for s in doc['spans']))

    def test_index_cache_warm_numeric_only_and_append(self):
        path=self.write('private-name.jsonl',[self.cx(1,'task_started'),self.cx(1,'message',role='user',content=[{'type':'input_text','text':'private prompt'}]),self.cx(2,'token_count',info={'total_token_usage':{'input_tokens':100,'output_tokens':30}}),self.cx(3,'task_complete')])
        cache=m.IndexCache(self.root/'cache')
        cold=m.index_session('codex',path,cache)
        self.assertEqual(cold['tokens'],130)
        self.assertFalse(cold['cached'])
        entry=cache.entry('codex',path)
        text=entry.read_text()
        self.assertNotIn('private',text)
        self.assertNotIn(str(path),text)
        self.assertEqual(entry.stat().st_mode & 0o777,0o600)
        with mock.patch.object(m,'read_session',side_effect=AssertionError('warm cache parsed transcript')):
            warm=m.index_session('codex',path,cache)
        self.assertTrue(warm['cached'])
        self.assertEqual(warm['tokens'],130)
        with path.open('a') as f:f.write(json.dumps(self.cx(4,'token_count',info={'total_token_usage':{'input_tokens':200,'output_tokens':30}}))+'\n')
        changed=m.index_session('codex',path,cache)
        self.assertFalse(changed['cached'])
        self.assertEqual(changed['tokens'],230)

    def test_index_cache_corruption_version_and_identity(self):
        path=self.write('session.jsonl',[self.cx(1,'task_started'),self.cx(2,'task_complete')])
        cache=m.IndexCache(self.root/'cache');m.index_session('codex',path,cache)
        entry=cache.entry('codex',path);before=m.source_fingerprint('codex',path)
        for bad in ('bad json','[]',json.dumps({'version':-1,'fingerprint':before,'summary':{}})):
            entry.write_text(bad)
            self.assertIsNone(cache.load('codex',path,before))
            self.assertFalse(m.index_session('codex',path,cache)['cached'])
        row=json.loads(entry.read_text());row['summary']['start']=1e300
        entry.write_text(json.dumps(row))
        self.assertIsNone(cache.load('codex',path,before))
        m.index_session('codex',path,cache)
        stat=path.stat();replacement=self.root/'replacement'
        replacement.write_bytes(path.read_bytes());os.replace(replacement,path)
        os.utime(path,ns=(stat.st_atime_ns,stat.st_mtime_ns))
        self.assertNotEqual(before,m.source_fingerprint('codex',path))
        self.assertFalse(m.index_session('codex',path,cache)['cached'])

    def test_index_cache_sidecars_invalidate(self):
        parent=self.write('parent.jsonl',[{'timestamp':1,'type':'user','message':{'content':'task'}},{'timestamp':2,'type':'assistant','message':{'id':'parent','usage':{'input_tokens':10},'content':[],'stop_reason':'end_turn'}}])
        child=self.write('parent/subagents/agent-worker.jsonl',[{'timestamp':1,'type':'user','message':{'content':'task'}},{'timestamp':2,'type':'assistant','message':{'id':'child','usage':{'input_tokens':20},'content':[],'stop_reason':'end_turn'}}])
        cache=m.IndexCache(self.root/'cache')
        self.assertEqual(m.index_session('claude',parent,cache)['tokens'],30)
        before=m.source_fingerprint('claude',parent)
        child.with_suffix('.meta.json').write_text(json.dumps({'description':'new description'}))
        self.assertNotEqual(before,m.source_fingerprint('claude',parent))
        self.assertFalse(m.index_session('claude',parent,cache)['cached'])
        before=m.source_fingerprint('claude',parent)
        with child.open('a') as f:f.write('\n')
        self.assertNotEqual(before,m.source_fingerprint('claude',parent))
        grok=self.write('grok/events.jsonl',[{'ts':1,'type':'turn_started'},{'ts':2,'type':'turn_ended','outcome':'success'}])
        usage=grok.with_name('usage.json')
        usage.write_text(json.dumps({'turns':[{'turnNumber':1,'inputTokens':100,'outputTokens':20}]}))
        self.assertEqual(m.index_session('grok',grok,cache)['tokens'],120)
        usage.write_text(json.dumps({'turns':[{'turnNumber':1,'inputTokens':200,'outputTokens':20}]}))
        changed=m.index_session('grok',grok,cache)
        self.assertFalse(changed['cached']);self.assertEqual(changed['tokens'],220)

    def test_index_cache_bound_failure_and_changing_source(self):
        path=self.write('session.jsonl',[self.cx(1,'task_started'),self.cx(2,'task_complete')])
        cache=m.IndexCache(self.root/'cache')
        original=m.read_session
        def changing(agent,path):
            doc=original(agent,path)
            with path.open('a') as f:f.write('\n')
            return doc
        with mock.patch.object(m,'read_session',side_effect=changing):result=m.index_session('codex',path,cache)
        self.assertEqual(result['cache_state'],'source changed; uncached')
        self.assertFalse(cache.entry('codex',path).exists())
        blocked=self.root/'not-directory';blocked.write_text('owned fixture')
        self.assertEqual(m.index_session('codex',path,m.IndexCache(blocked))['cache_state'],'cache unavailable')
        with mock.patch.object(m,'MAX_SESSIONS',2):
            for i in range(3):self.assertTrue(cache.store('codex',self.root/str(i),'fingerprint',{'start':1,'end':2,'duration':1,'tokens':None,'turn_count':1}))
        self.assertEqual(len(list(cache.root.glob('*.json'))),2)
        self.assertFalse(list(cache.root.glob('.index-*')))
    def test_codex_overlap_and_cumulative(self):
        rows=[self.cx(10,'task_started'),self.cx(11,'function_call',call_id='a',name='exec',arguments='{"cmd":"git diff"}'),self.cx(12,'function_call',call_id='b',name='read',arguments='{}'),self.cx(15,'function_call_output',call_id='a'),self.cx(18,'function_call_output',call_id='b')]
        for t,n in ((19,100),(19,100),(20,200)):
            rows.append(self.cx(t,'token_count',info={'total_token_usage':{'input_tokens':n,'cached_input_tokens':n//2,'output_tokens':20,'reasoning_output_tokens':5}}))
        rows += [self.cx(21,'task_complete'),self.cx(30,'task_started'),self.cx(31,'task_complete')]
        path=self.write('codex.jsonl',rows)
        s=m.codex(path).document()
        self.assertEqual(s['turns'][0]['tool_seconds'],7)
        self.assertEqual(s['turns'][0]['tools'],{'exec':4,'read':6})
        self.assertEqual(s['token_totals'],{'fresh input':100,'cached input':100,'cache write':0,'output':15,'reasoning':5})
        self.assertEqual(sum(x['end']-x['start'] for x in s['spans'] if x['activity']=='waiting for user'),9)
        self.assertEqual(s['agent_seconds'],15)
        self.assertEqual(s['wall_seconds'],21)
        # Planted wrong union must be distinguishable from parallel agent time.
        self.assertNotEqual(s['turns'][0]['tool_seconds'],10)

    def test_incomplete_unknown_malformed(self):
        path=self.write('partial.jsonl',[self.cx(1,'task_started'),self.cx(2,'function_call',call_id='open',name='exec'),self.cx(3,'new_format')])
        with path.open('a') as f:f.write('not-json\n')
        s=m.codex(path).document()
        self.assertTrue(s['turns'][0]['incomplete'])
        self.assertEqual(s['counts']['unfinished_tools'],1)
        self.assertEqual(s['counts']['unknown'],1)
        self.assertEqual(s['counts']['malformed'],1)

    def test_claude_stream_dedup_and_child(self):
        usage={'input_tokens':10,'cache_read_input_tokens':20,'cache_creation_input_tokens':30,'cache_creation':{'ephemeral_1h_input_tokens':30},'output_tokens':4}
        rows=[{'timestamp':1,'type':'user','message':{'content':'synthetic task'}}]
        for t,output in ((2,1),(3,4)):
            rows.append({'timestamp':t,'type':'assistant','message':{'id':'response','usage':dict(usage,output_tokens=output),'content':[{'type':'tool_use','id':'spawn','name':'Agent','input':{}}] if t==3 else []}})
        rows += [{'timestamp':4,'type':'user','toolUseResult':{'agentId':'child'},'message':{'content':[{'type':'tool_result','tool_use_id':'spawn','content':'ok'}]}}, {'timestamp':6,'type':'assistant','message':{'id':'final','content':[],'stop_reason':'end_turn'}}]
        path=self.write('parent.jsonl',rows)
        self.write('parent/subagents/agent-child.jsonl',[{'timestamp':3,'type':'user','message':{'content':'child work'}},{'timestamp':5,'type':'assistant','message':{'id':'child-response','usage':usage,'stop_reason':'end_turn','content':[]}}])
        s=m.claude(path).document()
        self.assertEqual(sum(s['token_totals'].values()),64)
        self.assertEqual(s['children'][0]['parent_call_id'],'spawn')
        self.assertEqual(len(s['turns']),1)
        self.assertFalse(s['turns'][0]['incomplete'])

    def test_grok_duration_permission_and_arguments(self):
        path=self.write('session/events.jsonl',[{'ts':1,'type':'turn_started'},{'ts':2,'type':'permission_requested','tool_name':'bash'},{'ts':3,'type':'permission_resolved','tool_name':'bash'},{'ts':7,'type':'tool_completed','tool_name':'bash','tool_call_id':'a','duration_ms':3000},{'ts':9,'type':'turn_ended','outcome':'success'}])
        self.write('session/chat_history.jsonl',[{'type':'user','content':[{'type':'text','text':'synthetic task'}]},{'type':'assistant','tool_calls':[{'id':'a','name':'bash','arguments':'{"command":"git diff --stat"}'}]}])
        s=m.grok(path).document()
        self.assertFalse(s['token_available'])
        self.assertEqual(s['turns'][0]['tool_seconds'],3)
        span=next(x for x in s['spans'] if x['activity']=='tool:bash')
        self.assertEqual(span['detail'],'git diff --stat')
        self.assertEqual(span['class'],'git')
        self.assertEqual(span['full'],'git diff --stat')
        self.assertEqual(s['title'],'synthetic task')
        self.assertEqual(sum(x['end']-x['start'] for x in s['spans']),8)

    def test_grok_usage_and_project(self):
        path=self.write('%2Fsrv%2Fproj/session/events.jsonl',[{'ts':1,'type':'turn_started'},{'ts':4,'type':'turn_ended','outcome':'success'},{'ts':5,'type':'turn_started'},{'ts':9,'type':'turn_ended','outcome':'success'}])
        (path.parent/'usage.json').write_text(json.dumps({'session':{},'turns':[{'turnNumber':2,'inputTokens':100,'cachedReadTokens':60,'cacheCreationTokens':0,'outputTokens':30,'reasoningTokens':10,'totalTokens':130}]}))
        s=m.grok(path).document()
        self.assertTrue(s['token_available'])
        self.assertEqual(s['token_totals'],{'fresh input':40,'cached input':60,'cache write':0,'output':20,'reasoning':10})
        self.assertEqual([t['turn'] for t in s['tokens']],[1])
        self.assertEqual(s['project'],'/srv/proj')

    def test_queued_prompt_does_not_reach_back(self):
        rows=[{'timestamp':10,'type':'user','message':{'content':'synthetic one'}},
              {'timestamp':20,'type':'assistant','message':{'id':'m1','content':[],'stop_reason':'end_turn'}},
              {'timestamp':5,'type':'user','message':{'content':'synthetic queued'}},
              {'timestamp':25,'type':'assistant','message':{'id':'m2','content':[],'stop_reason':'end_turn'}}]
        s=m.claude(self.write('queued.jsonl',rows),False).document()
        self.assertEqual(s['turns'][1]['start'],20)
        self.assertEqual(s['counts']['out_of_order_turns'],1)
        self.assertEqual(s['agent_seconds'],15)

    def test_adapter_hash_in_fingerprint(self):
        import subprocess,sys
        src=(ROOT/'src/profile/agent_time.py').read_text()
        out=subprocess.run([sys.executable,'-I','-B','-c',src+'\nprint(ADAPTER_HASH,file=sys.stderr)','--list'],capture_output=True,text=True,env={'HOME':str(self.root),'XDG_CACHE_HOME':str(self.root/'c')})
        self.assertEqual(out.stderr.strip(),__import__('hashlib').sha256((src+'\nprint(ADAPTER_HASH,file=sys.stderr)').encode()).hexdigest()[:16])
        self.assertEqual(m.ADAPTER_HASH,__import__('hashlib').sha256(src.encode()).hexdigest()[:16])
        path=self.write('h.jsonl',[{'timestamp':1,'type':'event_msg','payload':{'type':'task_started'}}])
        before=m.source_fingerprint('codex',path); m.ADAPTER_HASH='other'
        try: self.assertNotEqual(before,m.source_fingerprint('codex',path))
        finally: m.ADAPTER_HASH=m.adapter_hash()

    def test_fleet_totals_survive_shared_budget(self):
        rows=[self.cx(0,'task_started')]
        for i in range(6): rows+=[self.cx(1+2*i,'function_call',call_id=str(i),name='exec',arguments='{}'),self.cx(2+2*i,'function_call_output',call_id=str(i))]
        rows+=[self.cx(20,'task_complete')]
        a=self.write('a.jsonl',rows); b=self.write('b.jsonl',rows)
        alone=m.read_session('codex',b)['tree_agent_seconds']
        old=m.MAX_SPANS; m.MAX_SPANS=8
        try: f=m.fleet({'sessions':[{'agent':'codex','path':str(a)},{'agent':'codex','path':str(b)}]})
        finally: m.MAX_SPANS=old
        self.assertGreater(f['tree_counts'].get('limited_spans',0),0)
        self.assertEqual([c['tree_agent_seconds'] for c in f['children']],[alone,alone])

    def test_relative_xdg_cache_ignored(self):
        import os
        old=os.environ.get('XDG_CACHE_HOME')
        os.environ['XDG_CACHE_HOME']='relative'
        try: self.assertTrue(m.IndexCache().root.is_absolute())
        finally:
            if old is None: os.environ.pop('XDG_CACHE_HOME')
            else: os.environ['XDG_CACHE_HOME']=old

    def test_claude_meta_before_prompt_is_user_wait(self):
        rows=[{'timestamp':1,'type':'user','uuid':'u1','message':{'content':'synthetic one'}},
              {'timestamp':2,'type':'assistant','uuid':'a1','message':{'id':'m1','content':[],'stop_reason':'end_turn'}},
              {'timestamp':50,'type':'user','uuid':'meta','isMeta':True,'message':{'content':'harness note'}},
              {'timestamp':50.5,'type':'user','uuid':'u2','message':{'content':'synthetic two'}},
              {'timestamp':52,'type':'assistant','uuid':'a2','message':{'id':'m2','content':[],'stop_reason':'end_turn'}},
              {'timestamp':90,'type':'user','uuid':'wake','isMeta':True,'message':{'content':'harness wake'}},
              {'timestamp':91,'type':'assistant','uuid':'a3','message':{'id':'m3','content':[],'stop_reason':'end_turn'}}]
        s=m.claude(self.write('meta.jsonl',rows),False).document()
        waits=[(x['activity'],x['end']-x['start']) for x in s['spans'] if x['activity'].startswith('waiting')]
        self.assertEqual(waits,[('waiting for user',48),('waiting for resume',38)])
        self.assertEqual([x['title'] for x in s['turns']],['synthetic one','synthetic two','resumed work'])
        self.assertEqual(s['title'],'synthetic one')

    def test_claude_fork_copy_charged_once(self):
        shared=[{'timestamp':2,'type':'assistant','message':{'id':'m1','usage':{'input_tokens':10},'content':[{'type':'tool_use','id':'c1','name':'Read','input':{}}]}},
                {'timestamp':3,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'c1','content':'x'}]}}]
        spawn=[{'timestamp':4,'type':'assistant','message':{'id':'m2','usage':{'input_tokens':1},'content':[{'type':'tool_use','id':'fork','name':'Agent','input':{}}]}},
               {'timestamp':9,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'fork','content':'ok'}]}}]
        path=self.write('forked.jsonl',[{'timestamp':1,'type':'user','message':{'content':'synthetic'}}]+shared+spawn)
        self.write('forked/subagents/agent-f.jsonl',[{'timestamp':1,'type':'user','message':{'content':'synthetic'}}]+shared+[{'timestamp':5,'type':'assistant','message':{'id':'m3','usage':{'input_tokens':5},'content':[],'stop_reason':'end_turn'}}])
        (self.root/'forked/subagents/agent-f.meta.json').write_text(json.dumps({'toolUseId':'fork','isFork':True}))
        doc=m.claude(path).document()
        self.assertEqual(sum(doc['tree_token_totals'].values()),16)
        self.assertEqual(doc['tree_counts']['copied_usage'],1)
        self.assertEqual(doc['tree_counts']['copied_calls'],1)
        child=doc['children'][0]
        self.assertEqual(child['spawn_time'],4)
        self.assertEqual(child['agent_seconds'],1)
        self.assertEqual(child['counts']['copied_prefix_microseconds'],2000000)
        self.assertTrue(all(s['start']>=4 for s in child['spans']))
        self.assertEqual((child['start'],child['end']),(1,5)) # raw extent retained

    def test_packet_tags_and_grok_exact_call_association(self):
        self.assertEqual(m.packet_tag('Please resume A33-M1 after review'),'A33-M1')
        self.assertEqual(m.packet_tag('Use UTF-8 for the ordinary task'),'unlabelled')
        self.assertEqual(m.packet_tag('Next: AGENT-TIME'),'AGENT-TIME')
        path=self.write('packets/events.jsonl',[
            {'ts':1,'type':'turn_started'}, {'ts':3,'type':'turn_ended'},
            {'ts':4,'type':'turn_started'}, {'ts':6,'type':'tool_completed','tool_name':'bash','tool_call_id':'b','duration_ms':1000}, {'ts':7,'type':'turn_ended'},
            {'ts':8,'type':'turn_started'}, {'ts':9,'type':'tool_completed','tool_name':'bash','tool_call_id':'a','duration_ms':1000}, {'ts':10,'type':'turn_ended'}])
        self.write('packets/chat_history.jsonl',[
            {'type':'user','content':'Work A33-M1'}, {'type':'assistant','tool_calls':[{'id':'a','name':'bash','arguments':{}}]},
            {'type':'user','content':'Work A33-M2'}, {'type':'user','synthetic_reason':'reminder','content':'A33-M9'},
            {'type':'assistant','tool_calls':[{'id':'b','name':'bash','arguments':{}}]}])
        doc=m.grok(path).document()
        self.assertEqual([t['task'] for t in doc['turns']],['unlabelled','A33-M2','A33-M1'])

    def test_fleet_window_clips_intervals_and_usage_points(self):
        path=self.write('window.jsonl',[
            self.cx(86390,'task_started'),self.cx(86390,'message',role='user',content=[{'type':'input_text','text':'A33-M1 task'}]),
            self.cx(86395,'token_count',info={'total_token_usage':{'input_tokens':10}}),
            self.cx(86398,'function_call',call_id='a',name='exec',arguments='{}'),
            self.cx(86400,'token_count',info={'total_token_usage':{'input_tokens':30}}),
            self.cx(86405,'function_call_output',call_id='a'),
            self.cx(172800,'token_count',info={'total_token_usage':{'input_tokens':70}}),self.cx(172810,'task_complete')])
        doc=m.fleet({'sessions':[{'agent':'codex','path':str(path)}],'dates':'1970-01-02..1970-01-02'})
        self.assertEqual((doc['start'],doc['end']),(86400,172800))
        self.assertEqual(doc['tree_token_totals']['fresh input'],20) # lower inclusive, upper exclusive
        child=doc['children'][0]
        tool=next(s for s in child['spans'] if s['activity']=='tool:exec')
        self.assertEqual((tool['start'],tool['end']),(86400,86405))
        self.assertEqual(child['turns'][0]['tool_seconds'],5)
        self.assertEqual(child['turns'][0]['task'],'A33-M1')
        self.assertEqual(doc['tree_agent_seconds'],86400)
        self.assertEqual(doc['counts']['failed_sessions'],0)

    def test_fleet_child_extent_limits_failures_and_shared_budget(self):
        parent=self.write('short.jsonl',[{'timestamp':1,'type':'user','message':{'content':'task'}},{'timestamp':2,'type':'assistant','message':{'content':[],'stop_reason':'end_turn'}}])
        self.write('short/subagents/agent-long.jsonl',[{'timestamp':86401,'type':'user','message':{'content':'child'}},{'timestamp':86405,'type':'assistant','message':{'content':[],'stop_reason':'end_turn'}}])
        doc=m.fleet({'sessions':[{'agent':'claude','path':str(parent)},{'agent':'codex','path':str(self.root/'missing')}],'dates':'1970-01-02..1970-01-02','matched':40})
        self.assertEqual(doc['session_count'],1)
        self.assertEqual(doc['tree_agent_seconds'],4)
        self.assertEqual(doc['tree_counts']['failed_sessions'],1)
        self.assertEqual(doc['tree_counts']['limited_sessions'],38)
        self.assertEqual(len(doc['children'][0]['children']),1)
        summary=m.numeric_summary(m.claude(parent).document())
        self.assertEqual(m.dates(summary)['ended'],'1970-01-02')
        seen=[]
        original=m.read_session
        def record(agent,path,budget):seen.append(budget);return original(agent,path,budget)
        entries=[{'agent':'claude','path':str(parent)}]*34
        with mock.patch.object(m,'read_session',side_effect=record):limited=m.fleet({'sessions':entries,'matched':34})
        self.assertEqual(len(seen),32);self.assertTrue(all(b is seen[0] for b in seen))
        self.assertEqual(limited['counts']['limited_sessions'],2)
        with mock.patch.object(m,'MAX_SPANS',1):bounded=m.fleet({'sessions':entries[:2]})
        def count_spans(d):return len(d['spans'])+sum(count_spans(c) for c in d['children'])
        self.assertEqual(count_spans(bounded),1)
        self.assertGreater(bounded['tree_counts']['limited_spans'],0)
        self.assertEqual(m.fleet({'sessions':[]})['session_count'],0)
        with self.assertRaises(ValueError):m.date_window('1970-01-03..1970-01-01')

    def test_live_fingerprint_skips_parser_and_changes_on_append(self):
        path=self.write('live.jsonl',[self.cx(1,'task_started'),self.cx(2,'task_complete')])
        fingerprint=m.source_fingerprint('codex',path)
        args=['helper','--agent','codex','--file',str(path),'--if-fingerprint',fingerprint]
        output=io.StringIO()
        with mock.patch.object(sys,'argv',args),mock.patch.object(sys,'stdout',output),mock.patch.object(m,'read_session',side_effect=AssertionError('unchanged live source parsed')):m.main()
        self.assertEqual(json.loads(output.getvalue()),{'unchanged':True})
        with path.open('a') as f:f.write(json.dumps(self.cx(3,'task_started'))+'\n')
        output=io.StringIO()
        with mock.patch.object(sys,'argv',args),mock.patch.object(sys,'stdout',output):m.main()
        changed=json.loads(output.getvalue())
        self.assertEqual(len(changed['turns']),2)
        self.assertNotEqual(changed['source_fingerprint'],fingerprint)

    def test_child_only_usage_remains_available_in_index_and_fleet(self):
        def rows(usage=None):
            return [{'timestamp':1,'type':'user','message':{'content':'task'}},
                    {'timestamp':2,'type':'assistant','message':{'id':'leaf','content':[], 'stop_reason':'end_turn',**({'usage':usage} if usage else {})}}]
        parent=self.write('usage-parent.jsonl',rows())
        self.write('usage-parent/subagents/agent-middle.jsonl',rows())
        leaf=self.write('usage-parent/subagents/agent-leaf.jsonl',rows({'input_tokens':10}))
        leaf.with_suffix('.meta.json').write_text(json.dumps({'parentAgentId':'middle'}))
        doc=m.read_session('claude',parent)
        self.assertTrue(doc['token_available'])
        self.assertTrue(doc['children'][0]['token_available'])
        self.assertEqual(m.numeric_summary(doc)['tokens'],10)
        combined=m.fleet({'sessions':[{'agent':'claude','path':str(parent)}]})
        self.assertTrue(combined['token_available'])
        self.assertEqual(sum(combined['tree_token_totals'].values()),10)

    def test_claude_nested_metadata(self):
        def rows(call, start):
            return [
                {'timestamp':start,'type':'user','message':{'content':'synthetic work'}},
                {'timestamp':start+1,'type':'assistant','message':{'id':call,'usage':{'input_tokens':10},'content':[{'type':'tool_use','id':call,'name':'Agent','input':{}}]}},
                {'timestamp':start+4,'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':call,'content':'done'}]}},
                {'timestamp':start+5,'type':'assistant','message':{'id':call+'end','content':[],'stop_reason':'end_turn'}}]
        path=self.write('nested.jsonl',rows('spawn-one',1))
        self.write('nested/subagents/agent-one.jsonl',rows('spawn-two',2))
        self.write('nested/subagents/agent-two.jsonl',rows('leaf',3))
        (self.root/'nested/subagents/agent-one.meta.json').write_text(json.dumps({'toolUseId':'spawn-one','description':'first worker'}))
        (self.root/'nested/subagents/agent-two.meta.json').write_text(json.dumps({'toolUseId':'spawn-two','parentAgentId':'one','description':'nested worker'}))
        doc=m.claude(path).document()
        self.assertEqual(len(doc['children']),1)
        child=doc['children'][0]
        self.assertEqual(child['parent_call_id'],'spawn-one')
        self.assertEqual(child['subagent_name'],'first worker')
        self.assertEqual(len(child['children']),1)
        self.assertEqual(child['children'][0]['parent_call_id'],'spawn-two')
        self.assertEqual(child['children'][0]['subagent_name'],'nested worker')
        self.assertEqual(doc['tree_token_totals']['fresh input'],30)
        self.assertEqual(doc['tree_counts'].get('unlinked_subagents',0),0)

    def test_span_limit_visible(self):
        s=m.Session('test','x')
        s.spans=[{}]*m.MAX_SPANS
        s.span(1,2,'tool:a')
        self.assertEqual(len(s.spans),m.MAX_SPANS)
        self.assertEqual(s.counts['limited_spans'],1)


if __name__=='__main__':unittest.main()
