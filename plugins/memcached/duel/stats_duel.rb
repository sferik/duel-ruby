# frozen_string_literal: true

require_relative "duel_helper"

# What the plugin does around every sample of a project's benchmarks: it
# reads its server's statistics, and sums them into its metrics (the
# counted ones around a counting sample, memcached_cpu around every
# one). The less it does, the less it adds to what it measures.
teardown { @connection.close }

# Over the worker's own server: the round trip, and the reading. (A
# socket's timings are too noisy to settle: these are judged on what
# they allocate.)
duel "stats: read a server's statistics", only: :count do
  once { connect }
  @connection.stats
end

duel "stats: read a server's reply to stats", only: :count do
  once { connect }
  @connection.stats_reply
end

duel "stats: the operations, misses and bytes, from a server", only: :count do
  once { connect }
  Duel::Memcached.stats(@connection)
end

duel "cpu: the CPU time, from a server", only: :count do
  once { connect }
  Duel::Memcached.cpu_time(@connection)
end

# From a reply already there: the parsing and summing alone, which a
# round trip's cost would hide.
duel "stats: parse a stats reply" do
  once { connect_canned }
  @connection.stats
end

duel "stats: read a stats reply" do
  once { connect_canned }
  @connection.stats_reply
end

duel "stats: the operations, misses and bytes, from a stats reply" do
  once { connect_canned }
  Duel::Memcached.stats(@connection)
end

duel "cpu: the CPU time, from a stats reply" do
  once { connect_canned }
  Duel::Memcached.cpu_time(@connection)
end

# Each metric's sum, of a stats reply already read: each value found,
# and read in place.
{"operations" => Duel::Memcached::OPERATIONS, "misses" => Duel::Memcached::MISSES,
 "bytes" => %w[bytes_read bytes_written], "CPU time" => %w[rusage_user rusage_system]}.each do |metric, names|
  duel "sum: the #{metric}, of a stats reply" do
    once do
      connect_canned
      @stats = @connection.stats_reply
    end
    Duel::Memcached.sum(@stats, names)
  end
end
