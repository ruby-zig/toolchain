# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact io-wait artifact was not loaded" unless loaded.include?(artifact)
abort "IO wait methods are unavailable" unless IO.method_defined?(:wait_readable)

reader, writer = IO.pipe
begin
  abort "empty pipe reported readable" unless reader.wait_readable(0).nil?
  writer.write("w")
  abort "readable pipe was not returned" unless reader.wait_readable(1) == reader
  abort "pipe payload was not readable" unless reader.read(1) == "w"
  abort "writer did not report writable" unless writer.wait_writable(0) == writer
ensure
  reader.close
  writer.close
end

puts "io-wait exact compatibility artifact runtime passed"
