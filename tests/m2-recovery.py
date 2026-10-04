#!/usr/bin/env python3
"""DWARF range recovery with ELF function symbols removed, GCC/Clang O0/O2."""
from datetime import datetime
from pathlib import Path
import json, os, shutil, subprocess
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('m2-recovery-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
for cc in ['gcc','clang']:
 for opt in ['O0','O2']:
  original=run/f'{cc}-{opt}'
  subprocess.run([cc,'-g','-gdwarf-5','-'+opt,'-fPIE','-pie','tests/fixtures/m2.c','-o',str(original)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
  symbols={line.split()[-1]:int(line.split()[0],16) for line in subprocess.check_output(['nm','-n',str(original)],text=True).splitlines() if len(line.split())==3 and line.split()[0][0] in '0123456789abcdef'}
  c=Client('observe',str(original))
  try: baseline=c.inspect('get_function_graph',symbol='flow_fixture',limit=16)
  finally:c.close()
  stripped=run/(original.name+'-no-function-symbol');shutil.copy2(original,stripped)
  subprocess.run(['objcopy','--strip-symbol=flow_fixture',str(stripped)],check=True)
  c=Client('control',str(stripped))
  try:
   main=c.inspect('find_symbol',name='main');main_addr=int(main['address'],16)
   address=main_addr-symbols['main']+symbols['flow_fixture']
   initial=c.session();tid=initial['threads'][0]['tid'];regs=c.inspect('get_registers',tid=tid)
   graph=c.inspect('get_function_graph',address=hex(address),limit=16,generation=initial['generation'])
   assert graph['extent_source']=='dwarf_subprogram' and graph['symbol']=='flow_fixture',graph
   assert graph['whole_function'] and graph['range_count']==1 and graph['range_index']==0
   assert graph['size']==baseline['size'] and graph['total_blocks']==baseline['total_blocks']
   assert graph['decoded_bytes']==baseline['decoded_bytes'] and graph['execution_observed'] is False
   assert all(block['source'] for block in graph['blocks'])
   assert c.session()['generation']==initial['generation'] and c.inspect('get_registers',tid=tid)==regs
   bp=c.action('set_breakpoint',address=hex(address))['id']
   after=c.inspect('get_function_graph',address=hex(address),limit=16)
   assert after['blocks']==graph['blocks'] and after['edges']==graph['edges']
   stale=c.tool('get_function_graph',address=hex(address),generation=initial['generation'])
   assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot'
   c.action('continue');c.stopped('breakpoint')
   interior=c.inspect('get_function_graph',address=hex(address+1),limit=16)
   assert interior['address']==graph['address'] and interior['size']==graph['size']
   print(cc,opt,'DWARF recovery, PIE, source, overlay and guards passed',flush=True)
  finally:
   (run/(stripped.name+'.rpc.json')).write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
print(run)
