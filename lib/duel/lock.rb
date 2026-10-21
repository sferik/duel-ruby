# frozen_string_literal: true

require "fileutils"
require_relative "../duel"

module Duel
  # One run at a time in a project: two would share its tmp/duel and its
  # baseline's checkout, each checking out and building over the other's.
  # A run holds an flock on tmp/duel/lock, which ends with its process
  # however that ends, so a run that crashed leaves nothing to clear. The
  # file says whose it is, for a run that finds it taken.
  # @api private
  module Lock
    # An exclusive lock, or none if another holds it.
    EXCLUSIVE = File::LOCK_EX | File::LOCK_NB

    # Runs the block holding +dir+'s lock. Fails, naming the run that
    # holds it, if another does.
    def self.hold(dir)
      FileUtils.mkdir_p(dir)
      # (Read from the start, and written at the end: there's no more.)
      file = File.new(File.join(dir, "lock"), "a+")
      begin
        unless file.flock(EXCLUSIVE)
          # (Empty for a moment, while its run writes its pid.)
          pid = file.read
          raise Error, "another duel run#{" (pid #{pid})" unless pid.empty?} is using #{dir}: wait for it to end, or stop it"
        end
        file.truncate(0)
        file.write(Process.pid)
        file.flush
        yield
      ensure
        file.close
      end
    end
  end
end
