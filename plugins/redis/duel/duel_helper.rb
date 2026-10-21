# frozen_string_literal: true

# INFO all's reply, as Connection#call returns it, from a fixture: what a
# Redis 8 server answered (its lines end in CRLF, as Redis writes them).
#
# - fresh: the plugin's second reading of a server nothing else has used
# - typical: after a benchmark's few kinds of command (16 of them)
def info(name) = File.read(File.join(__dir__, "fixtures", "info_#{name}.txt")).chomp.gsub("\n", "\r\n")

# The typical reply, as if every command the server has (449, its COMMAND
# LIST: a worker's server keeps statistics for every benchmark it ran)
# had run: the most commandstats the plugin reads, with their latency
# percentiles.
def info_of_every_command
  random = Random.new(42)
  commands = File.readlines(File.join(__dir__, "fixtures", "commands.txt"), chomp: true)
  stats = commands.map do |command|
    calls = random.rand(1..5000)
    usec = calls * random.rand(1..40)
    "cmdstat_#{command}:calls=#{calls},usec=#{usec},usec_per_call=#{format("%.2f", usec.fdiv(calls))},rejected_calls=0,failed_calls=0"
  end
  latencies = commands.map do |command|
    p50 = random.rand(1.0..40.0)
    "latency_percentiles_usec_#{command}:p50=#{format("%.3f", p50)},p99=#{format("%.3f", p50 * 3)},p99.9=#{format("%.3f", p50 * 5)}"
  end
  info("typical")
    .sub(/(?<=# Commandstats\r\n).*?(?=\r\n\r\n)/m) { stats.join("\r\n") }
    .sub(/(?<=# Latencystats\r\n).*?(?=\r\n\r\n)/m) { latencies.join("\r\n") }
end

# A connection that answers every command with +reply+: Duel::Redis.stats
# over it parses a fixed INFO, without a server.
Answering = Struct.new(:reply) do
  def call(*) = reply
end

# A connection of the plugin's own to the worker's server (see .duel.rb),
# emptied, with its statistics reset; closed by the file's teardown.
def connect
  @redis = Duel::Redis::Connection.new(Duel::Redis.url)
  @redis.call("FLUSHALL")
  @redis.call("CONFIG", "RESETSTAT")
end
