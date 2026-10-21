# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's subscriber, as Active Support calls it for every event a
# user's benchmark makes (its #start and #finish), on its own: what it
# adds to every query is in the user's timings.
teardown { @counter.unsubscribe }

{
  "subscriber: 100 queries" => [{}, replayed(QUERIES)],
  "subscriber: 100 queries, timed" => [{query_time: true}, replayed(QUERIES)],
  "subscriber: 100 queries, some ignored" => [{ignore: ->(payload) { payload[:name] == "Post Count" }}, replayed(QUERIES)],
  "subscriber: 100 queries, 2 KB statements" => [{}, replayed(Array.new(5) { |i| query_payload("SELECT #{i}, '#{"x" * 2048}'") })],
  "subscriber: 100 queries it leaves out" => [{}, replayed(SKIPPED)]
}.each do |name, (options, payloads)|
  duel name do
    once do
      @counter = subscribed(**options)
      @payloads = payloads
      warm(@counter, payloads)
    end
    notify(@counter, @payloads)
  end
end

duel "subscriber: 100 transactions" do
  once do
    @counter = subscribed
    @payloads = replayed(TRANSACTIONS)
  end
  notify(@counter, @payloads, TRANSACTION)
end

duel "subscriber: 100 instantiations" do
  once do
    @counter = subscribed
    @payloads = replayed(INSTANTIATIONS)
  end
  notify(@counter, @payloads, INSTANTIATION)
end
