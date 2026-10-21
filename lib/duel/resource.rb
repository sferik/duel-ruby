# frozen_string_literal: true

require "fileutils"

module Duel
  # What a resource block (see Config#resource) gets: a worker's own
  # directory, and help starting a server there and stopping it.
  #
  #   c.resource do |r|
  #     socket = r.path("redis.sock")
  #     r.spawn("redis-server", "--port", "0", "--unixsocket", socket, "--save", "")
  #     r.wait_until { File.socket?(socket) }
  #     {"REDIS_URL" => "unix://#{socket}"}
  #   end
  #
  # The block returns the environment the worker gets. When the worker is
  # done, Duel runs the resource's #at_stop blocks (last first), then
  # stops what it spawned.
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

    # The lock on building a cache (each worker's resources start on a
    # thread of their own).
    # @api private
    CACHE = Mutex.new

    # The worker it's for ("baseline-1", say), the directory it has of its
    # own, and the tree of the version that worker runs.
    attr_reader :name, :dir, :root

    # +env+ with +vars+ (a resource's, for the worker +name+) too: two
    # resources that set a variable differently fail.
    # @api private
    def self.environment(name, env, vars)
      env.merge(vars) do |var, mine, theirs|
        raise Failed, "#{name}: two resources set #{var} (#{mine}, #{theirs})" unless mine == theirs

        mine
      end
    end

    # @api private
    def initialize(dir, name, root, timeout:, cache:)
      @name = name
      @dir = dir
      @root = root
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
    # say otherwise (in:, close_others:).
    def spawn(*command, log: nil, stop_signal: "TERM", **options)
      log = log_path(command, log)
      pid = start(command, log, options)
      @processes[pid] = [File.basename(log, ".log"), log, stop_signal]
      pid
    end

    # Runs a command (setting something up, say) to its end, its output
    # added to a log as #spawn's is; fails, showing it, unless it succeeds.
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
        @processes.each do |pid, (program, log)|
          failed("#{program} exited before it was ready", log: log) if Process.wait(pid, Process::WNOHANG)
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
      out = File.new(log, "a") # (here, so it's there for a failure to show)
      begin
        Process.spawn(*command, in: File::NULL, out: out, err: out, close_others: true, **options)
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
