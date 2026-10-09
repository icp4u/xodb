require 'json'
require ENV.fetch('XODB_RUBY_WATCHES')
$stdout.sync = true
$custom_calls = 0

def mark_paths(label, b)
  root = b.local_variable_get(:root)
  array = b.local_variable_get(:array)
  symbol = b.local_variable_get(:symbol)
  bad = b.local_variable_get(:bad)
  identity = b.local_variable_get(:identity)
  default = b.local_variable_get(:default)
  values = [
    XodbPaths.oracle(root, 'root["player"]["score"]', root['player']['score'], nil),
    XodbPaths.oracle(root, 'root["player"]["text"]', root['player']['text'], nil),
    XodbPaths.oracle(root, 'root["list"][1]', root['list'][1], root['list'].length>1 ? nil : 'RubyPathIndexOutOfRange'),
    XodbPaths.oracle(root, 'root["optional"]', root['optional'], root.key?('optional') ? nil : 'RubyPathKeyNotFound'),
    XodbPaths.oracle(array, 'array[0]', array[0], array.empty? ? 'RubyPathIndexOutOfRange' : nil),
    XodbPaths.oracle(symbol, 'symbol[:score]', symbol[:score], nil),
    XodbPaths.oracle(symbol, 'symbol[2]', symbol[2], nil),
    XodbPaths.oracle(bad, 'bad["score"]', nil, 'RubyPathContainerClassUnsupported'),
    XodbPaths.oracle(identity, 'identity["score"]', nil, 'RubyPathIdentityHashUnsupported'),
    XodbPaths.oracle(default, 'default["score"]', nil, 'RubyPathDefaultUnsupported'),
  ]
  puts JSON.generate(label:label, values:values, custom_calls:$custom_calls)
  XodbWatch.stop
end

def watched_paths
  root={'player'=>{'score'=>7,'text'=>'a'*512},'list'=>[10,20]}
  array=[1,nil,true]; symbol={:score=>8,2=>false}
  bad={'score'=>7}; def bad.[](key); $custom_calls+=1; super; end
  identity={'score'=>7}.compare_by_identity
  default=Hash.new {$custom_calls+=1; 7}
  b=binding
  mark_paths('initial', b)
  retained=root
  root={'player'=>{'score'=>9,'text'=>'a'*511+'b'},'list'=>[10,21],'optional'=>nil}
  array=[2,nil,true]; symbol[:score]=9; symbol[2]=true
  mark_paths('replaced', b)
  root=Marshal.load(Marshal.dump(root)); GC.start; GC.compact
  mark_paths('equal', b)
  root.delete('optional'); root['list'].clear; array.clear
  mark_paths('missing', b)
  root['optional']=true; root['list']=[10,22]; array=[3]
  mark_paths('recovered', b)
  root['player']={'score'=>10,'text'=>'a'*511+'c'}
  mark_paths('intermediate', b)
  root['player']['text']=root['player']['text'].dup
  mark_paths('equal-again', b)
  raise 'retained original missing' unless retained['player']['score']==7
end

puts 'ready'
STDIN.gets
watched_paths
raise 'custom method called' unless $custom_calls==0
puts 'done custom_calls=0'
