# frozen_string_literal: true

require_relative "duel_helper"

# A verdict is reached after every round of samples, on all the pairs so
# far (up to Runner::MAX_PAIRS, 60): its confidence interval's ranks come
# from binomial sums.
[10, 30, 60].each do |pairs|
  duel "stats: a verdict on #{pairs} pairs" do
    once { @ratios = ratios(pairs) }
    Subject::Duel::Stats.verdict(@ratios, limit: 1.02, confidence: 0.99)
  end
end
