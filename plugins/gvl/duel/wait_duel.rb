# frozen_string_literal: true

require_relative "duel_helper"

# What gvl_wait does around every sample of every benchmark: outside
# what's measured (Duel reads metrics outside its own), but in how long
# every run of every project that uses it takes.
setup { load_hook }

duel "wait: start and stop around a sample of a benchmark with threads of its own" do
  once do
    @start, @stop = sample_methods(Duel::GVL::Wait.new)
    @threaded = sample(:timing)
  end
  @start.call(@threaded)
  @stop.call
end

# Most benchmarks: nothing to measure, and nothing done.
duel "wait: start and stop around a sample of a benchmark without" do
  once do
    @start, @stop = sample_methods(Duel::GVL::Wait.new)
    @unthreaded = sample(nil)
  end
  @start.call(@unthreaded)
  @stop.call
end
