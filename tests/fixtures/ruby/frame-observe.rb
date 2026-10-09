module ObserveMixin
  def mixed
    123.digits
  end
end
class ObserveParent
  include ObserveMixin
  def instance_call
    123.digits
  end
  alias renamed instance_call
  def self.class_call
    123.digits
  end
  define_method(:dynamic) { 123.digits }
  alias dynamic_alias dynamic
  define_method(:dynamic_block) { proc { 123.digits }.call }
  def closure
    proc { 123.digits }.call
  end
end
class ObserveChild < ObserveParent; end
ObserveParent.name
ObserveMixin.name
ObserveChild.new.instance_call
GC.start; GC.compact
ObserveChild.new.renamed
ObserveChild.new.mixed
GC.start; GC.compact
ObserveChild.class_call
ObserveParent.new.closure
ObserveChild.new.dynamic
ObserveChild.new.dynamic_alias
ObserveChild.new.dynamic_block
123.digits
