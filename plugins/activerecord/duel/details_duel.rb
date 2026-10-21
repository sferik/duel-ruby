# frozen_string_literal: true

require_relative "duel_helper"

# What the plugin says of a sample's queries: Duel asks after every
# sample, so it should cost little. Each iteration sends the queries the
# sample ends with (its +pattern+, whose statements the plugin keeps the
# SQL of: saying what they were forgets them), then explains the last
# queries it counted, in +stretches+ (counted back from the last, as
# [first, last]: one, unless untimed blocks paused the sample), of +n+
# iterations. Each pattern divides the queries it keeps track of
# (Counter::KEPT, 1,000), so every iteration explains the same queries.
teardown { @counter.unsubscribe }

long = Array.new(4) { |i| query_payload("SELECT\n  #{Array.new(100) { |c| %("posts"."column_#{c}") }.join(",\n  ")}\nFROM \"posts\" -- #{i}") }
a, b, c, d = statements(4)
{
  "details: no queries" => [[], [[0, 0]], 1],
  "details: 10 queries, 2 statements" => [[a] * 8 + [b] * 2, [[10, 0]], 1],
  "details: 1000 queries, 4 statements" => [[a] * 5 + [b] * 3 + [c, d], [[1_000, 0]], 100],
  "details: 1000 queries, in 10 stretches" => [[a] * 5 + [b] * 3 + [c, d], Array.new(10) { |i| [1_000 - (100 * i), 910 - (100 * i)] }, 100],
  "details: 100 queries, long statements" => [long * 2 + long.first(2), [[100, 0]], 10]
}.each do |name, (pattern, stretches, n)|
  duel name do
    once do
      @counter = subscribed
      @pattern = pattern.freeze
      @stretches = stretches.freeze
      @n = n
      warm(@counter, pattern.empty? ? QUERIES : pattern)
      # (A sample without queries: none since the last were explained.)
      @counter.details([], 1)
    end
    notify(@counter, @pattern)
    last = @counter.totals.fetch("active_record_queries")
    @counter.details(@stretches.map { |first, final| [Reading.new(last - first), Reading.new(last - final)] }, @n)
  end
end
