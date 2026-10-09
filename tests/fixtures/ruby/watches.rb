require 'json'
require ENV.fetch('XODB_RUBY_WATCHES')
$stdout.sync = true
NAMES = %i[x word fraction truth empty object large]
def mark(label, values)
  puts JSON.generate(label:label, values:values.transform_values { |v| XodbWatch.sample(v) })
  XodbWatch.stop
end
def from_binding(b)
  NAMES.to_h { |name| [name, b.local_variable_get(name)] }
end
def deeper(n, b)
  if n>0
    deeper(n-1,b)
  else
    mark('deep',from_binding(b))
  end
end
def watched
  x=7;word='x'*512;fraction=3.5;truth=true;empty=nil;object=[];large=2**100
  mark('initial',{x:x,word:word,fraction:fraction,truth:truth,empty:empty,object:object,large:large})
  x=8;word.setbyte(511,121)
  b=binding
  mark('changed',from_binding(b))
  word=word.dup
  GC.start
  GC.compact
  mark('equal',from_binding(b))
  word.force_encoding(Encoding::ASCII_8BIT)
  mark('encoding',from_binding(b))
  x=8.0;fraction=-0.0;truth=false;empty=true
  mark('typed',from_binding(b))
  word='x'*4095
  mark('cap',from_binding(b))
  word='x'*4096
  mark('limit',from_binding(b))
  word="a\x00\xff".b;fraction=Float::INFINITY
  mark('bytes',from_binding(b))
  ->(x) { mark('shadow',from_binding(binding)) }.call(999)
  mark('outer',from_binding(b))
  Fiber.new { mark('other-fiber',{}) }.resume
  mark('fiber-return',from_binding(b))
  deeper(8,b)
  mark('unwound',from_binding(b))
end
puts 'ready'
STDIN.gets
watched
mark('gone',{})
watched
puts 'done'
