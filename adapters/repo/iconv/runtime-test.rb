# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact iconv artifact was not loaded" unless loaded.include?(artifact)
abort "Iconv was not defined" unless defined?(Iconv)

latin1 = "caf\xE9".b
utf8 = Iconv.conv("UTF-8", "ISO-8859-1", latin1)
abort "ISO-8859-1 to UTF-8 conversion failed" unless utf8.b == "caf\xC3\xA9".b

round_trip = Iconv.conv("ISO-8859-1", "UTF-8", utf8)
abort "UTF-8 to ISO-8859-1 round trip failed" unless round_trip.b == latin1

streamed = Iconv.open("UTF-8", "ISO-8859-1") do |converter|
  first = converter.iconv("caf".b)
  second = converter.iconv("\xE9".b)
  final = converter.iconv(nil)
  first + second + final
end
abort "streaming conversion failed" unless streamed.b == utf8.b

converter = Iconv.new("UTF-8", "ISO-8859-1")
converter.close
begin
  converter.iconv("x")
  abort "closed converter accepted input"
rescue ArgumentError
end

begin
  Iconv.new("ruby-zig-not-an-encoding", "UTF-8")
  abort "invalid encoding was accepted"
rescue Iconv::InvalidEncoding
end

puts "iconv exact artifact conversion runtime passed"
