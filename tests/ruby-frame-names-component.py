#!/usr/bin/env python3
"""Ruby reflection checks frame owners; every memory read and a wrong-label control fail closed."""
import argparse,json,os,resource,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ruby',required=True);p.add_argument('--work',required=True,type=Path)
a=p.parse_args();resource.setrlimit(resource.RLIMIT_CORE,(0,0));root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
h=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir"))'],text=True,timeout=30))
command=['cc','-DNDEBUG','-g','-O1','-fPIC','-shared','-I'+h[0],'-I'+h[1],
         'tests/fixtures/ruby/frame-names.c','src/language/ruby.c','src/language/ruby_layout.c','-ldw','-lelf']
for negative in (False,True):
    run=w/('negative' if negative else 'oracle');run.mkdir();addon=run/'xodb_frame_names.so'
    with (run/'compile.log').open('w') as log:
        subprocess.run([*command,*(['-DXODB_RUBY_FRAME_ORACLE_NEGATIVE'] if negative else []),'-o',str(addon)],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=90)
    done=subprocess.run([a.ruby,'tests/fixtures/ruby/frame-names.rb'],capture_output=True,text=True,timeout=60,
        env=dict(os.environ,XODB_RUBY_FRAME_NAMES=str(addon),XODB_RUBY_ORACLE_IMAGE=str(Path(a.ruby).resolve())))
    (run/'run.log').write_text(done.stdout+done.stderr)
    if negative:
        assert done.returncode!=0 and 'CHECK failed: found<stack->count' in done.stderr,done.stderr
    else:
        assert done.returncode==0,done.stderr
        assert 'verified 15 qualified frame labels' in done.stderr and '2 unproved owners' in done.stderr,done.stderr
(w/'results.json').write_text(json.dumps(dict(status='pass',qualified_labels=15,unproved_owners=2,every_read_refusal=True,wrong_label_control='rejected',ndebug=True),indent=2)+'\n')
print('Ruby qualified frames: 15 reflection checks, 2 unproved owners, every-read refusals and wrong-label control passed')
