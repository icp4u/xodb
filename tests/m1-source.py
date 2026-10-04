#!/usr/bin/env python3
"""DWARF 4/5, GCC/Clang, CFI and known-value differential fixture."""
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m1-source-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
env = os.environ.copy()
env['TMPDIR'] = str(root / '.work/tmp')
source = root / 'tests/fixtures/m1.c'
line = next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'WATCH_WRITE' in s)
for compiler in ['gcc','clang']:
    for version in [4,5]:
        for opt in [0,2]:
            name = f'{compiler}-dwarf{version}-O{opt}'
            binary = run / name
            subprocess.run([compiler, '-g',f'-gdwarf-{version}',f'-O{opt}','-fPIE','-pie',str(source),'-o',str(binary)],env=env,check=True)
            entry_client = Client('control', str(binary))
            try:
                # A symbol breakpoint is before -O0 argument spills. Stack slots
                # must be unavailable there, while optimized register args work.
                entry = entry_client.action('set_breakpoint',symbol='change_value')['id']
                entry_client.action('continue')
                entry_stop = entry_client.stopped('breakpoint')
                entry_tid = entry_stop['threads'][0]['tid']
                entry_locals = {v['name']:v for v in entry_client.inspect('list_locals',tid=entry_tid)['locals']}
                amount = entry_locals['amount']
                if opt == 0:
                    assert amount['value']['availability']=='unavailable', (name,amount)
                    assert amount['diagnostic']=='PrologueNotComplete', (name,amount)
                else:
                    assert amount['value']['display']=='5', (name,amount)
                assert entry_client.inspect('evaluate_expression',tid=entry_tid,expression='state.value')['value']['display']=='7'
            finally:
                (run / (name+'.entry.json')).write_text(json.dumps(entry_client.transcript,indent=2)+'\n')
                entry_client.close()
            evidence_path = run / (name+'.evidence.json')
            client = Client('control', str(binary), options=('--record',str(evidence_path)))
            try:
                bp = client.action('set_breakpoint',file=str(source),line=line)
                client.action('continue')
                snap = client.stopped('breakpoint')
                tid = snap['threads'][0]['tid']
                regs = client.inspect('get_registers',tid=tid)['registers']
                site = client.inspect('get_source_location',address=regs['rip'])['source']
                assert site['line']==line, (name,site)
                frames = client.inspect('get_stack',tid=tid)['frames']
                assert len(frames)>=2 and frames[0]['symbol']=='change_value' and frames[1]['symbol']=='main', (name,frames)
                variables = client.inspect('list_locals',tid=tid)['locals']
                locals = {v['name']:v for v in variables}
                if locals['next']['value']['availability']=='available':
                    assert locals['next']['value']['display']=='12', (name,locals)
                else:
                    assert opt==2 and locals['next']['value']['availability'] in ('optimized_out','unavailable'), (name,locals)
                assert client.inspect('evaluate_expression',tid=tid,expression='item->value')['value']['display']=='7'
                assert client.inspect('evaluate_expression',tid=tid,expression='item->value + amount')['value']['display']=='12'
                address = client.inspect('evaluate_expression',tid=tid,expression='&item->value')['bits']
                for probe in bp['ids']: client.action('remove_breakpoint',id=probe)
                investigation_id = client.action('investigate_write',tid=tid,question='Why did state.value change from 7 to 12?',expression='item->value')['id']
                client.action('continue')
                client.stopped('watchpoint')
                events = client.inspect('query_events')['events']
                hit = [e for e in events if e['kind']=='watchpoint_hit'][-1]
                assert (hit['before'],hit['after'])==(7,12)
                assert client.inspect('evaluate_expression',tid=tid,expression='state.value')['value']['display']=='12'
                # Hardware stops are after the store; retain both actual stop PC
                # and the preceding source-boundary experiment in the transcript.
                client.inspect('get_stack',tid=tid)
                client.inspect('list_locals',tid=tid)
                client.inspect('get_audit')
                record = client.inspect('get_investigation',id=investigation_id)
                assert record['initial']['display']=='7' and len(record['observations'])==1, record
                observation = record['observations'][0]
                assert observation['value']['display']=='12'
                assert observation['preceding_instruction']['source']['line']==line, observation
                assert observation['preceding_instruction']['address']<hit['pc']
                assert observation['frames'][0]['symbol']=='change_value'
                client.action('remove_watchpoint',id=record['watchpoint_id'])
            finally:
                (run / (name+'.json')).write_text(json.dumps({'question':'Why did state.value change from 7 to 12?', 'build':name,'transcript':client.transcript},indent=2)+'\n')
                client.close()
            saved = json.loads(evidence_path.read_text())
            assert saved['investigations'][0]['observations'][0]['value']['display']=='12'
            gdb = subprocess.run(['gdb','-nx','-q','-batch','-ex','set pagination off','-ex',f'break {source}:{line}','-ex','run','-ex','print next','-ex','print item->value','-ex','bt','--args',str(binary)],capture_output=True,text=True,timeout=15,env=env)
            (run / (name+'.gdb.txt')).write_text(gdb.stdout+gdb.stderr)
            expected_next = '$1 = 12' if locals['next']['value']['availability']=='available' else '$1 = <optimized out>'
            assert gdb.returncode==0 and expected_next in gdb.stdout and '$2 = 7' in gdb.stdout, (name,gdb.stdout,gdb.stderr)
            assert 'change_value' in gdb.stdout and 'main' in gdb.stdout
            print(f'{name}: source breakpoint, CFI stack, locals, pointer/struct arithmetic and watched write agree with fixture/GDB',flush=True)
print(f'M1 source evidence: {run}')
