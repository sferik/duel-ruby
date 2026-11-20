# frozen_string_literal: true

require "duel"
require "socket"
require_relative "redis/version"

module Duel
  # A Redis server of each worker's own, and what it did for each
  # benchmark:
  #
  # - redis_cpu: the time Redis spent running commands, in microseconds
  #   (judged by ratio, as CPU time is)
  # - redis_commands: the commands it ran (counted)
  # - redis_round_trips: the replies it wrote, one per round trip (counted)
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :redis }
  #
  # Benchmarks can call Duel::Redis.url, and Duel::Redis.reset in setup
  # (or untimed blocks): while a benchmark is measured, it fails.
  #
  # The server listens only on a Unix socket in the worker's directory
  # (or with +tcp+, on a port of 127.0.0.1's alone: by default on Windows,
  # whose builds of Redis, Cygwin's or MSYS2's, have Unix sockets of their
  # own, which Windows's Ruby can't reach), and works there too (--dir):
  # what its options make it write, a snapshot or an append-only file,
  # goes there, never in the project.
  # Its URL is in DUEL_REDIS_URL, and in REDIS_URL too (unless +env+
  # names others), so a client that reads that finds it.
  module Redis
    Duel.plugin(:redis, self)

    URL = "DUEL_REDIS_URL"

    # Every server's options: no TCP port, and nothing written to disk.
    OPTIONS = ["--port", "0", "--save", "", "--appendonly", "no"].freeze

    # Configures Duel for the plugin (c.use :redis): the server
    # (+server+ is the program, +settings+ more of its configuration's
    # directives: maxmemory: "64mb", as --maxmemory 64mb) and its
    # metrics. Returns the plugin's own connection to it, a worker's
    # (see Config#in_worker, and in tests, Duel::Testing.in_worker).
    def self.configure(config, server: ENV.fetch("DUEL_REDIS_SERVER", "redis-server"), settings: {}, env: %w[REDIS_URL],
      tcp: !Duel.unix_sockets?)
      config.prepare(:worker) do |w|
        program = Duel.find_program(server) ||
          w.fail!("no #{server}#{" on the PATH" unless Duel.path?(server)} (give redis-server's path as server:, or DUEL_REDIS_SERVER)")
        if tcp
          port = w.port
          listen = ["--port", port.to_s, "--bind", "127.0.0.1"]
          url = "redis://127.0.0.1:#{port}"
        else
          socket = w.path("redis.sock")
          listen = ["--unixsocket", socket]
          url = "unix://#{socket}"
        end
        # (Where it listens after OPTIONS, whose port of 0 a port takes the
        # place of, and +settings+ last: of a directive given twice, the
        # server takes the last.)
        w.spawn(program, "--dir", w.dir, *OPTIONS, *listen, *settings.flat_map { |name, value| ["--#{name}", value.to_s] })
        w.wait_until { Connection.ping(url) }
        ([URL] + env).to_h { |name| [name, url] }
      end
      connection = config.in_worker { |w| Connection.new(url).tap { |redis| w.at_stop { redis.close } } }
      config.metric(METRICS) { stats(connection.value) }.costly
      connection
    end

    # redis_cpu is the server's time on the clock (Redis times each
    # command so), and another process's, so what else the machine does
    # shows in it: it's judged on each benchmark, but left out across the
    # board, where the margin is too small for it, as duel-mysql's and
    # duel-postgresql's time are.
    METRICS = {
      "redis_cpu" => {kind: :ratio, unit: "µs", floor: 300, across: false},
      "redis_commands" => {kind: :counted, unit: %w[command commands]},
      "redis_round_trips" => {kind: :counted, unit: ["round trip", "round trips"]}
    }

    # What the worker's server has done so far, read over +connection+:
    # every command's time but INFO's own (the reading's, too slight to
    # count but not steady enough to take away), and every command and
    # reply.
    def self.stats(connection)
      info = connection.call("INFO", "all") #: String
      usec = calls = 0
      info.scan(/^cmdstat_([^:]+):calls=(\d+),usec=(\d+)/) do |command, c, u|
        calls += Integer(c)
        usec += Integer(u) unless command == "info"
      end
      {"redis_cpu" => usec, "redis_commands" => calls, "redis_round_trips" => Integer(info[/^total_writes_processed:(\d+)/, 1])}
    end

    # For benchmarks: the worker's server.
    def self.url = ENV.fetch(URL)

    # Empties it, over a connection of its own (opened and closed: a Unix
    # socket's is cheap). For setup or untimed blocks only: while a
    # benchmark is measured (Duel.measuring?) it fails, as its FLUSHALL
    # would be counted.
    def self.reset
      Duel.unmeasured!("Duel::Redis.reset")

      connection = Connection.new(url)
      begin
        connection.call("FLUSHALL") #: String
      ensure
        connection.close
      end
    end

    # The least a connection needs to read a server's statistics: not the
    # code's own, whose commands are what's measured.
    class Connection
      CLOSED = "Redis closed the connection"

      # The first byte of a reply: its type, one of RESP2's.
      STATUS, ERROR, INTEGER, BULK, ARRAY = "+-:$*".bytes

      # A socket to the server at +url+: unix://PATH (or PATH alone), or
      # redis://HOST:PORT, without TCP's delay before a small write (a
      # command), whose reply would wait for it.
      def self.socket(url)
        address = address(url)
        return UNIXSocket.new(url.delete_prefix("unix://")) unless address

        host, port = address
        # (RBS's setsockopt takes an Integer for the value, but Ruby's
        # takes true too.)
        TCPSocket.new(host, port).tap { |socket| socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true) } # steep:ignore ArgumentTypeMismatch
      end

      # The host and port of a redis:// URL, or nil (a Unix socket's).
      def self.address(url)
        match = %r{\Aredis://([^:/]+):(\d+)\z}.match(url) or return
        [match[1], Integer(match[2])]
      end

      def self.ping(url)
        connection = socket(url)
        begin
          connection.write("PING\r\n")
          connection.gets == "+PONG\r\n"
        ensure
          connection.close
        end
      rescue SystemCallError, IOError # (JRuby's refusal on a Unix socket is an IOError)
        false
      end

      def initialize(url)
        @socket = Connection.socket(url)
      end

      # Sends a command; returns its reply, read whole (every type RESP2
      # has): a status or a bulk string as a String, an integer as an
      # Integer, a missing one (a nil bulk string or array) as nil, and an
      # array as an Array of replies, any error in it a RuntimeError. An
      # error reply raises it. A reply cut short (the server gone) raises
      # IOError.
      #
      # The connection never sends HELLO, so Redis answers in RESP2. A
      # reply of a type RESP2 doesn't have (RESP3's, after a HELLO 3)
      # closes the connection, as the rest of it can't be read, and raises
      # IOError.
      def call(*args)
        command = "*#{args.size}\r\n"
        args.each do |arg|
          arg = arg.to_s
          command << "$#{arg.bytesize}\r\n#{arg}\r\n"
        end
        @socket.write(command)
        reply = read
        raise reply if reply.is_a?(Exception)

        reply
      end

      def close = @socket.close

      private

      # A reply, and every element of an array's: its first line's type
      # (its first byte), then what follows it.
      def read
        line = (@socket.gets or raise IOError, CLOSED)
        line.chomp!
        case line.getbyte(0)
        when STATUS then line.byteslice(1..)
        when BULK then bulk(number(line))
        when INTEGER then number(line)
        when ARRAY then array(number(line))
        when ERROR then RuntimeError.new("Redis: #{line.byteslice(1..)}")
        else
          close
          raise IOError, "Redis: a reply of a type the connection doesn't read (RESP2 only): #{line}"
        end
      end

      # A line's number, after its type: the type byte made a space rather
      # than cut (which would copy the line), as Integer() skips one.
      def number(line)
        line.setbyte(0, 32)
        Integer(line)
      end

      # A bulk string of +size+ bytes, and its CRLF (nil for size -1, a
      # missing one).
      def bulk(size)
        return if size == -1

        @socket.read(size + 2)&.delete_suffix!("\r\n") or raise IOError, CLOSED
      end

      # An array of +size+ replies (nil for size -1, a missing one).
      def array(size)
        Array.new(size) { read } unless size == -1
      end
    end
  end
end
