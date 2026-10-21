# frozen_string_literal: true

# Paired ratios (candidate / baseline) as a run collects them: around
# +center+, the same for every run.
def ratios(count, center: 1.0, seed: 42)
  random = Random.new(seed)
  Array.new(count) { center + ((random.rand - 0.5) * 0.04) }
end

# A version's Result of a benchmark judged on CPU time alone, with
# +median+ as its median ratio.
def cpu_result(name, median)
  Subject::Duel::Result.new(name).tap do |result|
    result.timed["cpu"] = {"median" => median, "limit" => 1.02, "across" => true}
  end
end

# A StackProf profile, as a worker reports it, of +frames+ frames.
def stackprof(frames, seed:)
  random = Random.new(seed)
  {"samples" => frames * 10, "frames" => Array.new(frames) { |i| ["Frame#m#{i}", random.rand(20), random.rand(40) + 20] }}
end

# Running totals, allocations and CPU time (those available here), as a
# worker makes them (and opens them, a version that does: see
# Duel::Metric#open).
def three_metrics
  total = 0
  totals = Subject::Duel::Snapshot.define({"widgets" => {}}, -> { total += 1 })
  metrics = [totals.new, Subject::Duel::Metrics::Allocations.new, Subject::Duel::Metrics::CPU.new].select { |metric| metric.class.available? }
  metrics.each { |metric| metric.open if metric.class.method_defined?(:open) }
end

# A benchmark's own hooks, as a version's Definition takes them: by name
# (Duel::HOOKS), or, a version from before them, its around block alone.
def own_hooks(around = nil)
  return (around ? {around_iteration: around} : {}) if Subject::Duel.const_defined?(:HOOKS, false)

  around
end
