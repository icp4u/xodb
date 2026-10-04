#!/usr/bin/env python3
"""Read-only normalized instruction effects agree with existing disassembly."""
from datetime import datetime
from pathlib import Path
import json,os
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('m2-ir-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
c=Client('control','./zig-out/bin/xodb-m2-fixture')
try:
 snap=c.session();tid=snap['threads'][0]['tid'];regs=c.inspect('get_registers',tid=tid)
 addr=c.inspect('find_symbol',name='flow_fixture')['address']
 ir=c.inspect('get_instruction_effects',address=addr,length=256,limit=32,generation=snap['generation'])
 asm=c.inspect('disassemble',address=addr)
 assert len(ir['instructions'])==len(asm['instructions'])
 for a,b in zip(ir['instructions'],asm['instructions']):
  assert a['address']==int(b['address'],16) and a['size']==b['size'] and a['mnemonic']==b['mnemonic']
  assert not a['semantics_complete'] and not a['memory_effects_complete']
 assert any(op['kind']=='memory' for i in ir['instructions'] for op in i['operands'])
 assert all(i['register_access_available'] for i in ir['instructions'])
 single=c.inspect('get_instruction_effects',address=addr,limit=1)
 assert single['instruction_limit_reached'] and len(single['instructions'])==1
 assert single['next_address']==int(addr,16)+single['instructions'][0]['size']
 assert c.session()['generation']==snap['generation'] and c.inspect('get_registers',tid=tid)==regs
 for args in [dict(limit=65),dict(limit=0),dict(length=1025),dict(length=0),dict(unrecognized=True)]:
  bad=c.tool('get_instruction_effects',address=addr,**args)
  assert bad['error']['code']==-32602,bad
 c.action('set_breakpoint',address=addr)
 over=c.inspect('get_instruction_effects',address=addr,length=256,limit=32)
 assert over['instructions']==ir['instructions'],'software breakpoint byte leaked into IR'
 stale=c.tool('get_instruction_effects',address=addr,generation=snap['generation'])
 assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot'
 print('IR: disassembly agreement, typed memory, bounds, pagination, unchanged state, breakpoint overlay and stale guard passed')
finally:
 (run/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
c=Client('observe','./zig-out/bin/xodb-m2-fixture')
try:
 addr=c.inspect('find_symbol',name='flow_fixture')['address']
 assert c.inspect('get_instruction_effects',address=addr)['instructions']
finally:c.close()
print(run)
