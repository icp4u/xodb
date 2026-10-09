#!/usr/bin/env python3
"""Create and observe runtime watches through an owned private display."""
import argparse,csv,importlib.util,io,json,os,queue,re,select,shlex,subprocess,threading,time
from pathlib import Path
from PIL import Image,ImageOps
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--paths',action='store_true');p.add_argument('--node');p.add_argument('--include',default='/usr/include/node');p.add_argument('--ruby');p.add_argument('--perl');p.add_argument('--padwalker',type=Path);p.add_argument('--reuse',action='store_true');p.add_argument('--source');p.add_argument('--library');p.add_argument('--python');p.add_argument('--work',type=Path,required=True)
a=p.parse_args()
if sum((bool(a.node),bool(a.ruby),bool(a.python),bool(a.perl),bool(a.source or a.library)))!=1 or (not (a.node or a.python or a.perl or a.ruby) and not (a.source and a.library)):p.error('choose --node, --ruby, --python, --perl, or both --source and --library')
if a.perl and not a.padwalker:p.error('--perl requires --padwalker')
if (a.node or a.python or a.perl or a.ruby) and a.reuse:p.error('--reuse uses the Lua fixture')
if a.paths and (not (a.source or a.python or a.perl or a.ruby) or a.reuse):p.error('--paths requires Ruby, Perl, Python or Lua without --reuse')
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-lwatch').resolve();w.mkdir(parents=True,mode=0o755)
fixture=w/'host';language='javascript' if a.node else 'ruby' if a.ruby else 'python' if a.python else 'perl' if a.perl else 'lua'
binding_name='$x' if a.perl else 'x'
source=root/('tests/fixtures/javascript/probe.cc' if a.node else 'tests/fixtures/ruby/watches.c' if a.ruby else 'tests/fixtures/python/named.c' if a.python else 'tests/fixtures/perl/watches.c' if a.perl else 'tests/fixtures/lua/named.c')
if a.node:
    addon=w/'probe.node'
    subprocess.run(['c++','-std=c++20','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+a.include,'-DNODE_GYP_MODULE_NAME=xodb_probe',str(source),'-o',str(addon)],check=True,timeout=60)
    target_command=[a.node,'--no-opt','--no-sparkplug','--no-maglev','--expose-gc',str(root/'tests/fixtures/javascript/watches.js')]
    target_env=dict(os.environ,XODB_NODE_PROBE=str(addon))
elif a.ruby:
    headers=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir","DLEXT"))'],text=True,timeout=30))
    addon=w/('xodb_watches.'+headers[2])
    subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+headers[0],'-I'+headers[1],str(source),'-o',str(addon)],check=True,timeout=60)
    target_command=[a.ruby,str(root/'tests/fixtures/ruby/watches.rb')]
    target_env=dict(os.environ,XODB_RUBY_WATCHES=str(addon))
elif a.python:
    spec=importlib.util.spec_from_file_location('python_component',root/'tests/python-component.py');component=importlib.util.module_from_spec(spec);spec.loader.exec_module(component)
    component.compile_fixture(a.python,w)
    target_command=[a.python,str(root/('tests/fixtures/python/path-watches.py' if a.paths else 'tests/fixtures/python/watches.py'))]
    target_env=dict(os.environ,PYTHONPATH=str(w))
elif a.perl:
    cfg=json.loads(subprocess.check_output([a.perl,'-MConfig','-MJSON::PP','-e','print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags)})'],timeout=30))
    shared=w/'watches.so'
    compiled_source=root/'tests/fixtures/perl/paths.c' if a.paths else source
    subprocess.run([*shlex.split(cfg['cc']),*shlex.split(cfg['ccflags']),'-U_FORTIFY_SOURCE','-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer','-I'+cfg['archlib']+'/CORE',str(compiled_source),'-o',str(shared)],check=True,timeout=90)
    target_command=[a.perl,str(root/('tests/fixtures/perl/paths.pl' if a.paths else 'tests/fixtures/perl/watches.pl')),str(shared)]
    target_env=dict(os.environ,PERL5LIB=str(a.padwalker.resolve()/'blib/lib')+':'+str(a.padwalker.resolve()/'blib/arch'))
