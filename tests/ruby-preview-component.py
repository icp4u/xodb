#!/usr/bin/env python3
"""Independent owned CRuby preview counts, order, names, bounds and read faults."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--ruby', required=True)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args()
os.chdir(Path(__file__).resolve().parents[1]); os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
headers = json.loads(subprocess.check_output([a.ruby, '-rjson', '-rrbconfig', '-e',
    'puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir"))'], text=True, timeout=30))
addon = w/'xodb_previews.so'
flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else []
command = ['cc', '-DNDEBUG', '-g', '-O1', '-fPIC', '-shared', *flags,
    *['-I'+h for h in headers], 'tests/fixtures/ruby/previews.c', 'src/language/ruby.c',
    'src/language/ruby_layout.c', '-ldw', '-lelf', '-ldl', '-o', str(addon)]

def compile(name, argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=90)
    (w/(name+'.log')).write_text(result.stdout+result.stderr)
    assert result.returncode == 0, (name, result.stderr)

compile('build', command)
env = dict(os.environ, XODB_RUBY_PREVIEWS=str(addon), XODB_RUBY_ORACLE_IMAGE=str(Path(a.ruby).resolve()))
if a.sanitize:
    env['LD_PRELOAD'] = subprocess.check_output(['cc', '-print-file-name=libasan.so'], text=True, timeout=30).strip()
    env['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'

program = r'''require 'json'
require ENV.fetch('XODB_RUBY_PREVIEWS')
checks=0
test=->(v,display) {
  r=XodbPreview.read(v); raise [v.class,display,r].to_s unless r['display']==display
  checks+=1; r
}
test.call(:ready,':ready')
raise 'static symbol untested' unless XodbPreview.read(:ready)['static_symbol']
dynamic=('owned_dynamic_'+123456789.to_s).to_sym
raise 'dynamic symbol untested' if XodbPreview.read(dynamic)['static_symbol']
test.call(dynamic,':owned_dynamic_123456789')
{''=>':""','+' => ':"+"',"white space"=>':"white space"',
 "quote\"slash\\"=>':"quote\x22slash\x5c"',"line\n"=>':"line\x0a"',
 "nul\0"=>':"nul\x00"','é'=>':"é"'}.each {|s,d|test.call(s.to_sym,d)}
test.call("é猫😀",'"é猫😀"')
test.call("é".b,'"\xc3\xa9"')
test.call("\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80".force_encoding('UTF-8'),'"\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80"')
[125,126,127].each do |prefix|
  r=test.call('x'*prefix+'😀','"'+'x'*prefix+'"...')
  raise unless r['truncated'] && r['display'].valid_encoding?
end
r=test.call('x'*124+'😀','"'+'x'*124+'😀"');raise if r['truncated']
child=("\xff"*53+'猫'*3).force_encoding('UTF-8')
r=test.call([child],'Array(1) ["'+'\xff'*53+'猫猫"...]')
raise unless r['truncated'] && r['children'][0]['display'].valid_encoding?
long=('x'*512).to_sym
r=test.call(long,':"'+'x'*128+'"...'); raise unless r['truncated'] && r['count']==512
test.call([1,nil,true],'Array(3) [1, nil, true]')
test.call({score:7,'name'=>'ruby'},'Hash(2) {:score => 7, "name" => "ruby"}')
test.call([], 'Array(0) []');test.call({}, 'Hash(0) {}')
shapes=[]
[0,1,3,8,9,32,600].each do |n|
  array=Array.new(n) {|i|i}; hash=n.times.to_h {|i|[i,i+100]}
  shapes << XodbPaths.shape(hash)['st']
  r=XodbPreview.read(array); raise unless r['children'].map {|x|x['display']}==array.first(8).map(&:to_s)
  r=XodbPreview.read(hash); raise unless r['children'].map {|x|[x['key'],x['display']]}==hash.first(8).map {|k,v|[k.to_s,v.to_s]}
  hash.delete(0);hash.delete(2)
  r=XodbPreview.read(hash); raise unless r['children'].map {|x|[x['key'],x['display']]}==hash.first(8).map {|k,v|[k.to_s,v.to_s]}
  checks+=3
end
raise 'both table representations required' unless shapes.include?(true) && shapes.include?(false)
r=XodbPreview.read(Array.new(80) {|i|i}[20,40]);raise unless r['children'].first['display']=='20'
cycle={};cycle[:self]=cycle;test.call(cycle,'Hash(1) {:self => {...}}')
cycle=[];cycle<<cycle;test.call(cycle,'Array(1) [[...]]')
test.call([{:x=>[1]}],'Array(1) [Hash(1)]')
r=test.call(['x'*512],'Array(1) ["'+'x'*128+'"...]')
raise 'child truncation was hidden' unless r['truncated'] && r['count']==1
array=["\xff"*128, "\xff"*128, "\xff"*128, :leaf];r=XodbPreview.read(array)
raise unless r['truncated'] && r['display'].end_with?(', ...]') && r['children'].length==4
raise 'partial escape' unless r['children'][0]['display']=='"'+'\xff'*54+'"...'
test.call(Hash.new(0).merge(x:7),'Hash(1) {:x => 7}')
test.call(Hash.new {raise 'default called'}.merge(x:7),'Hash(1) {:x => 7}')
identity={}.compare_by_identity;identity['x']=7
test.call(identity,'Hash(1) {"x" => 7}')
XodbPreview.refuse(Class.new(Hash).new.merge(x:7),'RubyPreviewContainerClassUnsupported')
XodbPreview.refuse(Class.new(Array).new([7]),'RubyPreviewContainerClassUnsupported')
single={x:7};def single.inspect;raise 'custom inspect ran';end
XodbPreview.refuse(single,'RubyPreviewContainerClassUnsupported')
faults=[:ready,dynamic,{key:[7]},30.times.to_h {|i|[i,"value#{i}"]},[dynamic,'value',nil],"é猫😀"].sum {|v|XodbPreview.faults(v)}
GC.start;GC.compact
test.call(dynamic,':owned_dynamic_123456789')
test.call(long,':"'+'x'*128+'"...')
# Preview reads raw storage even when these Ruby methods would raise.
root={ready: [7]}
class Symbol; def inspect;raise 'Symbol#inspect called';end;def to_s;raise 'Symbol#to_s called';end;end
class Hash;def [](k);raise 'Hash#[] called';end;def inspect;raise 'Hash#inspect called';end;end
class Array;def [](k);raise 'Array#[] called';end;def inspect;raise 'Array#inspect called';end;end
XodbPreview.read(:ready);XodbPreview.read(root);XodbPreview.read([:ready])
puts JSON.generate(checks:checks+3,class_refusals:3,failed_reads:faults)
'''

def run(name, source, runtime_env=env, expect=None):
    result = subprocess.run([a.ruby, '-e', source], env=runtime_env, capture_output=True, text=True, timeout=90)
    (w/(name+'.log')).write_text(result.stdout+result.stderr)
    if expect:
        assert result.returncode != 0 and expect in result.stderr, (name, result.returncode, result.stderr)
    else:
        assert result.returncode == 0, (name, result.returncode, result.stderr)
    return result

positive = json.loads(run('oracle', program).stdout)
negative = w/'negative'; negative.mkdir(); bad = negative/'xodb_previews.so'
compile('negative-build', [*command[:-2], '-DXODB_RUBY_PREVIEW_NEGATIVE', '-o', str(bad)])
run('negative', "require ENV.fetch('XODB_RUBY_PREVIEWS'); XodbPreview.read(:ready)",
    dict(env, XODB_RUBY_PREVIEWS=str(bad)), 'CHECK failed: got.count==count')
result = dict(status='pass', **positive, negative_control='wrong count rejected', sanitized=a.sanitize)
(w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print(f'Ruby previews: {positive["checks"]} display checks, {positive["failed_reads"]} read faults, overrides and negative oracle passed')
