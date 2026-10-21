# frozen_string_literal: true

# SimpleCov's strict profile: line, branch and method coverage, each held
# to 100% (COVERAGE=false to run some of the tests; mutant runs its own).
if ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby" && !defined?(Mutant)
  require "simplecov"
  SimpleCov.start("strict") do
    root File.expand_path("..", __dir__)
    skip %r{\A/?test/}
  end
end

require_relative "watchdog"

# A mysqld the tests start has a data directory of its own (an absolute
# --datadir): without one (a mutation that leaves it out, or makes it a
# relative path), it would start on the machine's (its default) or one
# in the directory it's in.
module OwnDataDir
  def spawn(*command, **options)
    program = command.grep(String).first.to_s
    if File.basename(program).start_with?("mysqld") && command.grep(%r{\A--datadir=/}).empty?
      raise ArgumentError, "a mysqld with no data directory of its own: #{command.grep(String).join(" ")}"
    end

    super
  end
end
Process.singleton_class.prepend(OwnDataDir)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/mysql"
require "duel/testing"
# Mutant runs the tests itself (and autorun, at exit, would run them all
# again in every one of its processes).
require defined?(Mutant) ? "minitest" : "minitest/autorun"
# Assertions that take only true and false for true and false.
require "minitest/strict"

begin
  # `cover "Duel::Thing*"` tells mutant which tests exercise which code.
  require "mutant/minitest/coverage"
rescue LoadError
  # mutant is CRuby's; elsewhere coverage declarations do nothing.
  module Minitest
    class Test
      def self.cover(_expression) = nil
    end
  end
end

# A server of the plugin's started once in a test process (when a test
# first asks for it), for the tests that need one but aren't about
# starting it, and stopped as the process ends. Starting one for each
# test made a mutation's run of them take most of a minute. (Mutant runs
# each mutation's tests in a process of their own, forked from its own,
# so each mutation's server is its own, started by the mutated code. If
# the process is killed, the watchdog stops it.)
module SharedServer
  @started = {} # (the environment of each process's, by pid)

  # The environment of this process's server, started first if it has
  # none, its builds in +cache+.
  def self.env(cache)
    @started[Process.pid] ||= start(cache)
  end

  # Starts one (Duel::Testing.prepare, its block left waiting in a
  # Fiber until the process ends), in a directory of its own, and
  # returns its environment. (The environment's left as it was: a test
  # sets it while it runs.)
  def self.start(cache)
    root = Dir.mktmpdir("dms", "/tmp")
    config = Duel::Config.new(root)
    config.use(:mysql)
    fiber = Fiber.new { Duel::Testing.prepare(config, cache:) { |env| Fiber.yield(env) } }
    saved = ENV.to_h
    begin
      env = Dir.chdir(root) { fiber.resume }
    ensure
      ENV.replace(saved)
      FileUtils.rm_rf(root) unless env # (it didn't start)
    end
    pid = Process.pid
    at_exit do
      next unless Process.pid == pid # (not in a process forked from it)

      begin
        fiber.resume # (Testing.prepare stops it)
      rescue => e
        # (The tests have reported: an error now would fail the process,
        # which mutant counts as a mutation's being killed.)
        warn "The shared server didn't stop: #{e.full_message}"
      end
      FileUtils.rm_rf(root)
    end
    env.freeze
  end

  # Gives a test its server as it started: its database empty (made
  # again), and the statements it ran so far forgotten.
  def self.clean(env)
    db = Trilogy.new(socket: env.fetch(Duel::MySQL::SOCKET), username: Duel::MySQL::USER)
    begin
      db.query("DROP DATABASE IF EXISTS #{Duel::MySQL::DATABASE}")
      db.query("CREATE DATABASE #{Duel::MySQL::DATABASE}")
      db.query("TRUNCATE TABLE performance_schema.events_statements_summary_by_digest")
    ensure
      db.close
    end
  end
end

