# frozen_string_literal: true

require "duel"
require "digest"
require "fileutils"
require "trilogy"
require_relative "mysql/version"

module Duel
  # A MySQL server of each worker's own, and what it did for each
  # benchmark, from its status and performance_schema:
  #
  # - mysql_queries: the statements clients sent it (Questions) (counted)
  # - mysql_rows: the rows they returned or changed (counted)
  # - mysql_rows_examined: the rows it read to run them (counted)
  # - mysql_time: the time it spent running them, in microseconds
  #   (judged like CPU time)
  #
  # Where one regressed, it says which statements did the most of it, on
  # each version (Statements#details).
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :mysql }
  #
  # Benchmarks can call Duel::MySQL.url and .socket, and .execute and
  # .reset in setup (or untimed blocks): while a benchmark is measured,
  # they fail.
  #
  # The server listens only on a Unix socket in the worker's directory;
  # its URL is in DUEL_MYSQL_URL, and in DATABASE_URL too (unless +env+
  # names others), and the socket's path in DUEL_MYSQL_SOCKET.
  module MySQL
    Duel.plugin(:mysql, self)

    URL = "DUEL_MYSQL_URL"
    SOCKET = "DUEL_MYSQL_SOCKET"
    DATABASE = "duel"
    USER = "root"

    # The server's options (after --no-defaults: no my.cnf of the
    # machine's): no network, nothing to disk that needn't be, little
    # memory, no Linux AIO contexts (there are only so many, for every
    # server on the machine), and nothing running on its own
    # (recalculating a table's statistics would change its plans while
    # they're measured).
    OPTIONS = %w[
      --skip-networking --mysqlx=OFF --skip-log-bin
      --innodb-buffer-pool-size=32M --innodb-redo-log-capacity=8M --innodb-doublewrite=OFF --innodb-use-native-aio=OFF
      --innodb-flush-log-at-trx-commit=0 --innodb-stats-auto-recalc=OFF --event-scheduler=OFF --performance-schema=ON
    ].freeze

    # And once it's initialized: stopped like a crash, nothing flushed (as
    # what's in it is thrown away).
    RUNNING = %w[--innodb-fast-shutdown=2].freeze

    # Configures Duel for the plugin (c.use :mysql): the server and its
    # metrics. +server+ is the program, +args+ more of its options,
    # +setup+ SQL each worker's database runs when it's started (a
    # schema, say), +env+ the variables given its URL besides
    # DUEL_MYSQL_URL, and +scheme+ the URL's (Rails takes it for the
    # adapter). A data directory is initialized once (Resource#cached),
    # and each worker's is a copy. Returns the plugin's own connection
    # to it, a worker's (see Config#in_worker, and in tests,
    # Duel::Testing.in_worker).
    def self.configure(config, server: ENV.fetch("DUEL_MYSQL_SERVER", "mysqld"), args: [], setup: nil, env: %w[DATABASE_URL],
      scheme: "mysql2")
      config.prepare(:worker) do |w|
        program = DataDir.find_server(server) || w.failed("no #{server} on the PATH (give it as server:, or DUEL_MYSQL_SERVER)")
        data = w.path("data")
        DataDir.new(w, program).create(data)
        socket = w.path("mysqld.sock")
        w.spawn(program, *DataDir.options(data), "--socket=#{socket}", "--pid-file=#{w.path("mysqld.pid")}", "--tmpdir=#{w.dir}",
          *(RUNNING + args))
        w.wait_until { Connection.ping(socket) }
        run(socket, setup) if setup
        url = "#{scheme}://#{USER}@localhost/#{DATABASE}?socket=#{socket}"
        {URL => url, SOCKET => socket}.merge(env.to_h { |name| [name, url] })
      end
      connection = config.in_worker { |w| Connection.new(socket).tap { |mysql| w.at_stop { mysql.close } } }
      statements = Statements.new(connection)
      config.metric(METRICS) { statements.read }.costly.details { |stretches, sample| statements.details(stretches, sample.n) }
      connection
    end

    # Runs SQL on a connection of its own to the server on +socket+;
    # returns the last statement's result.
    def self.run(socket, sql)
      connection = Connection.new(socket)
      begin
        connection.execute(sql)
      ensure
        connection.close
      end
    end

    # Server time isn't the worker's CPU time: another process's, on the
    # clock, so what else the machine does shows in it. It's judged on
    # each benchmark, but left out across the board, where the margin is
    # too small for it. Its readings leave themselves out (STATS), so
    # there's nothing to take away.
    METRICS = {
      "mysql_queries" => {kind: :counted, unit: %w[query queries], calibrate: false},
      "mysql_rows" => {kind: :counted, unit: %w[row rows], calibrate: false},
      "mysql_rows_examined" => {kind: :counted, unit: %w[row rows], calibrate: false},
      "mysql_time" => {kind: :ratio, unit: "µs", floor: 300, across: false}
    }

    # What the worker's server has done so far, but for this connection
    # (the plugin's own, reading it): the server's totals less the
    # connection's, so nothing's left to take away. Both are as of the
    # last statement that ended (see SETTLE).
    STATS = <<~SQL
      SELECT
        CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Questions') -
          (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME = 'Questions') AS SIGNED),
        CAST(server.sent - mine.sent AS SIGNED), CAST(server.examined - mine.examined AS SIGNED),
        CAST(server.wait - mine.wait AS SIGNED)
      FROM
        (SELECT SUM(SUM_ROWS_SENT + SUM_ROWS_AFFECTED) sent, SUM(SUM_ROWS_EXAMINED) examined, SUM(SUM_TIMER_WAIT) wait
          FROM performance_schema.events_statements_summary_global_by_event_name) server,
        (SELECT SUM(SUM_ROWS_SENT + SUM_ROWS_AFFECTED) sent, SUM(SUM_ROWS_EXAMINED) examined, SUM(SUM_TIMER_WAIT) wait
          FROM performance_schema.events_statements_summary_by_thread_by_event_name
          WHERE THREAD_ID = PS_CURRENT_THREAD_ID()) mine
    SQL

    # Whether a client besides the reading one is running a statement.
    # MySQL answers a statement's client before it's done with it: the
    # statement is counted (in performance_schema) after, so a reading
    # waits for every client to be done with what it was answered, for
    # SETTLE seconds at most (one running a statement still is counted in
    # the next reading instead). A client's thread shows a statement
    # (its PROCESSLIST_COMMAND isn't Sleep) until just before it's
    # counted, and Threads_running counts it until just after, so a
    # reading waits while either does. Threads_running counts the
    # server's event threads too (the event scheduler's, and each event's
    # while it runs), which no client waits for: those are taken away.
    # (It counts no other thread. An event's is counted a little less
    # long than it's in performance_schema, so the two together don't
    # miss a statement while one starts or ends.)
    BUSY = <<~SQL
      SELECT (SELECT COUNT(*) FROM performance_schema.threads
          WHERE CONNECTION_TYPE IS NOT NULL AND PROCESSLIST_COMMAND != 'Sleep' AND THREAD_ID != PS_CURRENT_THREAD_ID()) +
        ((SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Threads_running') -
          (SELECT COUNT(*) FROM performance_schema.threads WHERE NAME IN ('thread/sql/event_scheduler', 'thread/sql/event_worker')) > 1)
    SQL
    SETTLE = 1.0

    # What it has done so far by statement (its digest: a statement with
    # ? for each constant), any connection's, for explaining a regression:
    # of the statements run since a time (in seconds since the epoch, on
    # the server's clock, which is the machine's), but these digests
    # (Connection#quote'd: the plugin's own readings'). A statement's run
    # (LAST_SEEN) is when it ended, but it's counted just after.
    DIGESTS = <<~SQL
      SELECT DIGEST, COUNT_STAR, SUM_ROWS_SENT + SUM_ROWS_AFFECTED, SUM_ROWS_EXAMINED, SUM_TIMER_WAIT
      FROM performance_schema.events_statements_summary_by_digest
      WHERE DIGEST IS NOT NULL AND UNIX_TIMESTAMP(LAST_SEEN) >= %d AND DIGEST NOT IN (%s)
    SQL

    # The digests of these statements (Connection#quote'd), and the texts
    # of these digests.
    DIGEST_OF = "SELECT STATEMENT_DIGEST(%s)"
    TEXTS = "SELECT DIGEST, DIGEST_TEXT FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST IN (%s)"

    # What the worker's server has done so far, but for the plugin's own
    # connection, which reads it (+connection+): [queries, rows, rows
    # examined, time (ps)].
    def self.totals(connection)
      settle(connection)
      connection.query(STATS).rows.flatten # (one row)
    end

    # Waits, SETTLE seconds at most, until the connection reading
    # (+connection+) is the only one running a statement.
    def self.settle(connection)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SETTLE
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return if connection.query(BUSY).rows.flatten.first.zero?
      end
    end

    # The same by measure (time in µs).
    def self.stats(connection) = Statements.by_measure(totals(connection))

    # What the server has done so far, by statement, read over
    # +connection+: those run since +since+ (seconds since the epoch), but
    # the +own+ digests, each one's [digest, queries, rows, rows examined,
    # time (ps)].
    def self.digests(connection, since, own)
      connection.query(format(DIGESTS, since, own.map { |digest| connection.quote(digest) }.join(", "))).rows
    end

    # The digest of each of +statements+, read over +connection+.
    def self.digests_of(connection, statements) = statements.flat_map { |sql| connection.query(format(DIGEST_OF, connection.quote(sql))).rows.flatten }

    # The texts of the statements with these digests, by digest, read
    # over +connection+.
    def self.texts(connection, digests)
      connection.query(format(TEXTS, digests.map { |digest| connection.quote(digest) }.join(", "))).to_h
    end

    # For benchmarks: the worker's server.
    def self.url = ENV.fetch(URL)

    # Its socket's path (for a client that takes it, not a URL).
    def self.socket = ENV.fetch(SOCKET)

    # Runs SQL (statements, ;-separated) on it, over a connection of its
    # own; returns the last one's result. For setting up: it fails while
    # a benchmark is measured (Duel.measuring?), as what it runs would be
    # counted.
    def self.execute(sql)
      Duel.unmeasured!("Duel::MySQL.execute")
      run(socket, sql)
    end

    # Empties every table in its database, restarting their
    # AUTO_INCREMENTs. For setting up, as execute is.
    def self.reset
      Duel.unmeasured!("Duel::MySQL.reset")
      tables = run(socket, "SELECT table_name FROM information_schema.tables " \
        "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'").map(&:first)
      # (Only this connection's: it's closed after.)
      run(socket, "SET FOREIGN_KEY_CHECKS = 0#{tables.map { |table| "; TRUNCATE TABLE `#{table}`" }.join}")
    end

    # Running totals of what the worker's server did, all told (#read),
    # and by statement, to explain a regression with the statements that
    # did the most of it (#details).
    class Statements
      # The measures, in the order of a statement's numbers.
      NAMES = METRICS.keys.freeze

      # The statements a regression is explained with, and how much of
      # each one's text.
      SHOWN = 3
      TEXT = 80

      # A statement not read yet, as a row of MySQL.digests: it did
      # nothing.
      UNREAD = [nil, 0, 0, 0, 0].freeze

      # A statement that did nothing yet.
      NOTHING = [0, 0, 0, 0].freeze

      # Nothing to say (no statement ran).
      NONE = {} #: Hash[String, String]

      # No statement changed.
      UNCHANGED = [] #: Array[String]

      # A reading's context: every statement's row as of it, by digest (a
      # Hash it shares with the last reading, if none changed), the last
      # reading's, and the digests of those that changed since.
      Reading = Data.define(:rows, :previous, :changed)

      # How long before a reading (in seconds) the next one reads the
      # statements run since: a statement's counted just after it's run
      # (see DIGESTS), so one counted while the reading read is read again
      # (and the clock may be set back a little).
      OVERLAP = 1

      # A statement's numbers (or the server's, all told) by measure, time
      # in µs.
      def self.by_measure(numbers)
        NAMES.each_with_index.to_h do |name, i|
          number = numbers.fetch(i)
          [name, (name == "mysql_time") ? number.fdiv(1_000_000) : number]
        end
      end

      # Read over +connection+, the plugin's own (a worker's).
      def initialize(connection)
        @connection = connection
        @texts = {} # (each statement's, once)
        # (The last reading's rows.)
        @rows = {} #: Hash[String, row]
        @since = 0 # (when the next reading reads statements run since)
      end

      # What the server has done so far, all told, by measure, and by
      # statement (the reading's context, a Reading, for #details).
      def read
        connection = @connection.value
        [Statements.by_measure(MySQL.totals(connection)), reading(connection)]
      end

      # The statements that did the most of each measure in a sample's
      # stretches (pairs of #read's readings: see Snapshot#details), by
      # measure, but its own readings': how many times each ran an
      # iteration (+n+ of them), "an iteration: 2× SELECT `name` FROM
      # `items` WHERE `id` = ?", and each one's share of the rest,
      # "SELECT `name` FROM `items` WHERE `id` = ? (75%)".
      def details(stretches, n)
        # (A stretch whose readings share their rows: none changed.)
        return NONE if stretches.all? { |started, stopped| stopped.context.rows.equal?(started.context.rows) }

        grew = grew(stretches)
        texts = texts(grew.keys)
        NAMES.each_with_index.filter_map do |name, i|
          top = grew.filter_map { |digest, more| [more.fetch(i), texts.fetch(digest, digest)] if more.fetch(i).positive? } #: Array[[Integer, String]]
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

      # A Reading, read over +connection+: the server's statements run
      # since (a little before) the last reading, those that changed since
      # put in a copy of its rows.
      def reading(connection)
        own = @own ||= MySQL.digests_of(connection, [BUSY, STATS, format(DIGESTS, 0, "''")])
        since = @since
        @since = Process.clock_gettime(Process::CLOCK_REALTIME, :second) - OVERLAP
        previous = @rows
        rows = previous
        changed = UNCHANGED
        MySQL.digests(connection, since, own).each do |row|
          digest = row.fetch(0)
          next if row == previous[digest]

          # (The last reading's Hash is its own: copied, at the first change.)
          if rows.equal?(previous)
            rows = previous.dup
            changed = [] #: Array[String]
          end
          rows[digest] = row
          changed << digest
        end
        # (None changed, again: the last Reading does. A copy is no
        # reading's previous rows.)
        last = @last
        return last if last && last.previous.equal?(rows)

        @rows = rows.freeze
        @last = Reading.new(rows, previous, changed)
      end

      # What each statement did in the +stretches+, all told, by digest:
      # those that did anything.
      def grew(stretches)
        grew = {} #: Hash[String, numbers]
        stretches.each do |started, stopped|
          before = started.context.rows
          after = stopped.context
          # (Read right after +started+, it says which changed since: the
          # others can't have done anything.)
          digests = after.previous.equal?(before) ? after.changed : after.rows.keys
          digests.each do |digest|
            now = after.rows.fetch(digest)
            was = before.fetch(digest, UNREAD)
            so_far = grew.fetch(digest, NOTHING)
            grew[digest] = Array.new(NAMES.size) { |i| so_far.fetch(i) + now.fetch(i + 1) - was.fetch(i + 1) }
          end
        end
        grew.select { |_, more| more.any?(&:positive?) }
      end

      # Each statement's text, by digest: those not yet known read from
      # the server.
      def texts(digests)
        unknown = digests.reject { |digest| @texts.key?(digest) }
        MySQL.texts(@connection.value, unknown).each { |digest, text| @texts[digest] = shorten(text) } unless unknown.empty?
        @texts
      end

      def shorten(text) = (text.length > TEXT) ? "#{text[0, TEXT - 1]}…" : text
    end

    # A connection to a worker's server, as root, to its database.
    class Connection
      # Whether a server answers on +socket+.
      def self.ping(socket)
        new(socket).close
      rescue Trilogy::Error
        false
      end

      def initialize(socket)
        # (As root: trilogy's user, unless it's given another.)
        @client = Trilogy.new(socket: socket, database: DATABASE, multi_statement: true)
      end

      def query(sql) = @client.query(sql)

      # +text+ as a string literal.
      def quote(text) = "'#{@client.escape(text)}'"

      # Runs statements; returns the last one's result.
      def execute(sql)
        result = query(sql)
        result = @client.next_result while @client.more_results_exist?
        result
      end

      # Closes it without telling the server (no QUIT, which the server
      # could read after a benchmark's started, and count); true.
      def close = @client.discard!
    end

    # A worker's data directory: a copy of one initialized once, with the
    # database created in it.
    class DataDir
      # The server program: +server+ if it's a path, or the one by that
      # name on +path+; nil if there's none.
      def self.find_server(server, path = ENV.fetch("PATH", ""))
        files = server.include?(File::SEPARATOR) ? [server] : path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, server) }
        files.find { |file| File.executable?(file) }
      end

      # The options the server's run with, initializing +data+ or not.
      # (They come first: mysqld takes --no-defaults only there.)
      def self.options(data) = ["--no-defaults", "--datadir=#{data}", *OPTIONS]

      def initialize(resource, server)
        @resource = resource
        @server = server
      end

      # Makes one in +data+: a copy of the one made for this server.
      def create(data) = FileUtils.cp_r(@resource.cached(key) { |dir| make(dir) }, data)

      private

      # What a data directory is good for: this server (until it changes),
      # and this version of the plugin.
      def key
        server = File.realpath(@server)
        "mysql-#{VERSION}-#{Digest::SHA256.hexdigest([server, File.mtime(server).to_f].join("\0"))[0, 16]}"
      end

      # Initializes it (with root's password empty), and creates the
      # database.
      def make(data)
        init = @resource.path("init.sql")
        File.write(init, "CREATE DATABASE #{DATABASE};\n")
        @resource.run(@server, *DataDir.options(data), "--initialize-insecure", "--init-file=#{init}", log: "mysqld-initialize")
      end
    end
  end
end
