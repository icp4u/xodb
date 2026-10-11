#!/usr/bin/env python3
"""Periodic GUI: a GDScript engine above the remote image cap is refused visibly.
The native stack oracle remains in gdscript-gui.py; this checks agent limits.
"""
import argparse, importlib.util, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot',required=True);p.add_argument('--work',type=Path,required=True)
p.add_argument('--wrong-result',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
a.work.mkdir(parents=True,exist_ok=True);work=Path(tempfile.mkdtemp(prefix='gdlimit-',dir=a.work.resolve()));work.chmod(0o755)
spec=importlib.util.spec_from_file_location('limit_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
h.Display.reply_seconds=30*h.load_scale()
for name in ['tmp','cache']:(work/name).mkdir(mode=0o755)
engine=Path(a.redot).resolve();limit=256*1024*1024
# Small engines get inert trailing bytes in an owned copy, so this oracle
# always proves a size refusal. ELF load segments and DWARF stay unchanged.
if engine.stat().st_size<=limit:
    owned=work/'redot';shutil.copy2(engine,owned)
    with owned.open('r+b') as f:f.truncate(limit+1)
    engine=owned
shutil.copytree(root/'tests/fixtures/redot',work/'project')
log=(work/'game.log').open('wb');game=subprocess.Popen([str(engine),'--headless','--path',str(work/'project')],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
d=None;began=time.monotonic();report=dict(status='running',engine_bytes=engine.stat().st_size,load=os.getloadavg(),cpus=os.cpu_count())
try:
    deadline=time.monotonic()+30*h.load_scale()
    while 'ORACLE stack ' not in (work/'game.log').read_text(errors='replace'):
        assert game.poll() is None and time.monotonic()<deadline
        time.sleep(.01)
    each=(engine.stat().st_size*11//10>>20)+1
    d=h.Display(str(root),['--agent-scope','control','--runtime-agent',str(root/'zig-out/bin/xodb-agent'),'--attach',str(game.pid),'--image-limit',f'{each}M','--image-total-limit',f'{max(2*each,512)}M'])
    state=d.wait(lambda s:s['state']=='stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'],seconds=30)
    assert state,d.tail();generation=state['generation'];regs=d.tool('get_registers',tid=game.pid)
    deadline=time.monotonic()+30*h.load_scale()
    while True:
        reply=d.request('tools/call',{'name':'get_language_stack','arguments':dict(tid=game.pid,language='gdscript',generation=generation)})
        why=reply.get('content',[{}])[0].get('text','')
        if not why.endswith('Pending'):break
        assert time.monotonic()<deadline,reply
        time.sleep(.01)
    report['observed_refusal']=why
    expected='GDScriptDwarfUnavailable' if a.wrong_result else 'GDScriptImageBudgetExceeded'
    assert reply.get('isError') and why==expected,reply
    assert any('remote image transfer is capped at 256 MiB' in c.get('text','') for c in reply['content']),reply
    while True:
        view=d.tool('get_language_tabs')['view'];tab=next(t for t in view['tabs'] if t['tab']=='gdscript')
        if tab['status']!='pending':break
        assert time.monotonic()<deadline,view
        time.sleep(.01)
    assert tab['status']=='unavailable' and tab['reason']==expected and not tab['visible'],tab
    denied=d.request('tools/call',{'name':'select_language_tab','arguments':dict(generation=generation,tab='gdscript')})
    assert denied.get('isError') and denied['content'][0]['text']=='LanguageTabUnavailable',denied
    text=h.ocr_until(d,'budget-refusal',lambda s:'gdscript' in s and 'unavailable' in s and 'budget' in s,'--psm','11',seconds=20)
    assert d.session()['generation']==generation and d.tool('get_registers',tid=game.pid)==regs
    if not a.wrong_result:
        wrong=subprocess.run([sys.executable,__file__,'--redot',a.redot,'--work',str(a.work),'--wrong-result'],capture_output=True,text=True,timeout=90*h.load_scale())
        (work/'wrong-result.log').write_text(wrong.stdout+wrong.stderr)
        observed=[json.loads(line) for line in wrong.stdout.splitlines() if line.startswith('{')]
        assert wrong.returncode!=0 and observed and observed[-1].get('observed_refusal')=='GDScriptImageBudgetExceeded' and 'AssertionError' in wrong.stderr,wrong.stdout+wrong.stderr
        report['wrong_result']=dict(status='expected_failure',exit_code=wrong.returncode,observed=observed[-1])
    report.update(status='pass',tab=tab,ocr=text)
finally:
    if report['status']!='pass':report['status']='failed'
    report['seconds']=time.monotonic()-began
    if d:d.close()
    if game.poll() is None:game.kill()
    game.wait(timeout=30);log.close()
    (work/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report),flush=True)
print('GDScript owner: image cap observed, typed/visible refusal, selection denied, registers unchanged')
