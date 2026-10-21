# frozen_string_literal: true

require "json"
require_relative "native"

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
    # The lines of its output a failure shows.
    LOG_LINES = 10

    # Runs for the worker +label+, in +chdir+ with +env+ (over the
    # runner's own), each process's output to +log+. A run that takes
    # more than +timeout+ seconds fails.
    def initialize(label, env:, chdir:, log:, timeout:)
      @label = label
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
      {"timed" => {"cpu" => cpu}, "counted" => {}, "heap" => 0, "peak" => (peaks.min unless peaks.include?(nil))}
    end

    # Runs +command+ (as Process.spawn takes it) once, and returns its
    # sample ({"timed" => {"cpu" => nanoseconds}, "peak" => bytes or nil},
    # as a worker's has it). One that fails, or takes more than the
    # timeout (it's killed, with what it started, and the Ruby process
    # that ran it), fails.
    def run(command)
      start unless @pid
      @requests.puts JSON.generate(command)
      unless @replies.wait_readable(@timeout)
        kill
        raise Failed, "#{@label}: #{command.join(" ")} didn't end within #{@timeout}s (killed)"
      end
      reply = @replies.gets
      unless reply
        stop
        raise Failed, "#{@label}: the process running #{command.join(" ")} exited"
      end

      ended = JSON.parse(reply)
      failed = ended.fetch("failed")
      if failed
        tail = File.readlines(@log).last(LOG_LINES).join
        raise Failed, "#{@label}: #{command.join(" ")} #{failed}#{"\n#{tail}" unless tail.empty?}"
      end
      {"timed" => {"cpu" => ended.fetch("cpu")}, "counted" => {}, "heap" => 0, "peak" => ended.fetch("peak")}
    end

    # Ends the Ruby process of its own, if it started: closing its input
    # does.
    def stop
      pid = @pid
      return unless pid

      @requests.close
      Process.wait(pid)
      @replies.close
      @pid = nil
    end

    # Runs a process for each line of +input+ (a command, in JSON), with
    # what +spec+ says ({"env", "chdir", "log"}), and reports each (see
    # .once) as a line of +output+, at once, until the input ends: run in
    # the Ruby process of its own.
    def self.main(spec, input: $stdin, output: $stdout)
      spec = JSON.parse(spec)
      output.sync = true
      while (line = input.gets)
        output.puts JSON.generate(once(JSON.parse(line), spec.fetch("env"), spec.fetch("chdir"), spec.fetch("log")))
      end
    end

    # Runs +command+ once, in +chdir+ with +env+ alone, its output to
    # +log+, and returns what it took: its CPU time, its peak memory (or
    # nil), and how it failed (or nil).
    def self.once(command, env, chdir, log)
      before = cpu
      code, signal, peak = Native::Child.wait(Process.spawn(env, *command, chdir: chdir, in: File::NULL, out: [log, "w"],
        err: [:child, :out], unsetenv_others: true, close_others: true))
      {"cpu" => cpu - before, "peak" => peak, "failed" => (why(code, signal) unless code == 0)}
    end

    # The CPU time of the children waited for so far, in nanoseconds.
    def self.cpu
      times = Process.times
      ((times.cutime + times.cstime) * 1_000_000_000).round
    end

    # How a process that failed ended: its exit status +code+, or the
    # +signal+ that killed it.
    def self.why(code, signal)
      return "exited with #{code}" if code

      killed = signal #: Integer
      "was killed by SIG#{Signal.signame(killed)}"
    end

    private

    # Starts the Ruby process of its own, given the environment, the
    # directory and the log, and connected by a pipe each way (not a
    # socket: JRuby's spawn can't give one).
    def start
      spec = JSON.generate({"env" => {**ENV, **@env}, "chdir" => @chdir, "log" => @log})
      requests, @requests = IO.pipe
      @replies, replies = IO.pipe
      # (Out of the runner's bundle: it needs nothing of it.)
      @pid = Process.spawn({"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby,
        *WorkerProcess.load_path(RbConfig.ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/process_sample", "-e",
        "Duel::ProcessSample.main(*ARGV)", spec, in: requests, out: replies, pgroup: true, close_others: true)
      requests.close
      replies.close
    end

    # Kills the Ruby process of its own, and what it started.
    def kill
      pid = @pid #: Integer
      Process.kill("KILL", -pid)
      Process.wait(pid)
      @requests.close
      @replies.close
      @pid = nil
    end
  end
end
