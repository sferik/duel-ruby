# frozen_string_literal: true

require_relative "test_helper"

class MemcachedTest < PluginTest
  cover "Duel::Memcached*"

  # Mutant runs a mutation's tests in this order (rather than at random),
  # stopping at the first that fails: those that start no server first,
  # then those on the process's shared server, and those that start
  # servers of their own last.
  if defined?(Mutant)
    FIRST = %w[test_used_by_name test_its_cpu_time test_a_value test_a_value_that_isnt_one test_what_a_reading_allocates test_ready
      test_a_flush_closes_its_connection test_its_statistics test_its_errors test_its_statistics_errors
      test_its_statistics_in_pieces].freeze
    LAST = %w[test_the_server_from_the_environment test_a_server_that_doesnt_start test_a_server_of_the_workers_own test_its_options
      test_the_connection].freeze

    def self.runnable_methods
      super.sort_by { |name| [FIRST.index(name) || (FIRST.size + (LAST.index(name)&.succ || 0)), name] }
    end
  end

  # The plugin registers itself as :memcached, and c.use configures Duel
  # for it once: a server for each worker, and its metrics (its CPU time
  # too, when asked for).
  def test_used_by_name
    config = Duel::Config.new(@dir)
    connection = config.use(:memcached)

    assert_same Duel::Memcached, Duel.plugins.fetch(:memcached)
    assert_instance_of Duel::InWorker, connection
    assert_same connection, config.use(:memcached)
    assert_equal [:memcached], config.plugins
    assert_equal [1, 0, 1], [config.prepares.fetch(:worker).size, config.prepares.fetch(:version).size, config.in_workers.size]
    assert_equal [Duel::Memcached::METRICS.keys], config.metrics.map { |metric| metric.measures.keys }
    assert_equal [Duel::Memcached::METRICS.keys, ["memcached_cpu"]], Duel::Config.new(@dir).tap { |c| c.use(:memcached, cpu: true) }
      .metrics.map { |metric| metric.measures.keys }
  end

  def test_a_server_of_the_workers_own
    socket = worker(config) do |env|
      socket = env.fetch("DUEL_MEMCACHED_SERVERS")

      assert_equal socket, env.fetch("MEMCACHE_SERVERS")
      assert_equal "memcached.sock", File.basename(socket)
      assert File.absolute_path?(socket), "in the worker's directory"
      assert Duel::Memcached::Connection.ready?(socket)
      assert_equal ["1", (32 << 20).to_s], @connection.value.stats.values_at("threads", "limit_maxbytes")
      socket
    end

    refute Duel::Memcached::Connection.ready?(socket), "stopped with the worker"
  end

  def test_its_options
    worker(config(args: ["-m", "8"], env: %w[CACHE_SERVERS])) do |env|
      assert_equal %w[CACHE_SERVERS DUEL_MEMCACHED_SERVERS], env.keys.sort
      assert_equal (8 << 20).to_s, @connection.value.stats.fetch("limit_maxbytes"), "its own -m wins"
    end
  end

  def test_a_server_that_doesnt_start
    error = assert_raises(Duel::Failed) { Duel::Testing.prepare(config(server: "false")) { flunk "started" } }

    assert_equal "candidate-1's resource: false exited before it was ready", error.message
  end

  def test_the_server_from_the_environment
    ENV["DUEL_MEMCACHED_SERVER"] = "false"
    error = assert_raises(Duel::Failed) { Duel::Testing.prepare(config) { flunk "started" } }

    assert_equal "candidate-1's resource: false exited before it was ready", error.message
  ensure
    ENV.delete("DUEL_MEMCACHED_SERVER")
  end

  def test_measures_what_memcached_did
    config = self.config
    measured = shared do |env|
      cache = UNIXSocket.new(env.fetch("MEMCACHE_SERVERS"))
      Duel::Testing.measure(config) do
        cache.write("set k 0 0 1\r\nv\r\n") # 16 bytes
        cache.gets                         # STORED: 8
        cache.write("get k nope\r\n")      # 12, two keys
        3.times { cache.gets }             # VALUE k 0 1, v, END: 13 + 3 + 5
        cache.write("delete nope\r\n")     # 13
        cache.gets                         # NOT_FOUND: 11
      end
    ensure
      cache&.close
    end

    # (No memcached_cpu unless it's asked for.)
    assert_equal({"memcached_operations" => 4, "memcached_misses" => 2, "memcached_bytes" => 16 + 8 + 12 + 21 + 13 + 11}, measured)
    assert_equal [%w[operation operations], %w[miss misses], %w[B B]], config.metrics.first.settings.values.map { |s| s.values_at(:unit, :plural) }
  end

  # What the plugin's own connection does isn't counted in bytes: its
  # readings, whose length varies. A flush is any client's: an operation,
  # and its bytes.
  def test_its_own_traffic_isnt_counted
    config = self.config
    measured = shared do
      client = Duel::Memcached::Connection.new(Duel::Memcached.servers)
      Duel::Testing.measure(config) do |sample|
        sample.untimed { Duel::Memcached.flush } # (not counted)
        5.times { Duel::Memcached.stats(@connection.value) }
        client.flush_all
      end
    ensure
      client&.close
    end

    assert_equal({"memcached_operations" => 1, "memcached_misses" => 0, "memcached_bytes" => "flush_all\r\nOK\r\n".bytesize}, measured)
  end

  def test_its_cpu_time_when_asked_for
    config = self.config(cpu: true)
    measured = shared do
      Duel::Testing.measure(config) { 200.times { @connection.value.stats } }
    end

    assert_equal({"memcached_cpu" => {kind: :ratio, unit: "µs", floor: 300, limit: 1.05, unit_ns: 1000, across: false}},
      config.metrics.last.settings.transform_values { |s| s.slice(:kind, :unit, :floor, :limit, :unit_ns, :across) })
    assert_operator measured.fetch("memcached_cpu"), :>, 0
    assert_equal 0, measured.fetch("memcached_bytes"), "its readings are the plugin's own too"
  end

  # User and system time, in microseconds.
  def test_its_cpu_time
    connection = Struct.new(:stats_reply).new("STAT pid 1\r\nSTAT rusage_user 0.012345\r\nSTAT rusage_system 1.000020\r\nEND\r\n")

    assert_equal 1_012_365, Duel::Memcached.cpu_time(connection)
  end

  # A statistic's value, read from the reply in place: a whole number, or
  # seconds with their decimals (microseconds, without the point).
  def test_a_value
    stats = "STAT a 0\r\nSTAT b 1234567890\r\nSTAT c 1.000020\r\nSTAT ab 7\r\nEND\r\n"

    assert_equal [0, 1_234_567_890, 1_000_020, 7], %w[a b c ab].map { |name| Duel::Memcached.value(stats, name) }
    assert_equal 1_234_567_897, Duel::Memcached.sum(stats, %w[b ab])
    assert_same Duel::Memcached::NEEDLES["a"], Duel::Memcached::NEEDLES["a"], "made once"
    assert_equal "STAT a ", Duel::Memcached::NEEDLES["a"]
  end

  # One that isn't there, or isn't a number, fails.
  def test_a_value_that_isnt_one
    error = assert_raises(KeyError) { Duel::Memcached.value("STAT ab 1\r\nEND\r\n", "a") }

    assert_equal 'key not found: "a"', error.message
    ["", "x", "-1", "1x", ".5", "1.", "1.x", "1 2", "1\n"].each do |value|
      error = assert_raises(ArgumentError, value) { Duel::Memcached.value("STAT a #{value}\r\nSTAT b 1\r\nEND\r\n", "a") }

      assert_equal "memcached: a isn't a number", error.message
    end
  end

  # Reading the statistics for the metrics allocates only the Hash they
  # make (CRuby's count): the reply is read into the connection's own
  # buffer, and each value read in place. (Over a socket of the test's
  # own, each reply written to it first: no server runs meanwhile.)
  def test_what_a_reading_allocates
    skip "CRuby's allocation count" unless RUBY_ENGINE == "ruby"
    reply = File.read(File.expand_path("../duel/fixtures/stats.txt", __dir__)).gsub("\n", "\r\n").freeze
    connected do |memcached, server|
      assert_equal 0, allocations { server.syswrite(reply) && memcached.stats_reply }
      assert_equal 0, allocations { server.syswrite(reply) && Duel::Memcached.cpu_time(memcached) }
      assert_equal 1, allocations { server.syswrite(reply) && Duel::Memcached.stats(memcached) }
      assert_operator allocations { server.syswrite(reply) && memcached.stats }, :<=, 3 * reply.count("\n")
    end
  end

  # The helpers need only the worker's environment: Duel::Memcached.flush
  # opens a connection of its own.
  def test_for_benchmarks
    shared do |env|
      cache = UNIXSocket.new(env.fetch("MEMCACHE_SERVERS"))
      cache.write("set k 0 0 1\r\nv\r\n")
      cache.gets

      assert_equal env.fetch("DUEL_MEMCACHED_SERVERS"), Duel::Memcached.servers
      assert_equal "OK", Duel::Memcached.flush
      cache.write("get k\r\n")

      assert_equal "END\r\n", cache.gets, "flushed"
    ensure
      cache&.close
    end
  end

  def test_a_flush_closes_its_connection
    ENV["DUEL_MEMCACHED_SERVERS"] = File.join(@dir, "fake.sock")
    sent, closed = fake_server("OK\r\n") { Duel::Memcached.flush }

    assert_equal "flush_all\r\n", sent
    assert closed
  ensure
    ENV.delete("DUEL_MEMCACHED_SERVERS")
  end

  # While a benchmark is measured, a flush would be counted (an
  # operation, and its bytes): it fails, and flushes nothing.
  def test_a_flush_measured
    config = self.config
    shared do |env|
      cache = UNIXSocket.new(env.fetch("MEMCACHE_SERVERS"))
      cache.write("set k 0 0 1\r\nv\r\n")
      cache.gets
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::Memcached.flush } }

      assert_equal "Duel::Memcached.flush: in setup or untimed only (it would be counted)", error.message
      cache.write("get k\r\n")

      assert_equal "VALUE k 0 1\r\n", cache.gets, "not flushed"
    ensure
      cache&.close
    end
  end

  def test_the_connection
    memcached = Duel::Testing.prepare(config) do |env|
      memcached = Duel::Memcached::Connection.new(env.fetch("MEMCACHE_SERVERS"))

      assert_equal "OK", memcached.flush_all
      assert_match(/\A\d+\z/, memcached.stats.fetch("pid"))
      assert_equal "flush_all\r\nOK\r\nstats\r\n".bytesize, memcached.own, "its flush, its reply, and its stats command"
      memcached.send(:request, "nope\r\n")
      error = assert_raises(RuntimeError) { memcached.send(:reply) }
      assert_equal "memcached: ERROR", error.message
      memcached
    end

    assert_raises(IOError, Errno::EPIPE, Errno::ECONNRESET) { memcached.stats }
    refute Duel::Memcached::Connection.ready?(File.join(@dir, "nothing.sock"))
  end

  # The plugin's connection (what c.use returns) is opened in workers
  # (Config#in_worker), not by the runner, which loads .duel.rb too, and
  # closed as they end.
  def test_outside_a_worker
    connection = shared_worker(config) { @connection.value }

    assert_raises(IOError) { connection.stats }
    error = assert_raises(Duel::Error) { @connection.value }

    assert_match(/made in each worker only/, error.message)
  end

  # Statistics as memcached sends them: a value can have spaces.
  def test_its_statistics
    stats = nil
    sent, = fake_server("STAT pid 42\r\nSTAT version 1.6.0 (fake)\r\nEND\r\n") do |path|
      memcached = Duel::Memcached::Connection.new(path)
      stats = memcached.stats
    ensure
      memcached&.close
    end

    assert_equal "stats\r\n", sent
    assert_equal({"pid" => "42", "version" => "1.6.0 (fake)"}, stats)
  end

  # A reply read in pieces, as they come (a value can end in END), and
  # one with no statistics.
  def test_its_statistics_in_pieces
    {["STAT a 1\r\nST", "AT b xEND\r\n", "STAT c 3\r", "\nEND\r", "\n"] => {"a" => "1", "b" => "xEND", "c" => "3"},
     ["END\r\n"] => {}}.each do |reply, expected|
      stats = nil
      fake_server(reply) do |path|
        memcached = Duel::Memcached::Connection.new(path)
        stats = memcached.stats
      ensure
        memcached&.close
      end

      assert_equal expected, stats
    end
  end

  # An error for stats, whole or in pieces, fails, as does a server that
  # hangs up in the middle of a reply.
  def test_its_statistics_errors
    {["ERROR\r\n"] => [RuntimeError, "memcached: ERROR"],
     ["SERVER_ERROR out", " of memory\r", "\n"] => [RuntimeError, "memcached: SERVER_ERROR out of memory"],
     ["STAT a 1\r\n"] => [IOError, "memcached closed the connection"],
     ["END"] => [IOError, "memcached closed the connection"]}.each do |reply, (error_class, message)|
      fake_server(reply, hang_up: true) do |path|
        memcached = Duel::Memcached::Connection.new(path)
        error = assert_raises(error_class) { memcached.stats_reply }

        assert_equal [error_class, message], [error.class, error.message]
      ensure
        memcached&.close
      end
    end
  end

  # Errors, and a server that hangs up.
  def test_its_errors
    {"CLIENT_ERROR bad command line format\r\n" => RuntimeError, "SERVER_ERROR out of memory\r\n" => RuntimeError,
     "" => IOError}.each do |reply, error_class|
      fake_server(reply, hang_up: true) do |path|
        memcached = Duel::Memcached::Connection.new(path)
        error = assert_raises(error_class) { memcached.flush_all }

        assert_equal reply.empty? ? "memcached closed the connection" : "memcached: #{reply.chomp}", error.message
      ensure
        memcached&.close
      end
    end
  end

  # Ready only when the server answers with its version; it hangs up
  # either way.
  def test_ready
    {"VERSION 1.6.0\r\n" => true, "ERROR\r\n" => false}.each do |reply, ready|
      answer = nil
      sent, closed = fake_server(reply) { |path| answer = Duel::Memcached::Connection.ready?(path) }

      assert_equal ready, answer, reply
      assert_equal "version\r\n", sent
      assert closed
    end
    fake_server("", hang_up: true) { |path| refute Duel::Memcached::Connection.ready?(path) }
  end

  # Its metrics are costly to read, so a benchmark with an
  # around_iteration hook reads them only as each sample starts and
  # stops, and what the hook sends the server (deleting what each
  # iteration wrote) is learned in each worker and taken away: only the
  # iterations' operations and bytes are counted.
  def test_an_around_iteration_hook_left_out
    config = self.config(cpu: true)
    measured = Duel::Testing.prepare(config) do |env|
      cache = UNIXSocket.new(env.fetch("MEMCACHE_SERVERS"))
      around = lambda do |iteration|
        iteration.call
        cache.write("delete k\r\n")
        cache.gets
      end
      Duel::Testing.measure(config, n: 20, around_iteration: around) do
        cache.write("set k 0 0 1\r\nv\r\n") # 16 bytes
        cache.gets                         # STORED: 8
      end
    ensure
      cache&.close
    end

    assert_equal [true, true], config.metrics.map(&:costly?)
    assert_equal [20, 0, 20 * (16 + 8)], measured.values_at("memcached_operations", "memcached_misses", "memcached_bytes")
  end

  private

  # Objects the block allocates, counted the second time it runs: what's
  # made only the first time (Ruby's caches for each call, say) isn't.
  def allocations
    2.times.map do
      before = GC.stat(:total_allocated_objects)
      yield
      GC.stat(:total_allocated_objects) - before
    end.last
  end

  # Yields a connection, and the other end of its socket (for the test
  # to write the server's replies to); closes both after.
  def connected
    path = File.join(@dir, "fake.sock")
    listener = UNIXServer.new(path)
    memcached = Duel::Memcached::Connection.new(path)
    server = listener.accept
    yield memcached, server
  ensure
    [memcached, server, listener].each { |socket| socket&.close }
  end

  # A server on a socket in @dir of its own that reads a request and
  # writes +reply+ (an Array: a piece at a time, a little apart), then
  # hangs up (+hang_up+) or waits a second for the client to. Yields the
  # socket's path; returns what it was sent, and whether the client hung
  # up.
  def fake_server(reply, hang_up: false)
    path = File.join(@dir, "fake.sock")
    server = UNIXServer.new(path)
    thread = Thread.new do
      client = server.accept
      sent = client.readpartial(1024)
      Array(reply).each_with_index do |piece, i|
        sleep 0.05 if i.positive?
        client.write(piece)
      end
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
class MemcachedComparisonTest < PluginTest
  # Whole comparisons: the same code passes; code that stores more keys
  # fails on its operations (and bytes).
  def test_comparisons
    base = project("base", 1)
    same = Duel::Testing.compare(base, project("same", 1))

    assert_predicate same, :passed?, same.output
    assert_equal 1, same["store"].counted.fetch("memcached_operations").then { |c| c.fetch("candidate") / c.fetch("n") }
    more = Duel::Testing.compare(base, project("more", 2))

    assert_equal %w[memcached_operations memcached_bytes], more["store"].regressed & %w[memcached_operations memcached_bytes], more.output
    assert_includes more.output, "memcached_operations: 1 operation → 2 operations an iteration"
    assert_match(/^  memcached_bytes: [\d.]+ B → [\d.]+ B an iteration$/, more.output)
  end
end
