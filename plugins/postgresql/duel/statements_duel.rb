# frozen_string_literal: true

require_relative "duel_helper"

# Every sample reads the server's statements twice, at its start and its
# end (Statements#read: each one's numbers, those that changed since the
# last reading made anew, and the totals), and is explained by what each
# statement did in it (Statements#details), all outside the benchmark's
# timing but inside its worker's time. A worker's server has every
# statement its benchmarks ran so far (pg_stat_statements normalizes
# them: a statement is one however many constants it ran with), and a
# sample touches a few. A reading of none changed is a sample's of no
# queries.
[20, 500, 2000].each do |count|
  duel "read: #{count} statements so far" do
    once { @statements = Duel::PostgreSQL::Statements.new(Server.new(statement_rows(count))).tap(&:read) }
    @statements.read
  end
end

# A reading after a sample: the few statements it ran have changed, and
# the rest are as they were. (Each reading goes from one of two states
# of the server to the other, so as many change every time.)
[[10, 2000], [50, 500]].each do |touched, count|
  duel "read: #{touched} of #{count} statements changed since the last" do
    once do
      rows = statement_rows(count)
      @states = [Rows.new(grown_rows(rows, touched)), Rows.new(rows)]
      @server = Server.new(rows)
      @statements = Duel::PostgreSQL::Statements.new(@server).tap(&:read)
    end
    @server.rows = @states.rotate!.first
    @statements.read
  end
end

duel "details: a sample of no queries, of 500 statements so far" do
  once { @statements, @stretches = sample(500, touched: 0) }
  @statements.details(@stretches, 100)
end

duel "details: a sample of 3 statements, of 20 so far" do
  once { @statements, @stretches = sample(20, touched: 3) }
  @statements.details(@stretches, 100)
end

duel "details: a sample of 50 statements, of 500 so far" do
  once { @statements, @stretches = sample(500, touched: 50) }
  @statements.details(@stretches, 100)
end

duel "details: a sample of 10 statements in 3 stretches, of 100 so far" do
  once { @statements, @stretches = sample(100, touched: 10, stretches: 3) }
  @statements.details(@stretches, 100)
end

# A statement's text is read from the server the first time a sample
# touches it, and squeezed onto a line, shortened.
duel "details: 50 statements' texts, the first time" do
  once do
    _, @stretches = sample(500, touched: 50)
    rows = statement_rows(500)
    @server = Server.new(rows, statement_texts(rows))
  end
  Duel::PostgreSQL::Statements.new(@server).details(@stretches, 100)
end
