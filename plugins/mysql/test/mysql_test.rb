# frozen_string_literal: true

require_relative "test_helper"

class MySQLTest < PluginTest
  cover "Duel::MySQL*"

  # Mutant runs a mutation's tests in this order (rather than at random),
  # stopping at the first that fails: those that start no server first,
  # then those on the process's shared server, and those that start
  # servers of their own (the slowest last) after.
  if defined?(Mutant)
    FIRST = %w[test_registered test_by_measure test_texts_read_once test_readings_not_one_after_the_other test_what_ran_since_the_last_reading
      test_finding_the_server test_no_server test_initializing_that_fails].freeze
    LAST = %w[test_a_reading_waits_for_other_statements test_a_server_of_the_workers_own test_a_server_that_doesnt_start test_its_options
      test_a_data_directory_made_once test_a_reading_waits_for_clients_only test_a_server_on_a_port test_on_a_port_on_windows
      test_a_wrong_database test_comparisons].freeze

    def self.runnable_methods
      super.sort_by { |name| [FIRST.index(name) || (FIRST.size + (LAST.index(name)&.succ || 0)), name] }
    end
  end

  # The plugin registers itself, as c.use :mysql finds it, and is
  # configured once (one server for each worker), however many times it's
  # used: what it returns is its connection, each worker's.
  # Its connections are a client of its own: it loads no MySQL gem (in
  # trilogy's repository, or mysql2's, the version's would be measured).
  def test_needs_no_client_gem
    loaded = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", <<~RUBY], &:read)
      require "duel/mysql"
      print $LOADED_FEATURES.grep(/trilogy|mysql2/).inspect
    RUBY

    assert_equal "[]", loaded
  end

  def test_registered
    config = Duel::Config.new(@dir)
    connection = config.use(:mysql)

    assert_same Duel::MySQL, Duel.plugins.fetch(:mysql)
    assert_equal 450 << 20, config.worker_memory, "what each worker's server takes, for Duel to fit them"
    assert_instance_of Duel::InWorker, connection
    assert_same connection, config.use(:mysql)
    assert_equal [1, 1, [:mysql]], [config.prepares.fetch(:worker).size, config.metrics.size, config.plugins]
  end

  # Its options are its own: none from a my.cnf (~/.my.cnf here).
  def test_a_server_of_the_workers_own
    unix!
    File.write(File.join(@dir, ".my.cnf"), "[mysqld]\nmax_connections=7\n")
    asked = []
    shutdown = Duel::MySQL.method(:shutdown)
    socket = with_env("HOME" => @dir) do
      replacing(Duel::MySQL, :shutdown, ->(address) { asked << [address, Duel::MySQL::Connection.ping(address)] and shutdown.call(address) }) do
        prepare(config(tcp: false)) do |env|
          socket = env.fetch("DUEL_MYSQL_SOCKET")
          dir = File.dirname(socket)
          url = "mysql2://root@localhost/duel?socket=#{socket}"

          assert_equal "mysqld.sock", File.basename(socket)
          assert_equal url, env.fetch("DUEL_MYSQL_URL")
          assert_equal url, env.fetch("DATABASE_URL")
          assert_equal [["duel", 0, 0, dir, 2, 151]],
            query("SELECT DATABASE(), @@skip_networking - 1, @@log_bin, @@tmpdir, @@innodb_fast_shutdown, @@max_connections")
          assert_path_exists File.join(dir, "mysqld.pid")
          assert Duel::MySQL::Connection.ping(socket)
          assert_equal [["root@localhost"]], Duel::MySQL.execute("SELECT CURRENT_USER()").rows
          socket
        end
      end
    end

    refute Duel::MySQL::Connection.ping(socket), "stopped with the worker"
    assert_equal [[socket, true]], asked, "by SHUTDOWN first, as it stops (while it's up)"
    assert_nil Duel::MySQL.shutdown(socket), "nothing to ask once it's gone"
  end

  # SHUTDOWN stops the server (it answers first, or as it goes).
  def test_shutdown
    prepare(config) do
      address = Duel::MySQL.address
      Duel::MySQL.shutdown(address)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      sleep 0.1 while Duel::MySQL::Connection.ping(address) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      refute Duel::MySQL::Connection.ping(address), "gone"
    end
  end

  def test_its_options
    unix!
    config = config(server: MYSQLD, args: ["--max-connections=17"], env: %w[PRIMARY_URL], tcp: false,
      scheme: "trilogy", setup: "CREATE TABLE items (id int); INSERT INTO items VALUES (1), (2)")
    prepare(config) do |env|
      assert_equal %w[DUEL_MYSQL_SOCKET DUEL_MYSQL_URL PRIMARY_URL], env.keys.sort
      assert_equal "trilogy://root@localhost/duel?socket=#{Duel::MySQL.socket}", env.fetch("PRIMARY_URL")
      assert_equal [[17, 2, 1]], query("SELECT @@max_connections, (SELECT COUNT(*) FROM items), @@skip_networking"), "no network"
    end
  end

  def test_a_server_that_doesnt_start
    error = assert_raises(Duel::Failed) { prepare(config(args: ["--no-such-option"])) { flunk "started" } }

    assert_match(/\Ahead-1's resource: mysqld(\.exe)? exited before it was ready\n.*no-such-option/m, error.message)
  end

  def test_no_server
    error = assert_raises(Duel::Failed) { prepare(config(server: "no-such-mysqld")) { flunk "started" } }

    assert_equal "head-1's resource: no no-such-mysqld on the PATH (give it as server:, or DUEL_MYSQL_SERVER)", error.message
  end

  def test_finding_the_server
    unix!
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "mysqld"), "")
    File.chmod(0o755, File.join(bin, "mysqld"))

    assert_equal File.join(bin, "mysqld"), Duel::MySQL::DataDir.find_server("mysqld", [@dir, bin].join(File::PATH_SEPARATOR))
    assert_equal File.join(bin, "mysqld"), Duel::MySQL::DataDir.find_server(File.join(bin, "mysqld"), "")
    assert_nil Duel::MySQL::DataDir.find_server("mysqld", @dir)
    assert_nil Duel::MySQL::DataDir.find_server(File.join(@dir, "mysqld"), bin)
    with_env("PATH" => bin) { assert_equal File.join(bin, "mysqld"), Duel::MySQL::DataDir.find_server("mysqld"), "the PATH's" }
    with_env("PATH" => nil) { assert_nil Duel::MySQL::DataDir.find_server("mysqld"), "no PATH" }
    assert_equal File.join(bin, "mysqld"), Duel::MySQL::DataDir.find_server("mysqld", bin, exe: ".exe"), "without its .exe too"
  end

  # Windows's, by its .exe (this system's suffix, by default).
  def test_finding_the_server_by_its_exe
    windows = File.join(@dir, "windows")
    FileUtils.mkdir_p(windows)
    File.write(File.join(windows, "mysqld.exe"), "")
    File.chmod(0o755, File.join(windows, "mysqld.exe"))

    assert_equal File.join(windows, "mysqld.exe"), Duel::MySQL::DataDir.find_server("mysqld", windows, exe: ".exe"), "Windows's, by its .exe"
    assert_equal File.join(windows, "mysqld.exe"), Duel::MySQL::DataDir.find_server(File.join(windows, "mysqld"), "", exe: ".exe")
    assert_nil Duel::MySQL::DataDir.find_server("mysqld", windows, exe: ""), "no .exe, off Windows"
    exe = Duel::MySQL::DataDir::EXE
    begin
      Duel::MySQL::DataDir.send(:remove_const, :EXE)
      Duel::MySQL::DataDir.const_set(:EXE, ".exe")

      assert_equal File.join(windows, "mysqld.exe"), Duel::MySQL::DataDir.find_server("mysqld", windows), "EXE's, by default"
    ensure
      Duel::MySQL::DataDir.send(:remove_const, :EXE)
      Duel::MySQL::DataDir.const_set(:EXE, exe)
    end

    assert_equal RbConfig::CONFIG["EXEEXT"], Duel::MySQL::DataDir::EXE
  end

  # The first worker's data directory is initialized (Resource#cached);
  # the others copy it.
  def test_a_data_directory_made_once
    unix!
    config = self.config
    cache = own_cache
    made = prepare(config, cache:, name: "base-1") { |env| File.exist?(log(env, "mysqld-initialize.log")) }
    made_once = Dir.children(cache)

    server = File.realpath(MYSQLD)
    key = Digest::SHA256.hexdigest("#{server}\0#{File.mtime(server).to_f}")[0, 16]

    assert made, "initialized"
    assert_equal ["mysql-#{Duel::MySQL::VERSION}-#{key}"], made_once, "for the real server, by its path and time"
    link = File.join(@dir, "mysqld")
    File.symlink(MYSQLD, link)
    prepare(self.config(server: link, tcp: false), cache:) do |env| # (a link to it is the same server)
      refute_path_exists log(env, "mysqld-initialize.log")
      assert_equal [["duel"]], query("SELECT DATABASE()")
    end

    assert_equal made_once, Dir.children(cache), "copied, not made again"
  end

  def test_initializing_that_fails
    unix!
    server = File.join(@dir, "mysqld")
    File.write(server, "#!/bin/sh\necho \"mysqld: can't\"\nexit 1\n")
    File.chmod(0o755, server)
    cache = own_cache
    [config(server:), with_env("DUEL_MYSQL_SERVER" => server) { config }].each do |config|
      error = assert_raises(Duel::Failed) { prepare(config, cache:) { flunk "started" } }

      assert_equal "head-1's resource: mysqld-initialize exited with 1\nmysqld: can't\n", error.message
      assert_empty Dir.children(cache), "nothing left behind"
    end
  end

  def test_measures_what_mysql_did
    config = self.config
    measured, nothing = shared_worker(config) do
      db = client
      db.query("CREATE TABLE items (id int PRIMARY KEY, name text)")
      db.query("INSERT INTO items VALUES #{(1..500).map { |i| "(#{i}, 'n')" }.join(", ")}")
      [Duel::Testing.measure(config) do
        3.times { |i| db.query("SELECT name FROM items WHERE id = #{i}") }
        db.query("UPDATE items SET name = 'm' WHERE id <= 10")
      end, Duel::Testing.measure(config) {}]
    ensure
      db&.close
    end

    assert_equal [["mysql_queries", :counted, "query", "queries", 1, true], ["mysql_rows", :counted, "row", "rows", 1, true],
      ["mysql_rows_examined", :counted, "row", "rows", 1, true], ["mysql_time", :ratio, "µs", "µs", 1000, false]],
      config.metrics.first.settings.map { |name, s| [name, *s.values_at(:kind, :unit, :plural, :unit_ns, :across)] }
    assert_equal 4, measured.fetch("mysql_queries"), "the readings' own left out"
    assert_equal 2 + 10, measured.fetch("mysql_rows"), "ids 1 and 2, and the 10 updated"
    assert_equal 2 + 10, measured.fetch("mysql_rows_examined")
    assert_operator measured.fetch("mysql_time"), :>, 0
    assert_equal({"mysql_queries" => 0, "mysql_rows" => 0, "mysql_rows_examined" => 0, "mysql_time" => 0}, nothing)
  end

  # What's untimed isn't measured, but what's measured before it is.
  def test_untimed
    config = self.config
    measured = shared do
      db = client
      Duel::Testing.measure(config) do |sample|
        db.query("SELECT 1")
        sample.untimed { db.query("SELECT 2, 3") }
        db.query("SELECT 1")
      end
    ensure
      db&.close
    end

    assert_equal 2, measured.fetch("mysql_queries")
    assert_equal 2, measured.fetch("mysql_rows")
  end

  # A regression is explained by the statements that did the most of it,
  # in the sample but its untimed blocks (and not the plugin's own
  # readings): how many times each ran an iteration, and each one's share
  # of the rest.
  def test_details
    config = self.config
    shared_worker(config) do
      db = client
      db.query("CREATE TABLE items (id int, name text)")
      db.query("INSERT INTO items VALUES #{(1..1000).map { |i| "(#{i}, 'n')" }.join(", ")}")
      details = Duel::Testing.measure(config, n: 2) do |sample|
        db.query("SELECT 2")
        sample.untimed { db.query("SELECT 1") }
        2.times { db.query("SELECT name FROM items WHERE id = 7") }
        db.query("SELECT 1 AS #{"a" * 40}, 2 AS #{"b" * 40}") # (shortened)
        db.query("SELECT 1 FROM items WHERE false")
      end.details
      long = "SELECT ? AS `#{"a" * 40}` , ? AS `#{"b" * 16}…"

      assert_equal %w[mysql_queries mysql_rows mysql_rows_examined mysql_time], details.keys
      assert_equal "an iteration: 1× SELECT NAME FROM `items` WHERE `id` = ?; 0.5× SELECT ?; 0.5× #{long}",
        details.fetch("mysql_queries"), "what's before the untimed block, not the untimed one's"
      assert_equal "SELECT NAME FROM `items` WHERE `id` = ? (50%); SELECT ? (25%); #{long} (25%)", details.fetch("mysql_rows")
      assert_equal "SELECT NAME FROM `items` WHERE `id` = ? (99.9%); SELECT ? (0.05%); #{long} (0.05%)", details.fetch("mysql_rows_examined"),
        "(MySQL's SELECT without FROM examines a row)"
      assert_match(/SELECT NAME FROM `items` WHERE `id` = \? \([\d.]+%\)/, details.fetch("mysql_time"))
      details = Duel::Testing.measure(config) { db.query("SELECT 1 FROM items WHERE false") }.details

      assert_equal({"mysql_queries" => "an iteration: 1× SELECT ? FROM `items` WHERE FALSE"}, details.slice("mysql_queries", "mysql_rows"))
      assert_empty Duel::Testing.measure(config) {}.details, "nothing: the readings are left out"
    ensure
      db&.close
    end
  end

  # A scan examines every row of a table; an index, the ones it finds.
  def test_rows_examined_tell_a_missing_index
    shared_worker do
      db = client
      db.query("CREATE TABLE items (id int, name text)")
      db.query("INSERT INTO items VALUES #{(1..1000).map { |i| "(#{i}, 'n')" }.join(", ")}")
      find = lambda do
        before = Duel::MySQL.stats(@connection.value)
        db.query("SELECT name FROM items WHERE id = 7")
        Duel::MySQL.stats(@connection.value).fetch("mysql_rows_examined") - before.fetch("mysql_rows_examined")
      end

      assert_equal 1000, find.call
      db.query("CREATE INDEX by_id ON items (id)")

      assert_equal 1, find.call
    ensure
      db&.close
    end
  end

  # Statements on other connections count, and stay counted once they've
  # closed (but the helpers' connections close without quitting).
  def test_other_connections
    shared_worker do
      connection = @connection.value
      before = Duel::MySQL.stats(connection).fetch("mysql_queries")
      query("SELECT 1")

      assert_equal [[0]], alone(connection)
      assert_equal 2, Duel::MySQL.stats(connection).fetch("mysql_queries") - before, "SELECT 1, and quitting"
      before = Duel::MySQL.stats(connection).fetch("mysql_queries")
      Duel::MySQL.execute("SELECT 1")

      assert_equal [[0]], alone(connection)
      assert_equal 1, Duel::MySQL.stats(connection).fetch("mysql_queries") - before, "SELECT 1"
    end
  end

  # MySQL answers a statement before it's counted: a reading waits until
  # no other connection is running one, a second at most.
  def test_a_reading_waits_for_other_statements
    shared_worker do
      connection = @connection.value
      db = client
      sleeping = Thread.new { db.query("SELECT SLEEP(5)") }
      sleep 0.01 until query("SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_INFO = 'SELECT SLEEP(5)'") == [[1]]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Duel::MySQL.stats(connection)
      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator waited, :>=, 1.0
      assert_operator waited, :<, 4.0, "not until it's done"
      sleeping.join
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Duel::MySQL.stats(connection)

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0, "none running"
    ensure
      sleeping&.join
      db&.close
    end
  end

  # The server's event threads (the event scheduler's, and each event's
  # while it runs) aren't clients: a reading doesn't wait for them, but
  # for clients still.
  def test_a_reading_waits_for_clients_only
    worker(config(args: ["--event-scheduler=ON"])) do
      connection = @connection.value
      Duel::MySQL.execute("CREATE EVENT sleeping ON SCHEDULE EVERY 1 SECOND DO DO SLEEP(3)")
      sleep 0.01 until query("SELECT COUNT(*) FROM performance_schema.threads WHERE NAME = 'thread/sql/event_worker'") != [[0]]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Duel::MySQL.stats(connection)

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5, "the event scheduler, and an event, running"
      db = client
      sleeping = Thread.new { db.query("SELECT SLEEP(2)") }
      sleep 0.01 until query("SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_INFO = 'SELECT SLEEP(2)'") == [[1]]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Duel::MySQL.stats(connection)

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 1.0, "a client's statement"
    ensure
      sleeping&.join
      db&.close
    end
  end

  # The helpers need only the worker's environment: they open a
  # connection of their own.
  def test_for_benchmarks
    shared do |env|
      Duel::MySQL.execute("CREATE TABLE items (id int AUTO_INCREMENT PRIMARY KEY, name text); INSERT INTO items (name) VALUES ('a'); " \
        "CREATE TABLE notes (item_id int, FOREIGN KEY (item_id) REFERENCES items (id)); INSERT INTO notes VALUES (1)")

      assert_equal env.fetch("DUEL_MYSQL_URL"), Duel::MySQL.url
      assert_equal [[1, "a"]], query("SELECT * FROM items")
      assert_equal [[2]], Duel::MySQL.execute("SELECT 1; SELECT 2").rows, "the last statement's result"
      Duel::MySQL.reset # (items too, though notes refer to it)
      Duel::MySQL.execute("INSERT INTO items (name) VALUES ('b')")

      assert_equal [[1, "b"]], query("SELECT * FROM items"), "emptied, its AUTO_INCREMENT restarted"
    end
  end

  # While a benchmark is measured, what the helpers run would be
  # counted: they fail, and run nothing.
  def test_helpers_measured
    config = self.config
    shared do
      Duel::MySQL.execute("CREATE TABLE items (id int); INSERT INTO items VALUES (1)")
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::MySQL.execute("DELETE FROM items") } }

      assert_equal "Duel::MySQL.execute: in setup or untimed only (it would be counted)", error.message
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::MySQL.reset } }

      assert_equal "Duel::MySQL.reset: in setup or untimed only (it would be counted)", error.message
      assert_equal [[1]], query("SELECT count(*) FROM items")
      Duel::Testing.measure(config) { |sample| sample.untimed { Duel::MySQL.reset } }

      assert_equal [[0]], query("SELECT count(*) FROM items")
    end
  end

  # Their connections are closed once they've run (ping's too).
  def test_helpers_connections
    shared do
      GC.disable # (a connection left open would be closed when it's collected)
      Duel::MySQL.execute("SELECT 1")
      Duel::MySQL::Connection.ping(Duel::MySQL.address)
      db = client

      assert_equal [[0]], alone(db), "only the one asking"
    ensure
      db&.close
      GC.enable
    end
  end

  def test_reset_with_no_tables
    shared { assert_equal 0, Duel::MySQL.reset.count }
  end

  # The plugin's connection (what c.use returns) is opened in workers
  # (Config#in_worker), not by the runner, which loads .duel.rb too, and
  # closed as they end.
  def test_outside_a_worker
    config = self.config
    shared do
      connection = Duel::Testing.in_worker(config) { @connection.value }

      assert_raises(IOError, "closed (the server's still up)") { connection.query("SELECT 1") }
    end
    error = assert_raises(Duel::Error) { @connection.value }

    assert_match(/made in each worker only/, error.message)
  end

  # A statement's numbers (or the server's) by measure: time in µs.
  def test_by_measure
    assert_equal({"mysql_queries" => 1, "mysql_rows" => 2, "mysql_rows_examined" => 3, "mysql_time" => 4.5},
      Duel::MySQL::Statements.by_measure([1, 2, 3, 4_500_000]))
  end

  # Statements by digest: their numbers, as performance_schema has them
  # (of those run since a time, but some), and texts. (A statement's
  # counted just after its client is answered: it's read once its
  # client's gone, which is after.)
  def test_statements
    shared_worker do
      query("SELECT SLEEP(0.01)")
      connection = @connection.value

      assert_equal [[0]], alone(connection)
      digest, other = Duel::MySQL.digests_of(connection, ["SELECT SLEEP(0.01)", "SELECT 1"])
      numbers, text = query(<<~SQL).then { |rows| [rows.map { |row| row.first(4) }.first, rows.first.last] }
        SELECT COUNT_STAR, SUM_ROWS_SENT + SUM_ROWS_AFFECTED, SUM_ROWS_EXAMINED, SUM_TIMER_WAIT, DIGEST_TEXT
        FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST = '#{digest}'
      SQL
      now = Process.clock_gettime(Process::CLOCK_REALTIME, :second)

      assert_equal [digest, *numbers], Duel::MySQL.digests(connection, now - 60, [other]).assoc(digest)
      assert_nil Duel::MySQL.digests(connection, now + 60, [other]).assoc(digest), "not run since"
      assert_nil Duel::MySQL.digests(connection, now - 60, [other, digest]).assoc(digest), "left out"
      assert_equal({digest => text}, Duel::MySQL.texts(connection, [digest]))
    end
  end

  # A reading reads the statements that ran since the one before, but
  # the plugin's own readings: only those changed.
  def test_reading_what_ran
    shared_worker do
      connection = @connection.value
      statements = Duel::MySQL::Statements.new(Data.define(:value).new(connection))
      db = client
      db.query("SELECT 4")
      first = statements.read.last
      db.query("SELECT 5")
      db.query("SELECT 6")
      ran = statements.read.last
      nothing = statements.read.last
      digest = Duel::MySQL.digests_of(connection, ["SELECT 5"]).fetch(0)
      own = Duel::MySQL.digests_of(connection, [Duel::MySQL::BUSY, Duel::MySQL::STATS, format(Duel::MySQL::DIGESTS, 0, "''")])

      assert_equal [digest, 1, 1, 1], first.rows.fetch(digest).first(4), "all of them, first"
      assert_empty first.rows.keys & own
      assert_equal [digest], ran.changed
      assert_same first.rows, ran.previous
      assert_equal [digest, 3, 3, 3], ran.rows.fetch(digest).first(4)
      assert_same ran.rows, nothing.rows, "none changed"
      assert_empty nothing.changed
    ensure
      db&.close
    end
  end

  # Statements' texts are read once each, and only of those that did
  # something in the stretches, all told: one with none shows its digest.
  # Ties are in the order of their texts.
  def test_texts_read_once
    read = []
    statements = Duel::MySQL::Statements.new(Data.define(:value).new(:connection))
    reading = Data.define(:context)
    rows = {"1" => ["1", 1, 1, 1, 1], "2" => ["2", 2, 2, 2, 2]}
    first = reading.new(Duel::MySQL::Statements::Reading.new(rows, {}, %w[1 2]))
    after = rows.merge("1" => ["1", 2, 1, 2, 2], "2" => ["2", 2, 1, 2, 2], "3" => ["3", 1, 0, 0, 0])
    second = reading.new(Duel::MySQL::Statements::Reading.new(after, rows, %w[1 2 3]))
    third = reading.new(Duel::MySQL::Statements::Reading.new(after.merge("1" => ["1", 3, 1, 2, 4], "9" => ["9", 1, 0, 0, 0]), after, %w[1 9]))
    texts = ->(_connection, digests) { read << digests and digests.grep_v("9").to_h { |digest| [digest, {"1" => "SELECT ?", "3" => "DELETE FROM t"}.fetch(digest)] } }
    replacing(Duel::MySQL, :texts, texts) do
      assert_equal({"mysql_queries" => "an iteration: 1× SELECT ?; 0.5× 9; 0.5× DELETE FROM t", "mysql_rows_examined" => "SELECT ? (100%)",
                    "mysql_time" => "SELECT ? (100%)"}, statements.details([[first, second], [second, third]], 2))
      assert_equal({"mysql_queries" => "an iteration: 1× SELECT ?"}, statements.details([[first, first],
        [second, reading.new(Duel::MySQL::Statements::Reading.new(after.merge("1" => ["1", 3, 1, 2, 2]), after, %w[1]))]], 1))
      assert_same Duel::MySQL::Statements::NONE, statements.details([[first, first], [third, third]], 1), "none ran"
    end

    assert_equal [%w[1 3 9]], read
  end

  # A stretch's readings one right after the other: the second says
  # which statements changed, and only those are looked at. Otherwise
  # (something read in between), every one is.
  def test_readings_not_one_after_the_other
    statements = Duel::MySQL::Statements.new(Data.define(:value).new(:connection))
    reading = Data.define(:context)
    rows = {"1" => ["1", 1, 2, 3, 4]}
    first = reading.new(Duel::MySQL::Statements::Reading.new(rows, {}, %w[1]))
    between = rows.merge("2" => ["2", 1, 1, 1, 1])
    # (Its rows have a statement it doesn't say changed: to tell which
    # it looks at.)
    stopped = reading.new(Duel::MySQL::Statements::Reading.new(between.merge("1" => ["1", 2, 4, 6, 8], "3" => ["3", 1, 1, 1, 1]), between, %w[1]))
    texts = ->(_connection, digests) { digests.to_h { |digest| [digest, "S#{digest}"] } }
    replacing(Duel::MySQL, :texts, texts) do
      assert_equal "an iteration: 1× S1", statements.details([[reading.new(Duel::MySQL::Statements::Reading.new(between, rows, %w[2])), stopped]], 1)
        .fetch("mysql_queries"), "one right after the other"
      assert_equal ["an iteration: 1× S1; 1× S2; 1× S3", "S1 (50%); S2 (25%); S3 (25%)"],
        statements.details([[first, stopped]], 1).values_at("mysql_queries", "mysql_rows")
      assert_equal "an iteration: 1× S1; 1× S3", statements.details([[reading.new(Duel::MySQL::Statements::Reading.new(between.dup, rows, %w[2])),
        stopped]], 1).fetch("mysql_queries"), "the same rows, but not the reading before"
    end
  end

  # A reading reads the statements run since a little before the reading
  # before it (all of them, first), but the plugin's own readings': those
  # that changed, in a copy of the reading before's rows (or those rows,
  # if none did).
  def test_what_ran_since_the_last_reading
    own = []
    asked = []
    rows = [[["a", 1, 1, 1, 1], ["b", 2, 0, 2, 2]], [["a", 1, 1, 1, 1], ["b", 3, 1, 2, 4], ["c", 1, 0, 0, 1]], [["a", 1, 1, 1, 1]], [],
      [["c", 2, 0, 0, 2]], [], []]
    statements = Duel::MySQL::Statements.new(Data.define(:value).new(:connection))
    empty = nil
    readings = replacing(Duel::MySQL, :totals, ->(_connection) { [1, 2, 3, 4_000_000] }) do
      replacing(Duel::MySQL, :digests_of, ->(connection, sql) { own << [connection, sql] and %w[x y z] }) do
        replacing(Duel::MySQL, :digests, ->(connection, since, digests) { asked << [connection, since, digests] and rows.shift }) do
          Array.new(6) do
            before = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
            [statements.read, [before - 1, Process.clock_gettime(Process::CLOCK_REALTIME, :second) - 1]]
          end.tap { empty = Duel::MySQL::Statements.new(Data.define(:value).new(:connection)).read.last }
        end
      end
    end
    first, second, third, fourth, fifth, sixth = readings.map { |(_, reading), _| reading }

    assert_equal [[:connection, [Duel::MySQL::BUSY, Duel::MySQL::STATS, format(Duel::MySQL::DIGESTS, 0, "''")]]] * 2, own, "once each"
    assert_equal({"mysql_queries" => 1, "mysql_rows" => 2, "mysql_rows_examined" => 3, "mysql_time" => 4.0}, readings.first.first.first)
    assert_equal [{"a" => ["a", 1, 1, 1, 1], "b" => ["b", 2, 0, 2, 2]}, {}, %w[a b]], [first.rows, first.previous, first.changed]
    assert_equal [{"a" => ["a", 1, 1, 1, 1], "b" => ["b", 3, 1, 2, 4], "c" => ["c", 1, 0, 0, 1]}, %w[b c]], [second.rows, second.changed]
    assert_same first.rows, second.previous
    assert_equal({"a" => ["a", 1, 1, 1, 1], "b" => ["b", 2, 0, 2, 2]}, first.rows, "not changed after")
    assert_equal [true, true, [], true], [third.rows.equal?(second.rows), third.previous.equal?(second.rows), third.changed, third.rows.frozen?],
      "none changed: the same rows"
    assert_equal [true, %w[c], true, false, true, [{}, {}, []]], [fourth.equal?(third), fifth.changed, sixth.rows.equal?(fifth.rows),
      sixth.equal?(third), sixth.previous.equal?(fifth.rows), [empty.rows, empty.previous, empty.changed]], "the last Reading, while none changed"
    assert_equal [[:connection, 0, %w[x y z]]] * 2, asked.values_at(0, -1), "all of them, first"
    asked[1, 5].zip(readings) { |(_, since, _), (_, times)| assert_includes times, since }
  end

  # Whole comparisons: the same code passes; code that sends MySQL more
  # queries fails on them (and the rows they return and examine).
  def test_comparisons
    base = project("base", 1)
    same = Duel::Testing.compare(base, project("same", 1), timeout: 120.0)

    assert_predicate same, :passed?, same.output
    assert_equal 1, same["find"].counted.fetch("mysql_queries").then { |c| c.fetch("candidate") / c.fetch("n") }
    more = Duel::Testing.compare(base, project("more", 2), timeout: 120.0)

    assert_equal %w[mysql_queries mysql_rows mysql_rows_examined], more["find"].regressed & %w[mysql_queries mysql_rows mysql_rows_examined],
      more.output
    assert_includes more.output, "mysql_queries: 1 query → 2 queries an iteration"
    assert_includes more.output, "mysql_queries (candidate): an iteration: 2× SELECT `id` FROM `items` WHERE `id` = ?", "explained"
    assert_includes more.output, "mysql_queries (baseline): an iteration: 1× SELECT `id` FROM `items` WHERE `id` = ?"
  end

  # Its metrics are costly to read, so a benchmark with an
  # around_iteration hook reads them only as each sample starts and
  # stops, and what the hook sends the server (a transaction's BEGIN and
  # ROLLBACK, rolling back what each iteration wrote) is learned in each
  # worker and taken away: only the iterations' queries and rows are
  # counted.
  def test_an_around_iteration_hook_left_out
    config = self.config
    measured = worker(config) do
      db = client
      db.query("CREATE TABLE items (id int)")
      around = lambda do |iteration|
        db.query("BEGIN")
        iteration.call
        db.query("ROLLBACK")
      end
      Duel::Testing.measure(config, n: 20, around_iteration: around) { db.query("INSERT INTO items VALUES (1), (2)") }
    ensure
      db&.close
    end

    assert_predicate config.metrics.first, :costly?
    assert_equal [20, 40], measured.values_at("mysql_queries", "mysql_rows")
  end

  # Unix's alone: a Unix socket's (Windows's MySQL has none), and the
  # tests' links and shell scripts.
  def unix! = (skip "Unix's alone: see the tcp tests" if Duel::Native::WINDOWS)

  # With +tcp+ (Windows's, by default): on a port of its own, of
  # 127.0.0.1's alone, its URL host and port, with no socket, which the
  # plugin's connections reach it on.
  def test_a_server_on_a_port
    address = prepare(config(tcp: true, env: %w[PRIMARY_URL])) do |env|
      url = env.fetch("DUEL_MYSQL_URL")
      port = url[/:(\d+)\//, 1]

      assert_equal "mysql2://root@127.0.0.1:#{port}/duel", url
      assert_equal %w[DUEL_MYSQL_URL PRIMARY_URL], env.keys.sort, "no socket"
      assert_equal "127.0.0.1:#{port}", Duel::MySQL.address
      networking, bind, listening, database, socket = query("SELECT @@skip_networking, @@bind_address, @@port, DATABASE(), @@socket").first

      assert_equal [0, "127.0.0.1", Integer(port), "duel"], [networking, bind, listening, database]
      assert_equal "mysqld.sock", File.basename(socket), "its socket the worker's (MySQL can't do without one)"
      assert_equal [["root@localhost"]], Duel::MySQL.execute("SELECT CURRENT_USER()").rows
      Duel::MySQL.address
    end

    refute Duel::MySQL::Connection.ping(address), "stopped with the worker"
  end

  # On Windows, by default.
  def test_on_a_port_on_windows
    windows = Duel::Native::WINDOWS
    Duel::Native.send(:remove_const, :WINDOWS)
    Duel::Native.const_set(:WINDOWS, true)
    url = prepare(config) { |env| env.fetch("DUEL_MYSQL_URL") }

    assert_match %r{\Amysql2://root@127\.0\.0\.1:\d+/duel\z}, url
  ensure
    Duel::Native.send(:remove_const, :WINDOWS)
    Duel::Native.const_set(:WINDOWS, windows)
  end

  # A statement that fails raises its error (its code too), and the
  # connection goes on.
  def test_a_statement_that_fails
    shared do
      db = client
      error = assert_raises(Duel::MySQL::Error) { db.query("SELEKT 1") }

      assert_equal 1064, error.code
      assert_match(/\AMySQL: You have an error in your SQL syntax.* \(1064\)\z/, error.message)
      assert_kind_of Duel::Error, error
      assert_equal [[1]], db.query("SELECT 1").rows
    ensure
      db&.close
    end
  end

  # A database there isn't: the server refuses the connection.
  def test_a_wrong_database
    shared do
      error = assert_raises(Duel::MySQL::Error) { Duel::MySQL::Connection.new(Duel::MySQL.address, database: "nö_such_database") }

      assert_equal ["MySQL: Unknown database 'nö_such_database' (1049)", 1049], [error.message, error.code], "its message UTF-8"
      refute Duel::MySQL::Connection.ping("#{Duel::MySQL.address}x"), "nothing there"
    end
  end

  # Values of every kind: integers (and YEAR) as Integers, in base 10
  # (a ZEROFILL one's too), floating-point numbers as Floats, NULL as
  # nil, and the rest (decimals too) as Strings, UTF-8, of any length
  # (one past 250 bytes, and one past 64KB, take longer lengths); its
  # columns named, in UTF-8, as many as there are (past 250 too).
  def test_values
    shared do
      db = client
      result = db.query("SELECT 1 a, CAST(-2 AS SIGNED) b, CAST(3 AS UNSIGNED) c, 4.5e0 d, CAST(0.25 AS FLOAT) e, 1.25 f, NULL g, " \
        "'é' `é`, REPEAT('x', 300) i, REPEAT('y', 70000) j, YEAR('2026-01-01') k, CAST(7 AS CHAR) l")
      a, b, c, d, e, f, g, h, i, j, k, l = result.rows.first

      assert_equal %w[a b c d e f g é i j k l], result.fields
      assert_equal [1, -2, 3, 4.5, 0.25, "1.25", nil, "é", 2026, "7"], [a, b, c, d, e, f, g, h, k, l]
      assert_equal [[10]], db.query("CREATE TEMPORARY TABLE z (n INT(4) ZEROFILL); INSERT INTO z VALUES (10); SELECT n FROM z").rows
      assert_equal [(1..300).to_a], db.query("SELECT #{(1..300).to_a.join(", ")}").rows
      assert_equal [Encoding::UTF_8, 300, 70_000], [h.encoding, i.size, j.size]
      assert_equal [[1, nil], [2, nil]], db.query("SELECT 1, NULL UNION SELECT 2, NULL").to_a, "each row, as Enumerable has it"
    ensure
      db&.close
    end
  end

  # Several statements, and their results: the last one's, an OK's (no
  # rows) where it returns none.
  def test_several_statements
    shared do
      db = client
      last = db.query("CREATE TABLE t (id int); INSERT INTO t VALUES (1), (2); SELECT COUNT(*) FROM t")
      none = db.execute("INSERT INTO t VALUES (3); SET @a = 1")

      assert_equal [[2]], last.rows
      assert_equal [[], []], [none.fields, none.rows]
      assert_equal [[3]], db.query("SELECT 1; SELECT COUNT(*) FROM t").rows, "the last one's"
      many = "INSERT INTO t WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300) SELECT i FROM n"

      assert_equal [[303]], db.query("#{many}; SELECT COUNT(*) FROM t").rows, "after an OK of a longer count"
    ensure
      db&.close
    end
  end

  # A string literal for any text: what MySQL escapes, escaped.
  def test_quoting
    shared do
      db = client
      text = "a'b\"c\\d\0e\nf\rg\x1ah"

      assert_equal "'a\\'b\\\"c\\\\d\\0e\\nf\\rg\\Zh'", db.quote(text)
      assert_equal [[text]], db.query("SELECT #{db.quote(text)}").rows
    ensure
      db&.close
    end
  end

  # A connection over TCP sends each packet at once (TCP_NODELAY).
  def test_no_delay
    server = TCPServer.new("127.0.0.1", 0)
    socket = Duel::MySQL::Connection.socket("127.0.0.1:#{server.addr.fetch(1)}")

    assert no_delay?(socket)
  ensure
    socket&.close
    server&.close
  end

  # It connects to the host it's given (not another of the machine's:
  # one listening on ::1 alone isn't 127.0.0.1).
  def test_the_host_given
    server = begin
      TCPServer.new("::1", 0)
    rescue SystemCallError
      skip "no IPv6 loopback"
    end

    assert_raises(Errno::ECONNREFUSED) { Duel::MySQL::Connection.socket("127.0.0.1:#{server.addr.fetch(1)}").close }
  ensure
    server&.close
  end

  # HOST:PORT's host and port; a path's, none.
  def test_an_address
    assert_equal ["127.0.0.1", 3306], Duel::MySQL::Connection.address("127.0.0.1:3306")
    assert_equal ["db", 1], Duel::MySQL::Connection.address("db:1")
    ["/tmp/mysqld.sock", "mysqld.sock", "127.0.0.1", "a:b:1", "/a:1", "a:1x", "a:1\n"].each do |address|
      assert_nil Duel::MySQL::Connection.address(address), address
    end
    assert_equal "/s.sock", Duel::MySQL.address({"DUEL_MYSQL_SOCKET" => "/s.sock", "DUEL_MYSQL_URL" => "mysql2://root@127.0.0.1:1/duel"})
    assert_equal "127.0.0.1:1", Duel::MySQL.address({"DUEL_MYSQL_URL" => "mysql2://root@127.0.0.1:1/duel"}), "the URL's, without a socket"
  end

  # A server of the test's own, on a Unix socket, that greets (as MySQL
  # 8's does, caching_sha2_password's) and answers each packet the client
  # sends with the next of +replies+ (payloads; nil hangs up), each
  # numbered on from the client's (their numbers in @sequences). Its
  # greeting's header may say it's +longer+ than it is. Yields its path;
  # returns the packets it was sent.
  def fake_server(*replies, greeting: fake_greeting, longer: 0)
    path = File.join(@dir, "f.sock")
    server = UNIXServer.new(path)
    @sequences = []
    thread = Thread.new do
      client = server.accept
      sent = []
      write = ->(payload, sequence, size = payload.bytesize) { client.write([size].pack("V").byteslice(0, 3) + sequence.chr + payload.b) }
      write.call(greeting, 0, greeting.bytesize + longer)
      replies.each do |reply|
        header = client.read(4) or break
        @sequences << header.getbyte(3)
        sent << client.read(header.unpack1("V") & 0xFFFFFF)
        reply.nil? ? break : Array(reply).each_with_index { |payload, i| write.call(payload, header.getbyte(3) + 1 + i) }
      end
      sent
    ensure
      client&.close
    end
    yield path
    thread.value
  ensure
    server&.close
    FileUtils.rm_f(path)
  end

  def fake_greeting = "\x0a8.0.0\0" + [1].pack("V") + ("s" * 8) + "\0" + [0xFFFF, 45, 2, 0xFFFF, 21].pack("vCvvC") + ("\0" * 10) +
    ("t" * 12) + "\0" + "caching_sha2_password\0"

  OK = "\x00\x00\x00\x02\x00\x00\x00"

  # What it says as it connects: protocol 4.1's, root, no password, the
  # database, and the server's plugin. An auth switch is answered with an
  # empty response too, and caching_sha2_password's fast auth taken.
  def test_the_handshake
    sent = fake_server(["\x01\x03", OK], OK) { |path| Duel::MySQL::Connection.new(path, database: "mine").close }
    response = sent.first
    capabilities, max, charset = response.unpack("VVC")

    assert_equal [0xB_A209, (1 << 24) - 1, 45], [capabilities, max, charset]
    assert_equal ("\0" * 23) + "root\0\0mine\0caching_sha2_password\0", response.byteslice(9..)
    sent = fake_server("\xFEmysql_native_password\0#{"x" * 20}\0", OK) { |path| Duel::MySQL::Connection.new(path).close }

    assert_equal ["", 2], [sent.last, sent.size], "an empty response to the switch"
    assert_equal [1, 3], @sequences, "numbered on from the server's"
  end

  # What it can't connect with: a server that refuses at once (an error
  # for a greeting, of MySQL 4.1's form, without an SQL state), wants a
  # password, or answers what it doesn't read. Its socket's closed.
  def test_a_handshake_that_fails
    opened = []
    socket = Duel::MySQL::Connection.method(:socket)
    error = replacing(Duel::MySQL::Connection, :socket, ->(address) { socket.call(address).tap { |s| opened << s } }) do
      assert_raises(Duel::MySQL::Error) { fake_server(greeting: "\xFF\x10\x04Too many connections") { |path| Duel::MySQL::Connection.new(path) } }
    end

    assert_equal ["MySQL: Too many connections (1040)", 1040], [error.message, error.code]
    assert_equal [true], opened.map(&:closed?)
    error = assert_raises(Duel::MySQL::Error) { fake_server("\x01\x04") { |path| Duel::MySQL::Connection.new(path) } }

    assert_equal "MySQL wants a password (root's has none)", error.message
    error = assert_raises(Duel::MySQL::Error) { fake_server("\x07\x00") { |path| Duel::MySQL::Connection.new(path) } }

    assert_equal "MySQL: an authentication reply the connection doesn't read: 7", error.message
    assert_raises(Duel::MySQL::Error) { fake_server("\xFF\x15\x04#28000Access denied") { |path| Duel::MySQL::Connection.new(path) } }
  end

  # A server that hangs up, even in the middle of a packet.
  def test_a_server_that_hangs_up
    error = assert_raises(IOError) { fake_server(nil) { |path| Duel::MySQL::Connection.new(path) } }

    assert_equal "MySQL closed the connection", error.message
    error = assert_raises(IOError) { fake_server(greeting: "\xFF\x10\x04Too many", longer: 10) { |path| Duel::MySQL::Connection.new(path) } }

    assert_equal "MySQL closed the connection", error.message, "cut short"
  end

  # A row may start with an EOF's byte (a value's 8-byte length): it's a
  # row, at 9 bytes or more, and an EOF under 9. And a reply cut short
  # raises.
  def test_a_row_that_starts_like_an_end
    columns = ["\x01", "\x03def\0\0\0\x01v\0\x0c\x2d\0\x00\x01\0\0\xfd\0\0\0\0\0", "\xFE\0\0\x02\0"]
    rows = ["\xFE#{[3].pack("Q<")}abc", "\xFE#{[0].pack("Q<")}"]
    result = nil
    fake_server(OK, [*columns, *rows, "\xFE\0\0\x02\0\0\0\0"]) { |path| result = Duel::MySQL::Connection.new(path).query("SELECT").rows }

    assert_equal [["abc"], [""]], result
    assert_raises(IOError) { fake_server(OK, [*columns]) { |path| Duel::MySQL::Connection.new(path).query("SELECT") } }
  end

  private

  # A file in the worker's resource's directory.
  def log(env, name) = File.join(File.dirname(env.fetch("DUEL_MYSQL_SOCKET")), name)
end
