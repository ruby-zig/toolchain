# frozen_string_literal: true

abort "usage: runtime-test.rb ARTIFACT" unless ARGV.length == 1
abort "Etc was already defined before the exact artifact load" if
  Object.const_defined?(:Etc, false)

artifact = File.realpath(ARGV.fetch(0))
$LOAD_PATH.clear
require artifact

loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue SystemCallError
  nil
end
etc_features = loaded.select { |entry| File.basename(entry) == "etc.so" }
abort "exact etc artifact was not loaded" unless etc_features == [artifact]
abort "unexpected etc version: #{Etc::VERSION}" unless Etc::VERSION == "1.4.6"

passwd = Etc.getpwuid(Process.uid)
abort "getpwuid returned the wrong type" unless passwd.is_a?(Etc::Passwd)
abort "getpwuid returned the wrong uid" unless passwd.uid == Process.uid
abort "getpwuid returned an empty account name" if passwd.name.empty?
abort "getpwnam did not round trip the uid" unless
  Etc.getpwnam(passwd.name).uid == Process.uid

group = Etc.getgrgid(Process.gid)
abort "getgrgid returned the wrong type" unless group.is_a?(Etc::Group)
abort "getgrgid returned the wrong gid" unless group.gid == Process.gid
abort "getgrnam did not round trip the gid" unless
  Etc.getgrnam(group.name).gid == Process.gid

uname = Etc.uname
abort "uname did not return a Hash" unless uname.is_a?(Hash)
%i[sysname nodename release version machine].each do |key|
  value = uname.fetch(key)
  abort "uname returned an empty #{key}" unless value.is_a?(String) && !value.empty?
end

processors = Etc.nprocessors
abort "nprocessors did not return a positive Integer" unless
  processors.is_a?(Integer) && processors.positive?
abort "systmpdir returned an empty path" if Etc.systmpdir.to_s.empty?
abort "sysconfdir returned an empty path" if Etc.sysconfdir.to_s.empty?

if Etc.const_defined?(:SC_CLK_TCK, false)
  clock_ticks = Etc.sysconf(Etc::SC_CLK_TCK)
  abort "sysconf(SC_CLK_TCK) was not positive" unless
    clock_ticks.is_a?(Integer) && clock_ticks.positive?
end

puts "etc exact artifact runtime passed"
