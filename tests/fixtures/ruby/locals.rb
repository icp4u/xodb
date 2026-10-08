require 'json'
require ENV.fetch('XODB_RUBY_PROBE')
$stdout.sync = true
ORACLE = ARGV[0] == 'binding'

def mark(label, b)
  info = {label:label}
  if b
    info[:locals] = b.local_variables.to_h { |n| [n, (v=b.local_variable_get(n); [Integer,Float,String,TrueClass,FalseClass,NilClass].any?{|t|v.is_a?(t)} ? v : {type:v.class.name})] }
  end
  puts JSON.generate(info)
  XodbRuby.probe(label)
end

def plain_slots(seed)
  word = 'hello'
  truth = true
  negative = -7
  fraction = 3.5
  items = [1, nil, true]
  long_text = 'x' * 512
  mark('plain-slots', ORACLE ? binding : nil)
  seed + word.length + (truth ? 1 : 0)
end

def sample(seed)
  captured = 41
  keep = -> { captured + seed }
  stack_only = 17
  mark('sample', ORACLE ? binding : nil)
  stack_only + keep.call
end

def recursive(depth)
  own = depth * 10
  recursive(depth-1) if depth > 0
  mark('recursive-'+depth.to_s, ORACLE ? binding : nil)
  own
end
def outer(seed)
  captured = 41
  read_outer = -> { captured }
  inner = ->(captured) do
    mark('closure', ORACLE ? binding : nil)
    captured + seed + read_outer.call
  end
  inner.call(99)
end
puts 'ready'
STDIN.gets
raise 'plain' unless plain_slots(7) == 13
raise 'sample' unless sample(7) == 65
recursive(2)
raise "closure" unless outer(7) == 147
fiber = Fiber.new do
  captured = 11
  mark('fiber-0', ORACLE ? binding : nil)
  Fiber.yield captured
  captured = 12
  mark('fiber-1', ORACLE ? binding : nil)
  captured
end
raise 'fiber0' unless fiber.resume == 11
GC.start
raise 'fiber1' unless fiber.resume == 12
