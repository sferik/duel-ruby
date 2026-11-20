# frozen_string_literal: true

require "fiddle"

# On macOS, a PostgreSQL server keeps its locks in System V semaphore
# sets, which it removes as it stops, but one that's killed (by the
# watchdog, with its group, once a test process ends however it ends:
# mutant's, every one) leaves them, and macOS keeps them until it
# restarts: a few thousand mutations' worth, and initdb fails, "could
# not create semaphores: No space left on device". So before each test,
# the sets that servers no longer running left are removed: those whose
# last semaphore holds PostgreSQL's marker and was last set by a process
# that isn't a postgres now (its pid gone, or another process's). A
# running server's sets, a test's or anyone's, are left alone. (On Linux,
# PostgreSQL's semaphores are POSIX ones in its shared memory, which go
# with it.)
module Semaphores
  # What PostgreSQL puts in each set's last semaphore (PGSemaMagic).
  MARKER = 537

  # semctl's commands, as macOS's sys/sem.h has them.
  GETPID = 4
  GETVAL = 5
  IPC_RMID = 0

  # Removes the sets that servers no longer running left behind: on
  # macOS, and elsewhere nothing.
  def self.clear
    return unless RUBY_PLATFORM.include?("darwin")

    sets.each do |id, count|
      last = count - 1
      next unless semctl(id, last, GETVAL) == MARKER
      next if postgres?(semctl(id, last, GETPID))

      semctl(id, 0, IPC_RMID)
    end
  end

  # Each set's id and how many semaphores it has, as ipcs lists them.
  def self.sets
    IO.popen(%w[ipcs -s -a], &:read).lines.filter_map do |line|
      fields = line.split
      [Integer(fields[1]), Integer(fields[-3])] if fields[0] == "s"
    end
  end

  # Whether +pid+ is a running postgres's.
  def self.postgres?(pid)
    pid.positive? && IO.popen(["ps", "-o", "comm=", "-p", pid.to_s], err: File::NULL, &:read).include?("postgres")
  end

  def self.semctl(id, number, command) = (@semctl ||= Fiddle::Function.new(Fiddle.dlopen(nil)["semctl"],
    [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)).call(id, number, command)
end
