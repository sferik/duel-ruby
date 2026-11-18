# frozen_string_literal: true

require_relative "../duel"
require_relative "control"
require_relative "message"
require_relative "process_sample"
require_relative "rubies"
require_relative "spawn"

module Duel
  # A worker process (Duel::Worker) running one version of the code.
  # @api private
  class WorkerProcess
    LIB = File.expand_path("..", __dir__)
    # Seconds between looks at a worker that's loading.
    POLL = 0.01
    # Seconds a worker may take to end, once its connection is closed,
    # before it's killed.
    STOP_WAIT = 10
    # The gems that are Duel's: Duel, and its plugins (duel-redis, say).
    DUEL_GEM = /\Aduel(-|\z)/

    attr_reader :label, :benchmarks, :metrics, :memory, :profiler, :jit

    # The Ruby it runs on (RUBY_DESCRIPTION), the native extensions it
    # loaded (see Worker.extensions), those it loaded twice (see
    # Worker.twice), and the directories gems are installed in (see
    # Worker.gem_dirs).
    attr_reader :description, :extensions, :twice, :gem_dirs

    # Where a worker on +ruby+ loads Duel from, ahead of anything else
    # (a version's own bundle, which may not have Duel, or an older one):
    # the runner's Duel, and every Duel gem (+specs+) the runner loaded
    # (its plugins), so both versions are measured with the same. On the
    # runner's own Ruby, Duel's dependencies (Fiddle) too: on another,
    # their builds wouldn't load.
    def self.load_path(ruby, specs: Gem.loaded_specs)
      duel = specs.select { |name, _| name.match?(DUEL_GEM) }.values
      none = [] #: Array[Gem::BasicSpecification]
      dependencies = Rubies.runner?(ruby) ? specs["duel"]&.runtime_dependencies.to_a.filter_map { |d| specs[d.name] } : none
      [LIB, *(duel + dependencies).flat_map(&:full_require_paths)].uniq
    end

    # +timeout+: the seconds it may take to load, or to answer a request,
    # before it's taken for hung (and killed). It runs on +ruby+ (whose
    # engine is +engine+), with +env+, and on JRuby, the JVM's options for
    # a worker (see Rubies.worker_environment), not given to the processes
    # it starts for a process benchmark (see #run): their boot is measured
    # as it is. It connects over a Unix socket, unless +unix+ is false
    # (see Control).
    def initialize(label, root, candidate_root, dir, config_path:, env:, timeout:, ruby:, engine:, unix: Control::UNIX)
      @label = label
      @timeout = timeout
      @root = root
      @dir = dir
      @env = env
      @ruby = ruby
      @engine = engine
      server, control = Control.listen(File.join(dir, "#{label}.sock"), unix: unix)
      # (A nil config_path is left out. And the worker gets no other
      # worker's connection: TruffleRuby's sockets aren't close-on-exec,
      # and one left open in another worker would keep it from ending.)
      worker_env = Rubies.worker_environment(env, engine)
      @child = Spawn::STARTER.started(worker_env, [*Rubies.launch(ruby, engine, worker_env),
        *WorkerProcess.load_path(ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/worker", "-e", "Duel::Worker.main(*ARGV)", root,
        candidate_root, control, *[config_path].compact], close_others: true)
      @socket = accept(server, control)
      hello = read
      @benchmarks = hello.fetch("benchmarks").to_h { |b| [b.fetch("name"), b] }
      @metrics = hello.fetch("metrics")
      @memory = hello.fetch("memory")
      @profiler = hello.fetch("profiler")
      @jit = hello.fetch("jit")
      @description = hello.fetch("ruby")
      @extensions = hello.fetch("extensions")
      @twice = hello.fetch("twice")
      @gem_dirs = hello.fetch("gem_dirs")
    end

    # Sends a request, and returns the reply, or raises Failed with its
    # error.
    def request(op, name, **args)
      # (By name: +args+ come by keyword, as Symbols.)
      Message.write(@socket, {"op" => op, "name" => name, **args.transform_keys(&:to_s)})
      reply = read
      raise Failed, "#{@label}: #{reply.fetch("error")}\n  #{reply.fetch("backtrace").join("\n  ")}" if reply.key?("error")

      reply
    end

    def sample(name, n, runs: 1, count: false) = request("sample", name, n: n, runs: runs, count: count)

    # A run of a process benchmark (see DSL#duel_process): +process+, a
    # fresh process, started as this worker was (on its Ruby, in its
    # version's tree, with its environment), and measured (see
    # ProcessSample#run).
    def run(process)
      # (Code, without a command.)
      code = process.fetch("ruby") #: String
      command = process.fetch("command") || [*(@launch ||= Rubies.launch(@ruby, @engine, @env)), "-I", File.join(@root, "lib"), "-e", code]
      runs = @runs ||= ProcessSample.new(@label, env: @env, chdir: @root, log: File.join(@dir, "#{@label}.log"), timeout: @timeout)
      runs.run(command)
    end

    # Closing the connection ends the worker. One still running +wait+
    # seconds later is killed.
    def stop(wait: STOP_WAIT)
      @runs&.stop
      @socket.close
      @child.stop(wait)
    end

    private

    # The worker's connection, once it has loaded (or Failed if it died,
    # or took too long, first), to +server+, at +address+ (see Control).
    def accept(server, address)
      deadline = monotonic + @timeout
      until server.wait_readable(POLL)
        raise Failed, "#{@label} worker exited while loading" unless @child.alive?
        hung("load") if monotonic > deadline
      end
      server.accept
    ensure
      server.close
      Control.remove(address)
    end

    def read
      hung("answer") unless @socket.wait_readable(@timeout)
      Message.read(@socket) or raise Failed, "#{@label} worker exited"
    end

    # Kills a worker that didn't +what+ within the timeout, and fails.
    def hung(what)
      @child.kill
      raise Failed, "#{@label} worker didn't #{what} within #{@timeout}s (killed: a benchmark that hangs?)"
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
