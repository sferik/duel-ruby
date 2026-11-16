# frozen_string_literal: true

require "rbconfig"

module Duel
  # What this process runs on, for what differs by it: the host's system
  # (not RUBY_PLATFORM, which is "java" on JRuby) and its CPU, and the
  # Ruby. What differs by one takes it as an option (windows:
  # Platform::WINDOWS, say), for its tests to give it another.
  # @api private
  module Platform
    OS = RbConfig::CONFIG["host_os"]
    CPU = RbConfig::CONFIG["host_cpu"]

    # What host_os is on Windows: mingw's ("mingw32", "mingw-ucrt") or
    # mswin's ("mswin64_140").
    WINDOWS_OS = /mingw|mswin/
    WINDOWS = OS.match?(WINDOWS_OS)

    CRUBY = RUBY_ENGINE == "ruby"
    JRUBY = RUBY_ENGINE == "jruby"

    # JRuby on Windows, whose spawn and Open3 start a process through
    # Java's: spawn redirects nothing, and Process.wait doesn't wait (see
    # Spawn). It has no Unix sockets (see Control), its flock raises a
    # Java exception for a lock another process holds (see Lock), and its
    # jruby.exe starts the JVM in a process of its own (see
    # Rubies#launch).
    JRUBY_ON_WINDOWS = JRUBY && WINDOWS
  end
end
