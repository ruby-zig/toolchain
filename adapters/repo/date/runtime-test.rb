# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
source_lib = File.realpath(ARGV.fetch(1))
$LOAD_PATH.unshift(File.dirname(artifact), source_lib)
require "date"

loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact date_core artifact was not loaded" unless loaded.include?(artifact)
abort "source date.rb was not loaded" unless loaded.include?(File.join(source_lib, "date.rb"))
abort "unexpected date version: #{Date::VERSION}" unless Date::VERSION == "3.5.1"

checks = {
  iso8601: Date.iso8601("2026-08-27") == Date.new(2026, 8, 27),
  arithmetic: Date.new(2024, 2, 28).next_day == Date.new(2024, 2, 29),
  ordinal: Date.strptime("2026-239", "%Y-%j") == Date.new(2026, 8, 27),
  commercial: Date.commercial(2026, 35, 4) == Date.new(2026, 8, 27),
  parse: Date.parse("August 27, 2026") == Date.new(2026, 8, 27),
  strftime: Date.new(2026, 8, 27).strftime("%F") == "2026-08-27",
  datetime: DateTime.iso8601("2026-08-27T12:34:56-07:00").offset == Rational(-7, 24),
  marshal: Marshal.load(Marshal.dump(Date.new(2026, 8, 27))) == Date.new(2026, 8, 27)
}
failed = checks.reject { |_name, passed| passed }.keys
abort "date runtime checks failed: #{failed.join(', ')}" unless failed.empty?

puts "date runtime checks passed: #{checks.length}"
