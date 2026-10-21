# frozen_string_literal: true

# The extension is optional: without it, Duel::GVL leaves its metric out,
# so a gem install never fails over it. Where it can't be built (JRuby and
# TruffleRuby, which have no GVL to wait for; Windows, where Ruby's thread
# event hooks do nothing; 32-bit platforms, where a thread's slot can't
# hold a timestamp; no working C compiler), write a Makefile that does
# nothing.
def write_noop_makefile(reason)
  warn "duel-gvl: not building the extension (#{reason}); there will be no gvl_wait metric"
  File.write("Makefile", "all install clean distclean static:\n\t@:\n.PHONY: all install clean distclean static\n")
end

if RUBY_ENGINE != "ruby"
  write_noop_makefile("#{RUBY_ENGINE} has no GVL")
elsif Gem.win_platform?
  write_noop_makefile("Ruby's thread event hooks do nothing on Windows")
elsif [0].pack("J").bytesize < 8
  write_noop_makefile("a 32-bit platform")
else
  require "mkmf"

  if try_compile("int main(void) { return 0; }") && have_func("rb_internal_thread_specific_get", "ruby/thread.h")
    $CFLAGS << " -O2 -std=c99 -Wall -Wextra -Wno-unused-parameter -Wno-declaration-after-statement" # rubocop:disable Style/GlobalVars -- mkmf API
    create_makefile("duel_gvl/duel_gvl")
  else
    write_noop_makefile("no working C compiler")
  end
end
