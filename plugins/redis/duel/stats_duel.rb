# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's metrics read the server's totals before and after every
# sample (and twice in a row, a few times, to calibrate): what reading
# them costs adds to every sample of every benchmark.

# Parsing alone: INFO's reply, from a fixed one.
duel "stats: parse a fresh server's INFO" do
  once { @connection = Answering.new(info("fresh")) }
  Duel::Redis.stats(@connection)
end

duel "stats: parse INFO after a typical benchmark" do
  once { @connection = Answering.new(info("typical")) }
  Duel::Redis.stats(@connection)
end

duel "stats: parse INFO after every command" do
  once { @connection = Answering.new(info_of_every_command) }
  Duel::Redis.stats(@connection)
end

# A reading as a worker takes it: INFO over the plugin's connection, and
# its reply parsed (judged on its allocations: the socket's time is too
# noisy to).
duel "stats: read a server after a typical benchmark", only: :count do
  once do
    connect
    16.times { |i| @redis.call("SET", "k#{i}", "v") }
  end
  Duel::Redis.stats(@redis)
end

teardown { @redis&.close }
