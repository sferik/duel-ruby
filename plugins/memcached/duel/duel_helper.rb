# frozen_string_literal: true

require "stringio"

# The statistics a memcached 1.6 server gave after 200 sets and 300 gets
# (100 of them misses), as it sends them: a line each, then END.
STATS = File.read(File.join(__dir__, "fixtures", "stats.txt")).gsub("\n", "\r\n").freeze

# A server that answers every command with +reply+ at once, from memory:
# what's timed is the plugin's reading of it, not a round trip.
class CannedServer
  def initialize(reply)
    @reply = StringIO.new(reply)
  end

  def write(command)
    @reply.rewind
    command.bytesize
  end

  alias_method :syswrite, :write

  def gets = @reply.gets

  def readpartial(maxlen, buffer) = @reply.readpartial(maxlen, buffer)

  def close = nil
end

# The plugin's connection to the worker's server (see .duel.rb), as its
# metrics read it.
def connect = @connection = Duel::Memcached::Connection.new(ENV.fetch("DUEL_MEMCACHED_BENCHMARK_SERVER"))

# The plugin's connection, answered by a CannedServer with STATS.
def connect_canned
  connect.close
  @connection.instance_variable_set(:@socket, CannedServer.new(STATS))
end
