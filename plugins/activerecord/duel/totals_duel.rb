# frozen_string_literal: true

require_relative "duel_helper"

# Reading the totals: Duel does, before and after every sample.
teardown { @counter.unsubscribe }

duel "totals: 100 readings" do
  once do
    @counter = subscribed
    warm(@counter, QUERIES)
  end
  100.times { @counter.totals }
end
