# frozen_string_literal: true

abort "usage: runtime-test.rb ARTIFACT" unless ARGV.length == 1
abort "DEBUGGER__ was already defined before the exact artifact load" if
  Object.const_defined?(:DEBUGGER__, false)

module DEBUGGER__
  VERSION = "1.11.1"
  FrameInfo = Struct.new(
    :location,
    :self,
    :binding,
    :iseq,
    :class,
    :frame_depth,
    :has_return_value,
    :return_value,
    :has_raised_exception,
    :raised_exception,
    :show_line,
    :_local_variables,
    :_callee,
    :dupped_binding
  )
end

artifact = File.realpath(ARGV.fetch(0))
$LOAD_PATH.clear
require artifact

loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue SystemCallError
  nil
end
debug_features = loaded.select { |entry| File.basename(entry) == "debug.so" }
abort "exact debug artifact was not loaded" unless debug_features == [artifact]
abort "unexpected debug shared-object version: #{DEBUGGER__::SO_VERSION}" unless
  DEBUGGER__::SO_VERSION == DEBUGGER__::VERSION

def capture_probe
  DEBUGGER__.capture_frames(nil)
end

frames = capture_probe
abort "capture_frames did not return a nonempty Array" unless
  frames.is_a?(Array) && !frames.empty?
abort "capture_frames returned a non-FrameInfo entry" unless
  frames.all? { |frame| frame.is_a?(DEBUGGER__::FrameInfo) }
abort "capture_frames returned an invalid frame depth" unless
  frames.all? { |frame| frame.frame_depth.is_a?(Integer) && frame.frame_depth.positive? }

depth = DEBUGGER__.frame_depth
abort "frame_depth did not return a positive Integer" unless
  depth.is_a?(Integer) && depth.positive?

probe = lambda do |required, optional = nil, *rest, keyword: nil, **keywords, &block|
  [required, optional, rest, keyword, keywords, block]
end
iseq = RubyVM::InstructionSequence.of(probe)
abort "RubyVM did not return an InstructionSequence" unless
  iseq.is_a?(RubyVM::InstructionSequence)
abort "InstructionSequence#type returned an unexpected value" unless
  iseq.type.is_a?(Symbol)
parameters = iseq.parameters_symbols
abort "InstructionSequence#parameters_symbols did not return Symbols" unless
  parameters.is_a?(Array) && parameters.all?(Symbol)
abort "InstructionSequence#parameters_symbols omitted named parameters" unless
  %i[required optional rest keyword keywords block].all? { |name| parameters.include?(name) }
first_line = iseq.first_line
last_line = iseq.last_line
abort "InstructionSequence line range was invalid" unless
  first_line.is_a?(Integer) && first_line.positive? &&
    last_line.is_a?(Integer) && last_line >= first_line

count = ObjectSpace.count_iseq
abort "ObjectSpace.count_iseq did not return a positive Integer" unless
  count.is_a?(Integer) && count.positive?
collected = nil
ObjectSpace.each_iseq do |candidate|
  collected = candidate
  break
end
abort "ObjectSpace.each_iseq did not yield an InstructionSequence" unless
  collected.is_a?(RubyVM::InstructionSequence)

puts "debug exact artifact runtime passed"
