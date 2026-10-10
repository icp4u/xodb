#!/usr/bin/env python3
"""Fast GUI lane (<=15 s): visible Elisp dynamic and lexical frame bindings."""
import argparse, importlib.util, json, os, re, resource, subprocess, time
from pathlib import Path
from PIL import Image, ImageOps
from helpers.language_selection import check_layout
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--emacs',type=Path,required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path)
a=p.parse_args();os.umask(0o022);resource.setrlimit(resource.RLIMIT_CORE,(0,0));root=Path(__file__).resolve().parents[1]
w=(a.work/'.work/input-elb').resolve();w.mkdir(mode=0o755,parents=True)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],cwd=root,check=True,timeout=60)
os.environ.update(XODB_ELISP_ORACLE=str(w/'oracle.json'));d=None;result={};started=time.monotonic()
try:
    d=h.Display(str(root),['--agent-scope','control','--break','Fdebugger_trap',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--',str(a.emacs.resolve()),'-Q','--batch','-l',str(root/'tests/fixtures/elisp/bindings.el')])
    d.tool('continue',generation=d.session()['generation'])
    state=d.wait(lambda s:s['state']=='stopped' and not s['continue_pending'] and not s['symbol_discovery_pending'] and any(t['reason']=='breakpoint' for t in s['threads']),seconds=180);assert state
    pid=state['pid'];generation=state['generation'];regs=d.tool('get_registers',tid=pid)
    deadline=time.monotonic()+180
    while True:
        reply=d.request('tools/call',{'name':'get_language_stack','arguments':{'language':'elisp','tid':pid}})
        if not reply.get('isError'):break
        assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline;time.sleep(.002)
    frames=reply['structuredContent']['segments'][0]['frames'];first=next(i for i,f in enumerate(frames) if f['name']=='xodb-binding-mark')
    while not any(t['tab']=='elisp' and t['status']=='ready' for t in d.tool('get_language_tabs')['view']['tabs']):
        assert time.monotonic()<deadline;time.sleep(.002)
    d.tool('select_language_tab',generation=generation,tab='elisp')
    def select(level):
        d.tool('select_language_frame',generation=generation,tid=pid,language='elisp',segment=0,frame=first+level)
    def visible(label,wanted):
        until=time.monotonic()+15
        while True:
            shot=d.shot(label);crop=shot+'.bindings.png'
            with Image.open(shot) as im:
                pane=ImageOps.invert(im.crop((1013,130,1272,578)).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
            text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
            Path(shot+'.txt').write_text(text);normalized=re.sub('[^a-z0-9]','',text.lower())
            if all(x in normalized for x in wanted):return shot
            assert time.monotonic()<until,(label,text);time.sleep(.002)
    select(2);child=visible('elisp-child-binding',['xodbchildarg42','lexical'])
    select(4);parent=visible('elisp-parent-binding',['xodbparentarg17','lexical'])
    select(1);d.keys('scroll',1150,530,1,'scroll',1150,530,1)
    dynamic=visible('elisp-dynamic-binding',['xodbdynamic23','dynamic'])
    layout=check_layout(d,'elisp')
    assert d.session()['generation']==generation and d.tool('get_registers',tid=pid)==regs
    # Unsupported expressions still capture text before global hotkeys see it.
    # A trailing space separates the caret from the final letter for OCR.
    d.keys('tap',18,'tap',32,'tap',18,'tap',48,'tap',22,'tap',34,'tap',57)
    prompt=visible('elisp-expression-unavailable',['debug','unavailable'])
    assert d.session()['generation']==generation and d.alive();d.keys('tap',1)
    d.keys('tap',66);assert d.wait(lambda s:s['agent_scope']=='observe')
    current=d.session()['generation']
    view=d.tool('get_language_locals',generation=current,language='elisp',tid=pid,segment=0,frame=first+1)
    assert next(r for r in view['rows'] if r['name']=='xodb-dynamic')['value']['display']=='23'
    denied=d.request('tools/call',{'name':'select_language_frame','arguments':dict(generation=current,language='elisp',tid=pid,segment=0,frame=first+1)})
    assert denied.get('isError') and denied['content'][0]['text']=='AgentScopeDenied'
    result=dict(status='pass',screenshots=[child,parent,dynamic,prompt],layout=layout,seconds=time.monotonic()-started,observe_bindings=True)
finally:
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    if d:d.close()
print('elisp bindings GUI: lexical and shadowed dynamic values, paging, input capture and observer reads PASS')