else:
    subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,'tests/fixtures/lua/path-watches.c' if a.paths else 'tests/fixtures/lua/watch-reuse.c' if a.reuse else 'tests/fixtures/lua/watches.c',a.library,'-lm','-ldl','-o',str(fixture)],check=True,timeout=90)
    target_command=[str(fixture)];target_env=os.environ.copy()
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
os.environ['XDG_CACHE_HOME']=str(w/'cache')
target=subprocess.Popen(target_command,env=target_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);d=None;result={'status':'running'}
try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    lines=queue.Queue()
    def drain():
        for line in target.stdout:lines.put(line)
    thread=threading.Thread(target=drain,daemon=True);thread.start()
    d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid)])
    if a.node:d.tool('set_breakpoint',generation=d.session()['generation'],symbol='xodb_node_stop')
    else:
        line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if ('WATCH_STOP' if (a.perl or a.ruby) else 'NAMED_STOP') in s)
        d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)
    d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n' if (a.node or a.python or a.perl or a.ruby) else b'g');target.stdin.flush();assert d.stopped('breakpoint')
    json.loads(lines.get(timeout=10))
    if a.node:json.loads(lines.get(timeout=10))
    generation=d.session()['generation'];regs=d.tool('get_registers',tid=target.pid)
    segment,frame=0,0 if a.perl else 1
    if a.node or a.python or a.ruby:
        deadline=time.monotonic()+60
        while True:
            reply=d.request('tools/call',{'name':'get_language_stack','arguments':{'tid':target.pid,'language':language}})
            if not reply.get('isError'):break
            assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
            time.sleep(.02)
        stack=reply['structuredContent']
        segment,frame=next((s,f) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']==('watched' if (a.node or a.ruby or a.paths) else 'outer.<locals>.watched'))
    args=dict(generation=generation,tid=target.pid,language=language,segment=segment,frame=frame)
    d.tool('select_language_frame',**args)
    normalize=lambda t:re.sub(r'[^a-z0-9]','',t.lower())
    def visible(label,wanted,box,psm=6):
        deadline=time.monotonic()+30
        while True:
            shot=d.shot(label);crop=shot+'.crop.png'
            with Image.open(shot) as image:
                pane=ImageOps.invert(image.crop(box).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
            text=subprocess.run(['tesseract',crop,'stdout','--psm',str(psm)],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
            Path(shot+'.txt').write_text(text)
            if all(x in normalize(text) for x in wanted):return shot,text
            assert time.monotonic()<deadline,text
            time.sleep(.05)
    initial,changed=(10,20) if a.reuse else (7,8)
    numeric='smi' if a.node else '' if a.ruby else 'int' if a.python else 'IV' if a.perl else 'integer' if '/lua-5.4' in a.library else 'number'
    display=lambda value:str(value) if a.ruby else numeric+' '+str(value)
    if a.node or a.python or a.perl or a.ruby or a.paths:
        bindings=d.tool('get_language_locals',**args)['rows']
        visible('named-ready',['contextstorage' if a.node else 'namedlocals',normalize(bindings[0]['name'])],(1013,130,1272,578))
        index=next(i for i,row in enumerate(bindings) if row['name']==binding_name)
        for _ in range(index):d.keys('scroll',1150,540,1)
    if a.reuse:
        visible('reuse-first-binding',['v'+numeric+str(initial)],(1013,130,1272,578))
        d.keys('scroll',1150,540,1)
    # Ruby's value row is only 'x = 7'. The full stack/locals OCR block can
    # discard this short line, so read the first binding as one text line.
    if a.ruby:assert index==0,bindings
    named_box=(1013,485,1272,510) if a.ruby else (1013,130,1272,578)
    named_psm=7 if a.ruby else 6
    shot,_=visible('named-x',[normalize(binding_name+numeric+str(initial))],named_box,named_psm)
    tsv=subprocess.run(['tesseract',shot+'.crop.png','stdout','--psm',str(named_psm),'tsv'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
    candidates=[v for v in csv.DictReader(io.StringIO(tsv),delimiter='\t') if normalize(v['text'])==normalize(binding_name)];assert candidates,tsv
    row=candidates[-1];d.keys('click',named_box[0]+int(row['left'])//3+5,named_box[1]+int(row['top'])//3+5,'tap',17)
    deadline=time.monotonic()+10
    while True:
        rows=d.tool('get_language_watches')['watches']
        if len(rows)==1:break
        assert time.monotonic()<deadline,rows;time.sleep(.02)
    assert rows[0]['selector']==('context_storage' if a.node else 'binding') and rows[0]['expression']=='' and rows[0]['row_name']==binding_name and rows[0]['current']['display']==display(initial),rows
    _,result['initial']=visible('watch-binding',['runtimewatches','contextstorage' if a.node else 'binding',normalize('now'+display(initial)),*(['lexicalvisibilityunproved'] if a.node else [])],(600,585,1272,764))
    if a.reuse:
        before_stack=d.tool('get_language_stack',tid=target.pid,language='lua')
        location=tuple(before_stack['segments'][segment]['frames'][frame][key] for key in ('call_info','prototype'))
    # Shift+E creates a name expression watch; ordinary E stays a stopped read.
    if a.paths:
        # Enter the path through the actual Shift+E field.
        if a.perl:
            d.keys('down',42,'tap',18,'up',42,'down',42,'tap',5,'up',42,
                   'tap',35,'tap',30,'tap',31,'tap',35,'down',42,'tap',26,'up',42,
                   'tap',31,'tap',46,'tap',24,'tap',19,'tap',18,'down',42,'tap',27,'up',42,'tap',28)
        else:
            keys=(23,20,18,50,31,26,11,27) if a.ruby else (19,24,24,20,26,40,25,38,30,21,18,19,40,27,26,40,31,46,24,19,18,40,27) if a.python else (24,48,36,18,46,20,52,30)
            d.keys('down',42,'tap',18,'up',42,*[value for key in keys for value in ('tap',key)],'tap',28)
    else:
        d.keys('down',42,'tap',18,'up',42,*(['down',42,'tap',5,'up',42] if a.perl else []),'tap',45,'tap',28)
    if a.node:
        visible('name-watch-refused',['jsnameunproved'],(1013,130,1272,578))
        assert len(d.tool('get_language_watches')['watches'])==1
        d.keys('tap',1)
    else:
        deadline=time.monotonic()+10
        while True:
            rows=d.tool('get_language_watches')['watches']
            if len(rows)==2:break
            assert time.monotonic()<deadline,rows;time.sleep(.02)
        assert rows[1]['selector']=='expression' and rows[1]['expression']==(("items[0]" if a.ruby else "$hash{score}" if a.perl else "root['player']['score']" if a.python else 'object.a') if a.paths else binding_name),rows
    if a.paths:
        d.keys('click',850,639,'tap',27)
        visible('watch-path',['items0' if a.ruby else 'hashscore' if a.perl else 'rootplayerscore' if a.python else 'objecta','expression'],(600,585,1272,764))
    assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
    d.keys('tap',57);assert d.wait(lambda s:s['generation']>generation and s['state']=='stopped' and any(t['reason']=='breakpoint' for t in s['threads']))
    json.loads(lines.get(timeout=10))
    if a.node:json.loads(lines.get(timeout=10))
    if a.node:
        # The dedicated GC stop changes storage addresses without changing x.
        gc_generation=d.session()['generation'];deadline=time.monotonic()+20
        while True:
            gc_rows=d.tool('get_language_watches')['watches']
            if all(v['observed_generation']==gc_generation and v['state']=='value' for v in gc_rows):break
            assert time.monotonic()<deadline,gc_rows;time.sleep(.02)
        assert all(not v['changed'] and v['comparison']=='same_slot_equal' for v in gc_rows),gc_rows
        d.keys('tap',57);assert d.wait(lambda s:s['generation']>gc_generation and s['state']=='stopped' and any(t['reason']=='breakpoint' for t in s['threads']))
        json.loads(lines.get(timeout=10));json.loads(lines.get(timeout=10))
    generation=d.session()['generation']
    if a.reuse:
        after_stack=d.tool('get_language_stack',tid=target.pid,language='lua')
        actual=tuple(after_stack['segments'][segment]['frames'][frame][key] for key in ('call_info','prototype'))
        assert actual==location,('reuse precondition failed',location,actual)
        result['reuse_precondition']={'same_call_info_and_prototype':True,'first':location,'second':actual}
    deadline=time.monotonic()+20
    while True:
        rows=d.tool('get_language_watches')['watches']
        if all(v['observed_generation']==generation and v['changed'] for v in rows):break
        assert time.monotonic()<deadline,rows;time.sleep(.02)
    assert all(v['current']['display']==display(changed) and v['previous']['display']==display(initial) for v in rows),rows
    _,result['changed']=visible('watch-changed',['diffactivationunproved',normalize('now'+display(changed)),'before',str(initial),*(['lexicalvisibilityunproved'] if a.node else [])],(600,585,1272,764))
    # F8 returns agent control to the human. Hidden tools must also refuse
    # direct calls with valid watch arguments, without removing either entry.
    d.keys('tap',66)
    state=d.wait(lambda s:s['agent_scope']=='observe');assert state
    listed={v['name'] for v in d.request('tools/list')['tools']}
    assert 'add_language_watch' not in listed and 'remove_language_watch' not in listed
    for tool_name,arguments in (
        ('add_language_watch',dict(generation=state['generation'],language=language,tid=target.pid,segment=segment,frame=frame,**({'row':index} if a.node else {'expression':binding_name}))),
        ('remove_language_watch',dict(generation=state['generation'],id=rows[0]['id'])),
    ):
        reply=d.request('tools/call',{'name':tool_name,'arguments':arguments})
        assert reply.get('isError') and reply['content'][0]['text']=='AgentScopeDenied',reply
    assert len(d.tool('get_language_watches')['watches'])==(1 if a.node else 2)
    result['observe_scope_direct_calls']='denied after human F8'
    # Delete removes a shared model entry, visible through MCP immediately.
    d.keys('click',850,639,'tap',111)
    deadline=time.monotonic()+10
    while len(d.tool('get_language_watches')['watches'])!=(0 if a.node else 1):
        assert time.monotonic()<deadline;time.sleep(.02)
    result['status']='pass';result['watches']=rows;result['display_dir']=d.dir
finally:
    if d:d.close()
    if target.poll() is None:target.kill()
    target.wait(timeout=10)
    if 'thread' in locals():thread.join(timeout=5)
    if result['status']!='pass':result['status']='failed'
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Runtime watch GUI: W storage, Shift+E expression or explicit refusal, qualified differences, direct scope denials and Delete passed')
