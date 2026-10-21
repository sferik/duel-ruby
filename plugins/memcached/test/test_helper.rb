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

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/memcached"
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
# starting it, and stopped as the process ends. (Mutant runs each
# mutation's tests in a process of their own, forked from its own, so
# each mutation's server is its own, started by the mutated code. If the
# process is killed, the watchdog stops it.)
module SharedServer
  @started = {} # (the environment of each process's, by pid)

  # The environment of this process's server, started first if it has
  # none.
  def self.env
    @started[Process.pid] ||= start
  end

  # Starts one (Duel::Testing.prepare, its block left waiting in a
  # Fiber until the process ends), in a directory of its own, and
  # returns its environment. (The environment's left as it was: a test
  # sets it while it runs.)
  def self.start
    root = Dir.mktmpdir("dmcs", "/tmp")
    config = Duel::Config.new(root)
    config.use(:memcached)
    fiber = Fiber.new { Duel::Testing.prepare(config) { |env| Fiber.yield(env) } }
    saved = ENV.to_h
    begin
      env = fiber.resume
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

  # Gives a test its server as it started: no keys, and its
  # statistics reset.
  def self.clean(env)
    socket = UNIXSocket.new(env.fetch(Duel::Memcached::SERVERS))
    begin
      socket.write("flush_all\r\nstats reset\r\n")
      2.times { socket.gets }
    ensure
      socket.close
    end
  end
end

class PluginTest < Minitest::Test
  def setup
    skip "memcached isn't installed" unless system("memcached", "--version", out: File::NULL, err: File::NULL)
    @dir = Dir.mktmpdir("dm", "/tmp")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # Runs the block with the environment of this process's server
  # (SharedServer's) set, as its prepare block sets a worker's, emptied.
  # For a test that needs a server, but not one of its own.
  def shared
    env = SharedServer.env
    SharedServer.clean(env)
    saved = env.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    begin
      ENV.update(env)
      yield env
    ensure
      ENV.update(saved)
    end
  end

  # Runs the block in a worker of +config+'s on that server: its
  # in_worker blocks run (the plugin's connection opened, and closed
  # after).
  def shared_worker(config = self.config)
    shared { |env| Duel::Testing.in_worker(config) { yield env } }
  end

  # The plugin, used with +options+ (its connection, what c.use returns,
  # in @connection).
  def config(**options) = Duel::Config.new(@dir).tap { |c| @connection = c.use(:memcached, **options) }

  # Runs the block in a worker of +config+'s: its server started, and its
  # in_worker blocks run (the plugin's connection opened, and closed
  # after).
  def worker(config)
    Duel::Testing.prepare(config) { |env| Duel::Testing.in_worker(config) { yield env } }
  end

  # A project of one benchmark, whose code (with Dalli) stores +commands+
  # keys, with .duel.rb using the plugin.
  def project(name, commands)
    Duel::Testing.project(File.join(@dir, name),
      "lib/sample.rb" => <<~RUBY,
        module Sample
          def self.store(cache) = #{commands}.times { |i| cache.set("k\#{i}", "v") }
        end
      RUBY
      "duel/store_duel.rb" => <<~RUBY,
        require "dalli"
        require "sample"

        duel "store" do
          once do
            Duel::Memcached.flush
            @cache = Dalli::Client.new(nil, serializer: Dalli::JSONSerializer) # (MEMCACHE_SERVERS)
          end
          Sample.store(@cache)
        end
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :memcached
        end
      RUBY
  end
end
