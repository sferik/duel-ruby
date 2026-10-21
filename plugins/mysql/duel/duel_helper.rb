# frozen_string_literal: true

# The plugin's own work, around every sample of every benchmark: a
# reading of the worker's server (Statements#read) before and after it,
# and what explains it (Statements#details), after it. Most benchmarks
# time the plugin's Ruby, over a connection that answers from what it's
# given (Canned), so the server's timing (and its settling) isn't in
# them.

# A worker's server, as performance_schema has it after a suite's
# statements ran: +size+ statements by digest, each one's [queries,
# rows, rows examined, time (ps)] so far, the same for every run.
def digest_table(size, seed: 42)
  random = Random.new(seed)
  Array.new(size) do
    numbers = [random.rand(1..10_000), random.rand(0..100_000), random.rand(0..1_000_000), random.rand(1_000_000..10**12)]
    [random.bytes(32).unpack1("H*"), numbers]
  end.to_h
end

# The same, after +ran+ of them ran again (the first ones): a reading at
# a stretch's end.
def ran_again(statements, ran, seed: 7)
  random = Random.new(seed)
  statements.each_with_index.to_h do |(digest, numbers), i|
    [digest, (i < ran) ? numbers.map { |number| number + random.rand(1..1_000) } : numbers]
  end
end

# A connection to a worker's server, as the plugin uses one, that answers
# its queries from +tables+ (the server's statements, by digest, as
# #digest_table makes them, at each reading in turn, round and round,
# the last one's first) with Trilogy's own results, made once: no other
# connection running a statement, the server's totals, the statements
# (all of them, or those run since the reading before, as the server
# has them), their digests and their texts (a typical one's, from an
# Active Record app).
class Canned
  # A reading, as Statements#details takes it: what Statements#read read
  # by statement, as its context.
  Reading = Data.define(:context)

  # The plugin's connection, as Statements takes it (a worker's: see
  # Config#in_worker).
  Worker = Data.define(:value)

  TEXT = "SELECT `posts` . * FROM `posts` WHERE `posts` . `author_id` = ? AND `posts` . `published` = ? " \
    "ORDER BY `posts` . `created_at` DESC LIMIT ?"

  def initialize(*tables)
    @idle = result([[0]])
    @totals = result([[12_345, 67_890, 234_567, 89_012_345_678]])
    @all = tables.map { |statements| statements(statements) }
    @ran = tables.each_with_index.map { |statements, i| statements(statements.reject { |digest, numbers| tables[i - 1][digest] == numbers }) }
    @reading = -1
    @read = false
    @own = result([["0" * 64]])
    @texts = result(tables.flat_map(&:keys).uniq.map { |digest| [digest, TEXT] })
  end

  def query(sql)
    case sql
    when Duel::MySQL::BUSY then @idle
    when Duel::MySQL::STATS then @totals
    when /\ASELECT DIGEST, COUNT_STAR/ then statements_since(sql)
    when /\ASELECT STATEMENT_DIGEST/ then @own
    else @texts
    end
  end

  def quote(text) = "'#{text}'"

  private

  # The statements at the next reading: all of them, to a query for all
  # (or the first), or those run since the reading before.
  def statements_since(sql)
    reading = @reading
    @reading = (reading + 1) % @all.size
    since = @read && sql.include?("LAST_SEEN")
    @read = true
    since ? @ran.fetch(reading) : @all.fetch(reading)
  end

  def statements(statements) = result(statements.map { |digest, numbers| [digest, *numbers] })

  def result(rows) = Trilogy::Result.new([], rows, 0.0, false, 0, 0)
end

# Statements read over a Canned connection to +tables+, read once (the
# last of them), then for a sample of +stretches+ (so the texts of those
# that ran are read, as they are after a worker's first samples, and the
# next reading is the first table's).
def canned(*tables, stretches: 1)
  Duel::MySQL::Statements.new(Canned::Worker.new(Canned.new(*tables))).tap do |canned|
    canned.read
    sample(canned, stretches)
  end
end

# The plugin's work for a sample of +stretches+ stretches (more than
# one, with untimed blocks), over +statements+: a reading at each one's
# start and stop, and what explains the sample.
def sample(statements, stretches = 1)
  readings = Array.new(stretches) { [Canned::Reading.new(statements.read.last), Canned::Reading.new(statements.read.last)] }
  statements.details(readings, 10)
end
