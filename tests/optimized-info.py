#!/usr/bin/env python3
"""Real compiler inline chains and DWARF 4/5 split-unit resolution."""
from datetime import datetime
from pathlib import Path
import os,json,subprocess,shutil
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('optimized-info-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
source=root/'tests/fixtures/optimized.c'
for case in ('plain','dwarf5','dwarf4','missing','foreign'):
    work=run/case;work.mkdir();binary=work/'fixture'
    flags=['-g','-O2','-fno-omit-frame-pointer']
    if case!='plain':flags+=['-gsplit-dwarf','-gdwarf-4' if case=='dwarf4' else '-gdwarf-5']
    subprocess.run(['gcc',*flags,str(source),'-o','fixture'],cwd=work,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
    if case in ('missing','foreign'):
        dwo=next(work.glob('*.dwo'));shutil.copy2(dwo,work/'original-dwo.backup');dwo.unlink()
        if case=='foreign':
            subprocess.run(['gcc','-g','-O0','-gsplit-dwarf','-gdwarf-5',str(root/'tests/fixtures/m1.c'),'-o','foreign'],cwd=work,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
            shutil.copy2(next(work.glob('foreign*.dwo')),dwo)
    c=Client('control',str(binary))
    try:
        c.action('set_breakpoint',symbol='inline_stop');c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
        frame=c.inspect('get_stack',tid=tid)['frames'][0]
        if case in ('missing','foreign'):
            expected='SplitDwarfFileUnavailable' if case=='missing' else 'SplitDwarfMissingOrMismatched'
            assert frame['inline_diagnostic']==expected,frame
            assert not frame['inline_frames'],frame
            continue
        inline=frame['inline_frames'];assert [v['name'] for v in inline]==['inside','middle'],frame
        assert all(v['call_path']==str(source) and v['call_line'] for v in inline),inline
        derived=c.inspect('evaluate_expression',tid=tid,expression='derived')['value']
        assert derived['display']=='51',derived
        middle=c.inspect('evaluate_expression',tid=tid,inline_depth=1,expression='input')['value']
        assert middle['display']=='10',middle
        physical=c.inspect('list_locals',tid=tid,inline_depth=2)['locals']
        assert any(v['name']=='answer' for v in physical),physical
        assert not any(v['name']=='derived' for v in physical),physical
        bad=c.tool('list_locals',tid=tid,inline_depth=3)
        assert bad['result']['isError'] and 'InvalidInlineDepth' in json.dumps(bad),bad
        assert frame['source']['path']==str(source),frame
    finally:
        (work/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
# Different DWO files commonly reuse DIE offsets: types must retain CU identity.
work=run/'multiple-units';work.mkdir()
for name,ctype,value in (('one','unsigned long','123'),('two','double','6.25')):
    code=f'__attribute__((noinline)) void unit_{name}(void) {{ struct Box {{ {ctype} value; }} box = {{ {value} }}; asm volatile(".globl unit_{name}_stop\\nunit_{name}_stop:\\nnop" : : "m"(box)); }}\n'
    (work/(name+'.c')).write_text(code)
    subprocess.run(['gcc','-g','-O0','-gsplit-dwarf','-c',name+'.c','-o',name+'.o'],cwd=work,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
(work/'main.c').write_text('#include <unistd.h>\nvoid unit_one(void),unit_two(void);int main(void){alarm(10);unit_one();unit_two();}\n')
subprocess.run(['gcc','-g','main.c','one.o','two.o','-o','fixture'],cwd=work,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(work/'fixture'))
try:
    for name in ('one','two'):c.action('set_breakpoint',symbol='unit_'+name+'_stop')
    for name,expected in (('one',123),('two',6.25)):
        c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
        value=c.inspect('evaluate_expression',tid=tid,expression='box.value')['value']
        assert float(value['display'])==expected,(name,value)
        assert value['kind']==('unsigned' if name=='one' else 'float'),value
finally:
    (work/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
print('Nested inline chains, live values, DWARF 4/5 split units and missing/foreign DWO diagnostics passed:',run)
