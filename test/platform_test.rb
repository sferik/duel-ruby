# frozen_string_literal: true

require_relative "test_helper"

# What this process runs on.
class PlatformTest < DuelTest
  def test_windows
    assert_match Duel::Platform::WINDOWS_OS, "mingw32"
    assert_match Duel::Platform::WINDOWS_OS, "mswin64_140"
    refute_match Duel::Platform::WINDOWS_OS, "darwin24"
    assert_equal windows?, Duel::Platform::WINDOWS, "by the host's system (JRuby's RUBY_PLATFORM is \"java\")"
  end

  def test_the_ruby
    assert_equal [RUBY_ENGINE == "ruby", RUBY_ENGINE == "jruby"], [Duel::Platform::CRUBY, Duel::Platform::JRUBY]
    assert_equal RUBY_ENGINE == "jruby" && windows?, Duel::Platform::JRUBY_ON_WINDOWS
  end
end
