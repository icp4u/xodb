#!/usr/bin/env python3
"""Verified automatic companions and bidirectional source mapping on real ELF/DWARF."""
from datetime import datetime
from pathlib import Path
import os,json,subprocess,re,shutil
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('debug-discovery-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
source=root/'tests/fixtures/m1.c';line=10
for case in ('debuglink','crc-only','build-id','bad-crc','bad-id','disabled','explicit'):
    work=run/case;work.mkdir();(work/'roots').mkdir();(work/'.debug').mkdir()
    binary=work/'fixture';debug=work/'.debug/fixture.debug'
    def execute(*args):subprocess.run(list(args),cwd=work,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
    execute('gcc','-g','-O0','-fno-omit-frame-pointer',f'-fdebug-prefix-map={root}=/xodb-build','-Wl,--build-id=none' if case=='crc-only' else '-Wl,--build-id',str(source),'-o',str(binary))
    execute('objcopy','--only-keep-debug',str(binary),str(debug))
    execute('strip','--strip-all',str(binary))
    if case=='build-id':
        build_id=re.search(r'Build ID: (\w+)',subprocess.check_output(['readelf','-n',str(binary)],text=True)).group(1)
        dest=work/'roots/.build-id'/build_id[:2]/(build_id[2:]+'.debug');dest.parent.mkdir(parents=True);shutil.copy2(debug,dest)
    else:execute('objcopy','--add-gnu-debuglink='+str(debug),str(binary))
    if case=='bad-crc':
        shutil.copy2(debug,work/'original.debug');debug.write_bytes(debug.read_bytes()+b'CRC-must-reject')
    if case=='bad-id':
        shutil.copy2(debug,work/'original.debug')
        execute('gcc','-g','-O1','-Wl,--build-id',str(source),'-o',str(debug))
    options=['--debug-dir',str(work/'roots'),'--source-map','/xodb-build='+str(root)]
    if case in ('disabled','explicit'):
        prefs=work/'prefs.json';prefs.write_text('{"symbols":{"automatic":false}}');options+=['--config',str(prefs)]
    if case=='explicit':options+=['--debug-file',str(debug)]
    c=Client('control',str(binary),options=options)
    try:
        if case in ('bad-crc','bad-id','disabled'):
            response=c.tool('find_symbol',name='change_value')
            assert response['result']['isError'],response
            continue
        symbol=c.inspect('find_symbol',name='change_value')
        ids=c.action('set_breakpoint',file=str(source),line=line)['ids']
        c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
        frames=c.inspect('get_stack',tid=tid)['frames'];site=frames[0]['source']
        assert site['path']==str(source) and site['original_path']=='/xodb-build/tests/fixtures/m1.c',site
        assert c.inspect('evaluate_expression',tid=tid,expression='next')['value']['display']=='12'
        companions=c.inspect('get_debug_files')['files']
        selected=next(f for f in companions if f['path'].endswith('fixture.debug') or case=='build-id')
        expected='explicit_build_id' if case=='explicit' else 'build_id' if case=='build-id' else 'debuglink_crc'
        assert selected['verification']==expected,selected
    finally:
        (work/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
print('Build-ID/debuglink discovery, CRC and foreign-ID rejection, opt-out/explicit override, remapped breakpoints/source/locals passed:',run)
