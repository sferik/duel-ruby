# frozen_string_literal: true

require_relative "duel_helper"

# What a worker does around every sample, and between its iterations:
# the less it does, the less it adds to what it measures.
setup do
  # (A sample's own collecting and holding off the garbage collector
  # would do so for the sample measuring it too: it only holds it off.)
  sample = Subject::Duel::Sample
  sample.send(:remove_const, :QUIET_GC)
  sample.const_set(:QUIET_GC, -> { GC.disable })
end

duel "sample: start and stop, with three metrics" do
  once do
    @definition = Subject::Duel::Definition.new("work", nil, false, __FILE__, -> {}, own_hooks)
    @metrics = three_metrics
  end
  sample = Subject::Duel::Sample.new(@definition, @metrics, n: 1, counting: true)
  sample.start
  sample.stop
end

duel "sample: 1000 iterations of an empty benchmark" do
  once do
    definition = Subject::Duel::Definition.new("empty", nil, false, __FILE__, -> {}, own_hooks)
    # (A version without a Harness ran a benchmark in its Context.)
    @harness = (defined?(Subject::Duel::Harness) ? Subject::Duel::Harness : Subject::Duel::Context).new(definition)
    @trial = Subject::Duel::Trial.new
  end
  @harness.run(1000, @trial)
end

# Each iteration of a benchmark with an around_iteration hook pauses and
# resumes every metric.
duel "sample: 100 iterations around each, 3 metrics" do
  once do
    @definition = Subject::Duel::Definition.new("empty", nil, false, __FILE__, -> {}, own_hooks(->(iteration) { iteration.call }))
    @harness = Subject::Duel::Harness.new(@definition)
    @metrics = three_metrics
  end
  @harness.run(100, Subject::Duel::Sample.new(@definition, @metrics, n: 100, counting: true))
end
