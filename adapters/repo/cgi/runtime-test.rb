# frozen_string_literal: true

artifact = File.realpath(ARGV.fetch(0))
require artifact

loaded = $LOADED_FEATURES.map { |path| File.realpath(path) rescue path }
abort "exact CGI artifact was not loaded" unless loaded.include?(artifact)
abort "CGI::EscapeExt is missing" unless defined?(CGI::EscapeExt)

html = %(<&>"')
escaped_html = "&lt;&amp;&gt;&quot;&#39;"
abort "CGI.escapeHTML failed" unless CGI.escapeHTML(html) == escaped_html
abort "CGI.unescapeHTML failed" unless CGI.unescapeHTML(escaped_html) == html

form = "ruby zig/+?"
escaped_form = "ruby+zig%2F%2B%3F"
abort "CGI.escape failed" unless CGI.escape(form) == escaped_form
abort "CGI.unescape failed" unless CGI.unescape(escaped_form) == form

escaped_component = "ruby%20zig%2F%2B%3F"
unless CGI.escapeURIComponent(form) == escaped_component
  abort "CGI.escapeURIComponent failed"
end
unless CGI.unescapeURIComponent(escaped_component) == form
  abort "CGI.unescapeURIComponent failed"
end

puts "CGI exact artifact runtime passed"
