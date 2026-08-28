# frozen_string_literal: true

abort "usage: runtime-test.rb ARTIFACT LOAD_PATH" unless ARGV.length == 2
abort "Fiddle was already defined before the exact artifact load" if
  Object.const_defined?(:Fiddle, false)

artifact = File.realpath(ARGV.fetch(0))
runtime_load_path = File.realpath(ARGV.fetch(1))
$LOAD_PATH.replace([runtime_load_path])
require "fiddle"

loaded_extensions = $LOADED_FEATURES.filter_map do |entry|
  next unless File.basename(entry) == "fiddle.so"

  File.realpath(entry)
rescue SystemCallError
  nil
end
abort "exact fiddle artifact was not loaded" unless loaded_extensions == [artifact]
abort "unexpected Fiddle version: #{Fiddle::VERSION}" unless
  Fiddle::VERSION == "1.1.9"

strlen = Fiddle::Function.new(
  Fiddle::Handle::DEFAULT["strlen"],
  [Fiddle::TYPE_VOIDP],
  Fiddle::TYPE_SIZE_T
)
text = "ruby.zig"
pointer = Fiddle::Pointer[text]
abort "foreign strlen call returned the wrong length" unless
  strlen.call(pointer) == text.bytesize

callback = Fiddle::Closure::BlockCaller.new(
  Fiddle::TYPE_INT,
  [Fiddle::TYPE_INT, Fiddle::TYPE_INT]
) do |left, right|
  left + right
end
begin
  abort "closure was freed before use" if callback.freed?
  function = Fiddle::Function.new(
    callback,
    [Fiddle::TYPE_INT, Fiddle::TYPE_INT],
    Fiddle::TYPE_INT
  )
  abort "closure callback returned the wrong value" unless
    function.call(19, 23) == 42
ensure
  callback.free
end
abort "closure was not freed" unless callback.freed?

puts "fiddle exact artifact foreign-call and closure runtime passed"
