# frozen_string_literal: true

module Duel
  # The statistics behind a verdict: a distribution-free confidence
  # interval for the median of paired ratios (candidate / baseline), and
  # the decision it supports.
  # @api private
  module Stats
    class << self
      # The 1-based ranks [lower, upper] of the order statistics that bound
      # a +confidence+ interval for the median of +n+ samples, or nil when
      # +n+ is too small for one (fewer than 8 samples, at 99%). It's
      # distribution-free: the true median lies below the k-th smallest
      # sample with probability P(Binomial(n, 1/2) <= k - 1), whatever the
      # samples' distribution, so one outlier can't move it.
      #
      # The least k whose P(Binomial(n, 1/2) <= k) exceeds the tail, its
      # terms each found from the last (C(n, k + 1) = C(n, k) * (n - k) /
      # (k + 1), exactly), so that a thousand benchmarks across the board
      # take a thousand steps, not a billion.
      def median_ranks(n, confidence)
        tail = (1 - confidence) / 2
        whole = 2**n
        k = 0
        term = cumulative = 1
        # (It ends: at k = n, cumulative is the whole.)
        until cumulative.fdiv(whole) > tail
          term = term * (n - k) / (k + 1)
          k += 1
          cumulative += term
        end
        [k, n + 1 - k] if k.positive?
      end

      # [low, high] bounds of the +confidence+ interval for the median of
      # +samples+, or nil (see #median_ranks).
      def median_interval(samples, confidence)
        ranks = median_ranks(samples.size, confidence)
        return unless ranks

        sorted = samples.sort
        lower, upper = ranks
        [sorted.fetch(lower - 1), sorted.fetch(upper - 1)]
      end

      def median(samples)
        sorted = samples.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted.fetch(mid) : (sorted.fetch(mid - 1) + sorted.fetch(mid)) / 2.0
      end

      # What paired ratios (candidate / baseline, so above 1 is slower) say
      # against +limit+ (a ratio above 1): see #decide.
      def verdict(ratios, limit:, confidence:) = decide(median_interval(ratios, confidence), limit)

      # What a confidence +interval+ for the median ratio (or nil, for too
      # few) says against +limit+: :slower when it lies above the limit,
      # :faster when it lies below 1 / limit, :same when it lies below the
      # limit (it isn't slower: nothing more needs proving), and :undecided
      # while it straddles the limit.
      def decide(interval, limit)
        return :undecided unless interval

        low, high = interval
        return :slower if low > limit
        return :faster if high < 1 / limit
        return :same if high < limit

        :undecided
      end
    end
  end
end
