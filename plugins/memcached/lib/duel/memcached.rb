# frozen_string_literal: true

require "duel"
require "socket"
require_relative "memcached/version"

module Duel
  # A memcached server of each worker's own, and what it did for each
  # benchmark:
  #
  # - memcached_operations: the keys it fetched, stored, touched,
  #   deleted, incremented or decremented, and flushes (counted)
  # - memcached_misses: the operations that found no key (counted)
  # - memcached_bytes: the bytes it read and wrote, the protocol's and
  #   the values' (counted)
  # - memcached_cpu: its CPU time, in microseconds (judged like CPU
  #   time; only with cpu: true)
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :memcached }
  #
  # Benchmarks can call Duel::Memcached.servers, and
  # Duel::Memcached.flush in setup (or untimed blocks): while a benchmark
  # is measured, it fails.
  #
  # The server listens only on a Unix socket in the worker's directory,
  # with one thread (so its statistics are up to date when they're read);
  # the socket's path is in DUEL_MEMCACHED_SERVERS, and in
  # MEMCACHE_SERVERS too (unless +env+ names others), so a client that
  # reads that (Dalli does) finds it.
  module Memcached
    Duel.plugin(:memcached, self)

    SERVERS = "DUEL_MEMCACHED_SERVERS"

    # Configures Duel for the plugin (c.use :memcached): the server
    # (+server+ is the program, +args+ more of its options) and its
    # metrics, memcached_cpu too with +cpu+. Returns the plugin's own
    # connection to it, a worker's (see Config#in_worker, and in tests,
    # Duel::Testing.in_worker).
    def self.configure(config, server: ENV.fetch("DUEL_MEMCACHED_SERVER", "memcached"), args: [], env: %w[MEMCACHE_SERVERS], cpu: false)
      config.prepare(:worker) do |w|
        socket = w.path("memcached.sock")
        w.spawn(*[server, "-s", socket, "-m", "32", "-t", "1"] + args)
        w.wait_until { Connection.ready?(socket) }
        ([SERVERS] + env).to_h { |name| [name, socket] }
      end
      connection = config.in_worker { |w| Connection.new(servers).tap { |memcached| w.at_stop { memcached.close } } }
      config.metric(METRICS) { stats(connection.value) }.costly
      config.metric("memcached_cpu", **CPU) { cpu_time(connection.value) }.costly if cpu
      connection
    end

    # (Reading the statistics costs these nothing: stats isn't an
    # operation, and the plugin's own bytes are taken away.)
    METRICS = {
      "memcached_operations" => {kind: :counted, unit: %w[operation operations], calibrate: false},
      "memcached_misses" => {kind: :counted, unit: %w[miss misses], calibrate: false},
      # Values the server makes up (CAS ids, say) grow a digit now and
      # then, and so may the code's own: a byte more an iteration isn't a
      # regression.
      "memcached_bytes" => {kind: :counted, unit: "B", tolerance: 1, calibrate: false}
    }

    # memcached_cpu's settings. Its CPU time is the whole process's (its
    # background threads too), and swings with how the client paces it:
    # noisy, so judged only above 300µs, against a limit of its own, not
    # across the board (where the margin is a quarter of that), and only
    # when asked for. (A metric of its own: read around every sample, as a
    # ratio one is, where the counted ones are read only in counting
    # samples.)
    CPU = {kind: :ratio, unit: "µs", floor: 300, limit: 1.05, across: false}

    # The statistics each is the sum of.
    OPERATIONS = %w[cmd_get cmd_set cmd_touch cmd_flush delete_hits delete_misses incr_hits incr_misses decr_hits decr_misses].freeze
    MISSES = %w[get_misses touch_misses delete_misses incr_misses decr_misses cas_misses].freeze
    BYTES = %w[bytes_read bytes_written].freeze
    RUSAGE = %w[rusage_user rusage_system].freeze

    # What a statistic's line starts with, by its name (made once each).
    NEEDLES = Hash.new { |needles, name| needles[name] = "STAT #{name} " }

    # What the worker's server has done so far, read over +connection+
    # (the plugin's own): its traffic isn't counted (it's known to the
    # byte, while what readings write varies with the numbers in them).
    # Read around every counting sample, it allocates only its Hash.
    def self.stats(connection)
      stats = connection.stats_reply
      {"memcached_operations" => sum(stats, OPERATIONS),
       "memcached_misses" => sum(stats, MISSES),
       "memcached_bytes" => sum(stats, BYTES) - connection.own}
    end

    # Its CPU time so far, in microseconds, read over +connection+: the
    # readings' too, as they're too slight to matter and too unsteady to
    # take away. Read around every sample, it allocates nothing.
    def self.cpu_time(connection) = sum(connection.stats_reply, RUSAGE)

    # The sum of +names+ in +stats+, a stats reply as the server sent it.
    def self.sum(stats, names) = names.sum { |name| value(stats, name) }

    # The value of +name+ in +stats+ (a stats reply), read in place, digit
    # by digit, so as to allocate nothing: rusage_* are seconds with six
    # decimals, microseconds without the point.
    def self.value(stats, name)
      needle = NEEDLES[name]
      at = stats.byteindex(needle) or raise KeyError, "key not found: #{name.inspect}"
      at += needle.bytesize
      raise ArgumentError, "memcached: #{name} isn't a number" unless stats.match?(/\G\d+(?:\.\d+)?\r/, at)

      value = 0
      until (byte = stats.getbyte(at)) == 13 # "\r", where the number ends
        # (A digit, or the point: the value matched, so it's never nil.)
        value = (value * 10) + byte - 48 unless byte == 46 # steep:ignore UnresolvedOverloading
        at += 1
      end
      value
    end

    # For benchmarks: the worker's server (its socket's path).
    def self.servers = ENV.fetch(SERVERS)

    # Empties it, over a connection of its own (opened and closed: a Unix
    # socket's is cheap). A flush is an operation, and its bytes count as
    # any client's: so it's for setup or untimed blocks only, and fails
    # while a benchmark is measured (Duel.measuring?).
    def self.flush
      Duel.unmeasured!("Duel::Memcached.flush")

      connection = Connection.new(servers)
      begin
        connection.flush_all
      ensure
        connection.close
      end
    end

    # The least a connection needs to read a server's statistics (text
    # protocol): not the code's own, whose operations are what's
    # measured. It counts its own traffic.
    class Connection
      # Its bytes the server had counted when it answered the latest
      # stats: those sent (that stats command's too), and those received
      # before its reply.
      attr_reader :own

      # The most read at a time: a whole stats reply (some 2.5KB) at once.
      READ = 65_536

      def self.ready?(path)
        socket = UNIXSocket.new(path)
        begin
          socket.write("version\r\n")
          socket.gets.to_s.start_with?("VERSION ")
        ensure
          socket.close
        end
      rescue SystemCallError, IOError # (JRuby's refusal is an IOError)
        false
      end

      def initialize(path)
        @socket = UNIXSocket.new(path)
        @sent = @received = @own = 0
        @reply = +""
        @chunk = +""
      end

      # The server's statistics, by name: each line's name and value
      # sliced from the reply, without a String for each line.
      def stats
        reply = stats_reply
        stats = {} #: Hash[String, String]
        line = 0
        while reply.getbyte(line) == 83 # "S": a STAT line, not the END after them
          name = line + 5 # after "STAT "
          space = reply.byteindex(" ", name) #: Integer
          line = reply.byteindex("\r\n", space) #: Integer
          key = reply.byteslice(name, space - name) #: String
          value = reply.byteslice(space + 1, line - space - 1) #: String
          stats[key] = value
          line += 2
        end
        stats
      end

      # The server's statistics as it sent them (a line each, then END),
      # read whole into a buffer of the connection's, which the next
      # reading reuses: nothing's allocated.
      def stats_reply
        request("stats\r\n")
        @own = @sent + @received
        @reply.clear
        receive until @reply.end_with?("\r\n") && (!@reply.start_with?("STAT ") || @reply.end_with?("\nEND\r\n"))
        raise "memcached: #{@reply.chomp}" unless @reply.start_with?("STAT ") || @reply == "END\r\n"

        @reply
      end

      # Empties the server; returns its reply.
      def flush_all
        request("flush_all\r\n")
        reply
      end

      def close = @socket.close

      private

      # +command+ is a line, its CRLF too. (Written straight to the
      # socket, which write would allocate for.)
      def request(command)
        @sent += @socket.syswrite(command)
      end

      # Appends what the server sent next to the reply.
      def receive
        @socket.readpartial(READ, @chunk)
        @received += @chunk.bytesize
        @reply << @chunk
      rescue EOFError
        raise IOError, "memcached closed the connection"
      end

      def reply
        line = @socket.gets or raise IOError, "memcached closed the connection"
        @received += line.bytesize
        line = line.chomp
        raise "memcached: #{line}" if line.match?(/\A(?:ERROR|CLIENT_ERROR|SERVER_ERROR)/)

        line
      end
    end
  end
end
