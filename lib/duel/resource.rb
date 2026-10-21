# frozen_string_literal: true

require "fileutils"
require "rbconfig"

module Duel
  # What a prepare block (see Config#prepare) gets: a worker's, or a
  # version's, own directory, and help running commands and starting a
  # server there, and stopping it.
  #
  #   c.prepare(:worker) do |w|
  #     socket = w.path("redis.sock")
  #     w.spawn("redis-server", "--port", "0", "--unixsocket", socket, "--save", "")
  #     w.wait_until { File.socket?(socket) }
  #     {"REDIS_URL" => "unix://#{socket}"}
  #   end
  #
  # The block returns the environment the worker (or the version's
  # workers) gets. When the worker is done (or the run, for a version),
  # Duel runs the #at_stop blocks (last first), then stops what was
  # spawned.
  class Resource
    # Seconds between looks while waiting (#wait_until).
    # @api private
    POLL = 0.01

    # Seconds a process gets to end after its stop signal before it's
    # killed.
    # @api private
    STOP_WAIT = 5

    # The lines of its log a failure shows.
    # @api private
    LOG_LINES = 10

    # What a cache key may be.
    # @api private
    KEY = /\A[\w.-]+\z/

    # The lock on building a cache (each worker is prepared on a thread
    # of its own).
    # @api private
    CACHE = Mutex.new

    # The worker it's for ("baseline-1", say), or the version ("baseline",
    # for Config#prepare(:version)), the directory it has of its own, the
    # tree of the version that worker runs, and the Ruby it runs on (see
    # Config#ruby).
    attr_reader :name, :dir, :root, :ruby

    # What its commands (#spawn, #run) get in their environment, under
    # their own: its version's (what Config#prepare(:version) returned, and
    # its Ruby's: see Rubies.environment).
    attr_reader :env

    # +env+ with +vars+ (a prepare block's, for +name+) too: two that set
    # a variable differently fail.
    # @api private
    def self.environment(name, env, vars)
      env.merge(vars) do |var, mine, theirs|
        raise Failed, "#{name}: two prepare blocks set #{var} (#{mine}, #{theirs})" unless mine == theirs

        mine
      end
    end

    # @api private
    def initialize(dir, name, root, timeout:, cache:, ruby: RbConfig.ruby, env: {})
      @name = name
      @dir = dir
      @root = root
      @ruby = ruby
      @env = env
      @timeout = timeout
      @cache = cache
      @processes = {}
      @stops = []
      FileUtils.mkdir_p(dir)
    end

    # A path in its directory. (Unix socket paths are short: up to 104
    # bytes on macOS. Duel's directories leave room.)
    def path(file) = File.join(@dir, file)

    # A directory built once, by the block, for every worker of this run
    # and later ones (a database's initial files, say, for each worker to
    # copy): the first that asks for +key+ builds it, in a directory the
    # block is given, and the rest get it built. A key names what's built
    # (put a version in it), as a file name: tmp/duel/cache/+key+, which
    # `duel --clean` removes. A build that fails leaves nothing behind.
    def cached(key)
      raise ArgumentError, "a cache key is a file name (letters, digits, - _ .), not #{key.inspect}" unless key.match?(KEY)

      dir = File.join(@cache, key)
      CACHE.synchronize { build(dir) { |building| yield building } unless File.directory?(dir) }
      dir
    end

    # Starts a process (as Process.spawn takes it), its output added to a
    # log in the directory (+log+.log: by default, its program's name),
    # and stopped with the resource, by +stop_signal+ (then KILL, five
    # seconds later). Returns its pid. Its input is
    # nothing, and it gets no other file descriptors, unless +options+
    # say otherwise (in:, close_others:). It runs in its version's
    # environment (on its Ruby: see Config#ruby), under any it's given.
    def spawn(*command, log: nil, stop_signal: "TERM", **options)
      log = log_path(command, log)
      pid = start(command, log, options)
      @processes[pid] = [File.basename(log, ".log"), log, stop_signal]
      pid
    end

    # Runs a command (setting something up, say) to its end, its output
    # added to a log as #spawn's is. It fails, showing it, unless it
    # succeeds.
    def run(*command, log: nil, **options)
      log = log_path(command, log)
      _, status = Process.wait2(start(command, log, options))
      return if status.success?

      code = status.exitstatus
      signal = status.termsig #: Integer
      failed("#{File.basename(log, ".log")} #{code ? "exited with #{code}" : "was killed by SIG#{Signal.signame(signal)}"}", log: log)
    end

    # Waits until the block is true: fails if a process spawned dies
    # first, or the run's timeout (--timeout) passes.
    def wait_until
      deadline = monotonic + @timeout
      until yield
        ended = @processes.find { |pid, _| Process.wait(pid, Process::WNOHANG) }
        if ended
          # (It may have got ready, and ended, since the last look.)
          break if yield

          program, log = ended.last
          failed("#{program} exited before it was ready", log: log)
        end
        failed("not ready within #{@timeout}s", log: @processes.values.last&.fetch(1)) if monotonic > deadline
        sleep POLL
      end
    end

    # Runs the block when the resource stops, before its processes do.
    def at_stop(&block) = @stops << block

    # Fails, saying it's this resource that did, with the end of +log+ (a
    # path) to say why.
    def failed(message, log: nil)
      tail = log ? File.readlines(log).last(LOG_LINES).join : ""
      raise Failed, "#{@name}'s resource: #{message}#{"\n#{tail}" unless tail.empty?}"
    end

    # Stops it: the at_stop blocks, last first, then each process.
    # @api private
    def stop
      @stops.reverse_each(&:call)
      @processes.each { |pid, (_, _, signal)| end_process(pid, signal) }
    end

    private

    # Builds +dir+ in a directory of its own, then renames it into place:
    # if another run got there first, its build stands.
    def build(dir)
      building = "#{dir}.#{Process.pid}.building"
      begin
        FileUtils.rm_rf(building)
        FileUtils.mkdir_p(building)
        yield building
        File.rename(building, dir)
      rescue SystemCallError, IOError # (JRuby's, renaming onto a directory)
        raise unless File.directory?(dir)
      ensure
        FileUtils.rm_rf(building)
      end
    end

    # The log a command's output goes to: +name+.log, or its program's.
    def log_path(command, name) = path("#{name || File.basename(command.grep(String).fetch(0).split.fetch(0))}.log")

    def start(command, log, options)
      # (Its own environment, if it's given one, over its version's.)
      none = {} #: Hash[String, String?]
      env, *program = command.first.is_a?(Hash) ? command : [none, *command]
      out = File.new(log, "a") # (here, so it's there for a failure to show)
      begin
        Process.spawn(@env.merge(env), *program, in: File::NULL, out: out, err: out, close_others: true, **options)
      ensure
        out.close
      end
    end

    # (Waited for on a thread of its own: a Timeout can't interrupt a wait
    # on JRuby.)
    def end_process(pid, signal)
      Process.kill(signal, pid)
      waiter = Process.detach(pid)
      return if waiter.join(STOP_WAIT)

      Process.kill("KILL", pid)
      waiter.join
    rescue Errno::ESRCH # gone already
      nil
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
