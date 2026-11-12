# frozen_string_literal: true

require "duel"
require "digest"
require "fileutils"
require "rbconfig"
require "socket"
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
  # The server listens only on a Unix socket in the worker's directory
  # (or with +tcp+, on a port of 127.0.0.1's alone: by default on Windows,
  # whose MySQL has none); its URL is in DUEL_MYSQL_URL, and in
  # DATABASE_URL too (unless +env+ names others), and the socket's path
  # in DUEL_MYSQL_SOCKET (with +tcp+, none). The plugin's connections are
  # a client of its own (see Connection): no gem's.
  module MySQL
    Duel.plugin(:mysql, self)

    URL = "DUEL_MYSQL_URL"
    SOCKET = "DUEL_MYSQL_SOCKET"
    DATABASE = "duel"
    USER = "root"

    # The server's options (after --no-defaults: no my.cnf of the
    # machine's): nothing to disk that needn't be, little
    # memory, no Linux AIO contexts (there are only so many, for every
    # server on the machine), and nothing running on its own
    # (recalculating a table's statistics would change its plans while
    # they're measured).
    OPTIONS = %w[
      --mysqlx=OFF --skip-log-bin
      --innodb-buffer-pool-size=32M --innodb-redo-log-capacity=8M --innodb-doublewrite=OFF --innodb-use-native-aio=OFF
      --innodb-flush-log-at-trx-commit=0 --innodb-stats-auto-recalc=OFF --event-scheduler=OFF --performance-schema=ON
    ].freeze

    # And once it's initialized: stopped like a crash, nothing flushed (as
    # what's in it is thrown away).
    RUNNING = %w[--innodb-fast-shutdown=2].freeze

    # The most memory a worker's server takes (see Duel.plugin), even with
    # OPTIONS: some 450 MB, measured on a GitHub runner, more than it
    # takes as it starts, before it's used.
    def self.worker_memory = 450 << 20

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
      scheme: "mysql2", tcp: Native::WINDOWS)
      config.prepare(:worker) do |w|
        program = DataDir.find_server(server) || w.failed("no #{server} on the PATH (give it as server:, or DUEL_MYSQL_SERVER)")
        data = w.path("data")
        DataDir.new(w, program).create(data)
        if tcp
          port = free_port
          listen = ["--port=#{port}", "--bind-address=127.0.0.1"]
          address = "127.0.0.1:#{port}"
          url = "#{scheme}://#{USER}@127.0.0.1:#{port}/#{DATABASE}"
          vars = {URL => url}
        else
          # (No network at all.)
          address = w.path("mysqld.sock")
          listen = ["--skip-networking", "--socket=#{address}"]
          url = "#{scheme}://#{USER}@localhost/#{DATABASE}?socket=#{address}"
          vars = {URL => url, SOCKET => address}
        end
        w.spawn(program, *(DataDir.options(data) + listen), "--pid-file=#{w.path("mysqld.pid")}", "--tmpdir=#{w.dir}", *(RUNNING + args))
        w.wait_until { Connection.ping(address) }
        run(address, setup) if setup
        vars.merge(env.to_h { |name| [name, url] })
      end
      connection = config.in_worker { |w| Connection.new(address).tap { |mysql| w.at_stop { mysql.close } } }
      statements = Statements.new(connection)
      config.metric(METRICS) { statements.read }.costly.details { |stretches, sample| statements.details(stretches, sample.n) }
      connection
    end

    # A port of 127.0.0.1's that's free (one the system chose, let go of
    # again), for a server of a worker's to listen on.
    # mutant:disable -- any address the system binds to gives a port free
    # alike: 127.0.0.1's is the one the server listens on
    def self.free_port
      # (RBS's TCPServer.new takes a port alone, but Ruby's takes the host
      # before it.)
      server = TCPServer.new("127.0.0.1", 0) # steep:ignore UnexpectedPositionalArgument
      begin
        server.addr.fetch(1)
      ensure
        server.close
      end
    end

    # Runs SQL on a connection of its own to the server at +address+ (its
    # socket's path, or HOST:PORT); returns the last statement's result.
    def self.run(address, sql)
      connection = Connection.new(address)
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

    # Its socket's path (for a client that takes it, not a URL). With
    # +tcp+, there's none (see .url).
    def self.socket = ENV.fetch(SOCKET)

    # Where it is, for the plugin's own connections: its socket's path, or
    # (with +tcp+) its URL's HOST:PORT, in +env+ (a worker's).
    def self.address(env = ENV)
      env.fetch(SOCKET) do
        # (A URL the plugin made, with a HOST:PORT.)
        host_and_port = env.fetch(URL)[%r{@([^/]+)/}, 1] #: String
        host_and_port
      end
    end

    # Runs SQL (statements, ;-separated) on it, over a connection of its
    # own; returns the last one's result. For setting up: it fails while
    # a benchmark is measured (Duel.measuring?), as what it runs would be
    # counted.
    def self.execute(sql)
      Duel.unmeasured!("Duel::MySQL.execute")
      run(address, sql)
    end

    # Empties every table in its database, restarting their
    # AUTO_INCREMENTs. For setting up, as execute is.
    def self.reset
      Duel.unmeasured!("Duel::MySQL.reset")
      tables = run(address, "SELECT table_name FROM information_schema.tables " \
        "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'").map(&:first)
      # (Only this connection's: it's closed after.)
      run(address, "SET FOREIGN_KEY_CHECKS = 0#{tables.map { |table| "; TRUNCATE TABLE `#{table}`" }.join}")
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

    # What a connection to a worker's server raises where it fails: a
    # statement's error (its code and message), or a reply it can't read.
    class Error < Duel::Error
      # The server's error code, or nil (not the server's error).
      attr_reader :code

      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    # A query's result: its columns' names, and its rows, each value a
    # String, but an integer column's an Integer, a floating-point one's a
    # Float, and NULL nil. (One that returns none, an INSERT's, say, has
    # neither.)
    class Result
      include Enumerable

      attr_reader :fields, :rows

      def initialize(fields:, rows:)
        @fields = fields
        @rows = rows
      end

      def each(&) = rows.each(&)
    end

    # The least a connection needs to read a server's statistics: not the
    # code's own, whose statements are what's measured. As root (with no
    # password: the data directory's initialized with none), to its
    # database, over its Unix socket (a path), or over TCP (HOST:PORT: on
    # Windows), in MySQL's text protocol: statements, several to a query
    # if need be, and their results, the last one's returned.
    class Connection
      # What the client says it can do: protocol 4.1's packets, a
      # database to connect to, transactions' statuses, 4.1's (and 8.0's)
      # authentication, several statements to a query, and their results.
      LONG_PASSWORD = 0x1
      CONNECT_WITH_DB = 0x8
      PROTOCOL_41 = 0x200
      TRANSACTIONS = 0x2000
      SECURE_CONNECTION = 0x8000
      MULTI_STATEMENTS = 0x10000
      MULTI_RESULTS = 0x20000
      PLUGIN_AUTH = 0x80000
      CAPABILITIES = LONG_PASSWORD | CONNECT_WITH_DB | PROTOCOL_41 | TRANSACTIONS | SECURE_CONNECTION | MULTI_STATEMENTS | MULTI_RESULTS |
        PLUGIN_AUTH
      # The largest packet it takes, and its character set (utf8mb4).
      MAX_PACKET = (1 << 24) - 1
      UTF8MB4 = 45

      # A packet's first byte: an OK, an error, an end of rows (EOF, of
      # fewer than 9 bytes), or more of authentication's (caching_sha2_
      # password's: FAST_AUTH, the password matched what it had cached).
      OK = 0x00
      ERR = 0xFF
      EOF = 0xFE
      AUTH_SWITCH = 0xFE
      AUTH_MORE = 0x01
      FAST_AUTH = 0x03
      COM_QUERY = 0x03
      # A NULL value in a row, and lenenc integers' prefixes.
      NULL = 0xFB
      # An OK's or EOF's status: more results to come.
      MORE_RESULTS = 0x08

      # The column types read as Integers (TINY, SHORT, LONG, LONGLONG,
      # INT24, YEAR) and as Floats (FLOAT, DOUBLE).
      INTEGERS = [1, 2, 3, 8, 9, 13].freeze
      FLOATS = [4, 5].freeze

      # What the client says it is when the server's gone.
      CLOSED = "MySQL closed the connection"

      # Whether a server answers at +address+.
      def self.ping(address)
        new(address).close
      rescue Error, SystemCallError, IOError
        false
      end

      # The host and port of a HOST:PORT address, or nil (a Unix socket's
      # path).
      def self.address(address)
        match = %r{\A([^:/]+):(\d+)\z}.match(address) or return
        [match[1], Integer(match[2])]
      end

      # A socket to +address+, without TCP's delay before a small write
      # (a statement), whose reply would wait for it.
      def self.socket(address)
        host_and_port = address(address)
        return UNIXSocket.new(address) unless host_and_port

        host, port = host_and_port
        # (RBS's setsockopt takes an Integer for the value, but Ruby's
        # takes true too.)
        TCPSocket.new(host, port).tap { |socket| socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true) } # steep:ignore ArgumentTypeMismatch
      end

      def initialize(address, database: DATABASE)
        @socket = Connection.socket(address)
        begin
          authenticate(database)
        rescue Exception # rubocop:disable Lint/RescueException
          close
          raise
        end
      end

      # Runs +sql+ (statements, ;-separated); returns the last one's
      # result. A statement that fails raises its Error.
      def query(sql)
        write(COM_QUERY.chr + sql, 0)
        loop do
          result, more = next_result
          return result unless more
        end
      end

      # Runs statements; returns the last one's result.
      def execute(sql) = query(sql)

      # +text+ as a string literal.
      def quote(text) = "'#{text.gsub(/[\0\n\r\\'"\x1a]/, ESCAPES)}'"

      ESCAPES = {"\0" => "\\0", "\n" => "\\n", "\r" => "\\r", "\\" => "\\\\", "'" => "\\'", "\"" => "\\\"", "\x1a" => "\\Z"}.freeze

      # Closes it without telling the server (no QUIT, which the server
      # could read after a benchmark's started, and count); true.
      def close
        @socket.close
        true
      end

      private

      # The server's greeting (a handshake, protocol 10), and the client's
      # reply: root, with no password (an empty response, whichever plugin
      # the server authenticates with), to +database+. Fails unless it's
      # let in.
      def authenticate(database)
        greeting, sequence = read
        error!(greeting) if greeting.getbyte(0) == ERR
        # (Its last string: the scramble before it has no NUL in it.)
        plugin = greeting.split("\0").last #: String
        # (23 bytes reserved, and the response's length, 0, before the
        # database.)
        write([CAPABILITIES, MAX_PACKET, UTF8MB4, USER, database, plugin].pack("VVCx23Z*xZ*Z*"), sequence + 1)
        loop do
          reply, sequence = read
          case reply.getbyte(0)
          when OK then return
          when ERR then error!(reply)
          # (Another plugin: an empty response again.)
          when AUTH_SWITCH then write("", sequence + 1)
          # (caching_sha2_password's: the empty password matched.)
          when AUTH_MORE then raise Error, "MySQL wants a password (root's has none)" unless reply.getbyte(1) == FAST_AUTH
          else raise Error, "MySQL: an authentication reply the connection doesn't read: #{reply.getbyte(0)}"
          end
        end
      end

      # A statement's result, and whether more follow: an OK's (no rows),
      # or a result set's (its columns, then its rows, each ended by an
      # EOF). An error raises it.
      def next_result
        packet, = read
        case packet.getbyte(0)
        # (Its status after its affected rows and insert id.)
        when OK then [Result.new(fields: [], rows: []), more?(packet, lenenc(packet, lenenc(packet, 1).last).last)]
        when ERR then error!(packet)
        else
          columns = Array.new(lenenc(packet, 0).first) { column(read.first) }
          read # (the columns' EOF)
          rows = [] #: Array[Array[untyped]]
          while (row = read.first) && !eof?(row)
            rows << row(row, columns)
          end
          # (Its status after its warnings.)
          [Result.new(fields: columns.map(&:first), rows: rows), more?(row, 3)]
        end
      end

      # Whether an OK's or an EOF's status, at +at+, says more results
      # follow.
      def more?(packet, at)
        status = packet.unpack1("v", offset: at) #: Integer
        (status & MORE_RESULTS).positive?
      end

      # An EOF: one of fewer than 9 bytes that starts with EOF (a row can
      # too, with a value's 8-byte length).
      def eof?(packet) = packet.getbyte(0) == EOF && packet.bytesize < 9

      # A column's name, and its type: after six lenenc strings (its
      # catalog, schema, table, original table, name, original name) and
      # its fixed fields' length, its character set (2 bytes) and length
      # (4), then its type.
      def column(packet)
        at = 0
        strings = Array.new(6) do
          string, at = lenenc_string(packet, at)
          string
        end
        _, at = lenenc(packet, at)
        [strings.fetch(4).force_encoding(Encoding::UTF_8), packet.getbyte(at + 6)]
      end

      # A row's values, by its columns' types.
      def row(packet, columns)
        at = 0
        columns.map do |_, type|
          if packet.getbyte(at) == NULL
            at += 1
            next
          end

          value, at = lenenc_string(packet, at)
          cast(value, type)
        end
      end

      def cast(value, type)
        return Integer(value, 10) if INTEGERS.include?(type)
        return Float(value) if FLOATS.include?(type)

        value.force_encoding(Encoding::UTF_8)
      end

      # A length-encoded integer at +at+, and where what follows starts.
      def lenenc(packet, at)
        first = packet.getbyte(at) #: Integer
        size = LENGTHS.fetch(first) { return [first, at + 1] }
        # (Its bytes, little-endian, padded to 8.)
        value = "#{packet.byteslice(at + 1, size)}\0\0\0\0\0\0".unpack1("Q<") #: Integer
        [value, at + 1 + size]
      end

      # A length-encoded integer's prefixes, and its bytes after them (one
      # under 0xFB is the integer itself).
      LENGTHS = {0xFC => 2, 0xFD => 3, 0xFE => 8}.freeze

      # A length-encoded string at +at+, and where what follows starts.
      def lenenc_string(packet, at)
        length, at = lenenc(packet, at)
        string = packet.byteslice(at, length) #: String
        [string, at + length]
      end

      # A packet's payload, and its sequence number.
      def read
        header = read_exactly(4)
        size = header.unpack1("V") #: Integer
        sequence = header.getbyte(3) #: Integer
        [read_exactly(size & MAX_PACKET), sequence]
      end

      def read_exactly(size)
        data = @socket.read(size)
        raise IOError, CLOSED unless data && data.bytesize == size

        data
      end

      # (Its header: its length in 3 bytes, then its sequence number.)
      def write(payload, sequence) = @socket.write([payload.bytesize + (sequence << 24)].pack("V"), payload)

      # Raises an error packet's error: its code (2 bytes), its SQL state
      # (# and 5 characters), and its message.
      def error!(packet)
        code = packet.unpack1("v", offset: 1) #: Integer
        start = (packet.getbyte(3) == 35) ? 9 : 3 # (after the SQL state, where there's one)
        message = packet.byteslice(start..) #: String
        message.force_encoding(Encoding::UTF_8)
        raise Error.new("MySQL: #{message} (#{code})", code: code)
      end
    end

    # A worker's data directory: a copy of one initialized once, with the
    # database created in it.
    class DataDir
      # A program's file ends with +EXE+: on Windows, .exe.
      EXE = RbConfig::CONFIG["EXEEXT"]

      # The server program: +server+ if it's a path, or the one by that
      # name on +path+; nil if there's none. Either may end with +exe+ too
      # (on Windows, .exe: mysqld.exe, for mysqld).
      def self.find_server(server, path = ENV.fetch("PATH", ""), exe: EXE)
        files = server.include?(File::SEPARATOR) ? [server] : path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, server) }
        files.flat_map { |file| [file, "#{file}#{exe}"] }.find { |file| File.executable?(file) }
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
