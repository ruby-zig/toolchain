# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
source_lib = File.realpath(ARGV.fetch(1))
generated_parser = File.realpath(ARGV.fetch(2))
profile_root = File.dirname(File.dirname(artifact))

$LOAD_PATH.unshift(source_lib)
$LOAD_PATH.unshift(profile_root)
load generated_parser

loaded = $LOADED_FEATURES.map { |path| File.realpath(path) rescue path }
abort "exact Racc artifact was not loaded" unless loaded.include?(artifact)

source_parser = File.realpath(File.join(source_lib, "racc/parser.rb"))
abort "source Racc parser runtime was not loaded" unless loaded.include?(source_parser)

native_methods = Racc::Parser.private_instance_methods
unless native_methods.include?(:_racc_do_parse_c) &&
       native_methods.include?(:_racc_yyparse_c)
  abort "Racc native parser methods are missing"
end

unless Racc::Parser::Racc_Runtime_Core_Version_C == Racc::VERSION
  abort "Racc native runtime version differs from source lib/racc/info.rb"
end
abort "Racc selected the Ruby fallback runtime" unless
  Racc::Parser.racc_runtime_type == "c"

puts "Racc exact artifact generated-parser runtime passed"
