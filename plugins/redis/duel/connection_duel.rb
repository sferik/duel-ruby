# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's own connection, for its readings (INFO's bulk reply) and
# Duel::Redis.flush (FLUSHALL's status), and for benchmarks' setup. Its
# time is the socket's, too noisy to judge: these are judged on their
# allocations.
setup { connect }
teardown { @redis.close }

duel("connection: a status reply", only: :count) { @redis.call("PING") }

duel("connection: a command of three arguments", only: :count) { @redis.call("SET", "key", "value") }

duel("connection: INFO all", only: :count) { @redis.call("INFO", "all") }

# INFO all's reply, as big as a server that ran every command makes it.
duel "connection: an 80 KB bulk reply", only: :count do
  once { @redis.call("SET", "big", "x" * 80_000) }
  @redis.call("GET", "big")
end

# An array reply, of a hundred bulk strings (LRANGE's, or MGET's).
duel "connection: an array reply", only: :count do
  once { @redis.call("RPUSH", "list", *Array.new(100) { |i| "value #{i}" }) }
  @redis.call("LRANGE", "list", 0, -1)
end
