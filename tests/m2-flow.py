#!/usr/bin/env python3
"""Static graph contract, independent objdump boundaries, live overlay and limits."""
from datetime import datetime
from pathlib import Path
import json, os, re, subprocess
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-flow-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
env = dict(os.environ, TMPDIR=str(root/'.work/tmp'))
source = root/'tests/fixtures/m2.c'
for compiler in ('gcc','clang'):
    for optimize in ('-O0','-O2'):
        binary = run/f'{compiler}-{optimize[1:]}'
        subprocess.run([compiler,'-g','-gdwarf-5',optimize,'-fPIE','-pie',str(source),'-o',str(binary)],env=env,check=True)
        client = Client('control',str(binary))
        try:
            initial = client.session()
            rows, edges = [], []
            start = 0
            while True:
                graph = client.inspect('get_function_graph',symbol='flow_fixture',start_block=start,limit=2,generation=initial['generation'])
                rows += graph['blocks']; edges += graph['edges']
                if graph['next_block'] is None: break
                start = graph['next_block']
            assert len(rows)==graph['total_blocks'] and len(rows)>=3, graph
            assert graph['execution_observed'] is False and graph['undecoded_bytes']==0
            assert client.session()['generation']==initial['generation']
            assert any(e['kind']=='return_site' and e['assumed'] for e in edges), edges
            assert any(b['source'] and b['source']['path']==str(source) for b in rows), rows
            output = subprocess.check_output(['objdump','-d','-w','-Mintel','--disassemble=flow_fixture',str(binary)],text=True)
            (run/(binary.name+'.objdump.txt')).write_text(output)
            decoded = {}
            for line in output.splitlines():
                match = re.match(r'\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(\S+)\s*(.*)',line)
                if match: decoded[int(match[1],16)] = (len(match[2].split()),match[3],match[4])
            # Optimizers may use cmov and unroll every loop: Clang O2 has no
            # conditional branch here. Check actual machine code, not source ifs.
            branches = {addr for addr, (_,mnemonic,_) in decoded.items() if mnemonic.startswith('j') and mnemonic != 'jmp'}
            actual = {int(b['terminator']['address'],16) - (int(graph['address'],16)-int(graph['link_address'],16)) for b in rows if b['terminator']['flow']=='conditional'}
            assert actual == branches, (actual,branches)
            if optimize == '-O0': assert branches
            bias = int(graph['address'],16)-int(graph['link_address'],16)
            for block in rows:
                first,last = int(block['address'],16)-bias,int(block['terminator']['address'],16)-bias
                assert first in decoded and last in decoded, (block,output)
                assert decoded[last][1]==block['terminator']['mnemonic'], (block,decoded[last])
                for edge in [e for e in edges if e['from']==block['id'] and e['kind'] in ('taken','jump','call') and e['address'] is not None]:
                    operand = decoded[last][2].split()[0]
                    assert int(operand,16)+bias==int(edge['address'],16), (edge,decoded[last])
            full = client.inspect('get_function_graph',symbol='flow_fixture',limit=16)
            bp = client.action('set_breakpoint',symbol='flow_fixture')['id']
            overlay = client.inspect('get_function_graph',symbol='flow_fixture',limit=16)
            assert overlay['blocks']==full['blocks'] and overlay['edges']==full['edges'], 'INT3 leaked into graph'
            stale = client.tool('get_function_graph',symbol='flow_fixture',generation=initial['generation'])
            assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot', stale
            client.action('continue'); stopped = client.stopped('breakpoint'); tid=stopped['threads'][0]['tid']
            before = client.inspect('get_registers',tid=tid)['registers']
            addressed = client.inspect('get_function_graph',address=before['rip'])
            assert addressed['address']==graph['address']
            assert client.inspect('get_registers',tid=tid)['registers']==before
            bad = client.tool('get_function_graph',symbol='flow_result')
            assert bad['result']['isError'] and bad['result']['content'][0]['text']=='FunctionSymbolRequired', bad
            for args in ({'symbol':'flow_fixture','limit':17},{'symbol':'flow_fixture','start_block':999},{'symbol':'flow_fixture','address':before['rip']}):
                assert client.tool('get_function_graph',**args)['error']['code']==-32602
            client.action('remove_breakpoint',id=bp)
            client.action('continue')
            running = client.tool('get_function_graph',symbol='flow_fixture')
            assert running['result']['isError'] and running['result']['content'][0]['text']=='NotStopped', running
            (run/(binary.name+'.graph.json')).write_text(json.dumps(dict(header=graph,blocks=rows,edges=edges),indent=2)+'\n')
        finally:
            (run/(binary.name+'.rpc.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')
            client.close()
        print(f'{binary.name}: graph matches objdump, source links, pages, breakpoint overlay and inspection-only behavior',flush=True)
# Observe-only agents can inspect existing mapped functions at the exec stop.
client=Client('observe','./zig-out/bin/xodb-m2-fixture')
try:
    assert 'get_function_graph' in {t['name'] for t in client.call('tools/list')['result']['tools']}
    assert client.inspect('get_function_graph',symbol='flow_fixture')['total_blocks']>=3
finally: client.close()
print(f'M2 flow artifacts: {run}')
