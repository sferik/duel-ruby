# frozen_string_literal: true

module Duel
  # The statistics behind a verdict: a distribution-free confidence
  # interval for the median of paired ratios (candidate / baseline), and
  # the decision it supports.
  # @api private
  module Stats
    class << self
      # P(X <= k) for X ~ Binomial(n, 1/2).
      def binomial_cdf(k, n) = (0..k).sum { |i| binomial(n, i) }.fdiv(2**n)

      def binomial(n, k) = (1..k).reduce(1) { |product, i| product * (n - k + i) / i }

      # The 1-based ranks [lower, upper] of the order statistics that bound
      # a +confidence+ interval for the median of +n+ samples, or nil when
      # +n+ is too small for one (fewer than 8 samples, at 99%). It's
      # distribution-free: the true median lies below the k-th smallest
      # sample with probability P(Binomial(n, 1/2) <= k - 1), whatever the
      # samples' distribution, so one outlier can't move it.
      #
      # mutant:disable -- the k sought is well below n, so any range (or
      # step) reaching past it finds the same k.
      def median_ranks(n, confidence)
        tail = (1 - confidence) / 2
        # (One is found: binomial_cdf(n, n) is 1.)
        k = (0..n).find { |i| binomial_cdf(i, n) > tail } #: Integer
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
      # against +limit+ (a ratio above 1): :slower when the whole interval
      # lies above the limit, :faster when it lies below 1 / limit, :same
      # when it lies below the limit (it isn't slower: nothing more needs
      # proving), and :undecided while it straddles the limit.
      def verdict(ratios, limit:, confidence:)
        interval = median_interval(ratios, confidence)
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
