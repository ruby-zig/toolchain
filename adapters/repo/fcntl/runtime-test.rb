# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact fcntl artifact was not loaded" unless loaded.include?(artifact)
abort "unexpected fcntl version" unless Fcntl::VERSION == "1.3.0"

reader, writer = IO.pipe
begin
  original = reader.fcntl(Fcntl::F_GETFL, 0)
  abort "F_GETFL did not return flags" unless original.is_a?(Integer)
  reader.fcntl(Fcntl::F_SETFL, original | Fcntl::O_NONBLOCK)
  changed = reader.fcntl(Fcntl::F_GETFL, 0)
  abort "O_NONBLOCK was not set" if (changed & Fcntl::O_NONBLOCK).zero?
  reader.fcntl(Fcntl::F_SETFL, original)
  restored = reader.fcntl(Fcntl::F_GETFL, 0)
  abort "file status flags were not restored" unless restored == original
ensure
  reader.close
  writer.close
end

puts "fcntl exact artifact runtime passed"
