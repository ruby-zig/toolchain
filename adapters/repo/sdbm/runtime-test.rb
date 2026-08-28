# frozen_string_literal: true

require "tmpdir"

artifact = File.realpath(ARGV.fetch(0))
require artifact
loaded = $LOADED_FEATURES.filter_map do |entry|
  File.realpath(entry)
rescue Errno::ENOENT
  nil
end
abort "exact sdbm artifact was not loaded" unless loaded.include?(artifact)
abort "SDBM::PAIRMAX is unexpectedly small" unless SDBM::PAIRMAX > 1_000

Dir.mktmpdir("ruby-zig-sdbm-") do |directory|
  database_path = File.join(directory, "roundtrip")
  lock_path = "#{database_path}.lock"

  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    abort "could not acquire the database advisory lock" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

    reader, writer = IO.pipe
    child = fork do
      reader.close
      lock.close
      acquired = File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |competitor|
        competitor.flock(File::LOCK_EX | File::LOCK_NB)
      rescue Errno::EACCES, Errno::EAGAIN, Errno::EWOULDBLOCK
        false
      end
      writer.write(acquired ? "acquired" : "blocked")
      writer.close
      exit!(acquired ? 1 : 0)
    end
    writer.close
    child_result = reader.read
    reader.close
    child_status = Process.wait2(child).last
    abort "competing process bypassed the advisory lock" unless child_result == "blocked" && child_status.success?

    SDBM.open(database_path, 0o600) do |database|
      database["language"] = "ruby"
      database["compiler"] = "zig cc"
      database.update("target" => "x86_64-linux-gnu.2.17", "empty" => "")
      expected = {
        "language" => "ruby",
        "compiler" => "zig cc",
        "target" => "x86_64-linux-gnu.2.17",
        "empty" => ""
      }
      abort "SDBM in-process round trip failed" unless database.to_hash == expected
    end
  end

  SDBM.open(database_path, nil) do |database|
    abort "SDBM persistence round trip failed" unless database["compiler"] == "zig cc"
    abort "SDBM key set changed" unless database.keys.sort == %w[compiler empty language target]
  end

  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    abort "advisory lock was not released" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  end
end

puts "sdbm exact artifact database and advisory-lock runtime passed"
