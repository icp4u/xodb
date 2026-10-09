#!/usr/bin/env python3
"""E on the Ruby tab after a stop dropped the frame selection, then E on C/C++.

The demo-cruby flow on a private compositor: the first E reads `round`; after
Space the logical selection is gone. E must still open the field so the typed
expression never reaches global keys (r = FP/SIMD panel, d = Detach, ...).
The frame chosen next binds it, and C/C++ E still adds a native watch."""
import argparse,importlib.util,os,re,subprocess,time
from pathlib import Path
from PIL import Image,ImageOps
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ruby',required=True);p.add_argument('--work',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-rbe').resolve();w.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
 subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
 subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
target=subprocess.Popen([a.ruby,'examples/ruby-demo.rb'],stdout=subprocess.PIPE)
d=None
normalize=lambda t:re.sub(r'[^a-z0-9]','',t.lower())
ROUND=(19,24,22,49,32)
def ocr(label,box):
 shot=d.shot(label);crop=shot+'.crop.png'
 with Image.open(shot) as image:
  pane=ImageOps.invert(image.crop(box).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
 text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
 Path(shot+'.txt').write_text(text);return text
def visible(label,box,wanted,absent=()):
 deadline=time.monotonic()+30
 while True:
  text=normalize(ocr(label,box))
  if all(x in text for x in wanted) and not any(x in text for x in absent):return text
  assert time.monotonic()<deadline,(label,text)
  time.sleep(.05)
def tick():
 deadline=time.monotonic()+120
 while True:
  reply=d.request('tools/call',{'name':'get_language_stack','arguments':{'tid':target.pid,'language':'ruby'}})
  if not reply.get('isError'):break
  assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
  time.sleep(.02)
 s,f=next((s,f) for s,part in enumerate(reply['structuredContent']['segments']) for f,row in enumerate(part['frames']) if row['name']=='tick')
 d.tool('select_language_frame',generation=d.session()['generation'],tid=target.pid,language='ruby',segment=s,frame=f)
SIDE=(1013,90,1272,578);SCREEN=(0,0,1280,800);WATCH=(600,585,1272,764)
try:
 pid=int(target.stdout.readline())
 d=h.Display(str(root),['--agent-scope','control','--source','examples/ruby-demo.rb','--attach',str(pid),'--break','rb_ary_store'])
 g=d.session()['generation'];d.keys('tap',57);assert d.wait(lambda s:s['generation']>g and s['state']=='stopped' and any(t['reason']=='breakpoint' for t in s['threads']),10)
 d.tool('select_language_tab',generation=d.session()['generation'],tab='ruby');tick()
 d.keys('tap',18,*[v for k in ROUND for v in ('tap',k)],'tap',28)
 first=visible('first-read',SIDE,['eround'])
 # The next stop drops the logical selection; E and the typed name follow.
 g=d.session()['generation'];d.keys('tap',57);assert d.wait(lambda s:s['generation']>g and s['state']=='stopped',10)
 g=d.session()['generation'];d.keys('tap',18,*[v for k in ROUND for v in ('tap',k)])
 pending=visible('unselected-E',SCREEN,['round','namedlocals'],['fpsimd'])  # hint text is truncated, so OCR checks the field and the absent panel
 s=d.session();assert s['generation']==g and s['state']=='stopped',s  # no Detach/continue from typed letters
 tick();d.keys('tap',28)
 second=visible('second-read',SIDE,['eround'],['selectalogicalfram'])
 d.keys('click',1110,109,'tap',18,'tap',23,'tap',32,'tap',45,'tap',28)
 native=visible('c-watch',WATCH,['idx'],['fpsimd'])
 Path(w/'results.json').write_text('{"status":"pass"}\n')
finally:
 if d:d.close()
 if target.poll() is None:target.kill()
 target.wait(timeout=10)
print('Ruby E without a selected frame keeps typed keys in the field; C/C++ E still works')
