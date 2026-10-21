# frozen_string_literal: true

require "duel"
require "digest"
require "fileutils"
require "pg"
require_relative "postgresql/version"

module Duel
  # A PostgreSQL server of each worker's own, and what it did for each
  # benchmark, from pg_stat_statements:
  #
  # - postgres_queries: the statements it ran (counted)
  # - postgres_rows: the rows they returned or changed (counted)
  # - postgres_blocks: the shared buffer blocks they touched, from the
  #   cache or not (judged like CPU time: nearly steady, but a table
  #   that grows, say, takes more)
  # - postgres_time: the time it spent planning and running them, in
  #   microseconds (judged like CPU time)
  #
  # Where one regressed, it says which statements did the most of it, on
  # each version (Statements#details).
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :postgresql }
  #
  # Benchmarks can call Duel::PostgreSQL.url, and .execute and .reset in
  # setup (or untimed blocks): while a benchmark is measured, they fail.
  #
  # The server listens only on a Unix socket in the worker's directory;
  # its URL is in DUEL_POSTGRESQL_URL, and in DATABASE_URL too (unless
  # +env+ names others), and libpq's PGHOST, PGPORT, PGUSER and
  # PGDATABASE point at it, so a client finds it and nothing reaches
  # another database.
  module PostgreSQL
    Duel.plugin(:postgresql, self)

    URL = "DUEL_POSTGRESQL_URL"
    DATABASE = "duel"
    USER = "postgres"
    # It names the socket (.s.PGSQL.5432): the server listens on no port.
    PORT = 5432

    # The server's settings: nothing to disk that needn't be, nothing
    # running on its own (autovacuum would change what a query touches,
    # and its plan, while it's measured), and pg_stat_statements.
    SETTINGS = {
      "listen_addresses" => "",
      "fsync" => "off",
      "synchronous_commit" => "off",
      "full_page_writes" => "off",
      "autovacuum" => "off",
      "jit" => "off",
      "shared_buffers" => "32MB",
      "shared_preload_libraries" => "pg_stat_statements",
      "compute_query_id" => "on",
      "pg_stat_statements.max" => "10000",
      "pg_stat_statements.track_planning" => "on"
    }.freeze

    # Configures Duel for the plugin (c.use :postgresql): the server and
    # its metrics. +bin+ is the directory of its programs (postgres and
    # initdb: by default, the real directory of the postgres on the
    # PATH), +settings+ more of its settings, +setup+ SQL each worker's
    # database runs when it's started (a schema, say), and +env+ the
    # variables given its URL besides DUEL_POSTGRESQL_URL. A cluster is
    # initdb'd once (Resource#cached), and each worker's is a copy.
    # Returns the plugin's own connection to it, a worker's (see
    # Config#in_worker, and in tests, Duel::Testing.in_worker).
    def self.configure(config, bin: ENV.fetch("DUEL_POSTGRESQL_BIN", nil), settings: {}, setup: nil, env: %w[DATABASE_URL])
      config.prepare(:worker) do |w|
        programs = File.expand_path(bin || Cluster.find_bin ||
          w.failed("no postgres on the PATH (give its directory as bin:, or DUEL_POSTGRESQL_BIN)"))
        data = w.path("data")
        Cluster.new(w, programs).create(data)
        # (Stopped by INT: its clients are disconnected, not waited for, as
        # TERM would.)
        # (Of a setting given twice, postgres takes the last: +settings+'.)
        w.spawn(File.join(programs, "postgres"), "-D", data, "-k", w.dir, "-p", PORT.to_s,
          *SETTINGS.merge(settings).flat_map { |name, value| ["-c", "#{name}=#{value}"] }, stop_signal: "INT")
        # (The user in the query, with no authority at all: Ruby's URI, which
        # Rails parses DATABASE_URL with, takes a user without a host for
        # a malformed host.)
        url = "postgres:///#{DATABASE}?host=#{w.dir}&port=#{PORT}&user=#{USER}"
        w.wait_until { PG::Connection.ping(url) == PG::PQPING_OK }
        run(url, setup) if setup
        {URL => url, "PGHOST" => w.dir, "PGPORT" => PORT.to_s, "PGUSER" => USER, "PGDATABASE" => DATABASE}
          .merge(env.to_h { |name| [name, url] })
      end
      # (In the worker, libpq's environment is its server's.)
      connection = config.in_worker { |w| PG.connect.tap { |pg| w.at_stop { pg.close } } }
      statements = Statements.new(connection)
      config.metric(METRICS) { statements.read }.costly.details { |stretches, sample| statements.details(stretches, sample.n) }
      connection
    end

    # Runs SQL on a connection of its own to +url+; returns the last
    # statement's result. (async_exec is exec, by its other name: one a
    # mutation can't make Kernel#exec.)
    def self.run(url, sql)
      connection = PG.connect(url)
      begin
        connection.async_exec(sql)
      ensure
        connection.close
      end
    end

    # Server time isn't the worker's CPU time: another process's, on the
    # clock, so what else the machine does shows in it. It's judged on
    # each benchmark, but left out across the board, where the margin is
    # too small for it. Its readings leave themselves out (STATEMENTS), so
    # there's nothing to take away.
    METRICS = {
      "postgres_queries" => {kind: :counted, unit: %w[query queries], calibrate: false},
      "postgres_rows" => {kind: :counted, unit: %w[row rows], calibrate: false},
      "postgres_blocks" => {kind: :ratio, unit: %w[block blocks], floor: 100, sizes_samples: false},
      "postgres_time" => {kind: :ratio, unit: "µs", floor: 300, across: false}
    }

    # What the worker's server has done so far, by statement (query id),
    # but for these readings themselves (their statement is left out by
    # its query id), so nothing's left to take away. pg_stat_statements
    # is updated as each statement ends, before the client hears it has
    # (but for one left open in a transaction: see .settle).
    STATEMENTS = <<~SQL
      SELECT queryid, sum(calls), sum(rows), sum(shared_blks_hit + shared_blks_read), sum(total_plan_time + total_exec_time)
      FROM pg_stat_statements
      WHERE queryid IS DISTINCT FROM (SELECT query_id FROM pg_stat_activity WHERE pid = pg_backend_pid())
      GROUP BY queryid
    SQL

    # STATEMENTS' columns, as pg decodes them: the query id as text, the
    # counts as Integers and the time (ms) as a Float, with no String
    # made for a number only to be parsed.
    COLUMNS = PG::TypeMapByColumn.new([nil, PG::TextDecoder::Integer.new, PG::TextDecoder::Integer.new,
      PG::TextDecoder::Integer.new, PG::TextDecoder::Float.new])

    # Statements' texts, by query id (a PostgreSQL array of them).
    TEXTS = "SELECT DISTINCT ON (queryid) queryid, coalesce(query, '') FROM pg_stat_statements WHERE queryid = ANY($1::bigint[])"

    # What the worker's server has done so far, by statement, read over
    # +connection+ (the plugin's own): a column each of their query ids,
    # queries, rows, blocks and time (ms), a statement to a row.
    def self.columns(connection)
      settle
      # (None is NULL: every statement has a query id.)
      result = connection.async_exec(STATEMENTS).map_types!(COLUMNS)
      [result.column_values(0), result.column_values(1), result.column_values(2), result.column_values(3), result.column_values(4)]
    end

    # The empty query's parameters (see .settle).
    NO_PARAMS = [] #: Array[String]
    NO_PARAMS.freeze

    # Ends the statement each of the process's +connections+ (the
    # benchmark's, the app's) has left open in a transaction, for a
    # reading to count it. pg_stat_statements counts a statement as its
    # executor ends, and one sent with the extended protocol (pg's
    # exec_params and exec_prepared, so every query of Active Record's)
    # keeps its executor open, in the unnamed portal, until the
    # connection's next statement, or its transaction's end. Inside an
    # around_iteration hook's transaction, an iteration's last query
    # would be counted only as the hook's ROLLBACK ran, as the hook's.
    # Closing the portal (libpq 17's Close, or before it, an empty query,
    # which takes its place) ends it, and counts nothing of its own. One
    # outside a transaction, busy, or in a failed one has none to end.
    def self.settle(connections = ObjectSpace.each_object(PG::Connection))
      connections.each do |pg|
        next if pg.finished? || pg.transaction_status != PG::PQTRANS_INTRANS

        pg.respond_to?(:close_portal) ? pg.close_portal("") : pg.exec_params("", NO_PARAMS)
      end
    end

    # What the worker's server has done so far, by statement, read over
    # +connection+: each one's [queries, rows, blocks, time (ns)], by
    # query id.
    def self.statements(connection)
      ids, calls, rows, blocks, ms = columns(connection)
      ids.each_with_index.to_h { |id, i| [id, [calls.fetch(i), rows.fetch(i), blocks.fetch(i), ns(ms.fetch(i))]] }
    end

    # A time in ms (pg_stat_statements'), in ns.
    def self.ns(ms) = (ms * 1_000_000).round

    # What the worker's server has done so far, all told, by measure, read
    # over +connection+.
    def self.stats(connection) = Statements.total(statements(connection).values)

    # The texts of the statements with these query ids, by query id
    # (normalized: $1 for each constant), read over +connection+.
    def self.texts(connection, ids)
      connection.exec_params(TEXTS, ["{#{ids.join(",")}}"]).values.to_h
    end

    # For benchmarks: the worker's server.
    def self.url = ENV.fetch(URL)

    # Runs SQL (statements, ;-separated) on it, over a connection of its
    # own; returns the last one's result. For setting up: it fails while
    # a benchmark is measured (Duel.measuring?), as what it runs would be
    # counted.
    def self.execute(sql)
      Duel.unmeasured!("Duel::PostgreSQL.execute")
      run(url, sql)
    end

    # Empties every table (but PostgreSQL's own), restarting their
    # sequences. For setting up, as execute is.
    def self.reset
      Duel.unmeasured!("Duel::PostgreSQL.reset")
      run(url, RESET)
    end

    # What reset runs.
    RESET = <<~SQL
      DO $$
      DECLARE tables text;
      BEGIN
        SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') INTO tables
          FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
        IF tables IS NOT NULL THEN
          EXECUTE 'TRUNCATE ' || tables || ' RESTART IDENTITY CASCADE';
        END IF;
      END $$
    SQL

    # Running totals of what the worker's server did, all told (#read),
    # and by statement, to explain a regression with the statements that
    # did the most of it (#details). A reading makes numbers only for the
    # statements that changed since the last one, and a sample's are told
    # from those: the rest are the last reading's.
    class Statements
      # The measures, in the order of a statement's numbers.
      NAMES = METRICS.keys.freeze

      # The statements a regression is explained with, and how much of
      # each one's text.
      SHOWN = 3
      TEXT = 80

      # A statement that did nothing yet.
      NOTHING = [0, 0, 0, 0].freeze

      # A reading's context: every statement's numbers, by query id (a
      # Hash it shares with the last reading, if none changed), the last
      # reading's, and the query ids of those that changed since.
      Reading = Data.define(:numbers, :previous, :changed)

      # Statements' numbers, all told, by measure (time in µs).
      def self.total(statements) = by_measure(sum(statements))

      # Statements' numbers, added up.
      def self.sum(statements) = NAMES.each_index.map { |i| statements.sum { |numbers| numbers.fetch(i) } }

      # A statement's numbers, or several's added up, by measure (time in
      # µs).
      def self.by_measure(numbers)
        NAMES.each_with_index.to_h { |name, i| [name, (name == "postgres_time") ? numbers.fetch(i).fdiv(1000) : numbers.fetch(i)] }
      end

      # Read over +connection+, the plugin's own (a worker's).
      def initialize(connection)
        @connection = connection
        @texts = {} # (each statement's, once)
        # (The last reading's numbers, and theirs added up.)
        @numbers = {} #: Hash[String, numbers]
        @sums = NOTHING.dup
      end

      # What the server has done so far, all told, by measure, and by
      # statement (the reading's context, a Reading, for #details).
      def read
        ids, calls, rows, blocks, ms = PostgreSQL.columns(@connection.value)
        previous = @numbers
        numbers = previous
        changed = [] #: Array[String]
        ids.each_with_index do |id, i|
          was = previous[id]
          time = PostgreSQL.ns(ms.fetch(i))
          next if was && was.fetch(0) == calls.fetch(i) && was.fetch(1) == rows.fetch(i) && was.fetch(2) == blocks.fetch(i) &&
            was.fetch(3) == time

          # (The last reading's Hash is its own: copied, at the first change.)
          numbers = previous.dup if numbers.equal?(previous)
          now = numbers[id] = [calls.fetch(i), rows.fetch(i), blocks.fetch(i), time]
          changed << id
          was ||= NOTHING
          NAMES.each_index { |n| @sums[n] += now.fetch(n) - was.fetch(n) }
        end
        numbers = forget(numbers, ids) if numbers.size > ids.size
        @numbers = numbers.freeze
        [Statements.by_measure(@sums), Reading.new(numbers, previous, changed)]
      end

      # The statements that did the most of each measure in a sample's
      # stretches (pairs of #read's readings: see Snapshot#details), by
      # measure: how many times each ran an iteration (+n+ of them), "an
      # iteration: 2× SELECT name FROM items WHERE id = $1", and each
      # one's share of the rest, "SELECT name FROM items WHERE id = $1
      # (75%)".
      def details(stretches, n)
        grew = grew(stretches)
        texts = texts(grew.keys)
        NAMES.each_with_index.filter_map do |name, i|
          top = grew.filter_map { |id, more| [more.fetch(i), texts.fetch(id, id)] if more.fetch(i).positive? } #: Array[[Integer, String]]
          next if top.empty?

          shown = top.sort_by { |value, text| [-value, text] }.first(SHOWN)
          told = if i.zero? # (queries)
            "an iteration: #{shown.map { |value, text| "#{format("%.4g", value.fdiv(n))}× #{text}" }.join("; ")}"
          else
            all = top.sum { |value, _| value }
            shown.map { |value, text| "#{text} (#{format("%.3g%%", value * 100.0 / all)})" }.join("; ")
          end
          [name, told]
        end.to_h
      end

      private

      # What each statement did in the +stretches+, all told, by query
      # id: those that did anything.
      def grew(stretches)
        grew = {} #: Hash[String, numbers]
        stretches.each do |started, stopped|
          before = started.context.numbers
          after = stopped.context
          # (Read right after +started+, it says which changed since: the
          # others can't have done anything.)
          ids = after.previous.equal?(before) ? after.changed : after.numbers.keys
          ids.each do |id|
            now = after.numbers.fetch(id)
            was = before.fetch(id, NOTHING)
            so_far = grew.fetch(id, NOTHING)
            grew[id] = Array.new(now.size) { |i| so_far.fetch(i) + now.fetch(i) - was.fetch(i) }
          end
        end
        grew.select { |_, more| more.any?(&:positive?) }
      end

      # The +numbers+ of the statements with these query ids (+ids+, of
      # every statement in pg_stat_statements: those gone, the oldest past
      # pg_stat_statements.max, or every one after a reset, forgotten),
      # and their sums.
      def forget(numbers, ids)
        kept = numbers.slice(*ids)
        @sums = Statements.sum(kept.values)
        kept
      end

      # Each statement's text, squeezed onto a line, by query id: those
      # not yet known read from the server.
      def texts(ids)
        unknown = ids.reject { |id| @texts.key?(id) }
        PostgreSQL.texts(@connection.value, unknown).each { |id, query| @texts[id] = shorten(query.split.join(" ")) } unless unknown.empty?
        @texts
      end

      def shorten(text) = (text.length > TEXT) ? "#{text[0, TEXT - 1]}…" : text
    end

    # A worker's database cluster: a copy of one initdb'd once, with the
    # database and pg_stat_statements created in it.
    class Cluster
      # The real directory of the postgres on +path+ (where its initdb is:
      # the one on the PATH may be another version's, libpq's, say), or of
      # the newest Debian's; nil if there's none.
      def self.find_bin(path = ENV.fetch("PATH", ""), debian: "/usr/lib/postgresql/*/bin")
        postgres = path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "postgres") }.find { |file| File.executable?(file) }
        return File.dirname(File.realpath(postgres)) if postgres

        Dir[debian].max_by { |dir| File.basename(File.dirname(dir)).to_i }
      end

      def initialize(resource, bin)
        @resource = resource
        @bin = bin
      end

      # Makes one in +data+: a copy of the one made for these programs.
      def create(data)
        FileUtils.cp_r(@resource.cached(key) { |dir| make(dir) }, data)
        File.chmod(0o700, data) # (as postgres insists)
      end

      private

      # What a cluster is good for: these programs (until they change),
      # and this version of the plugin.
      def key
        postgres = File.realpath(File.join(@bin, "postgres"))
        "postgresql-#{VERSION}-#{Digest::SHA256.hexdigest([postgres, File.mtime(postgres).to_f].join("\0"))[0, 16]}"
      end

      def make(data)
        run("initdb", "--pgdata=#{data}", "-U", USER, "-A", "trust", "-E", "UTF8", "--locale=C", "--no-sync")
        single(data, "postgres", "CREATE DATABASE #{DATABASE}")
        single(data, DATABASE, "CREATE EXTENSION pg_stat_statements")
      end

      # Runs a statement in the cluster's +database+, in single-user mode:
      # no server to start, and stop.
      def single(data, database, sql)
        input = @resource.path("single.sql")
        File.write(input, "#{sql}\n")
        run("postgres", "--single", "-D", data, "-c", "exit_on_error=on", database, in: input)
      end

      # Runs one of the programs (to its end), logged as its name.
      def run(program, *args, **options) = @resource.run(File.join(@bin, program), *args, **options)
    end
  end
end
