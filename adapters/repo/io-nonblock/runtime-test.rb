# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact io-nonblock artifact was not loaded" unless loaded.include?(artifact)

reader, writer = IO.pipe
begin
  writer.nonblock = false
  abort "writer unexpectedly started nonblocking" if writer.nonblock?
  result = writer.nonblock do |io|
    abort "nonblock block did not enable O_NONBLOCK" unless io.nonblock?
    io.write_nonblock("z")
    :completed
  end
  abort "nonblock block returned the wrong value" unless result == :completed
  abort "nonblock block did not restore flags" if writer.nonblock?
  abort "pipe transfer failed" unless reader.read(1) == "z"
ensure
  reader.close
  writer.close
end

puts "io-nonblock exact artifact runtime passed"
