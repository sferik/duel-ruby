# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "control"
require_relative "spawn"

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

    # What a cache key may be.
    # @api private
    KEY = /\A[\w.-]+\z/

    # The lock on building a cache (each worker is prepared on a thread
    # of its own).
    # @api private
    CACHE = Mutex.new

    # What a cache key names, without the version and the hash it ends
    # with: "mysql", of mysql-0.1.2-3f9c2a1b7e5d4c6a. Builds of one name
    # are of one thing, and the one a run used replaces the rest (see
    # .evict).
    # @api private
    NAME = /\A(.+?)(?:-\d[\w.]*)?-\h{8,}\z/

    # The builds this process's runs used (#cached), by path.
    # @api private
    USED = Set.new

    # Removes from +cache+ the builds that ones this process used replace:
    # of the same name (see NAME), with another version or hash. A server
    # or a plugin upgraded, or a lockfile changed, left its old build
    # behind otherwise: tens of megabytes of a database's files, each
    # time. A key that doesn't end with a hash is never removed, nor is
    # any that this process used (each version's bundle, say). (Once a
    # run's workers have started: none adds to USED then.)
    # @api private
    def self.evict(cache)
      used = USED.select { |dir| File.dirname(dir) == cache }.map { |dir| File.basename(dir) }
      names = used.filter_map { |key| key[NAME, 1] }
      Dir.children(cache).each do |build|
        FileUtils.rm_rf(File.join(cache, build)) if !used.include?(build) && names.include?(build[NAME, 1])
      end
    rescue Errno::ENOENT # (no cache)
      nil
    end

    # A process #spawn started: its program (what its log is named for),
    # its log, the signal that stops it, and its Spawn::Child.
    # @api private
    Spawned = Data.define(:program, :log, :stop_signal, :child)

    # The worker it's for ("base-1", say), or the version ("base",
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

    # (+starter+: how its processes start, Spawn::Directly or
    # Spawn::ThroughOpen3.)
    # @api private
    def initialize(dir, name, root, timeout:, cache:, ruby: RbConfig.ruby, env: {}, starter: Spawn::STARTER)
      @name = name
      @dir = dir
      @root = root
      @ruby = ruby
      @env = env
      @timeout = timeout
      @cache = cache
      @starter = starter
      @processes = []
      @stops = []
      FileUtils.mkdir_p(dir)
    end

    # A path in its directory. (Unix socket paths are short: up to 104
    # bytes on macOS. Duel's directories leave room.)
    def path(file) = File.join(@dir, file)

    # A port of 127.0.0.1's that's free (one the system chose, let go of
    # again), for a server of its own to listen on, rather than on a Unix
    # socket in its directory (see #path).
    def port
      server = Control.tcp_server
      begin
        server.addr.fetch(1)
      ensure
        server.close
      end
    end

    # A directory built once, by the block, for every worker of this run
    # and later ones (a database's initial files, say, for each worker to
    # copy): the first that asks for +key+ builds it, in a directory the
    # block is given, and the rest get it built. A key names what's built
    # (put a version in it), as a file name: tmp/duel/cache/+key+, which
    # `duel --clean` removes. A build that fails leaves nothing behind.
    # A key that ends with a hash (and a version before it, if you like:
    # mysql-0.1.2-3f9c2a1b) replaces the builds of its name when the run
    # ends (see .evict): the one a run used is the one that's kept.
    def cached(key)
      raise ArgumentError, "a cache key is a file name (letters, digits, - _ .), not #{key.inspect}" unless key.match?(KEY)

      dir = File.join(@cache, key)
      CACHE.synchronize do
        USED << dir
        build(dir) { |building| yield building } unless File.directory?(dir)
      end
      dir
    end

    # Starts a process (as Process.spawn takes it), its output added to a
    # log in the directory (+log+.log: by default, its program's name),
    # and stopped with the resource, by +stop_signal+ (then KILL, five
    # seconds later). On Windows, which can't send another process a
    # signal, it's killed: ask it to stop in an #at_stop block, which
    # runs first. Returns its pid. Its input is
    # nothing, and it gets no other file descriptors, unless +options+
    # say otherwise (in:, close_others:). It runs in its version's
    # environment (on its Ruby: see Config#ruby), under any it's given.
    def spawn(*command, log: nil, stop_signal: "TERM", **options)
      log = log_path(command, log)
      child = start(command, log, options)
      @processes << Spawned.new(program: File.basename(log, ".log"), log:, stop_signal:, child:)
      child.pid
    end

    # Runs a command (setting something up, say) to its end, its output
    # added to a log as #spawn's is. It fails, showing it, unless it
    # succeeds.
    def run(*command, log: nil, **options)
      log = log_path(command, log)
      code, signal = start(command, log, options).wait
      return if code == 0

      failed("#{File.basename(log, ".log")} #{Spawn.why(code, signal)}", log: log)
    end

    # Waits until the block is true: fails if a process spawned dies
    # first, or the run's timeout (--timeout) passes.
    def wait_until
      deadline = monotonic + @timeout
      until yield
        ended = @processes.find { |process| !process.child.alive? }
        if ended
          # (It may have got ready, and ended, since the last look.)
          break if yield

          failed("#{ended.program} exited before it was ready", log: ended.log)
        end
        failed("not ready within #{@timeout}s", log: @processes.last&.log) if monotonic > deadline
        sleep POLL
      end
    end

    # Runs the block when the resource stops, before its processes do.
    def at_stop(&block) = @stops << block

    # Fails, saying it's this resource that did, with the end of +log+ (a
    # path) to say why.
    def failed(message, log: nil)
      tail = log ? Spawn.tail(log) : ""
      raise Failed, "#{@name}'s resource: #{message}#{"\n#{tail}" unless tail.empty?}"
    end

    # Stops it: the at_stop blocks, last first, then each process.
    # @api private
    def stop
      @stops.reverse_each(&:call)
      @processes.each do |process|
        process.child.signal(process.stop_signal)
        process.child.stop(STOP_WAIT)
      end
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

    # The log a command's output goes to: +name+.log, or its program's:
    # a command line's first word (a String alone, which a shell runs), or
    # else the program given its arguments, whole, as its path may have a
    # space in it (C:/Program Files/PostgreSQL/17/bin/initdb, say).
    def log_path(command, name)
      words = command.grep(String)
      program = words.fetch(0)
      program = program.split.fetch(0) if words.size == 1
      path("#{name || File.basename(program)}.log")
    end

    # Starts +command+, its output added to +log+, and returns its
    # Spawn::Child, waited for on a thread from the start (see
    # Child#detach), so it's reaped as it ends. (On a thread: a Timeout
    # can't interrupt a wait on JRuby.)
    def start(command, log, options)
      # (Its own environment, if it's given one, over its version's.)
      none = {} #: Hash[String, String?]
      env, *program = command.first.is_a?(Hash) ? command : [none, *command]
      @starter.logged(@env.merge(env), program, log: log, mode: "a", close_others: true, **options).detach
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
