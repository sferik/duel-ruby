# frozen_string_literal: true

require "rbconfig"

module Duel
  # What this process runs on, for what differs by it: the host's system
  # (not RUBY_PLATFORM, which is "java" on JRuby) and its CPU, and the
  # Ruby. What differs by one takes it as an option, for its tests to
  # give it another: a yes or no (windows: Platform::WINDOWS, say), but
  # in Native, whose readers tell three systems apart, the system's name
  # (platform: Platform::OS). A plugin asks Duel.windows? instead.
  # @api private
  module Platform
    OS = RbConfig::CONFIG["host_os"]
    CPU = RbConfig::CONFIG["host_cpu"]

    # What host_os is on Windows: mingw's ("mingw32", "mingw-ucrt") or
    # mswin's ("mswin64_140").
    WINDOWS_OS = /mingw|mswin/
    WINDOWS = OS.match?(WINDOWS_OS)

    # What a program's file ends with: on Windows, .exe (see
    # Duel.find_program).
    EXE = RbConfig::CONFIG["EXEEXT"]

    CRUBY = RUBY_ENGINE == "ruby"
    JRUBY = RUBY_ENGINE == "jruby"

    # JRuby on Windows, whose spawn and Open3 start a process through
    # Java's: spawn redirects nothing, and Process.wait doesn't wait (see
    # Spawn). CONTRIBUTING.md's "JRuby on Windows" lists every way it
    # differs, and where Duel deals with each.
    JRUBY_ON_WINDOWS = JRUBY && WINDOWS
  end
end
