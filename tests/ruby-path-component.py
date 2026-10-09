#!/usr/bin/env python3
"""Owned CRuby subscriptions and method overrides check raw container paths."""
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
addon = w/'xodb_paths.so'
flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else []
command = ['cc', '-DNDEBUG', '-g', '-O1', '-fPIC', '-shared', '-DXODB_RUBY_PATH_ORACLE', *flags,
    *['-I'+h for h in headers], 'tests/fixtures/ruby/paths.c', 'src/language/ruby.c',
    'src/language/ruby_layout.c', '-ldw', '-lelf', '-ldl', '-o', str(addon)]

def compile(name, argv):
    r = subprocess.run(argv, capture_output=True, text=True, timeout=90)
    (w/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode == 0, (name, r.stderr)

compile('build', command)
env = dict(os.environ, XODB_RUBY_WATCHES=str(addon), XODB_RUBY_ORACLE_IMAGE=str(Path(a.ruby).resolve()))
if a.sanitize:
    env['LD_PRELOAD'] = subprocess.check_output(['cc', '-print-file-name=libasan.so'], text=True, timeout=30).strip()
    env['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'

program = '''require 'json'
require ENV.fetch('XODB_RUBY_WATCHES')
checks=0; shapes=[]
test=->(root,query,want,why=nil) { XodbPaths.oracle(root,query,want,why); checks+=1 }
[0,1,3,8,9,16,64].each do |n|
  array=Array.new(n) {|i|i}
  array.each_index {|i|test.call(array,"root[#{i}]",array[i])}
  test.call(array,"root[#{n}]",nil,'RubyPathIndexOutOfRange')
  hash={}; n.times {|i|hash["key#{i}"]=i}
  shapes << XodbPaths.shape(hash)['st']
  hash.each {|k,v|test.call(hash,"root[#{k.inspect}]",v)}
  test.call(hash,'root["missing"]',nil,'RubyPathKeyNotFound')
  hash.delete('key0'); hash.delete('key2')
  hash.each {|k,v|test.call(hash,"root[#{k.inspect}]",v)}
end
raise 'both table representations required' unless shapes.include?(true) && shapes.include?(false)
[{'key'=>7},{:key=>8},{2=>9}, {"owned_dynamic_#{123456789}".to_sym=>10}].each do |root|
  key=root.keys.first; expression="root[#{key.inspect}]"
  test.call(root,expression,root[key])
  # st_table retains the full hash; compact-table hints can collide in 8 bits.
  full=(root.to_a+16.times.map {|i|[100000+i,i]}).to_h
  raise 'full stored hash required' unless XodbPaths.shape(full)['st']
  XodbPaths.wrong_seed(full,expression)
end
mixed={'key'=>7,:symbol=>nil,2=>false}
mixed.each {|k,v|test.call(mixed,"root[#{k.inspect}]",v)}
test.call({-1=>7,2147483647=>8},'root[2147483647]',8)
test.call({'outer'=>[{'score'=>11}]},'root["outer"][0]["score"]',11)
test.call(Array.new(80) {|i|i}[20,40],'root[39]',59)
cycle={};cycle['self']=cycle;cycle['value']=13
test.call(cycle,'root["self"]["self"]["value"]',13)
test.call(Hash.new(3),'root["missing"]',nil,'RubyPathDefaultUnsupported')
[0,3,false,'fallback'].each do |fallback|
  root=Hash.new(fallback); root['found']=7; root['nil']=nil
  test.call(root,'root["found"]',7);test.call(root,'root["nil"]',nil)
  test.call(root,'root["missing"]',nil,'RubyPathDefaultUnsupported')
  20.times {|i|root[100000+i]=i}
  test.call(root,'root["found"]',7)
  test.call(root,'root["missing"]',nil,'RubyPathDefaultUnsupported')
end
calls=0; default=Hash.new {calls+=1; 5}
test.call(default,'root["missing"]',nil,'RubyPathDefaultUnsupported'); raise unless calls==0
test.call({}.compare_by_identity,'root["missing"]',nil,'RubyPathIdentityHashUnsupported')
test.call(600.times.to_h {|i|[i,i]},'root[1]',nil,'RubyPathHashLimit')
test.call({'é'=>1},'root["missing"]',nil,'RubyPathKeyUnsupported')
test.call({'x'*1100=>1},'root["missing"]',nil,'RubyPathKeyUnsupported')
test.call({Object.new=>1},'root["missing"]',nil,'RubyPathKeyUnsupported')
test.call(Class.new(Hash).new,'root["missing"]',nil,'RubyPathContainerClassUnsupported')
test.call(Class.new(Array).new,'root[0]',nil,'RubyPathContainerClassUnsupported')
single={'score'=>7}; def single.[](k); raise 'called custom []'; end
test.call(single,'root["score"]',nil,'RubyPathContainerClassUnsupported')
faults=XodbPaths.faults({'key'=>[7]},'root["key"][0]')
faults+=XodbPaths.faults(30.times.to_h {|i|["key#{i}",i]},'root["key20"]')
malformed=XodbPaths.corrupt_metadata({'key'=>7},'root["key"]')
malformed+=XodbPaths.corrupt_metadata(30.times.to_h {|i|["key#{i}",i]},'root["key20"]')
puts JSON.generate(checks:checks,failed_reads: faults,malformed_metadata:malformed)
'''

def run(name, source, runtime_env=env, expect=None):
    r = subprocess.run([a.ruby, '-e', source], env=runtime_env, capture_output=True, text=True, timeout=90)
    (w/(name+'.log')).write_text(r.stdout+r.stderr)
    if expect:
        assert r.returncode != 0 and expect in r.stderr, (name, r.returncode, r.stderr)
    else:
        assert r.returncode == 0, (name, r.returncode, r.stderr)
    return r

positive = json.loads(run('oracle', program).stdout)
# Each mutation gets an independent owned interpreter; no restoration assumptions.
cases = {
    'hash_aref': ('root={"score"=>7}; class Hash; def [](key); $calls+=1; super; end; end',
                  'root["score"]', 'RubyPathCustomMethodUnsupported'),
    'array_aref': ('root=[7]; class Array; def [](key); $calls+=1; super; end; end',
                  'root[0]', 'RubyPathCustomMethodUnsupported'),
    'string_hash_empty': ('root={}; class String; def hash; $calls+=1; super; end; end',
                         'root["missing"]', 'RubyPathCustomMethodUnsupported'),
    'string_eql': ('root={"score"=>7}; class String; def eql?(key); $calls+=1; super; end; end',
                   'root["score"]', 'RubyPathCustomMethodUnsupported'),
    'integer_hash': ('root={1=>7}; class Integer; def hash; $calls+=1; super; end; end',
                     'root[1]', 'RubyPathCustomMethodUnsupported'),
    'symbol_eql': ('root={:score=>7}; class Symbol; def eql?(key); $calls+=1; super; end; end',
                   'root[:score]', 'RubyPathCustomMethodUnsupported'),
    'refinement': ('root={"score"=>7}; module Refine; refine Hash do; def [](key); $calls+=1; super; end; end; end; using Refine',
                   'root["score"]', 'RubyPathCustomMethodUnsupported'),
    'prepend': ('root={"score"=>7}; Hash.prepend(Module.new {def [](key); $calls+=1; super; end})',
                'root["score"]', 'RubyPathPrependUnsupported'),
}
for name, (setup, expression, reason) in cases.items():
    run(name, "require ENV.fetch('XODB_RUBY_WATCHES'); $calls=0; "+setup+
        '; XodbPaths.oracle(root,'+json.dumps(expression)+',nil,'+json.dumps(reason)+
        "); raise 'custom method ran' unless $calls==0; puts 'refused without calls'")
negative = w/'negative'; negative.mkdir(); bad = negative/'xodb_paths.so'
compile('negative-build', [*command[:-2], '-DXODB_RUBY_PATH_ORACLE_NEGATIVE', '-o', str(bad)])
run('negative', "require ENV.fetch('XODB_RUBY_WATCHES'); XodbPaths.oracle([7], 'root[0]', 7, nil)",
    dict(env, XODB_RUBY_WATCHES=str(bad)), 'CHECK failed: actual.tagged==expected')
result = dict(status='pass', **positive, overridden_methods=list(cases), negative_control='wrong element rejected', sanitized=a.sanitize)
(w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print(f'Ruby paths: {positive["checks"]} subscriptions, {positive["failed_reads"]} injected read failures, method/refinement refusal and negative oracle passed')
