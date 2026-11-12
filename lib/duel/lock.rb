# frozen_string_literal: true

require "fileutils"
require_relative "../duel"
require_relative "native"

module Duel
  # One run at a time in a project: two would share its tmp/duel and its
  # baseline's checkout, each checking out and building over the other's.
  # A run holds an flock on tmp/duel/lock, which ends with its process
  # however that ends, so a run that crashed leaves nothing to clear. The
  # file says whose it is, for a run that finds it taken. A run that ends
  # removes it, and the directories that leaves empty: tmp/duel, and tmp
  # if Duel made it. Windows locks the whole file, and removes none
  # that's open: there, another run's pid can't be read while it holds
  # the lock, and a run removes its lock once it has closed it (unless
  # another has opened it meanwhile, which keeps it).
  # @api private
  module Lock
    # An exclusive lock, or none if another holds it.
    EXCLUSIVE = File::LOCK_EX | File::LOCK_NB

    # Runs the block holding +dir+'s lock. Fails, naming the run that
    # holds it, if another does.
    def self.hold(dir, windows: Native::WINDOWS)
      made = missing(dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "lock")
      file = acquire(path, dir)
      begin
        file.truncate(0)
        file.write(Process.pid)
        file.flush
        yield
      ensure
        # (Removed while it's held, so a run that opens it after makes a new
        # one. `duel --clean` may have removed it already.)
        FileUtils.rm_f(path)
        file.close
        FileUtils.rm_f(path) if windows
        tidy(dir, made)
      end
    end

    # The lock file at +path+, locked: the one there now (a run that
    # ended may have removed the one this opened, after this opened it).
    def self.acquire(path, dir)
      loop do
        # (Read from the start, and written at the end: there's no more.)
        file = File.new(path, "a+")
        unless file.flock(EXCLUSIVE)
          # (Empty for a moment, while its run writes its pid.)
          pid = whose(file)
          file.close
          raise Error, "another duel run#{" (pid #{pid})" unless pid.empty?} is using #{dir}: wait for it to end, or stop it"
        end
        return file if File.exist?(path) && File.identical?(path, file)

        file.close
      end
    end

    # The pid another run wrote in its lock, +file+, or "": none yet, or
    # on Windows, which keeps a locked file from being read.
    def self.whose(file)
      file.read
    rescue Errno::EACCES
      ""
    end

    # The directories, +dir+ and those it's in, that aren't there yet,
    # deepest first.
    def self.missing(dir)
      made = [] #: Array[String]
      path = dir
      until File.exist?(path)
        made << path
        path = File.dirname(path)
      end
      made
    end

    # Removes the empty directories in +dir+ (cache/, say: not what's in
    # them, nor in a baseline's checkout there), then +dir+, then those of
    # +made+ (Duel made them), where they're empty. (One that isn't empty
    # holds those it's in.)
    def self.tidy(dir, made)
      [*Dir.glob(File.join(dir, "*/")), dir, *made].each do |path|
        Dir.rmdir(path)
      rescue SystemCallError # (not empty, or gone already)
        nil
      end
    end
  end
end
