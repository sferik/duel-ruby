# frozen_string_literal: true

# What the metric learns of a sample: its iterations, n. (Duel::Sample
# is Duel's own; the metric asks nothing else of it.)
Iterations = Data.define(:n)

# Something of a class of its own, for what a sample keeps.
class Kept; end

# The metric, as a worker makes it, measuring nothing yet, and its
# methods that start and stop a sample, as this version of the plugin
# names them (start_sample and stop_sample, or, before them, start and
# stop: Duel's own Metric, the runner's, may have both).
def build_metric
  @metric = Duel::Retained::Objects.new
  started = Duel::Retained::Objects.method_defined?(:start_sample, false)
  @start = @metric.method(started ? :start_sample : :start)
  @stop = @metric.method(started ? :stop_sample : :stop)
end

# Has the metric measure a sample of +n+ iterations that keeps one Kept
# an iteration (a leak), as Duel would, so that it retained more than
# Duel lets through. The last one's are let go first, before the sample
# starts. (They're cleared, not replaced: a stale reference to a
# replaced Array, on the machine stack, would keep them all alive.)
def keep(n)
  (@kept ||= []).clear
  @start.call(Iterations.new(n))
  n.times { @kept << Kept.new }
  @stop.call
end
