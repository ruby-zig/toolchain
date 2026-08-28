# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
source_root = File.realpath(ARGV.fetch(1))
source_lib = File.join(source_root, "lib")

abort "Syck Ruby sources are missing" unless File.file?(File.join(source_lib, "syck.rb"))

$LOAD_PATH.unshift(File.dirname(artifact), source_lib)
require artifact
require File.join(source_lib, "syck")

loaded_shared_objects = $LOADED_FEATURES.filter_map do |entry|
  realpath = File.realpath(entry)
  realpath if File.basename(realpath) == "syck.so"
rescue Errno::ENOENT
  nil
end.uniq
abort "exact Syck artifact was not loaded" unless loaded_shared_objects == [artifact]
abort "Psych was loaded into the isolated Syck process" if defined?(Psych)
abort "Syck did not replace the YAML constant" unless YAML.equal?(Syck)

document = <<~YAML
  ---
  language: ruby
  compiler: zig cc
  targets:
    - native
    - cross
  enabled: true
  count: 2
YAML
expected = {
  "language" => "ruby",
  "compiler" => "zig cc",
  "targets" => %w[native cross],
  "enabled" => true,
  "count" => 2
}

parsed = Syck.load(document)
abort "Syck YAML parse failed" unless parsed == expected

node = Syck.parse(document)
abort "Syck representation parse failed" unless node.transform == expected

dumped = Syck.dump(expected)
abort "Syck dump omitted the YAML document marker" unless dumped.start_with?("---")
abort "Syck YAML dump round trip failed" unless Syck.load(dumped) == expected

puts "syck exact artifact parse and dump runtime passed"
