# frozen_string_literal: true

require "stringio"

abort "usage: runtime-test.rb ARTIFACT" unless ARGV.length == 1
abort "Zlib was already defined before the exact artifact load" if
  Object.const_defined?(:Zlib, false)

artifact = File.realpath(ARGV.fetch(0))
$LOAD_PATH.clear
require artifact

loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue SystemCallError
  nil
end
zlib_features = loaded.select { |entry| File.basename(entry) == "zlib.so" }
abort "exact zlib artifact was not loaded" unless zlib_features == [artifact]
abort "unexpected Ruby zlib extension version: #{Zlib::VERSION}" unless
  Zlib::VERSION == "3.2.3"
abort "zlib compile-time and runtime versions differ" unless
  Zlib::ZLIB_VERSION == Zlib.zlib_version

payload = ((0..255).to_a.pack("C*") * 16) + ("ruby.zig\0zlib\n" * 128)
compressed = Zlib::Deflate.deflate(payload, Zlib::BEST_COMPRESSION)
abort "deflate did not reduce the test payload" unless
  compressed.bytesize < payload.bytesize
abort "deflate/inflate round trip failed" unless
  Zlib::Inflate.inflate(compressed) == payload

first = payload.byteslice(0, payload.bytesize / 2)
second = payload.byteslice(first.bytesize, payload.bytesize - first.bytesize)
combined_crc = Zlib.crc32_combine(
  Zlib.crc32(first), Zlib.crc32(second), second.bytesize
)
abort "combined CRC32 differs from the complete payload" unless
  combined_crc == Zlib.crc32(payload)

gzip_buffer = StringIO.new("".b)
writer = Zlib::GzipWriter.new(gzip_buffer)
writer.mtime = 0
writer.orig_name = "ruby-zig-zlib.txt"
writer.write(payload)
writer.finish
gzip_buffer.rewind
reader = Zlib::GzipReader.new(gzip_buffer)
gzip_payload = reader.read
abort "gzip round trip failed" unless gzip_payload.b == payload.b
abort "gzip original name was not preserved" unless
  reader.orig_name == "ruby-zig-zlib.txt"
reader.finish

begin
  Zlib::Inflate.inflate("not a zlib stream")
  abort "invalid compressed input was accepted"
rescue Zlib::DataError
end

puts "zlib exact artifact runtime passed; zlib=#{Zlib.zlib_version}"
