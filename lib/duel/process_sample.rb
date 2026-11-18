# frozen_string_literal: true

require "json"
require_relative "native"
require_relative "platform"
require_relative "metric"
require_relative "spawn"

module Duel
  # The runs of a process benchmark (see DSL#duel_process) for one worker:
  # each a fresh process, started and waited for by a Ruby process of its
  # own (the runner's Ruby, out of any bundle) that has nothing else to
  # wait for, so what its child took is the process's alone, even while
  # the runner waits for others. That Ruby process starts with the first
  # run and is kept for the worker's life, so that its start is paid once,
  # not for every run. For each run, it reports a line of JSON: the CPU
  # time the process took (user and system, its children's too), its peak
  # memory where it can tell, and how it ended.
  # @api private
  class ProcessSample
    # Seconds the Ruby process of its own may take to end once its input
    # is closed, before it's killed, with what it started (see #stop).
    STOP_WAIT = 10

    # Runs for the worker +label+, in +chdir+ with +env+ (over the
    # runner's own), each process's output to +log+. A run that takes
    # more than +timeout+ seconds fails. (+starter+: how its Ruby process
    # starts, Spawn::Directly or Spawn::ThroughOpen3.)
    def initialize(label, env:, chdir:, log:, timeout:, starter: Spawn::STARTER)
      @label = label
      @starter = starter
      @env = env
      @chdir = chdir
      @log = log
      @timeout = timeout
    end

    # The fastest of +samples+ (one version's runs, as #run returns them):
    # the least CPU time, and the least peak memory where every one has
    # it.
    def self.fastest(samples)
      peaks = samples.map { |sample| sample.fetch("peak") }
      cpu = samples.map { |sample| sample.fetch("timed").fetch("cpu") }.min #: Integer
      sampled(cpu, (peaks.min unless peaks.include?(nil)))
    end

    # A process benchmark's sample, as a worker's is: its CPU time
    # (nanoseconds) and its peak memory (bytes, or nil), counting nothing
    # and leaving no heap.
    def self.sampled(cpu, peak) = {"timed" => {"cpu" => cpu}, "counted" => {}, "heap" => 0, "peak" => peak}

    # Runs +command+ (as Process.spawn takes it) once, and returns its
    # sample ({"timed" => {"cpu" => nanoseconds}, "peak" => bytes or nil},
    # as a worker's has it). One that fails, or takes more than the
    # timeout (it's killed, with what it started, and the Ruby process
    # that ran it), fails.
    def run(command)
      start unless @child
      @requests.puts JSON.generate(command)
      # (Read on a thread of its own, waited for until the timeout: on JRuby
      # on Windows, IO.select takes Open3's pipe for ready before it is,
      # https://github.com/jruby/jruby/issues/5765, and wait_readable
      # never does, on JRuby 10.0.)
      replies = @replies #: IO
      reading = Thread.new { replies.gets }
      reading.report_on_exception = false
      unless reading.join(@timeout)
        kill
        raise Failed, "#{@label}: #{command.join(" ")} didn't end within #{@timeout}s (killed)"
      end
      reply = reading.value
      unless reply
        stop
        raise Failed, "#{@label}: the process running #{command.join(" ")} exited"
      end

      ended = JSON.parse(reply)
      failed = ended.fetch("failed")
      raise Failed, Spawn.with_tail("#{@label}: #{command.join(" ")} #{failed}", @log) if failed

      ProcessSample.sampled(ended.fetch("cpu"), ended.fetch("peak"))
    end

    # Ends the Ruby process of its own, if it started: closing its input
    # does. One still running +wait+ seconds later is killed, with what it
    # started: on Windows, a process started meanwhile (another worker)
    # can have inherited the input's other end, which keeps it open.
    def stop(wait: STOP_WAIT)
      child = @child
      return unless child

      @requests.close
      child.stop(wait)
      @replies.close
      @child = nil
    end

    # Runs a process for each line of +input+ (a command, in JSON) after
    # its first, with what that says ({"env", "chdir", "log"}), and
    # reports each (see .once) as a line of +output+, at once, until the
    # input ends: run in the Ruby process of its own.
    def self.main(input: $stdin, output: $stdout)
      first = input.gets or return
      spec = JSON.parse(first)
      output.sync = true
      while (line = input.gets)
        output.puts JSON.generate(once(JSON.parse(line), spec.fetch("env"), spec.fetch("chdir"), spec.fetch("log")))
      end
    end

    # Runs +command+ once, in +chdir+ with +env+ alone, its output to
    # +log+, and returns what it took: its CPU time, its peak memory (or
    # nil), and how it failed (or nil). On Windows, whose children's CPU
    # time Process.times doesn't have, what its own handle on the process
    # says (see Native::Windows::Spawned), its cycles in nanoseconds (see
    # CycleClock). A command that can't start (there's no such program,
    # say, or on Windows, a shell command with no COMSPEC in +env+ to
    # find cmd.exe by) failed, and took nothing.
    def self.once(command, env, chdir, log, windows: Platform::WINDOWS, starter: Spawn::STARTER)
      before = cpu
      begin
        child = starter.logged(env, command, log: log, mode: "w", chdir: chdir, unsetenv_others: true, close_others: true)
      rescue SystemCallError => e
        return {"cpu" => 0, "peak" => nil, "failed" => "couldn't start: #{e}"}
      end
      spawned = Native::Windows::Spawned.open(child.pid) if windows
      begin
        code, signal, peak = child.wait
        if spawned
          taken = CycleClock.ns(spawned.cycles)
          peak = spawned.peak
        else
          taken = cpu - before
        end
        {"cpu" => taken, "peak" => peak, "failed" => (Spawn.why(code, signal) unless code == 0)} #: ended
      ensure
        spawned&.close
      end
    end

    # The CPU time of the children waited for so far, in nanoseconds.
    def self.cpu
      times = Process.times
      ((times.cutime + times.cstime) * 1_000_000_000).round
    end

    private

    # Starts the Ruby process of its own, connected by a pipe each way
    # (not a socket: JRuby's spawn can't give one), and gives it the
    # environment, the directory and the log, as the first line of its
    # input. (Not an argument: JRuby's spawn on Windows splits one at its
    # spaces, and the environment can be longer than Windows lets a
    # command be.)
    def start
      # (Out of the runner's bundle: it needs nothing of it.)
      @child, @requests, @replies = @starter.piped({"RUBYOPT" => nil, "RUBYLIB" => nil},
        [RbConfig.ruby, *WorkerProcess.load_path(RbConfig.ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/process_sample", "-e",
          "Duel::ProcessSample.main"], group: true, close_others: true)
      @requests.puts JSON.generate({"env" => {**ENV, **@env}, "chdir" => @chdir, "log" => @log})
    end

    # Kills the Ruby process of its own, and what it started.
    def kill
      child = @child #: Spawn::Child
      child.kill
      @requests.close
      @replies.close
      @child = nil
    end
  end
end
