# frozen_string_literal: true

require_relative "test_helper"
require "uri"

class PostgreSQLTest < PluginTest
  cover "Duel::PostgreSQL*"

  # Mutant runs a mutation's tests in this order (rather than at random),
  # stopping at the first that fails: those that start no server first,
  # then those on the process's shared server, then those that start
  # servers of their own, and the comparisons last.
  if defined?(Mutant)
    FIRST = %w[test_registered test_totals test_texts_read_once test_a_first_reading test_a_reading_of_none_changed test_a_reading_of_some_changed
      test_statements_gone test_details_from_what_changed test_settle test_finding_postgres test_no_postgres].freeze
    LAST = %w[test_a_server_of_the_workers_own test_stopped_with_a_client_connected test_its_options test_a_server_that_doesnt_start
      test_a_program_that_fails test_making_a_cluster test_a_cluster_made_once test_comparisons].freeze

    def self.runnable_methods
      super.sort_by { |name| [FIRST.index(name) || (FIRST.size + (LAST.index(name)&.succ || 0)), name] }
    end

    # Those that start servers of their own stop the shared one first
    # (the rest have run): a postgres takes a System V shared memory
    # segment, and macOS allows 32 in all, for mutant's processes (one
    # for each processor) to share.
    def setup
      super
      SharedServer.stop if LAST.include?(name)
    end
  end

  def test_a_server_of_the_workers_own
    url = prepare(config) do |env|
      dir = env.fetch("PGHOST")
      url = "postgres:///duel?host=#{dir}&port=5432&user=postgres"

      assert_equal url, env.fetch("DUEL_POSTGRESQL_URL")
      assert_equal url, env.fetch("DATABASE_URL")
      assert_equal "/duel", URI::RFC2396_Parser.new.parse(url).path, "a URL Rails can parse"
      assert_equal ["5432", "postgres", "duel"], env.values_at("PGPORT", "PGUSER", "PGDATABASE")
      assert_equal [%w[duel off]], query("SELECT current_database(), current_setting('fsync')")
      assert File.socket?(File.join(dir, ".s.PGSQL.5432"))
      url
    end

    refute_equal PG::PQPING_OK, PG::Connection.ping(url), "stopped with the worker"
  end

  # Stopped by INT: its clients are disconnected, not waited for (as TERM
  # would, until Duel's KILL, five seconds later).
  def test_stopped_with_a_client_connected
    prepare(config) do
      @pg = PG.connect
      @stopping = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - @stopping, :<, 4
  ensure
    @pg&.close
  end

  def test_its_options
    config = config(bin: POSTGRES, settings: {work_mem: "5MB", jit: "on"}, env: %w[PRIMARY_URL],
      setup: "CREATE TABLE items (id int); INSERT INTO items VALUES (1), (2)")
    prepare(config) do |env|
      assert_equal %w[DUEL_POSTGRESQL_URL PGDATABASE PGHOST PGPORT PGUSER PRIMARY_URL], env.keys.sort
      assert_equal env.fetch("DUEL_POSTGRESQL_URL"), env.fetch("PRIMARY_URL")
      assert_equal [["5MB", "on", "2"]], query("SELECT current_setting('work_mem'), current_setting('jit'), (SELECT count(*) FROM items)"),
        "the settings given, over the plugin's"
    end
  end

  def test_a_server_that_doesnt_start
    error = assert_raises(Duel::Failed) do
      prepare(config(settings: {"no_such_setting" => "1"})) { flunk "started" }
    end

    assert_match(/\Acandidate-1's resource: postgres exited before it was ready\n.*no_such_setting/m, error.message)
  end

  def test_no_postgres
    error = replacing(Duel::PostgreSQL::Cluster, :find_bin, -> {}) do
      assert_raises(Duel::Failed) { prepare(config(bin: nil)) { flunk "started" } }
    end

    assert_equal "candidate-1's resource: no postgres on the PATH (give its directory as bin:, or DUEL_POSTGRESQL_BIN)",
      error.message
  end

  def test_finding_postgres
    bin = File.realpath(POSTGRES)
    linked = linked_bin
    File.write(File.join(@dir, "postgres"), "") # (not a program)
    %w[9 10 16 latest].each { |version| FileUtils.mkdir_p(File.join(@dir, "lib", version, "bin")) }
    debian = File.join(@dir, "lib", "*", "bin")
    nothing = File.join(@dir, "nothing", "*")
    find = Duel::PostgreSQL::Cluster.method(:find_bin)

    assert_equal bin, find.call([@dir, linked].join(File::PATH_SEPARATOR), debian: nothing),
      "the real directory: the initdb on the PATH may be another version's"
    assert_equal File.join(@dir, "lib", "16", "bin"), find.call(@dir, debian:), "the newest Debian's"
    assert_nil find.call(@dir, debian: nothing)
    with_env("PATH" => linked) { assert_equal bin, find.call(debian: nothing), "the PATH's" }
    with_env("PATH" => nil) { assert_equal File.join(@dir, "lib", "16", "bin"), find.call(debian:), "no PATH" }
    patterns = []
    replacing(Dir, :[], ->(pattern) { [].tap { patterns << pattern } }) { find.call(@dir) }

    assert_equal ["/usr/lib/postgresql/*/bin"], patterns, "Debian's, by default"
  end

  # The first worker's cluster is initdb'd (Resource#cached); the others
  # copy it. It's made for the real postgres (by its path and time), of
  # bin: (~ expanded), wherever the PATH's is.
  def test_a_cluster_made_once
    linked_bin
    config = config(bin: "~/linked")
    cache = own_cache
    made = with_env("HOME" => @dir, "PATH" => "/usr/bin:/bin", "LC_ALL" => "en_US.UTF-8") do
      prepare(config, cache:, name: "baseline-1") do |env|
        assert_path_exists File.join(env.fetch("PGHOST"), "single.sql"), "in the worker's directory"
        assert_equal [%w[C C]], query("SELECT datcollate, datctype FROM pg_database WHERE datname = current_database()"),
          "the C locale, whatever the environment's"
        File.read(File.join(env.fetch("PGHOST"), "initdb.log"))
      end
    end
    clusters = Dir.children(cache)
    postgres = File.realpath(File.join(POSTGRES, "postgres"))
    key = Digest::SHA256.hexdigest("#{postgres}\0#{File.mtime(postgres).to_f}")[0, 16]

    assert_includes made, "Sync to disk skipped", "initdb'd, with --no-sync"
    assert_equal ["postgresql-#{Duel::PostgreSQL::VERSION}-#{key}"], clusters
    with_env("HOME" => @dir) do
      prepare(config, cache:) do |env|
        refute_path_exists File.join(env.fetch("PGHOST"), "initdb.log")
        assert_equal 0o700, File.stat(File.join(env.fetch("PGHOST"), "data")).mode & 0o777
        assert_equal [["1"]], query("SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'")
      end
    end

    assert_equal clusters, Dir.children(cache), "copied, not made again"
  end

  # A cluster is made (initdb'd, then the database and pg_stat_statements
  # created in it, in single-user mode) in a cache of the test's own,
  # empty, so it's made here whatever other tests have built. A statement
  # that fails in single-user mode fails it (exit_on_error).
  def test_making_a_cluster
    resource = Duel::Resource.new(File.join(@dir, "resource"), "candidate-1", @dir, timeout: 60, cache: own_cache)
    cluster = Duel::PostgreSQL::Cluster.new(resource, POSTGRES)
    data = File.join(@dir, "data")
    cluster.create(data)
    shown = single_user(data, "SELECT extname FROM pg_extension WHERE extname = 'pg_stat_statements'")

    assert_includes shown, 'extname = "pg_stat_statements"', "the database, with pg_stat_statements"
    error = assert_raises(Duel::Failed) { cluster.send(:single, data, "duel", "SELECT no_such_column") }

    assert_match(/\Acandidate-1's resource: postgres exited with 1\n.*no_such_column/m, error.message)
    assert_equal "SELECT no_such_column\n", File.read(File.join(@dir, "resource", "single.sql"))
  end

  # (bin:, or DUEL_POSTGRESQL_BIN.)
  def test_a_program_that_fails
    cache = own_cache # (this postgres's cluster would be copied)
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    File.symlink(File.join(POSTGRES, "postgres"), File.join(bin, "postgres"))
    File.write(File.join(bin, "initdb"), "#!/bin/sh\necho \"initdb: can't\"\nexit 1\n")
    File.chmod(0o755, File.join(bin, "initdb"))
    [config(bin:), with_env("DUEL_POSTGRESQL_BIN" => bin) { config }].each do |config|
      error = assert_raises(Duel::Failed) { prepare(config, cache:) { flunk "started" } }

      assert_equal "candidate-1's resource: initdb exited with 1\ninitdb: can't\n", error.message
      assert_empty Dir.children(cache), "nothing left behind"
    end
  end

  def test_measures_what_postgres_did
    config = self.config
    measured, nothing = shared_worker(config) do
      pg = PG.connect
      pg.exec("CREATE TABLE items (id int PRIMARY KEY, name text); INSERT INTO items SELECT g, 'n' FROM generate_series(1, 500) g")
      [Duel::Testing.measure(config) do
        3.times { |i| pg.exec_params("SELECT name FROM items WHERE id = $1", [i]) }
        pg.exec("UPDATE items SET name = 'm' WHERE id <= 10")
      end, Duel::Testing.measure(config) {}]
    ensure
      pg&.close
    end

    assert_equal [["postgres_queries", :counted, "query", "queries", 1, true], ["postgres_rows", :counted, "row", "rows", 1, true],
      ["postgres_blocks", :ratio, "block", "blocks", 1, true], ["postgres_time", :ratio, "µs", "µs", 1000, false]],
      config.metrics.first.settings.map { |name, s| [name, *s.values_at(:kind, :unit, :plural, :unit_ns, :across)] }
    assert_equal 4, measured.fetch("postgres_queries"), "the readings' own left out"
    assert_equal 2 + 10, measured.fetch("postgres_rows"), "ids 1 and 2, and the 10 updated"
    assert_operator measured.fetch("postgres_blocks"), :>, 0
    assert_operator measured.fetch("postgres_time"), :>, 0
    assert_equal({"postgres_queries" => 0, "postgres_rows" => 0, "postgres_blocks" => 0, "postgres_time" => 0}, nothing)
  end

  # What's untimed isn't measured, but what's measured before it is.
  def test_untimed
    config = self.config
    measured = shared do
      pg = PG.connect
      Duel::Testing.measure(config) do |sample|
        pg.exec("SELECT 1")
        sample.untimed { Duel::PostgreSQL.execute("SELECT 2, 3") }
        pg.exec("SELECT 1")
      end
    ensure
      pg&.close
    end

    assert_equal 2, measured.fetch("postgres_queries")
    assert_equal 2, measured.fetch("postgres_rows")
  end

  # A regression is explained by the statements that did the most of it,
  # in the sample but its untimed blocks: how many times each ran an
  # iteration, and each one's share of the rest.
  def test_details
    config = self.config
    shared_worker(config) do
      Duel::PostgreSQL.execute("CREATE TABLE items (id int, name text); INSERT INTO items SELECT g, 'n' FROM generate_series(1, 5000) g")
      pg = PG.connect
      details = Duel::Testing.measure(config, n: 2) do |sample|
        pg.exec("SELECT 2")
        sample.untimed { Duel::PostgreSQL.execute("SELECT 1") }
        2.times { pg.exec("SELECT name FROM items WHERE id = 7") }
        pg.exec("SELECT 1 AS #{"a" * 40}, 2 AS #{"b" * 40}") # (shortened)
        pg.exec("SELECT 1 WHERE false")
      end.details

      assert_equal %w[postgres_queries postgres_rows postgres_blocks postgres_time], details.keys
      long = "SELECT $1 AS #{"a" * 40}, $2 AS #{"b" * 18}…"

      assert_equal "an iteration: 1× SELECT name FROM items WHERE id = $1; 0.5× SELECT $1; 0.5× #{long}",
        details.fetch("postgres_queries"), "what's before the untimed block, not the untimed one's"
      assert_equal "SELECT name FROM items WHERE id = $1 (50%); SELECT $1 (25%); #{long} (25%)", details.fetch("postgres_rows")
      assert_match(/\ASELECT name FROM items WHERE id = \$1 \([\d.]+%\)/, details.fetch("postgres_blocks"), "the scan's the most")
      assert_match(/SELECT name FROM items WHERE id = \$1 \([\d.]+%\)/, details.fetch("postgres_time"))
      details = Duel::Testing.measure(config) { pg.exec("SELECT 1 WHERE false") }.details

      assert_equal({"postgres_queries" => "an iteration: 1× SELECT $1 WHERE $2"}, details.slice("postgres_queries", "postgres_rows"))
      assert_empty Duel::Testing.measure(config) {}.details, "nothing: the readings are left out"
    ensure
      pg&.close
    end
  end

  # A scan reads every block of a table; an index, a few.
  def test_blocks_tell_a_missing_index
    shared_worker do
      pg = PG.connect
      pg.exec("CREATE TABLE items (id int, name text); INSERT INTO items SELECT g, repeat('n', 100) FROM generate_series(1, 5000) g")
      find = lambda do
        pg.exec("SELECT name FROM items WHERE id = 7") # (planned)
        before = Duel::PostgreSQL.stats(@connection.value)
        pg.exec("SELECT name FROM items WHERE id = 7")
        Duel::PostgreSQL.stats(@connection.value).fetch("postgres_blocks") - before.fetch("postgres_blocks")
      end
      scan = find.call
      pg.exec("CREATE INDEX ON items (id)")

      assert_operator scan, :>, 10 * find.call
    ensure
      pg&.close
    end
  end

  # The helpers need only the worker's environment: they open a
  # connection of their own.
  def test_for_benchmarks
    shared do |env|
      Duel::PostgreSQL.execute("CREATE TABLE items (id serial PRIMARY KEY, name text); INSERT INTO items (name) VALUES ('a')")

      assert_equal env.fetch("DUEL_POSTGRESQL_URL"), Duel::PostgreSQL.url
      assert_equal [["1", "a"]], query("SELECT * FROM items")
      Duel::PostgreSQL.reset
      Duel::PostgreSQL.execute("INSERT INTO items (name) VALUES ('b')")

      assert_equal [["1", "b"]], query("SELECT * FROM items"), "emptied, its sequence restarted"
    end
  end

  # While a benchmark is measured, what the helpers run would be
  # counted: they fail, and run nothing.
  def test_helpers_measured
    config = self.config
    shared do
      Duel::PostgreSQL.execute("CREATE TABLE items (id int); INSERT INTO items VALUES (1)")
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::PostgreSQL.execute("DELETE FROM items") } }

      assert_equal "Duel::PostgreSQL.execute: in setup or untimed only (it would be counted)", error.message
      error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { Duel::PostgreSQL.reset } }

      assert_equal "Duel::PostgreSQL.reset: in setup or untimed only (it would be counted)", error.message
      assert_equal [["1"]], query("SELECT count(*) FROM items")
      Duel::Testing.measure(config) { |sample| sample.untimed { Duel::PostgreSQL.reset } }

      assert_equal [["0"]], query("SELECT count(*) FROM items")
    end
  end

  # Their connections are closed once they've run. (Asked over one
  # connection, kept open: one for each look would leave a backend
  # exiting, counted by the next, as each closed.)
  def test_helpers_connections
    shared do
      GC.disable # (a connection left open would be closed when it's collected)
      Duel::PostgreSQL.execute("SELECT 1")
      pg = PG.connect
      others = "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid != pg_backend_pid()"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      sleep 0.01 until (count = pg.exec(others).values) == [["0"]] || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      assert_equal [["0"]], count, "only the one asking"
    ensure
      pg&.close
      GC.enable
    end
  end

  def test_reset_with_no_tables
    shared { assert_equal PG::PGRES_COMMAND_OK, Duel::PostgreSQL.reset.result_status }
  end

  # The plugin's connection (what c.use returns) is opened in workers
  # (Config#in_worker), not by the runner, which loads .duel.rb too, and
  # closed as they end.
  def test_outside_a_worker
    connection = shared_worker(config) { @connection.value }

    assert_predicate connection, :finished?
    error = assert_raises(Duel::Error) { @connection.value }

    assert_match(/made in each worker only/, error.message)
  end

  # The plugin registers itself, as c.use :postgresql finds it, and is
  # configured once (one server for each worker), however many times it's
  # used: what it returns is its connection, each worker's.
  def test_registered
    config = Duel::Config.new(@dir)
    connection = config.use(:postgresql)

    assert_same Duel::PostgreSQL, Duel.plugins.fetch(:postgresql)
    assert_instance_of Duel::InWorker, connection
    assert_same connection, config.use(:postgresql)
    assert_equal [1, 1, [:postgresql]], [config.prepares.fetch(:worker).size, config.metrics.size, config.plugins]
  end

  # Statements' numbers, all told, by measure: time in µs.
  def test_totals
    total = Duel::PostgreSQL::Statements.method(:total)

    assert_equal({"postgres_queries" => 2, "postgres_rows" => 2, "postgres_blocks" => 8, "postgres_time" => 4.5},
      total.call([[1, 2, 3, 4000], [1, 0, 5, 500]]))
    assert_equal({"postgres_queries" => 0, "postgres_rows" => 0, "postgres_blocks" => 0, "postgres_time" => 0.0}, total.call([]))
  end

  # Each statement's numbers, by query id: time in ns (pg_stat_statements
  # has it in ms).
  def test_statements
    shared_worker do
      query("SELECT pg_sleep(0.01)")
      id, blocks, ms = query(<<~SQL).first
        SELECT queryid, sum(shared_blks_hit + shared_blks_read), sum(total_plan_time + total_exec_time)
        FROM pg_stat_statements WHERE query = 'SELECT pg_sleep($1)' GROUP BY queryid
      SQL
      numbers = Duel::PostgreSQL.statements(@connection.value).fetch(id)

      assert_equal [1, 1, Integer(blocks), (Float(ms) * 1_000_000).round], numbers
      assert_instance_of Integer, numbers.last
      assert_equal({id => "SELECT pg_sleep($1)"}, Duel::PostgreSQL.texts(@connection.value, [id]))
    end
  end

  # Statements' texts are read once each, and only of those that did
  # something; one with none (gone from pg_stat_statements) shows its
  # query id.
  def test_texts_read_once
    read = []
    statements = Duel::PostgreSQL::Statements.new(Data.define(:value).new(:connection))
    started = reading({"1" => [1, 1, 1, 1], "2" => [2, 2, 2, 2]})
    stretches = [[started, reading({"1" => [3, 1, 2, 3], "2" => [2, 2, 2, 2], "9" => [1, 0, 0, 0]})]]
    texts = ->(_connection, ids) { read << ids and ids.grep_v("9").to_h { |id| [id, "SELECT  #{id}\n  FROM t"] } }
    replacing(Duel::PostgreSQL, :texts, texts) do
      assert_equal({"postgres_queries" => "an iteration: 1× SELECT 1 FROM t; 0.5× 9", "postgres_blocks" => "SELECT 1 FROM t (100%)",
                    "postgres_time" => "SELECT 1 FROM t (100%)"}, statements.details(stretches, 2))
      assert_equal({"postgres_queries" => "an iteration: 1× SELECT 1 FROM t"},
        statements.details([[started, reading({"1" => [2, 1, 1, 1]})]], 1))
    end

    assert_equal [%w[1 9]], read
  end

  # A first reading makes every statement's numbers: time in ns, and
  # all told in µs.
  def test_a_first_reading
    totals, first = reader(ROWS.dup).call

    assert_equal({"postgres_queries" => 4 + BIG, "postgres_rows" => 5, "postgres_blocks" => 6, "postgres_time" => 1250.0}, totals)
    assert_equal({"1" => [1, 2, 3, 500_000], "2" => [1, 1, 1, 250_000], "3" => [1, 1, 1, 250_000], "4" => [1, 1, 1, 250_000],
                  "5" => [BIG, 0, 0, 0]}, first.numbers)
    assert_equal [{}, %w[1 2 3 4 5]], [first.previous, first.changed]
    assert_predicate first.numbers, :frozen?
  end

  # A reading of none changed shares the last one's numbers, Hash and
  # all.
  def test_a_reading_of_none_changed
    rows = ROWS.dup
    read = reader(rows)
    _, first = read.call
    rows["5"] = [2**70, 0, 0, 0.0] # (another Integer, the same)
    totals, same = read.call

    assert_equal [4 + BIG, 1250.0], totals.values_at("postgres_queries", "postgres_time")
    assert_same first.numbers, same.numbers
    assert_same first.numbers, same.previous
    assert_empty same.changed
  end

  # A reading makes numbers only for the statements that changed since
  # the last one (in any measure, or new), and shares the rest: the last
  # one's are left as they were. The totals are kept up as they change.
  def test_a_reading_of_some_changed
    rows = ROWS.dup
    read = reader(rows)
    _, first = read.call
    rows.merge!("1" => [2, 2, 3, 0.5], "2" => [1, 3, 1, 0.25], "3" => [1, 1, 4, 0.25], "4" => [1, 1, 1, 0.75], "6" => [0, 0, 0, 0.0])
    totals, changed = read.call

    assert_equal({"postgres_queries" => 5 + BIG, "postgres_rows" => 7, "postgres_blocks" => 9, "postgres_time" => 1750.0}, totals)
    assert_equal [%w[1 2 3 4 6], first.numbers], [changed.changed, changed.previous], "each in one measure, or new"
    assert_equal({"1" => [2, 2, 3, 500_000], "2" => [1, 3, 1, 250_000], "3" => [1, 1, 4, 250_000], "4" => [1, 1, 1, 750_000],
                  "5" => [BIG, 0, 0, 0], "6" => [0, 0, 0, 0]}, changed.numbers)
    assert_same first.numbers.fetch("5"), changed.numbers.fetch("5")
    assert_equal [1, 2, 3, 500_000], first.numbers.fetch("1"), "the last reading's left as it was"
    assert_predicate changed.numbers, :frozen?
  end

  # Statements gone from pg_stat_statements (the oldest, past its max, or
  # every one, reset) are forgotten, and their numbers with them.
  def test_statements_gone
    rows = ROWS.dup
    read = reader(rows)
    _, first = read.call
    rows.delete("5")
    rows.delete("1")
    rows["7"] = [1, 1, 1, 0.5]
    totals, gone = read.call

    assert_equal({"postgres_queries" => 4, "postgres_rows" => 4, "postgres_blocks" => 4, "postgres_time" => 1250.0}, totals)
    assert_equal [%w[2 3 4 7], %w[7], first.numbers], [gone.numbers.keys, gone.changed, gone.previous]
    rows.delete("7")
    totals, = read.call

    assert_equal({"postgres_queries" => 3, "postgres_rows" => 3, "postgres_blocks" => 3, "postgres_time" => 750.0}, totals)
  end

  # What a sample's statements did is told from what changed in each of
  # its stretches: of a reading right after the stretch's first, those it
  # says changed, and of another, every one.
  def test_details_from_what_changed
    statements = Duel::PostgreSQL::Statements.new(Data.define(:value).new(:connection))
    before = {"1" => [1, 1, 1, 1], "2" => [1, 1, 1, 1]}.freeze
    after = {"1" => [2, 1, 1, 1], "2" => [3, 1, 1, 1]}
    texts = ->(_connection, ids) { ids.to_h { |id| [id, "SELECT #{id}"] } }
    replacing(Duel::PostgreSQL, :texts, texts) do
      assert_equal({"postgres_queries" => "an iteration: 1× SELECT 1"},
        statements.details([[reading(before), reading(after, before, %w[1])]], 1), "right after: what it says changed")
      assert_equal({"postgres_queries" => "an iteration: 2× SELECT 2; 1× SELECT 1"},
        statements.details([[reading(before), reading(after, before.dup, %w[1])]], 1), "after another: every one")
      later = {"1" => [5, 1, 1, 1], "2" => [3, 1, 1, 1]}

      assert_equal({"postgres_queries" => "an iteration: 4× SELECT 1"},
        statements.details([[reading(before), reading(after, before, %w[1])], [reading(after), reading(later, after, %w[1])]], 1),
        "every stretch's, added up")
    end
  end

  # Whole comparisons: the same code passes; code that sends PostgreSQL
  # more queries fails on them (and the rows they return).
  def test_comparisons
    base = project("base", 1)
    same = Duel::Testing.compare(base, project("same", 1), timeout: 120.0)

    assert_predicate same, :passed?, same.output
    assert_equal 1, same["find"].counted.fetch("postgres_queries").then { |c| c.fetch("candidate") / c.fetch("n") }
    more = Duel::Testing.compare(base, project("more", 2), timeout: 120.0)

    assert_equal %w[postgres_queries postgres_rows], more["find"].regressed & %w[postgres_queries postgres_rows], more.output
    assert_includes more.output, "postgres_queries: 1 query → 2 queries an iteration"
    assert_includes more.output, "postgres_queries (candidate): an iteration: 2× SELECT id FROM items WHERE id = $1", "explained"
    assert_includes more.output, "postgres_queries (baseline): an iteration: 1× SELECT id FROM items WHERE id = $1"
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
      pg = PG.connect
      pg.exec("CREATE TABLE items (id int)")
      around = lambda do |iteration|
        pg.exec("BEGIN")
        iteration.call
        pg.exec("ROLLBACK")
      end
      Duel::Testing.measure(config, n: 20, around_iteration: around) { pg.exec("INSERT INTO items VALUES (1), (2)") }
    ensure
      pg&.close
    end

    assert_predicate config.metrics.first, :costly?
    assert_equal [20, 40], measured.values_at("postgres_queries", "postgres_rows")
  end

  # An iteration's last query, sent with the extended protocol (as
  # Active Record sends every one) inside an around_iteration hook's
  # transaction, is counted as the iteration's: PostgreSQL would count it
  # only as the hook's next statement (its ROLLBACK) ran, and it would be
  # learned as the hook's, and taken away. The hook's own BEGIN,
  # SAVEPOINT and ROLLBACK aren't counted. A connection closed, or in a
  # failed transaction, is left alone.
  def test_an_iterations_query_in_a_transaction
    config = self.config
    measured = shared_worker(config) { |env| in_a_transaction(env) { |measure| measure.call(config) } }

    assert_predicate config.metrics.first, :costly?
    assert_equal [20, 40], measured.values_at("postgres_queries", "postgres_rows")
  end

  # So it is with a metric read around each iteration, not costly to
  # read: what's read as each iteration ends counts its last query.
  def test_an_iterations_query_in_a_transaction_paused
    config = self.config
    measured = shared_worker(config) do |env|
      statements = Duel::PostgreSQL::Statements.new(@connection)
      config.metrics.clear
      config.metric(Duel::PostgreSQL::METRICS) { statements.read }
      in_a_transaction(env) { |measure| measure.call(config) }
    end

    refute_predicate config.metrics.first, :costly?
    assert_equal [20, 40], measured.values_at("postgres_queries", "postgres_rows")
  end

  # Each of the process's connections in a transaction has its unnamed
  # portal closed (with libpq 17's Close, or before it, an empty query):
  # none closed, outside a transaction, busy, or in a failed one.
  def test_settle
    sent = []
    connection = Struct.new(:name, :finished?, :transaction_status) do
      define_method(:exec_params) { |sql, params| sent << [name, :exec_params, sql, params] }
    end
    closing = Class.new(connection) { define_method(:close_portal) { |portal| sent << [name, :close_portal, portal] } }
    connections = [connection.new(:closed, true, PG::PQTRANS_INTRANS), connection.new(:idle, false, PG::PQTRANS_IDLE),
      connection.new(:busy, false, PG::PQTRANS_ACTIVE), connection.new(:failed, false, PG::PQTRANS_INERROR),
      # (A status equal to PQTRANS_INTRANS, but not the same object.)
      connection.new(:old, false, PG::PQTRANS_INTRANS), closing.new(:new, false, PG::PQTRANS_INTRANS.to_f)]
    Duel::PostgreSQL.settle(connections)

    assert_equal [[:old, :exec_params, "", []], [:new, :close_portal, ""]], sent
    assert_predicate Duel::PostgreSQL::NO_PARAMS, :frozen?
  end

  private

  # Yields a block that measures, with +config+, 20 iterations of a
  # query (of 2 rows, sent with the extended protocol) inside an
  # around_iteration hook's transaction, on the server of +env+, while
  # another connection is closed, and another in a failed transaction.
  def in_a_transaction(env)
    pg, closed, failed = Array.new(3) { PG.connect(env.fetch(Duel::PostgreSQL::URL)) }
    pg.exec("CREATE TABLE items (id int); INSERT INTO items VALUES (1), (2)")
    closed.close
    failed.exec("BEGIN")
    assert_raises(PG::DivisionByZero) { failed.exec("SELECT 1 / 0") }
    around = lambda do |iteration|
      pg.exec("BEGIN; SAVEPOINT duel")
      iteration.call
      pg.exec("ROLLBACK")
    end
    yield ->(config) { Duel::Testing.measure(config, n: 20, around_iteration: around) { pg.exec_params("SELECT id FROM items WHERE id > $1", [0]) } }
  ensure
    [pg, failed].each { |c| c&.close }
  end

  # pg_stat_statements' rows, by query id: calls, rows, blocks, time (ms).
  BIG = 2**70
  ROWS = {"1" => [1, 2, 3, 0.5], "2" => [1, 1, 1, 0.25], "3" => [1, 1, 1, 0.25], "4" => [1, 1, 1, 0.25], "5" => [BIG, 0, 0, 0.0]}.freeze

  # Reads Statements (#read) over a server whose pg_stat_statements has
  # these +rows+, as they are at each reading.
  def reader(rows)
    statements = Duel::PostgreSQL::Statements.new(Data.define(:value).new(:connection))
    columns = ->(_connection) { [rows.keys, *(0..3).map { |i| rows.values.map { |numbers| numbers.fetch(i) } }] }
    -> { replacing(Duel::PostgreSQL, :columns, columns) { statements.read } }
  end

  # A reading (Snapshot::Reading) of these statements' +numbers+, read
  # after +previous+ (by default, a reading of none), which says these
  # +changed+.
  def reading(numbers, previous = {}, changed = [])
    Data.define(:context).new(Duel::PostgreSQL::Statements::Reading.new(numbers, previous, changed))
  end

  # What postgres shows for +sql+, run in single-user mode in the
  # database "duel" of the cluster in +data+ (no server started).
  def single_user(data, sql)
    IO.popen([File.join(POSTGRES, "postgres"), "--single", "-D", data, "duel"], "r+", err: %i[child out]) do |io|
      io.puts(sql)
      io.close_write
      io.read
    end
  end

  # The rows a query returns, on a connection to the worker's server
  # (libpq's environment).
  def query(sql)
    pg = PG.connect
    pg.exec(sql).values
  ensure
    pg&.close
  end
end
