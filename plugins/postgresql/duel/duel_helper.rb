# frozen_string_literal: true

# The plugin's own work around every sample, on pg_stat_statements' rows
# as a worker's server returns them, from a connection that only answers
# with them: what the server takes to answer isn't the plugin's, and
# isn't the same from one run to the next.

# A query's result, as pg gives it: its rows, every value a String, or
# by column, decoded by a type map (Result#map_types!). It's decoded once:
# pg's decoding isn't the plugin's work.
class Rows
  attr_reader :values

  def initialize(values)
    @values = values
  end

  def map_types!(map)
    @columns ||= map.coders.zip(values.transpose).map { |coder, column| coder ? column.map { |value| coder.decode(value) } : column }
    self
  end

  def column_values(index) = @columns.fetch(index)
end

# A reading of the running totals, as Duel takes one (Snapshot::Reading:
# its totals, and the context the plugin read with them).
Reading = Struct.new(:totals, :context)

# The plugin's connection, a worker's (see Config#in_worker), to a server
# whose pg_stat_statements has these +rows+ (STATEMENTS) and +texts+
# (TEXTS, by query id).
class Server
  attr_accessor :rows

  def initialize(rows, texts = {})
    @rows = Rows.new(rows)
    @texts = texts
  end

  def value = self

  def async_exec(_sql) = @rows

  def exec_params(_sql, (ids))
    Rows.new(ids.delete("{}").split(",").map { |id| [id, @texts.fetch(id)] })
  end
end

# A server's pg_stat_statements, by statement, after +count+ distinct
# statements have run: [query id, calls, rows, blocks, time (ms)], as
# STATEMENTS reads them.
def statement_rows(count, seed: 42)
  random = Random.new(seed)
  Array.new(count) do
    calls = random.rand(1..5000)
    [random.rand(-(2**63)...(2**63)).to_s, calls.to_s, (calls * random.rand(0..20)).to_s,
      (calls * random.rand(1..40)).to_s, (calls * random.rand * 0.2).to_s]
  end
end

# The same rows, after a sample in which the first +touched+ statements
# ran: the first once, the second twice, and so on.
def grown_rows(rows, touched)
  rows.each_with_index.map do |(id, calls, returned, blocks, ms), i|
    next [id, calls, returned, blocks, ms] if i >= touched

    times = i + 1
    [id, (Integer(calls) + times).to_s, (Integer(returned) + (times * 2)).to_s,
      (Integer(blocks) + (times * 3)).to_s, (Float(ms) + (times * 0.01)).to_s]
  end
end

# Statement texts, normalized, as pg_stat_statements keeps them: an
# application's, of every length, some over several lines (and longer
# than a regression's details show).
def statement_texts(rows)
  rows.each_with_index.to_h do |(id), i|
    columns = Array.new((i % 12) + 1) { |c| %("items"."column_#{c}") }.join(", ")
    [id, "SELECT #{columns}\nFROM \"items\"\n  WHERE \"items\".\"id\" = $1 AND \"items\".\"kind\" = $2\nLIMIT $3"]
  end
end

# The plugin's Statements for a server of +count+ statements, and the
# stretches of a sample (pairs of its readings) in each of which the
# first +touched+ statements ran: +stretches+ of them, as untimed blocks
# that ran none make. Every text has been read, as after a first sample.
def sample(count, touched:, stretches: 1)
  rows = statement_rows(count)
  server = Server.new(rows, statement_texts(rows))
  statements = Duel::PostgreSQL::Statements.new(server)
  readings = (0..stretches).map do |i|
    server.rows = Rows.new(i.times.reduce(rows) { |grown, _| grown_rows(grown, touched) })
    Reading.new(*statements.read)
  end
  stretches = readings.each_cons(2).to_a
  statements.details(stretches, 1)
  [statements, stretches]
end
