require ENV.fetch('XODB_RUBY_FRAME_NAMES')
module FrameMixin
  def mixed
    method = method(__callee__)
    suffix = method.original_name == __callee__ ? '' : " (alias of #{method.original_name})"
    XodbFrameNames.capture("#{method.owner.name}##{__callee__}#{suffix}")
  end
end
class FrameParent
  include FrameMixin
  def instance_call
    method = method(__callee__)
    suffix = method.original_name == __callee__ ? '' : " (alias of #{method.original_name})"
    XodbFrameNames.capture("#{method.owner.name}##{__callee__}#{suffix}")
  end
  alias renamed instance_call
  def self.class_call
    XodbFrameNames.capture('FrameParent.class_call')
  end
  define_method(:dynamic) do
    XodbFrameNames.capture('FrameParent#dynamic (define_method)')
  end
  alias dynamic_alias dynamic
  define_method(:aliased_dynamic) do
    method = method(__callee__)
    XodbFrameNames.capture("FrameParent##{__callee__} (alias of #{method.original_name}) (define_method)")
  end
  alias dynamic_call aliased_dynamic
  define_method(:dynamic_block) do
    proc { XodbFrameNames.capture('block in FrameParent#dynamic_block (define_method)') }.call
  end
  def closure
    proc { XodbFrameNames.capture('block in FrameParent#closure') }.call
  end
  def recursive(depth)
    if depth.zero?
      XodbFrameNames.capture('FrameParent#recursive')
    else
      recursive(depth - 1)
    end
  end
  def special_variables
    /a/ =~ 'a'
    XodbFrameNames.capture('FrameParent#special_variables')
  end
  def escaped
    binding
    XodbFrameNames.capture('FrameParent#escaped')
  end
end
class FrameChild < FrameParent; end
FrameParent.name # Prove a stored name; never ask the external reader to name an anonymous class.
FrameChild.name
FrameParent.new.instance_call
FrameChild.new.instance_call
FrameChild.new.renamed
FrameChild.new.mixed
FrameParent.class_call
FrameChild.class_call
FrameParent.new.closure
FrameParent.new.dynamic
FrameParent.new.dynamic_call
FrameParent.new.dynamic_block
XodbFrameNames.capture('<main>')
FrameParent.new.recursive(3)
FrameParent.new.special_variables
FrameParent.new.escaped
XodbFrameNames.capture('XodbFrameNames.capture') # A native boundary gets its actual method name.
Class.new do
  def unnamed
    XodbFrameNames.capture_unproved('RubyFrameOwnerUnnamed')
  end
end.new.unnamed
object = Object.new
def object.individual
  XodbFrameNames.capture_unproved('RubyFrameSingletonOwnerUnproved')
end
object.individual
XodbFrameNames.report
