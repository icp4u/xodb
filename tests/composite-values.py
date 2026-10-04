#!/usr/bin/env python3
"""Optimized aggregate arguments split across GP and SIMD registers."""
from datetime import datetime
from pathlib import Path
import os, json, subprocess
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('composite-values-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
binary=run/'fixture';source=root/'tests/fixtures/pieces.c'
subprocess.run(['gcc','-g','-O2','-fno-omit-frame-pointer',str(source),'-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(binary))
try:
    c.action('set_breakpoint',symbol='pieces_stop');c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
    for name,expected in (('pair.first',123),('pair.second',-456),('scale.first',6.25),('scale.second',-3.5)):
        value=c.inspect('evaluate_expression',tid=tid,expression=name)['value']
        assert float(value['display'])==expected,(name,value)
        assert value['address'] is None and value['composite'] and not value['partial'],value
    for name,expected in (('pair',[123,-456]),('scale',[6.25,-3.5])):
        view=c.inspect('get_value_children',tid=tid,expression=name)['view']
        assert [float(v['value']['display']) for v in view['children']]==expected,view
        assert view['value']['address'] is None and view['value']['composite'],view
    response=c.call('tools/call',{'name':'evaluate_expression','arguments':{'tid':tid,'expression':'&pair'}})
    assert response['result']['isError'] and 'NotAddressable' in json.dumps(response),response
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
print('Register pieces, SIMD arguments, field expressions, child views and address rejection passed:',run)
