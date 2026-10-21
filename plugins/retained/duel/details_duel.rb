# frozen_string_literal: true

require_relative "duel_helper"

# What the metric says after every sample: nothing, for one that
# retained no more than Duel lets through, but it clears the trace.
duel "details: a sample within its allowance" do
  once do
    build_metric
    @start.call(Iterations.new(1))
    @stop.call
  end
  @metric.details
end

# What it says of a sample that retained more: a walk of every live
# object (the worker's, and those kept) for what the sample traced, by
# class and where it was made. For a leak of one object an iteration,
# over a sample's iterations. (The sample is untimed: it collects the
# garbage, and what details walks is what's left, as it is in a worker.)
[100, 1000].each do |kept|
  duel "details: a sample that kept #{kept} objects" do |n|
    once { build_metric }
    n.times do
      untimed { keep(kept) }
      @metric.details
    end
  end
end
