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

# A postgres (or initdb) the tests start has a data directory of its own
# (an absolute -D, or --pgdata=): without one (a mutation that leaves it
# out, or makes it a relative path), it would start on the machine's
# (PGDATA's, say) or one in the directory it's in.
module OwnDataDir
  def spawn(*command, **options)
    words = command.grep(String)
    if %w[postgres initdb].include?(File.basename(words.first.to_s))
      data = words.each_cons(2).find { |flag, _| flag == "-D" }&.last ||
        words.find { |word| word.start_with?("--pgdata=") }&.delete_prefix("--pgdata=")
      raise ArgumentError, "#{File.basename(words.first)} with no data directory of its own: #{words.join(" ")}" unless data&.start_with?("/")
    end

    super
  end
end
Process.singleton_class.prepend(OwnDataDir)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/postgresql"
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
  # Each process's: its environment, the Fiber its prepare blocks wait in, and
  # its directory, by pid.
  @started = {}

  # The environment of this process's server, started first if it has
  # none, its builds in +cache+.
  def self.env(cache)
    (@started[Process.pid] || start(cache)).first
  end

  # Starts one (Duel::Testing.prepare, its block left waiting in a
  # Fiber until it's stopped), in a directory of its own, and returns
  # what @started has of it. (The environment's left as it was: a test
  # sets it while it runs.)
  def self.start(cache)
    root = Dir.mktmpdir("dps", "/tmp")
    config = Duel::Config.new(root)
    config.use(:postgresql)
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
      stop if Process.pid == pid # (not in a process forked from it)
    rescue => e
      # (The tests have reported: an error now would fail the process,
      # which mutant counts as a mutation's being killed.)
      warn "The shared server didn't stop: #{e.full_message}"
    end
    @started[pid] = [env.freeze, fiber, root]
    # Its database as it starts, for each test's to be a copy of.
    admin(env) { |pg| pg.exec("CREATE DATABASE #{TEMPLATE} TEMPLATE #{Duel::PostgreSQL::DATABASE}") }
    @started.fetch(pid)
  end

  # Stops this process's, if it has one.
  def self.stop
    _, fiber, root = @started.delete(Process.pid)
    return unless fiber

    fiber.resume # (Testing.prepare stops it)
    FileUtils.rm_rf(root)
  end

  TEMPLATE = "duel_template"

  # Gives a test its server as it started: its database a fresh copy,
  # and pg_stat_statements emptied.
  def self.clean(env)
    database = Duel::PostgreSQL::DATABASE
    admin(env) do |pg|
      pg.exec("DROP DATABASE IF EXISTS #{database} WITH (FORCE)")
      pg.exec("CREATE DATABASE #{database} TEMPLATE #{TEMPLATE}")
    end
    pg = PG.connect(env.fetch(Duel::PostgreSQL::URL))
    begin
      pg.exec("SELECT pg_stat_statements_reset()")
    ensure
      pg.close
    end
  end

  # Yields a connection to the server's database "postgres" (not its own,
  # which it can then drop, or copy).
  def self.admin(env)
    pg = PG.connect(host: env.fetch("PGHOST"), port: env.fetch("PGPORT"), user: env.fetch("PGUSER"), dbname: "postgres")
    begin
      yield pg
    ensure
      pg.close
    end
  end
end

class PluginTest < Minitest::Test
  # The directory of the postgres the tests run, found as they load (so a
  # mutation of find_bin fails them, rather than skipping them all).
  POSTGRES = ENV["DUEL_POSTGRESQL_BIN"] || Duel::PostgreSQL::Cluster.find_bin

  # Where prepare blocks' builds (Resource#cached: the clusters initdb'd) are
  # kept, removed when the tests are done: a directory in it for each
  # process. (Mutant runs them in processes forked from this one, a
  # mutation in each, at once, and has no after_run. A cluster one
  # mutation built, broken, say, mustn't be another's to copy.)
  CACHE = Dir.mktmpdir("dpc", "/tmp")
  if defined?(Mutant)
    main = Process.pid
    at_exit { FileUtils.rm_rf(CACHE) if Process.pid == main }
  else
    Minitest.after_run { FileUtils.rm_rf(CACHE) }
  end

  # Each test runs in its directory: whatever a mutation has the plugin,
  # or a server, write to a relative path (a cluster copied to "data",
  # say, for r.path("data")) is written there, not into the project.
  def setup
    skip "PostgreSQL isn't installed" unless POSTGRES
    @dir = Dir.mktmpdir("dp", "/tmp")
    @cwd = Dir.pwd
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(@cwd) if @cwd
    FileUtils.rm_rf(@dir) if @dir
  end

  # The plugin used, with +options+ (its connection, what c.use
  # returns, in @connection).
  def config(**options) = Duel::Config.new(@dir).tap { |c| @connection = c.use(:postgresql, **options) }

  # Runs +config+'s prepare blocks (Duel::Testing.prepare, with +options+),
  # their builds in +cache+ (by default, this process's in CACHE).
  def prepare(config, cache: File.join(CACHE, Process.pid.to_s), **options, &) = Duel::Testing.prepare(config, cache:, **options, &)

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

  # A directory (in the test's) of links to postgres's programs.
  def linked_bin
    File.join(@dir, "linked").tap do |linked|
      FileUtils.mkdir_p(linked)
      %w[postgres initdb].each { |program| File.symlink(File.join(POSTGRES, program), File.join(linked, program)) }
    end
  end

  # Runs the block with a class method replaced by +replacement+.
  def replacing(object, method, replacement)
    original = object.method(method)
    object.define_singleton_method(method, &replacement)
    yield
  ensure
    object.define_singleton_method(method, original) if original
  end

  # A project of one benchmark, whose code sends +queries+ queries, with
  # .duel.rb using the plugin.
  def project(name, queries)
    Duel::Testing.project(File.join(@dir, name),
      "lib/sample.rb" => <<~RUBY,
        module Sample
          def self.find(pg) = #{queries}.times { |i| pg.exec_params("SELECT id FROM items WHERE id = $1", [i]) }
        end
      RUBY
      "duel/find_duel.rb" => <<~RUBY,
        require "sample"

        setup { @pg = PG.connect(Duel::PostgreSQL.url) }
        teardown { @pg.close }

        duel("find") { Sample.find(@pg) }
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :postgresql, setup: "CREATE TABLE items (id int PRIMARY KEY); INSERT INTO items VALUES (0), (1)"
        end
      RUBY
  end
end
