#!/usr/bin/env python3
"""Private GUI reconnect preserves the explicit UUID-matched Mach-O file."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def main():
    os.umask(0o022)
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary');p.add_argument('--wrong-result',action='store_true');args=p.parse_args()
    root=Path(__file__).resolve().parents[1];os.chdir(root)
    owner=module('owner',root/'tests/remote-owner-gui.py');shared=module('shared',root/'tests/shared-sessions.py');names=module('names',root/'tests/macos-names.py')
    h,work=owner.setup(root);scale=h.load_scale()
    recording=json.loads((names.FIXTURES/'transcripts/cxx-basic.json').read_text());stops=names.phases(recording)
    class Reconnect(names.Replay):
        def run(self):
            try:
                for _ in range(2):
                    saved=self.listener.dup()
                    super().run()
                    self.listener=saved
            finally:self.listener.close()
    stub=Reconnect(recording,stops);stub.start()
    binary=names.FIXTURES/'corpus'/recording['program'];registry=SimpleNamespace(path=str(work/'session.sock'),clients=[])
    display=None;report=dict(status='running',rows=[])
    def label(client):
        result=client.raw('get_macho_image',address=hex(stops[0].pc))['result']
        assert not result.get('isError'),result
        value=result['structuredContent']
        return None if value['status']=='pending' else value
    try:
        display=h.Display(str(root),['--gdb-remote',stub.endpoint,'--exe',str(binary),'--session-socket',registry.path],stdio=False,binary=args.binary)
        registry.proc=display.app
        for n in range(2):
            client=shared.Client(registry,'names-'+str(n));state=client.session()
            value=owner.wait(lambda:label(client),'symbols did not settle',timeout=30*scale)
            if args.wrong_result:value['label']='planted-wrong-label'
            assert value['status']=='ready' and value['label']=='cxxprog!bp_target+0x0',value
            report['rows'].append(dict(session=state['session_id'],label=value))
            if n==0:
                display.keys('down',29,'down',42,'tap',19,'up',42,'up',29)
                owner.wait(lambda:'remote incarnation=1 retired;' in Path(display.log).read_text(),'old owner did not retire',timeout=30*scale)
                assert client.sock.recv(1)==b''
            client.close()
        assert report['rows'][0]['session']!=report['rows'][1]['session']
        assert not stub.extra,stub.extra
        report['status']='pass'
    finally:
        for client in registry.clients:client.close()
        if display:display.close()
        stub.join(timeout=2)
        if report['status']=='running':report['status']='fail'
        (work/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(work=str(work),**report)),flush=True)


if __name__=='__main__':main()
