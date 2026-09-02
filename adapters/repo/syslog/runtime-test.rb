# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact syslog artifact was not loaded" unless loaded.include?(artifact)
abort "unexpected syslog version: #{Syslog::VERSION}" unless Syslog::VERSION == "0.4.0"
abort "syslog unexpectedly started open" if Syslog.opened?
abort "Syslog.instance did not return the module" unless Syslog.instance.equal?(Syslog)

info_mask = Syslog::LOG_MASK(Syslog::LOG_INFO)
info_and_above = Syslog::LOG_UPTO(Syslog::LOG_INFO)
abort "LOG_MASK returned an invalid mask" unless info_mask.is_a?(Integer) && info_mask.positive?
abort "LOG_UPTO omitted LOG_INFO" if (info_and_above & info_mask).zero?

options = Syslog.const_defined?(:LOG_ODELAY) ? Syslog::LOG_ODELAY : 0
result = Syslog.open("ruby-zig-syslog-smoke", options, Syslog::LOG_USER) do |facility|
  abort "Syslog.open yielded the wrong object" unless facility.equal?(Syslog)
  abort "syslog did not open" unless Syslog.opened?
  abort "syslog ident did not round trip" unless Syslog.ident == "ruby-zig-syslog-smoke"
  abort "syslog options did not round trip" unless Syslog.options == options
  abort "syslog facility did not round trip" unless Syslog.facility == Syslog::LOG_USER
  Syslog.mask = info_and_above
  abort "syslog mask did not round trip" unless Syslog.mask == info_and_above
  :closed_without_emitting
end
abort "Syslog.open did not return the module" unless result.equal?(Syslog)
abort "syslog remained open after the block" if Syslog.opened?

# No log method is called: LOG_ODELAY exercises open/close and setlogmask
# without requiring a syslog socket, daemon, or writable system log.
puts "syslog exact artifact state-only runtime passed"
