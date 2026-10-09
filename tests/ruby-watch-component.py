#!/usr/bin/env python3
"""CRuby public macros independently verify complete watch samples."""
import argparse,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ruby',required=True);p.add_argument('--work',required=True,type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
h=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir"))'],text=True,timeout=30))
addon=w/'xodb_watches.so'
cmd=['cc','-g','-O1','-fPIC','-shared','-DXODB_RUBY_WATCH_ORACLE','-I'+h[0],'-I'+h[1],
     'tests/fixtures/ruby/watches.c','src/language/ruby.c','src/language/ruby_layout.c','-ldw','-lelf','-o',str(addon)]
with (w/'compile.log').open('w') as log:subprocess.run(cmd,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=90)
program='''require ENV.fetch('XODB_RUBY_WATCHES')
values=[nil,true,false,0,-1,2**61-1,-(2**61),2**100,0.0,-0.0,Float::INFINITY,-Float::INFINITY,Float::NAN,:symbol,[],{},Object.new]
500.times {|i| values << (i*0.0123456789) << -(i*12345678) }
[0,1,15,128,512,4095,4096].each {|n| [Encoding::UTF_8,Encoding::ASCII_8BIT,Encoding::UTF_16LE].each {|encoding|values << ('x'*n).force_encoding(encoding)}}
values.each {|v|XodbWatch.sample(v)}
XodbWatch.stop
puts 'public macro samples passed'
'''
with (w/'oracle.log').open('w') as log:
    subprocess.run([a.ruby,'-e',program],check=True,stdout=log,stderr=subprocess.STDOUT,env=dict(os.environ,XODB_RUBY_WATCHES=str(addon),XODB_RUBY_ORACLE_IMAGE=str(Path(a.ruby).resolve())),timeout=60)
(w/'results.json').write_text(json.dumps({'status':'pass','samples':1038,'extended_encoding_refusal':'covered_by_synthetic_reader_test'})+'\n')
print('Ruby watch samples: 1038 public-macro values, signed/float/NaN, bytes/encodings, cap and unsupported refusal passed')
