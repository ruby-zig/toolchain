# frozen_string_literal: true

source_root, artifact_root = ARGV
abort "usage: runtime-test.rb SOURCE_ROOT ARTIFACT_ROOT" unless ARGV.length == 2
abort "expected Ruby 3.2.3, got #{RUBY_VERSION}" unless RUBY_VERSION == "3.2.3"

preloaded = $LOADED_FEATURES.grep(%r{(?:^|/)digest(?:\.rb|\.so|/)})
unless preloaded.empty?
  abort "Digest was preloaded before the certified load path: #{preloaded.join(', ')}"
end

$LOAD_PATH.unshift(
  File.join(source_root, "lib"),
  File.join(source_root, "ext", "digest", "lib"),
  artifact_root
)

require "digest"
%w[md5 rmd160 sha1 sha2 bubblebabble crc32 blake3].each do |feature|
  require "digest/#{feature}"
end

relative_artifacts = %w[
  digest.so
  digest/md5.so
  digest/rmd160.so
  digest/sha1.so
  digest/sha2.so
  digest/bubblebabble.so
  digest/crc32.so
  digest/blake3.so
]
expected_artifacts = relative_artifacts.map do |relative|
  File.realpath(File.join(artifact_root, relative))
end
loaded_features = $LOADED_FEATURES.filter_map do |feature|
  File.realpath(feature) if File.file?(feature)
rescue Errno::ENOENT
  nil
end
missing = expected_artifacts - loaded_features
abort "exact Digest artifacts were not loaded: #{missing.join(', ')}" unless missing.empty?

vectors = {
  Digest::MD5 => "900150983cd24fb0d6963f7d28e17f72",
  Digest::RMD160 => "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc",
  Digest::SHA1 => "a9993e364706816aba3e25717850c26c9cd0d89d",
  Digest::SHA256 => "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  Digest::SHA384 => "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" \
                        "8086072ba1e7cc2358baeca134c825a7",
  Digest::SHA512 => "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" \
                        "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
  Digest::CRC32 => "352441c2",
  Digest::BLAKE3 => "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
}

vectors.each do |algorithm, expected|
  actual = algorithm.hexdigest("abc")
  abort "#{algorithm} abc vector failed: #{actual}" unless actual == expected

  incremental = algorithm.new
  incremental << "a" << "b"
  copy = incremental.clone
  incremental << "c"
  copy << "d"
  unless incremental.hexdigest == expected && copy.hexdigest == algorithm.hexdigest("abd")
    abort "#{algorithm} incremental or clone behavior failed"
  end

  incremental.reset
  abort "#{algorithm} reset behavior failed" unless incremental.hexdigest == algorithm.hexdigest("")
end

unless Digest.bubblebabble("message") == "xirek-hasol-fumik-lanax"
  abort "Digest BubbleBabble vector failed"
end
unless Digest::CRC32.digest("abc").bytes == [0x35, 0x24, 0x41, 0xC2]
  abort "Digest CRC32 byte order failed"
end

blake3_vectors = {
  0 => "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
  64 => "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98",
  1024 => "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7",
  1025 => "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444",
  4096 => "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969",
  4097 => "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"
}
blake3_vectors.each do |length, expected|
  input = Array.new(length) { |index| index % 251 }.pack("C*")
  actual = Digest::BLAKE3.hexdigest(input)
  abort "BLAKE3 #{length}-byte vector failed: #{actual}" unless actual == expected
end

input = Array.new(4097) { |index| index % 251 }.pack("C*")
incremental = Digest::BLAKE3.new
offset = 0
[1, 63, 64, 65, 900, 1024, 1080].each do |length|
  incremental << input.byteslice(offset, length)
  offset += length
end
incremental << input.byteslice(offset..)
unless incremental.hexdigest == blake3_vectors.fetch(4097)
  abort "BLAKE3 unaligned multi-chunk streaming failed"
end

puts "Digest runtime verified: 8 exact native artifacts, 8 abc vectors, " \
     "BubbleBabble, CRC32 byte order, BLAKE3 boundaries, clone/reset/streaming"
