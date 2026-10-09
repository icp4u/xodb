require 'json'
require ENV.fetch('XODB_RUBY_PROBE')
$stdout.sync = true

def preview_values
  symbol = :ready
  unicode = "é猫😀"
  cycle_hash = {}; cycle_hash[:self] = cycle_hash
  cycle_array = []; cycle_array << cycle_array
  subclass = Class.new(Hash)[score: 7]
  def subclass.inspect; raise "custom inspect ran"; end
  mapping = {state: symbol, 'score' => 7}
  items = [symbol, 7, nil]
  ['symbol', 'mapping', 'items', 'unicode', 'cycle_hash', 'cycle_array', 'subclass', 'compacted'].each do |label|
    if label == 'compacted'
      symbol = ('état prêt ' + 123456789.to_s).to_sym
      mapping = {state: symbol, 'score' => 8}
      items = [symbol, 8, nil]
      GC.start
      GC.compact
    end
    expected = {
      'symbol' => {type:'Symbol', count:symbol.to_s.bytesize, display: symbol.inspect, children:[]},
      'mapping' => {type:'Hash', count:mapping.size,
        display: "Hash(#{mapping.size}) {" + mapping.map {|k,v| "#{k.inspect} => #{v.inspect}"}.join(', ') + '}',
        children:mapping.map {|k,v| {key:k.inspect, display:v.inspect}}},
      'items' => {type:'Array', count:items.size,
        display:"Array(#{items.size}) [" + items.map(&:inspect).join(', ') + ']',
        children:items.each_with_index.map {|v,i|{key:i.to_s, display:v.inspect}}}
    }
    expected['unicode'] = {type:'String', count:unicode.bytesize, display:unicode.inspect, children:[]}
    raise 'unexpected Ruby cycle rendering' unless cycle_hash.inspect == '{self: {...}}' && cycle_array.inspect == '[[...]]'
    expected['cycle_hash'] = {type:'Hash', count:cycle_hash.size, display:'Hash(1) {:self => {...}}', truncated:true,
      children:[{key:':self', display:'{...}'}]}
    expected['cycle_array'] = {type:'Array', count:cycle_array.size, display:'Array(1) [[...]]', truncated:true,
      children:[{key:'0', display:'[...]'}]}
    expected['subclass'] = {diagnostic:'RubyPreviewContainerClassUnsupported'}
    native = label == 'compacted' ? 'mapping' : label
    puts JSON.generate(label:label, expected:expected, native:native)
    XodbRuby.probe({'symbol'=>symbol, 'mapping'=>mapping, 'items'=>items, 'unicode'=>unicode, 'cycle_hash'=>cycle_hash, 'cycle_array'=>cycle_array, 'subclass'=>subclass}.fetch(native))
  end
end
puts 'ready'
STDIN.gets
preview_values
