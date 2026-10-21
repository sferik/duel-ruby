# frozen_string_literal: true

# Every process the tests start (a Redis server, a comparison's workers,
# and through them their servers) leads a process group of its own,
# which a watchdog kills when the test process ends, however it ends.
# Ensure blocks and at_exit don't run when it's killed (mutant kills a
# test that runs past its timeout with SIGKILL, say), so what it started
# would be left running.
#
# A process the test process reaps (a comparison's worker, say) takes
# what's left of its group with it: an orphan (a server a worker that
# died left behind) is killed then, not when the test process ends. (The
# group's id is its leader's pid, which can't be another's until no
# process is left in it.)
#
# The watchdog is a process of the test process's own (an awk that reads
# a pipe from it, in a process group of its own too, so a signal to the
# test's group doesn't end it first). The test process writes each group
# it starts to the pipe, and each process it reaps (whose pid could
# then be another's): when the pipe closes, as it does when the test
# process ends in any way, the watchdog kills each group still there. A
# process forked from the test process (mutant runs each mutation's
# tests in one) gets a watchdog of its own.
module Watchdog
  SPAWN = Process.method(:spawn)

  # Groups added (a pid) and taken away (-pid), then, at the end of its
  # input, those left killed.
  AWK = "$1 > 0 { groups[$1] = 1 } $1 < 0 { delete groups[-$1] } " \
    'END { for (group in groups) system("kill -KILL -" group " 2>/dev/null") }'

  LOCK = Mutex.new

  # Tells the test process's watchdog (started first, if it has none)
  # of +line+: a group started, or a process reaped.
  def self.tell(line)
    LOCK.synchronize do
      unless @owner == Process.pid
        reader, @writer = IO.pipe
        SPAWN.call("awk", AWK, in: reader, out: File::NULL, err: File::NULL, pgroup: true)
        reader.close
        @writer.sync = true
        @owner = Process.pid
      end
      @writer.puts(line)
    end
  end

  # The process +pid+ reaped: what's left of the group it led killed,
  # and the group forgotten.
  def self.reaped(pid)
    begin
      Process.kill(:KILL, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      # (None left.)
    end
    tell(-pid)
  end

  # Process's spawn, wait, wait2 and detach, telling the watchdog (and
  # killing what's left of a reaped process's group).
  #
  # A server starts in the directory above its socket's (the lane's,
  # removed with it), not the worker's, where it works (--dir): so a
  # mutation that drops --dir is seen, and what it makes the server write
  # (a dump.rdb, which the next server started there would load) isn't
  # left in the project.
  module Hooks
    def spawn(*command, **options)
      # (Options passed as a Hash, as Open3 does: mutant's git, say.)
      options = command.pop.merge(options) if command.size > 1 && command.last.is_a?(Hash)
      socket = command.index("--unixsocket")&.then { |i| command[i + 1] }
      options = {chdir: File.dirname(socket, 2), **options} if socket.is_a?(String)
      super(*command, **options, pgroup: true).tap { |pid| Watchdog.tell(pid) }
    end

    def wait(...) = super.tap { |pid| Watchdog.reaped(pid) if pid }

    def wait2(...) = super.tap { |pid, _| Watchdog.reaped(pid) if pid }

    def detach(pid) = super.tap { |waiter| Thread.new { waiter.join && Watchdog.reaped(pid) } }
  end
end

Process.singleton_class.prepend(Watchdog::Hooks)

# Kernel's spawn too, which a mutation of r.spawn (its receiver dropped)
# would call.
Kernel.define_singleton_method(:spawn) { |*command, **options| Process.spawn(*command, **options) }
Kernel.send(:define_method, :spawn) { |*command, **options| Process.spawn(*command, **options) }
Kernel.send(:private, :spawn)
