#!/usr/bin/env python3
"""Context storage and lexical refusal on an owned private display."""
import argparse
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
from PIL import Image, ImageOps
from helpers.language_selection import check_native_values

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--node', required=True)
p.add_argument('--include', default='/usr/include/node')
p.add_argument('--work', required=True, type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
w = (a.work/'.work/input-jsc').resolve(); w.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h); h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'): (w/name).mkdir(parents=True, exist_ok=True)
os.environ['XDG_CACHE_HOME'] = str(w/'cache')
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(w/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c',
                str(w/'virtual-pointer.c'), str(w/'virtual-keyboard.c'), '-lwayland-client',
                '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
addon = w/'probe.node'
subprocess.run(['c++', '-std=c++20', '-g', '-O0', '-fno-omit-frame-pointer', '-fPIC', '-shared',
                '-I'+a.include, '-DNODE_GYP_MODULE_NAME=xodb_probe',
                'tests/fixtures/javascript/probe.cc', '-o', str(addon)], check=True, timeout=60)
target = subprocess.Popen([a.node, '--no-opt', '--no-sparkplug', '--no-maglev', '--expose-gc',
                           'tests/fixtures/javascript/context.js', 'plain'],
                          env=dict(os.environ, XODB_NODE_PROBE=str(addon)),
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
d = None
try:
    assert select.select([target.stdout], [], [], 10)[0] and target.stdout.readline() == b'ready\n'
    d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(target.pid)])
    d.tool('set_breakpoint', generation=d.session()['generation'], symbol='xodb_node_stop')
    d.tool('continue', generation=d.session()['generation']); target.stdin.write(b'go\n'); target.stdin.flush()
    assert d.stopped('breakpoint')
    def read_stack():
        deadline = time.monotonic()+900
        while True:
            reply = d.request('tools/call', {'name':'get_language_stack', 'arguments':{'tid':target.pid, 'language':'javascript'}})
            if not reply.get('isError'): return reply['structuredContent']
            assert reply['content'][0]['text'] == 'DebugMetadataPending' and time.monotonic()<deadline, reply
            time.sleep(.03)
    assert json.loads(target.stdout.readline())['label']=='context-shadow'
    stack = read_stack()
    native_values = check_native_values(d, target.pid, 'javascript', 'context')
    segment, frame = next((s, f) for s, part in enumerate(stack['segments']) for f, row in enumerate(part['frames']) if row['name']=='sample')
    generation = d.session()['generation']; regs = d.tool('get_registers', tid=target.pid)
    args = dict(generation=generation, tid=target.pid, language='javascript', segment=segment, frame=frame)
    d.tool('select_language_frame', **args)
    rows = d.tool('get_language_locals', **args)
    assert rows['view_kind']=='context_storage' and rows['diagnostic']=='JavaScriptLexicalUnproved', rows
    assert next(row for row in rows['rows'] if row['name']=='captured')['value']['display']=='smi 41', rows
    normalize = lambda text: re.sub(r'[^a-z0-9]', '', text.lower())
    def visible(label, wanted, marker=None):
        deadline = time.monotonic()+30
        while True:
            shot = d.shot(label); crop = shot+'.side.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'))
                pane.resize((pane.width*3,pane.height*3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'],
                env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=30).stdout
            Path(shot+'.side.txt').write_text(text)
            if all(part in normalize(text) for part in wanted) and (marker is None or marker in text): return shot, text
            assert time.monotonic()<deadline, text
            time.sleep(.05)
    first, first_text = visible('context-storage', ['contextstorage', 'lexicalvisibility', 'unprovedstackhidden', 'psmi7', 'context0'])
    # The one-row viewport must not skip captured between p and module names.
    d.keys('scroll',1150,540,1)
    _, scrolled = visible('context-next-binding',['capturedsmi41','context0'])
    d.keys('scroll',1150,540,-1)
    visible('context-first-binding',['psmi7'])
    # E captured Return must visibly refuse despite the context row with that name.
    d.keys('tap',18,'tap',46,'tap',30,'tap',25,'tap',20,'tap',22,'tap',19,'tap',18,'tap',32,'tap',28)
    _, refused = visible('context-refusal', ['ecaptured', 'unproved', 'psmi7'])
    assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
    for label in ('two-contexts', 'closure', 'recursive-0'):
        previous = d.session()['generation']
        d.tool('continue',generation=previous)
        assert d.wait(lambda state:state['generation']>previous and state['state']=='stopped' and any(t['reason']=='breakpoint' for t in state['threads']))
        assert json.loads(target.stdout.readline())['label']==label
    generation = d.session()['generation']; stack = read_stack()
    segment, frame = next((s,f) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']=='recursive')
    frame += 2
    d.tool('select_language_frame',generation=generation,tid=target.pid,language='javascript',segment=segment,frame=frame)
    # The three owned recursive frames must all fit simultaneously above values.
    deadline = time.monotonic()+30
    while True:
        # Wait for the selected frame's bindings before deriving click coordinates.
        # An intermediate stack-only paint has a different native-header height.
        shot, text = visible('context-stack', ['recursive', 'contextstorage', 'depthsmi2', 'context0'])
        if text.lower().count('recursive')>=3: break
        assert time.monotonic()<deadline, text
        time.sleep(.05)
    def header_at(shot):
        tsv = subprocess.run(['tesseract',shot+'.side.png','stdout','--psm','6','tsv'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        Path(shot+'.side.tsv').write_text(tsv)
        word = next(word for word in csv.DictReader(io.StringIO(tsv),delimiter='\t') if word['text']=='Native')
        return {'left':1013+int(word['left'])//3,'top':130+int(word['top'])//3}
    header = header_at(shot)
    d.keys('click',int(header['left'])+5,int(header['top'])+5)
    shot, expanded = visible('context-expanded',['nativeframe','contextstorage','nomappednativeimage'],marker='[-]')
    header = header_at(shot)
    d.keys('click',int(header['left'])+5,int(header['top'])+5)
    _, collapsed = visible('context-collapsed',['contextstorage'],marker='[+]')
    assert collapsed.lower().count('recursive')>=3, collapsed
    d.keys('tap',66); assert d.wait(lambda state:state['agent_scope']=='observe')
    generation = d.session()['generation']; regs = d.tool('get_registers',tid=target.pid)
    observed = d.tool('get_language_locals',generation=generation,tid=target.pid,language='javascript',segment=segment,frame=frame)
    assert observed['diagnostic']=='JavaScriptLexicalUnproved'
    assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
    (w/'results.json').write_text(json.dumps({'status':'pass','rows':rows,'native_values':native_values,
        'first_text':first_text,'refusal_text':refused,'expanded':expanded,'collapsed':collapsed,
        'generation_registers_unchanged':True,'display_dir':d.dir},indent=2)+'\n')
finally:
    if d: d.close()
    if target.poll() is None: target.kill()
    target.wait(timeout=10)
print('JS context storage labels, lexical refusal, three stack rows, native collapse and observer reads passed')
