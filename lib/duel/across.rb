# frozen_string_literal: true

require_relative "stats"

module Duel
  # Whether the candidate is slower across the board: a slowdown smaller
  # than any one benchmark can settle (1% everywhere, say) still shows in
  # all of them together. For each ratio metric, every benchmark judged on
  # it is a sample (its median ratio), and the candidate is slower when a
  # distribution-free confidence interval for their median lies entirely
  # above a quarter of the metric's own margin (1.005, for a limit of
  # 1.02). It takes 8 benchmarks at least. One that says across: false
  # is left out.
  # @api private
  class Across
    # The across-the-board limit for a metric whose own limit is +limit+.
    def self.limit(limit) = 1 + ((limit - 1) / 4.0)

    def initialize(results, confidence:)
      @results = results
      @confidence = confidence
    end

    # {metric => {"median", "interval", "limit", "benchmarks", "verdict"}}
    # for every ratio metric any benchmark was judged on.
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
      medians.to_h do |metric, list|
        limit = limits.fetch(metric)
        [metric, {"median" => Stats.median(list), "interval" => Stats.median_interval(list, @confidence), "limit" => limit,
                  "benchmarks" => list.size, "verdict" => Stats.verdict(list, limit: limit, confidence: @confidence).to_s}]
      end
    end
  end
end
