# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class RedisTest < PluginTest
  cover "Duel::Redis*"

  # Mutant runs a mutation's tests in this order (rather than at random),
  # stopping at the first that fails: those that start no server first,
  # then those on the process's shared server, and those that start
  # servers of their own last.
  if defined?(Mutant)
    FIRST = %w[test_used_by_name test_a_ping test_a_flush_closes_its_connection test_a_reply_of_another_type test_a_reply_cut_short].freeze
    LAST = %w[test_the_server_from_the_environment test_a_server_that_doesnt_start test_a_server_of_the_workers_own test_its_options
      test_its_directory test_the_connection].freeze

    def self.runnable_methods
      super.sort_by { |name| [FIRST.index(name) || (FIRST.size + (LAST.index(name)&.succ || 0)), name] }
    end
  end

  # The plugin registers itself as :redis, and c.use configures Duel for
  # it once: a server for each worker, and its metrics.
  def test_used_by_name
    config = Duel::Config.new(@dir)
    connection = config.use(:redis)

    assert_same Duel::Redis, Duel.plugins.fetch(:redis)
    assert_instance_of Duel::InWorker, connection
    assert_same connection, config.use(:redis)
    assert_equal [:redis], config.plugins
    assert_equal [1, 0, 1], [config.prepares.fetch(:worker).size, config.prepares.fetch(:version).size, config.in_workers.size]
    assert_equal [%w[redis_cpu redis_commands redis_round_trips]], config.metrics.map { |metric| metric.measures.keys }
  end

  def test_a_server_of_the_workers_own
    socket = Duel::Testing.prepare(config) do |env|
      path = env.fetch("DUEL_REDIS_URL").delete_prefix("unix://")

      assert_equal env.fetch("DUEL_REDIS_URL"), env.fetch("REDIS_URL")
      assert_equal "redis.sock", File.basename(path)
      assert File.absolute_path?(path), "in the worker's directory"
      assert Duel::Redis::Connection.ping(path)
      path
    end

    refute Duel::Redis::Connection.ping(socket), "stopped with the worker"
  end

  def test_its_options
    Duel::Testing.prepare(config(args: ["--databases", "4"], env: %w[CACHE_URL])) do |env|
      redis = Duel::Redis::Connection.new(env.fetch("CACHE_URL"))

      assert_equal %w[CACHE_URL DUEL_REDIS_URL], env.keys.sort
      assert_raises(RuntimeError) { redis.call("SELECT", 4) }
      redis.call("SELECT", 3)
    end
  end

  # The server works in the worker's directory: what a user's options make
  # it write (an append-only file, here) goes there, not in the project.
  def test_its_directory
    Duel::Testing.prepare(config(args: ["--appendonly", "yes"])) do |env|
      dir = File.dirname(env.fetch("REDIS_URL").delete_prefix("unix://"))
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))

      assert_equal ["dir", File.realpath(dir)], redis.call("CONFIG", "GET", "dir")
      assert_path_exists File.join(dir, "appendonlydir"), "the append-only file's, in the worker's directory"
      refute_path_exists "appendonlydir", "and not in the project"
    end
  end

  # Nothing written to disk: no snapshots, no append-only file.
  def test_no_persistence
    shared do |env|
      socket = UNIXSocket.new(env.fetch("REDIS_URL").delete_prefix("unix://"))
      socket.write("CONFIG GET save\r\nCONFIG GET appendonly\r\n")

      assert_equal ["*2", "$4", "save", "$0", "", "*2", "$10", "appendonly", "$2", "no"], Array.new(10) { socket.gets.chomp }
    ensure
      socket&.close
    end
  end

  def test_the_server_from_the_environment
    ENV["DUEL_REDIS_SERVER"] = "false"
    error = assert_raises(Duel::Failed) { Duel::Testing.prepare(config) { flunk "started" } }

    assert_equal "candidate-1's resource: false exited before it was ready", error.message
  ensure
    ENV.delete("DUEL_REDIS_SERVER")
  end

  def test_a_server_that_doesnt_start
    error = assert_raises(Duel::Failed) { Duel::Testing.prepare(config(server: "false")) { flunk "started" } }

    assert_equal "candidate-1's resource: false exited before it was ready", error.message
  end

  def test_measures_what_redis_did
    config = self.config
    measured = shared do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      Duel::Testing.measure(config) { 3.times { |i| redis.call("SET", "k#{i}", "v") } }
    end

    assert_equal 3, measured.fetch("redis_commands"), "the readings' own INFO taken away"
    assert_equal 3, measured.fetch("redis_round_trips")
    assert_operator measured.fetch("redis_cpu"), :>, 0
    assert_equal [[:ratio, "µs", "µs"], [:counted, "command", "commands"], [:counted, "round trip", "round trips"]],
      config.metrics.first.settings.values.map { |s| s.values_at(:kind, :unit, :plural) }
  end

  # The readings themselves: every command and reply so far, and every
  # command's time but INFO's.
  def test_its_statistics
    shared do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      redis.call("CONFIG", "RESETSTAT")
      first = Duel::Redis.stats(redis)
      second = Duel::Redis.stats(redis)

      assert_equal [1, 1], first.values_at("redis_commands", "redis_round_trips"), "CONFIG RESETSTAT's"
      assert_equal [2, 2], second.values_at("redis_commands", "redis_round_trips"), "and the first INFO's"
      assert_equal first.fetch("redis_cpu"), second.fetch("redis_cpu"), "but not its time"
      1000.times { |i| redis.call("SET", "k#{i}", "v") }

      assert_operator Duel::Redis.stats(redis).fetch("redis_cpu"), :>, 100, "a thousand SETs' microseconds"
    end
  end

  # A flush while a benchmark is measured would be counted (a command,
  # and a round trip): it fails, and flushes nothing.
  def test_a_flush_measured
    config = self.config
    shared do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      redis.call("SET", "k", "v")
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::Redis.flush } }

      assert_equal "Duel::Redis.flush: in setup or untimed only (it would be counted)", error.message
      assert_equal 1, redis.call("DBSIZE")
      Duel::Testing.measure(config) { |sample| sample.untimed { Duel::Redis.flush } }

      assert_equal 0, redis.call("DBSIZE"), "untimed: flushed"
    end
  end

  # The helpers need only the worker's environment: Duel::Redis.flush
  # opens a connection of its own.
  def test_for_benchmarks
    shared do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      redis.call("SET", "k", "v")

      assert_equal env.fetch("DUEL_REDIS_URL"), Duel::Redis.url
      assert_equal "OK", Duel::Redis.flush
      assert_equal 0, redis.call("DBSIZE")
    end
  end

  def test_a_flush_closes_its_connection
    ENV["DUEL_REDIS_URL"] = "unix://#{File.join(@dir, "fake.sock")}"
    sent, closed = fake_server("+OK\r\n") { Duel::Redis.flush }

    assert_equal "*1\r\n$8\r\nFLUSHALL\r\n", sent
    assert closed
  ensure
    ENV.delete("DUEL_REDIS_URL")
  end

  # The plugin's connection (what c.use returns) is opened in workers
  # (Config#in_worker), not by the runner, which loads .duel.rb too, and
  # closed as they end.
  def test_outside_a_worker
    connection = nil
    config = Duel::Config.new(@dir).tap { |c| connection = c.use(:redis) }
    redis = shared_worker(config) { connection.value.tap { |r| assert_match(/^redis_version:/, r.call("INFO", "server")) } }

    assert_raises(IOError) { redis.call("PING") }
    error = assert_raises(Duel::Error) { connection.value }

    assert_match(/made in each worker only/, error.message)
  end

  def test_the_connection
    redis = Duel::Testing.prepare(config) do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))

      assert_equal "OK", redis.call("SET", "k", "a value")
      assert_equal "a value", redis.call("GET", "k")
      assert_equal 1, redis.call("DEL", "k")
      error = assert_raises(RuntimeError) { redis.call("NOPE") }
      assert_match(/\ARedis: ERR unknown command 'NOPE'/, error.message)
      redis
    end

    assert_raises(IOError, Errno::EPIPE) { redis.call("PING") }
    refute Duel::Redis::Connection.ping(File.join(@dir, "nothing.sock"))
  end

  # Every type of reply RESP2 has, each read whole: the next one, PING's,
  # is read in step. (A missing key's, a nil bulk string, was read as one
  # of a byte, and waited for it: a timeout stops the test rather than
  # hang it.)
  def test_every_type_of_reply
    shared do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      replies, transaction = Timeout.timeout(5) do
        [
          [
            ["SET", "k", "v"], ["GET", "k"], ["SET", "e", ""], ["GET", "e"], ["SET", "b", "a\r\nb\r"], ["GET", "b"],
            ["GET", "missing"], ["INCR", "n"], ["DECRBY", "n", 3],
            ["RPUSH", "l", "a", "b"], ["LRANGE", "l", 0, -1], ["LRANGE", "missing", 0, -1], ["MGET", "k", "missing"],
            ["BLPOP", "missing", "0.01"], ["EVAL", "return {1, 'two', {3, false, {}}}", 0]
          ].map { |command| [redis.call(*command), redis.call("PING")] },
          [["MULTI"], ["SET", "k", "w"], ["INCR", "k"], ["EXEC"], ["PING"]].map { |command| redis.call(*command) }
        ]
      end

      assert_equal [
        "OK", "v", "OK", "", "OK", "a\r\nb\r",
        nil, 1, -2,
        2, %w[a b], [], ["v", nil],
        nil, [1, "two", [3, nil, []]]
      ], replies.map(&:first)
      assert_equal ["PONG"] * 15, replies.map(&:last)
      *queued, (set, incr), pong = transaction

      assert_equal ["OK", "QUEUED", "QUEUED", "OK", "PONG"], [*queued, set, pong]
      assert_instance_of RuntimeError, incr, "an error in an array: returned, not raised"
      assert_match(/\ARedis: ERR value is not an integer/, incr.message)
      assert_equal "w", redis.call("GET", "k")
    end
  end

  # The connection reads RESP2 only (it never sends HELLO): another type
  # of reply, RESP3's, closes it, as the rest of the reply can't be read.
  def test_a_reply_of_another_type
    ["_\r\n", "%1\r\n+a\r\n:1\r\n"].each do |reply|
      redis = nil
      _, closed = fake_server(reply) do |path|
        redis = Duel::Redis::Connection.new(path)
        error = assert_raises(IOError) { redis.call("HELLO", 3) }

        assert_equal "Redis: a reply of a type the connection doesn't read (RESP2 only): #{reply.lines.first.chomp}", error.message
      end

      assert closed
      assert_raises(IOError) { redis.call("PING") }
    end
  end

  # A server that hangs up mid-reply.
  def test_a_reply_cut_short
    ["", "$5\r\n", "$5\r\nab", "*2\r\n+a\r\n"].each do |reply|
      fake_server(reply, hang_up: true) do |path|
        redis = Duel::Redis::Connection.new(path)
        error = assert_raises(IOError) { redis.call("GET", "k") }

        assert_equal "Redis closed the connection", error.message
      ensure
        redis&.close
      end
    end
  end

  # Ready only when the server answers PONG; it hangs up either way.
  def test_a_ping
    ["+PONG\r\n", "-LOADING\r\n"].each do |reply|
      ready = nil
      sent, closed = fake_server(reply) { |path| ready = Duel::Redis::Connection.ping(path) }

      assert_equal reply == "+PONG\r\n", ready
      assert_equal "PING\r\n", sent
      assert closed
    end
  end

  # Its metrics are costly to read, so a benchmark with an
  # around_iteration hook reads them only as each sample starts and
  # stops, and what the hook sends the server (deleting what each
  # iteration wrote) is learned in each worker and taken away: only the
  # iterations' commands and round trips are counted.
  def test_an_around_iteration_hook_left_out
    config = self.config
    measured = Duel::Testing.prepare(config) do |env|
      redis = Duel::Redis::Connection.new(env.fetch("REDIS_URL"))
      around = lambda do |iteration|
        iteration.call
        redis.call("DEL", "k")
      end
      Duel::Testing.measure(config, n: 20, around_iteration: around) { redis.call("SET", "k", "v") }
    end

    assert_predicate config.metrics.first, :costly?
    assert_equal [20, 20], measured.values_at("redis_commands", "redis_round_trips")
  end

  private

  # A server on a socket in @dir of its own that reads a request and
  # writes +reply+, then hangs up (+hang_up+) or waits a second for the
  # client to. Yields the socket's path; returns what it was sent, and
  # whether the client hung up.
  def fake_server(reply, hang_up: false)
    path = File.join(@dir, "fake.sock")
    server = UNIXServer.new(path)
    thread = Thread.new do
      client = server.accept
      sent = client.readpartial(1024)
      client.write(reply)
      [sent, !hang_up && client.wait_readable(1) && client.read_nonblock(1, exception: false).nil?]
    ensure
      client&.close
    end
    yield path
    thread.value
  ensure
    server&.close
    FileUtils.rm_f(path)
  end
end

# (Too slow for mutation testing: the code they run is covered there by
# the faster tests above.)
class RedisComparisonTest < PluginTest
  # Whole comparisons: the same code passes; code that sends Redis more
  # commands (and round trips) fails on them.
  def test_comparisons
    base = project("base", 1)
    same = Duel::Testing.compare(base, project("same", 1))

    assert_predicate same, :passed?, same.output
    assert_equal 1, same["store"].counted.fetch("redis_commands").then { |c| c.fetch("candidate") / c.fetch("n") }
    more = Duel::Testing.compare(base, project("more", 2))

    assert_equal %w[redis_commands redis_round_trips], more["store"].regressed & %w[redis_commands redis_round_trips], more.output
    assert_includes more.output, "redis_commands: 1 command → 2 commands an iteration"
    assert_includes more.output, "redis_round_trips: 1 round trip → 2 round trips an iteration"
  end
end
