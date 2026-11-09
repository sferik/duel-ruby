# frozen_string_literal: true

require_relative "stats"

module Duel
  # Whether the candidate is slower across the board: a slowdown smaller
  # than any one benchmark can settle (1% everywhere, say) still shows in
  # all of them together. For each ratio metric, the candidate is slower
  # when a distribution-free confidence interval lies entirely above a
  # quarter of the metric's own margin (1.005, for a limit of 1.02). It
  # takes 8 benchmarks at least, at 99%. One that says across: false is
  # left out.
  #
  # Where the benchmarks were judged by process (Lane#judge_processes),
  # the interval is over the workers: each has a score, how much faster
  # or slower it was than its lane's other workers on the same
  # benchmarks (see #scores), and the interval is for the ratio of the
  # candidate's workers' scores to the baseline's (Stats.shift_interval).
  # The same workers measure every benchmark in their lane, so a worker
  # whose luck makes it slower is slower at all of them: an interval
  # over the benchmarks would take that for a slowdown across the board.
  # Otherwise, every benchmark judged on the metric is a sample (its
  # median ratio), and the interval is for their median.
  # @api private
  class Across
    # The fewest benchmarks across the board is judged on by process.
    MIN_BENCHMARKS = 8

    # The across-the-board limit for a metric whose own limit is +limit+.
    def self.limit(limit) = 1 + ((limit - 1) / 4.0)

    # +by_process+: whether the run judged benchmarks over workers (see
    # Lane.by_process?), which they're judged across the board by too.
    # Without, it looks for none, so that a run over pairs costs nothing
    # more for them.
    def initialize(results, confidence:, by_process: false)
      @results = results
      @confidence = confidence
      @by_process = by_process
    end

    # {metric => {"median", "interval", "limit", "benchmarks", "verdict"}},
    # and where it's judged by process, "processes" (the workers of each
    # version), for every ratio metric any benchmark was judged on.
    def verdicts
      medians = Hash.new { |h, k| h[k] = [] }
      # @type var limits: Hash[String, Float]
      limits = {}
      @results.each do |result|
        next if result.error || result.skipped

        result.timed.each do |metric, timed|
          next unless timed.fetch("across")

          medians[metric] << timed.fetch("median")
          limits[metric] ||= Across.limit(timed.fetch("limit"))
        end
      end
      return by_process_or_benchmark(medians, limits) if @by_process

      medians.to_h do |metric, list|
        limit = limits.fetch(metric)
        interval = Stats.median_interval(list, @confidence)
        [metric, {"median" => Stats.median(list), "interval" => interval, "limit" => limit, "benchmarks" => list.size,
                  "verdict" => Stats.decide(interval, limit).to_s}]
      end
    end

    private

    # The verdicts of a run that judged benchmarks over workers: over the
    # workers' scores, for a metric with MIN_BENCHMARKS judged by process
    # at least, and else over the benchmarks (+medians+, with +limits+).
    def by_process_or_benchmark(medians, limits)
      found = workers
      medians.to_h do |metric, list|
        limit = limits.fetch(metric)
        processes = found.fetch(metric, [])
        [metric, (processes.size >= MIN_BENCHMARKS) ? by_process(processes, limit) : by_benchmark(list, limit)]
      end
    end

    # Each benchmark's workers' medians (Result#processes), of those
    # judged by process, by metric.
    def workers
      # @type var found: Hash[String, Array[Result::processes]]
      found = Hash.new { |h, k| h[k] = [] }
      @results.each do |result|
        next if result.error || result.skipped

        result.timed.each do |metric, timed|
          each = result.processes[metric]
          found[metric] << each if each && timed.fetch("across")
        end
      end
      found
    end

    # The verdict over every benchmark's median ratio (+list+).
    def by_benchmark(list, limit)
      interval = Stats.median_interval(list, @confidence)
      {"median" => Stats.median(list), "interval" => interval, "limit" => limit, "benchmarks" => list.size,
       "verdict" => Stats.decide(interval, limit).to_s}
    end

    # The verdict over the workers' scores (see #scores), from each
    # benchmark's workers' medians (+processes+: Result#processes).
    def by_process(processes, limit)
      scored = scores(processes)
      bases = scored.fetch("baseline")
      candidates = scored.fetch("candidate")
      interval = Stats.shift_interval(bases, candidates, @confidence)
      {"median" => Stats.shift(bases, candidates), "interval" => interval, "limit" => limit, "benchmarks" => processes.size,
       "processes" => bases.size, "verdict" => Stats.decide(interval, limit).to_s}
    end

    # Each worker's score, by version: the median, over the benchmarks it
    # measured, of how much its median was above or below the median of
    # every worker's in its lane (each version's), as a ratio. A worker's
    # luck (where things landed in its memory) is the same for every
    # benchmark, so it shows in the score, and the scores of two versions
    # whose code is the same are alike.
    def scores(processes)
      deviations = Hash.new { |h, k| h[k] = [] }
      processes.each do |each|
        logs = {"baseline" => each.fetch("baseline"), "candidate" => each.fetch("candidate")}.transform_values do |values|
          values.map { |value| Math.log([value, 1].max) }
        end
        center = Stats.median(logs.values.flatten)
        logs.each do |side, list|
          list.each_with_index { |log, i| deviations[[side, each.fetch("lane"), i]] << (log - center) }
        end
      end
      %w[baseline candidate].to_h do |side|
        [side, deviations.select { |(of, _, _), _| of == side }.values.map { |list| Math.exp(Stats.median(list)) }]
      end
    end
  end
end
