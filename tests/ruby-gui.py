#!/usr/bin/env python3
"""Ruby stack, native VALUEs and named locals on a private compositor."""
import argparse,importlib.util,json,os,re,select,subprocess,time
from pathlib import Path
from PIL import Image,ImageOps
from helpers.language_selection import check_native_values,check_layout
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--previews',action='store_true');p.add_argument('--ruby',required=True);p.add_argument('--work',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-rby').resolve();w.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
 subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
 subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
headers=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir","DLEXT"))'],text=True,timeout=30))
addon=w/('xodb_probe.'+headers[2]);subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+headers[0],'-I'+headers[1],'tests/fixtures/ruby/probe.c','-o',str(addon)],check=True,timeout=60)
target=subprocess.Popen([a.ruby,'tests/fixtures/ruby/previews.rb' if a.previews else 'tests/fixtures/ruby/locals.rb','plain'],env=dict(os.environ,XODB_RUBY_PROBE=str(addon)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
d=None
try:
 assert select.select([target.stdout],[],[],15)[0] and target.stdout.readline()==b'ready\n'
 d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid)])
 d.tool('set_breakpoint',generation=d.session()['generation'],symbol='xodb_ruby_stop')
 d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n');target.stdin.flush();assert d.stopped('breakpoint')
 assert json.loads(target.stdout.readline())['label']==('symbol' if a.previews else 'plain-slots')
 def stack():
  deadline=time.monotonic()+120
  while True:
   reply=d.request('tools/call',{'name':'get_language_stack','arguments':{'tid':target.pid,'language':'ruby'}})
   if not reply.get('isError'):return reply['structuredContent']
   assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
   time.sleep(.02)
 def choose(name,last=False):
  s=stack();rows=[(si,fi) for si,part in enumerate(s['segments']) for fi,f in enumerate(part['frames']) if f['name']==name]
  si,fi=rows[-1 if last else 0];args=dict(generation=d.session()['generation'],tid=target.pid,language='ruby',segment=si,frame=fi)
  selected=d.tool('select_language_frame',**args)['view'];assert selected['logical_selection']['anchor_basis']=='reader_segment'
  return args
 native=check_native_values(d,target.pid,'ruby','ruby')
 args=choose('preview_values' if a.previews else 'plain_slots');generation=d.session()['generation'];regs=d.tool('get_registers',tid=target.pid)
 normalize=lambda t:re.sub(r'[^a-z0-9]','',t.lower())
 def visible(label,wanted,psm=6):
  deadline=time.monotonic()+30
  while True:
   shot=d.shot(label);crop=shot+'.side.png'
   with Image.open(shot) as image:
    pane=ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
   text=subprocess.run(['tesseract',crop,'stdout','--psm',str(psm)],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
   Path(shot+'.side.txt').write_text(text)
   if all(any(word in normalize(text) for word in (item if isinstance(item,tuple) else (item,))) for item in wanted):return text
   assert time.monotonic()<deadline,text
   time.sleep(.05)
 if a.previews:
  first=visible('ruby-preview-locals',['namedlocals','symbolready'])
  keys=dict(zip('abcdefghijklmnopqrstuvwxyz',[30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44]))
  screenshots={}
  for name,wanted in [('symbol',['esymbol','ready']),('mapping',['emapping','hash2']),('items',['eitems','array3']),('subclass',['esubclass','unavail'])]:
   # Open E and replace any previous expression with Ctrl+A.
   d.keys('tap',18,'down',29,'tap',30,'up',29,*[part for c in name for part in ('tap',keys[c])],'tap',28)
   screenshots[name]=visible('ruby-preview-'+name,wanted)
  refused=d.tool('evaluate_language_expression',expression='subclass',**args)
  assert refused['rows'][0]['value']['diagnostic']=='RubyPreviewContainerClassUnsupported',refused
  decoded=d.tool('evaluate_language_expression',expression='unicode',**args)
  assert decoded['rows'][0]['value']['display']=='\"é猫😀\"',decoded
  for name,marker in [('cycle_hash','{...}'),('cycle_array','[...]')]:
   decoded=d.tool('evaluate_language_expression',expression=name,**args)
   assert decoded['rows'][0]['value']['children'][0]['display']==marker,decoded
  expression=screenshots;recursive=None
  assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
 else:
  # MCP checks the exact name; OCR can mistake the mono-font l for 1.
  first=visible('ruby-locals',['namedlocals','seed7',('plainslots','p1ainslots')])
  d.keys('tap',18,'tap',31,'tap',18,'tap',18,'tap',32,'tap',28)
  expression=visible('ruby-expression',['eseed7','expressionresultabove'])
  assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
  for label in ('sample','recursive-0'):
   previous=d.session()['generation'];d.tool('continue',generation=previous)
   assert d.wait(lambda s:s['generation']>previous and s['state']=='stopped' and any(t['reason']=='breakpoint' for t in s['threads']))
   assert json.loads(target.stdout.readline())['label']==label
  args=choose('recursive',last=True)
  deadline=time.monotonic()+30
  while True:
   recursive=visible('ruby-recursive',['recursive','namedlocals','depth2'])
   if recursive.lower().count('recursive')>=3:break
   assert time.monotonic()<deadline,recursive
   time.sleep(.05)
 d.keys('tap',66);assert d.wait(lambda s:s['agent_scope']=='observe')
 args['generation']=d.session()['generation'];regs=d.tool('get_registers',tid=target.pid)
 locals_=d.tool('get_language_locals',**args);value=d.tool('evaluate_language_expression',expression='symbol' if a.previews else 'depth',**args)
 assert value['rows'][0]['value']['display']==(':ready' if a.previews else '2') and not value['diagnostic'],value
 assert d.session()['generation']==args['generation'] and d.tool('get_registers',tid=target.pid)==regs
 d.keys('tap',66);assert d.wait(lambda s:s['agent_scope']=='control')
 observed=stack()
 si,fi,frame=next((si,fi,f) for si,part in enumerate(observed['segments']) for fi,f in enumerate(part['frames']) if f['qualified_name']=='XodbRuby.probe')
 assert frame['name']=='<cfunc>' and frame['name_reason'] is None and frame['reason']=='RubyNativeBoundary',frame
 d.tool('select_language_frame',generation=d.session()['generation'],tid=target.pid,language='ruby',segment=si,frame=fi)
 # Sparse text mode separates the selected-row outline from its glyphs.
 qualified=visible('ruby-native-method',['xodbrubyprobe','rubynativeboundary'],psm=11)
 layout=check_layout(d,'ruby','RubyNativeBoundary')
 mains=[f for part in stack()['segments'] for f in part['frames'] if f['name']=='<main>']
 assert mains and all(f['qualified_name']=='<main>' and f['name_reason'] is None for f in mains),mains
 choose('<main>')
 main=visible('ruby-main',['main'],psm=11)
 assert 'mainownerunproved' not in normalize(main),main
 (w/'results.json').write_text(json.dumps(dict(status='pass',layout=layout,main=main,native=native,locals=locals_,first=first,expression=expression,recursive=recursive,qualified=qualified,observer=True),indent=2)+'\n')
finally:
 if d:d.close()
 if target.poll() is None:target.kill()
 target.wait(timeout=10)
print('Ruby GUI: Symbol/Hash/Array expressions and observer reads passed' if a.previews else 'Ruby GUI: qualified native method, named locals, expression label, three recursive frames, native VALUEs and observer reads passed')
