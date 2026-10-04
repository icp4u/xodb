#!/usr/bin/env python3
"""Run T07 scenarios against the built application, without applying old patches.

Usage: python3 scripts/input-smoke.py [layouts|cursor|controls|holding|lifecycle]
Always uses private headless Sway. Build first with ./scripts/build.
"""
import ctypes
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('t07', root/'tests/helpers/input.py')
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)
suite.WORK = str(root/'.work'/('input-live-' + datetime.now().strftime('%Y%m%dT%H%M%S%f')))
Path(suite.WORK).mkdir()
Path(suite.WORK,'tmp').mkdir()
os.environ['TMPDIR'] = str(Path(suite.WORK,'tmp'))
# Own orphaned fixtures after the detach scenario; pidfds keep cleanup tied to
# the exact process created by this test, even after the debugger exits.
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0  # PR_SET_CHILD_SUBREAPER
class Display(suite.Display):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.target_pid = self.session()['pid']
        self.target_fd = os.pidfd_open(self.target_pid)
    def close(self):
        try:
            super().close()
        finally:
            try:
                signal.pidfd_send_signal(self.target_fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(self.target_pid, 0)
            except ChildProcessError:
                pass  # debugger already reaped its target
            os.close(self.target_fd)
suite.Display = Display

for xml, stem in ((suite.VPTR,'virtual-pointer'),(suite.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(Path(suite.WORK,stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(Path(suite.WORK,stem+'.c'))],check=True)
suite.HELPER = str(Path(suite.WORK,'vinput'))
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',suite.WORK,str(root/'tests/helpers/vinput.c'),str(Path(suite.WORK,'virtual-pointer.c')),str(Path(suite.WORK,'virtual-keyboard.c')),'-lwayland-client','-lxkbcommon','-lm','-o',suite.HELPER],check=True)
subprocess.run(['cc','-g','-O0','-pthread',str(root/'tests/fixtures/input-threads.c'),'-o',str(Path(suite.WORK,'threads'))],check=True)

def active_layout():
    d = Display(str(root),suite.TARGET)
    try:
        d.stopped()
        d.keys('layout','fr,ru','group',1,'tap',suite.KEY['a'])
        press = [e for e in d.trace() if e['kind']=='press' and e['code']==suite.KEY['a']][-1]
        suite.check('inactive French layout cannot supply Q while Russian is active',d.alive() and press['shortcut']=='NoSymbol' and press['text']=='ф',press)
        d.keys('layout','fr,ru','group',0,'tap',suite.KEY['a'])
        suite.check('selecting French makes the same key Q',d.app.wait(timeout=5)==0)
    finally:
        d.close()

scenarios = dict(bursts=lambda: suite.bursts(str(root),'integrated',True),
                 controls=lambda: suite.controls(str(root)),
                 holding=lambda: suite.holding(str(root)),
                 layouts=lambda: (suite.layouts(str(root)),active_layout()),
                 lifecycle=lambda: suite.lifecycle(str(root)),
                 cursor=lambda: suite.cursor(str(root)))
selected = sys.argv[1:] or list(scenarios)
assert all(name in scenarios for name in selected), list(scenarios)
for name in selected:
    try:
        scenarios[name]()
    except Exception as error:
        suite.check(name+' scenario completed',False,repr(error))
Path(suite.WORK,'results.json').write_text(json.dumps(suite.results,indent=2,ensure_ascii=False)+'\n')
checks = [r for r in suite.results if r['ok'] is not None]
failed = [r for r in checks if not r['ok']]
print(f'{len(checks)-len(failed)}/{len(checks)} checks passed; artifacts: {suite.WORK}')
sys.exit(bool(failed))
