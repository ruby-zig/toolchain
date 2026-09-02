# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact

loaded = $LOADED_FEATURES.map { |path| File.realpath(path) rescue path }
abort "exact NKF artifact was not loaded" unless loaded.include?(artifact)
abort "NKF module is missing" unless defined?(NKF)
abort "NKF.nkf is missing" unless NKF.respond_to?(:nkf)
abort "NKF.guess is missing" unless NKF.respond_to?(:guess)

expected_constants = %i[ASCII BINARY EUC JIS SJIS UTF8 UTF16 UTF32]
missing_constants = expected_constants.reject { |name| NKF.const_defined?(name, false) }
abort "NKF constants are missing: #{missing_constants.join(', ')}" unless missing_constants.empty?

utf8 = "Ruby Zig \u65e5\u672c\u8a9e"
expected_euc = utf8.encode(Encoding::EUC_JP)
actual_euc = NKF.nkf("-e", utf8)
abort "NKF UTF-8 to EUC-JP conversion failed" unless actual_euc == expected_euc
abort "NKF EUC-JP output encoding is wrong" unless actual_euc.encoding == Encoding::EUC_JP

round_trip = NKF.nkf("-w", actual_euc)
abort "NKF EUC-JP to UTF-8 conversion failed" unless round_trip == utf8
abort "NKF UTF-8 output encoding is wrong" unless round_trip.encoding == Encoding::UTF_8
abort "NKF EUC-JP detection failed" unless NKF.guess(actual_euc) == NKF::EUC

jis = NKF.nkf("-j", actual_euc)
abort "NKF JIS detection failed" unless NKF.guess(jis) == NKF::JIS

puts "NKF exact artifact runtime passed"
