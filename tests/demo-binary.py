#!/usr/bin/env python3
"""Demo selection and stale-reader refusals using owned MCP fixture binaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
os.umask(0o022)
(root/'.work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='demo-binary-', dir=root/'.work') as tmp:
    work = Path(tmp)
    work.chmod(0o755)
    helper = work/'scripts/helpers/demo-binary.py'
    helper.parent.mkdir(parents=True)
    shutil.copyfile(root/'scripts/helpers/demo-binary.py', helper)
    fixture = '''import json,sys
for line in sys.stdin:
    request=json.loads(line)
    if 'id' not in request:continue
    result={'tools':[{'name':'get_language_stack','inputSchema':{'properties':{'language':{'enum':LANGUAGES}}}}]} if request['method']=='tools/list' else {}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
'''
    def binary(path, languages):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!'+sys.executable+'\n'+fixture.replace('LANGUAGES',repr(languages)))
        path.chmod(0o755)
    langs = ['python','perl','lua','javascript']
    local, installed, explicit, stale = [work/n for n in ['zig-out/bin/xodb','path/xodb','chosen','old']]
    for path in [local, installed, explicit]:binary(path, langs)
    binary(stale, [])
    env = {**os.environ, 'PATH':str(installed.parent)}
    env.pop('XODB', None)
    count = 0
    def check(language, expected=None, override=None, refusal=None):
        global count
        selected = dict(env)
        if override is not None:selected['XODB']=str(override)
        result = subprocess.run([sys.executable,str(helper),language],cwd=work,env=selected,
                                capture_output=True,text=True,timeout=15)
        if refusal:
            assert result.returncode != 0 and refusal in result.stderr, result
        else:
            assert result.returncode == 0 and result.stdout.strip()==str(expected.resolve()), result
            assert str(expected.resolve()) in result.stderr, result
        count += 1
    for language in langs:
        check(language, local)
        check(language, explicit, explicit)
        check(language, override=stale, refusal='does not advertise the '+language+' reader')
    local.unlink()
    for language in langs:check(language, installed)
    local.symlink_to(stale)
    for language in langs:check(language, refusal='Using xodb: '+str(stale.resolve()))
    check('lua', override=work/'missing', refusal='Build xodb')
    print(str(count)+' demo binary selection and stale-reader checks passed')