class PluginTest < Minitest::Test
  # The project's directory, where the tests start.
  ROOT = File.expand_path("..", __dir__)

  # The server the tests run, found as they load (so a mutation of
  # find_server fails them, rather than skipping them all).
  MYSQLD = Duel::MySQL::DataDir.find_server(ENV.fetch("DUEL_MYSQL_SERVER", "mysqld"))

  # Where prepare blocks' builds (Resource#cached: the data directories
  # initialized) are kept, for every test, removed when they're done.
  # (Mutant runs them in processes forked from this one, at once, and has
  # no after_run.)
  CACHE = Dir.mktmpdir("dmc", "/tmp")
  if defined?(Mutant)
    main = Process.pid
    at_exit { FileUtils.rm_rf(CACHE) if Process.pid == main }
  else
    Minitest.after_run { FileUtils.rm_rf(CACHE) }
  end

  def setup
    # (trilogy's extension installs and loads there, but a connection
    # that has run a thousand or so queries takes TruffleRuby down.)
    skip "TruffleRuby 40.0 fails inside Trilogy#query (a dead handle)" if RUBY_ENGINE == "truffleruby"
    skip "MySQL isn't installed" unless MYSQLD
    @dir = Dir.mktmpdir("dm", "/tmp")
    # (In the test's directory: what a mutation makes a relative path,
    # and writes there, isn't left in the project.)
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(ROOT)
    FileUtils.rm_rf(@dir) if @dir
  end

  # The plugin used, with +options+ (its connection, what c.use
  # returns, in @connection).
  def config(**options) = Duel::Config.new(@dir).tap { |c| @connection = c.use(:mysql, **options) }

  # Runs +config+'s prepare blocks (Duel::Testing.prepare, with +options+),
  # their builds in +cache+: by default, this process's own in CACHE.
  # (Mutant's processes share CACHE: a mutation that initializes a data
  # directory wrongly but without failing would leave it there, for every
  # other mutation's tests to copy and fail with.)
  def prepare(config, cache: File.join(CACHE, Process.pid.to_s), **options, &)
    Duel::Testing.prepare(config, cache:, **options, &)
  end

  # Runs the block in a worker of +config+'s: its server started, and its
  # in_worker blocks run (the plugin's connection opened, and closed after).
  def worker(config = self.config)
    prepare(config) { |env| Duel::Testing.in_worker(config) { yield env } }
  end

  # Runs the block with the environment of this process's server
  # (SharedServer's) set, as its prepare blocks set a worker's, its database
  # fresh. For a test that needs a server, but not one of its own.
  def shared
    env = SharedServer.env(File.join(CACHE, Process.pid.to_s))
    SharedServer.clean(env)
    with_env(env) { yield env }
  end

  # Runs the block in a worker of +config+'s on that server: its in_worker
  # blocks run (the plugin's connection opened, and closed after).
  def shared_worker(config = self.config)
    shared { |env| Duel::Testing.in_worker(config) { yield env } }
  end

  # A cache of the test's own, for builds it looks at (others' share
  # CACHE).
  def own_cache = File.join(@dir, "cache").tap { |dir| FileUtils.mkdir_p(dir) }

  # Runs the block with environment variables set (or, nil, unset).
  def with_env(vars)
    saved = vars.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    vars.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved&.each { |name, value| ENV[name] = value }
  end

  # Runs the block with a class method replaced by +replacement+.
  def replacing(object, method, replacement)
    original = object.method(method)
    object.define_singleton_method(method, &replacement)
    yield
  ensure
    object.define_singleton_method(method, original) if original
  end

  # A connection to the worker's server, as a benchmark's would be.
  def client = Trilogy.new(socket: Duel::MySQL.socket, username: "root", database: "duel")

  # The rows a query returns, on a connection of its own to the worker's
  # server.
  def query(sql)
    db = client
    db.query(sql).rows
  ensure
    db&.close
  end

  # Waits until +connection+ (the plugin's, or a Trilogy) is the only
  # client of the worker's server (those that closed are gone, a QUIT
  # they sent read: the server reads it after its client's moved on);
  # returns how many others there are, [[0]] (or more, after 10s).
  def alone(connection)
    others = "SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_USER = 'root' AND THREAD_ID != PS_CURRENT_THREAD_ID()"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.01 until (count = connection.query(others).rows) == [[0]] || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    count
  end

  # A project of one benchmark, whose code sends +queries+ queries, with
  # .duel.rb using the plugin.
  def project(name, queries)
    Duel::Testing.project(File.join(@dir, name),
      "lib/sample.rb" => <<~RUBY,
        module Sample
          def self.find(db) = #{queries}.times { |i| db.query("SELECT id FROM items WHERE id = \#{i}") }
        end
      RUBY
      "duel/find_duel.rb" => <<~RUBY,
        require "sample"

        setup { @db = Trilogy.new(socket: Duel::MySQL.socket, username: "root", database: "duel") }
        teardown { @db.close }

        duel("find") { Sample.find(@db) }
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :mysql, setup: "CREATE TABLE items (id int PRIMARY KEY); INSERT INTO items VALUES (0), (1)"
        end
      RUBY
  end
end
