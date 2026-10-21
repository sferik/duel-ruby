# frozen_string_literal: true

require_relative "duel_helper"

# A reading, before and after every sample: the server's totals, by
# measure, and what each statement did since the reading before, by
# digest. A worker's server has every benchmark's statements (each
# worker runs them all): a few dozen for a small suite, hundreds for an
# app's, and up to performance_schema's 10,000. Most benchmarks run none
# of them (their code sends the server nothing), or a few.
[20, 200, 2000].each do |size|
  duel "read: a reading of #{size} statements, none ran since" do
    once { @statements = canned(digest_table(size)) }
    @statements.read
  end
end

duel "read: a reading of 2000 statements, 20 ran since" do
  once do
    table = digest_table(2000)
    @statements = canned(table, ran_again(table, 20))
  end
  @statements.read
end
