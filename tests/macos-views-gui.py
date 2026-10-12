#!/usr/bin/env python3
"""Private GUI: recorded Darwin thread labels and Mach stop details."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def main():
    os.umask(0o022)
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary');p.add_argument('--wrong-result',action='store_true');args=p.parse_args()
    root=Path(__file__).resolve().parents[1];os.chdir(root)
    owner=module('owner',root/'tests/remote-owner-gui.py')
    shared=module('shared',root/'tests/shared-sessions.py')
    views=module('views',root/'tests/macos-views.py')
    h,work=owner.setup(root);scale=h.load_scale()
    report=dict(status='running',rows=[]);started=time.monotonic()
    def ocr(display,name):
        assert display.alive(),Path(display.log).read_text()
        shot=display.shot(name)
        text=subprocess.run(['tesseract',shot,'stdout'],capture_output=True,text=True,check=True,
                            env={**os.environ,'OMP_THREAD_LIMIT':'1'},timeout=10*scale).stdout
        assert display.alive(),Path(display.log).read_text()
        (work/(name+'-ocr.txt')).write_text(text)
        return text
    try:
        for kind in ['threads','crash-bad-access']:
            recording=json.loads((views.FIXTURES/('transcripts/c-'+kind+'.json')).read_text())
            if kind=='threads':
                at=next(i for i,(q,r) in enumerate(recording['exchanges']) if q=='c' and r[0].startswith('T05'))
                stops=[views.Stop(recording,at)]
            else:_,stops=views.recorded_stops(kind)
            stub=views.Replay(recording,stops);stub.start()
            registry=SimpleNamespace(path=str(work/('s'+str(len(report['rows']))+'.sock')),clients=[])
            display=None
            try:
                display=h.Display(str(root),['--gdb-remote',stub.endpoint,'--session-socket',registry.path,'--agent-scope','mutate'],
                                  stdio=False,binary=args.binary)
                registry.proc=display.app
                client=shared.Client(registry,kind)
                before=views.resource(display.app.pid)
                if kind=='threads':
                    state=owner.wait(lambda:s if len((s:=client.session())['thread_labels'])==5 else None,
                                     'thread labels absent',timeout=10*scale)
                    assert state['thread_labels'][1]['name']=='xf-worker-1',state
                    # OCR may render the punctuation in the exact recorded name
                    # as a dot. The MCP assertion above verifies the bytes; here
                    # verify that the worker label and queue row reached pixels.
                    visible=owner.wait(lambda:t if 'xf-worker' in (t:=ocr(display,'threads')) and 'queue' in t else None,
                                       'thread names/queue address not rendered',timeout=10*scale)
                    if args.wrong_result:visible='planted wrong visible text'
                    assert 'xf-worker' in visible and 'queue' in visible,visible
                else:
                    client.claim();client.action('continue')
                    state=owner.wait(lambda:s if (s:=client.session()) and any(t['reason']=='exception' for t in s['threads']) else None,
                                     'Mach exception not published',timeout=10*scale)
                    stop=client.tool('get_stop_info',tid=stops[1].tid)['stop']
                    assert stop['mach_exception']['name']=='EXC_BAD_ACCESS' and stop['fault_address']==16,stop
                    display.keys('tap',46)
                    visible=owner.wait(lambda:t if 'EXC_BAD_ACCESS' in (t:=ocr(display,'exception')) else None,
                                       'Mach exception details not rendered',timeout=10*scale)
                    # The exact numeric value is asserted through MCP above;
                    # OCR commonly confuses hexadecimal zero with O or @.
                    assert 'Fault address' in visible and 'pending application signal' in visible,visible
                    assert 'Fault map unavailable' in visible and 'GdbListUnavailable' in visible,visible
                    assert 'qMemoryRegionInfo:0' in stub.requests,stub.requests
                assert not stub.extra,stub.extra
                assert display.alive(),Path(display.log).read_text()
                report['rows'].append(dict(case=kind,status='pass',resources_before=before,
                                           resources_after=views.resource(display.app.pid),visible=visible))
            finally:
                for client in registry.clients:client.close()
                if display:display.close()
                stub.join(timeout=2)
        report['status']='pass'
    finally:
        if report['status']=='running':report['status']='fail'
        report['seconds']=time.monotonic()-started
        (work/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(dict(work=str(work),**report)),flush=True)


if __name__=='__main__':main()
