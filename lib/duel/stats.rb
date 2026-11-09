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

      # The 1-based rank r whose r-th smallest and r-th largest cross
      # ratio (see #cross_ratios) bound a +confidence+ interval for the
      # ratio between two versions, from +m+ samples of one and +n+ of the
      # other, or nil when they're too few for one (fewer than 5 each, at
      # 99%). It's distribution-free, as long as each version's samples
      # are independent and alike: the true ratio lies below the r-th
      # smallest with probability P(U <= r - 1), for the Mann-Whitney U
      # statistic (see #u_lower_tail), whatever their distribution. So a
      # sample can be a worker process's median, and then the interval
      # accounts for how a process's luck (where things landed in its
      # memory) differs from another's, as an interval over pairs from a
      # few processes can't.
      def shift_rank(m, n, confidence)
        tail = (1 - confidence) / 2
        r = u_lower_tail(m, n).index { |p| p > tail }
        # (None only where the tail is a half or more, at no confidence.)
        r unless r.nil? || r.zero?
      end

      # P(U <= u) for u from 0 to m * n / 2, where U is the Mann-Whitney
      # statistic of samples of +m+ and +n+ from the same distribution:
      # the pairs (one of each) in which the first's is the larger. Each
      # P(U = u) is found from samples of one fewer (the largest of all is
      # one of the first's, beating all +n+, as often as m / (m + n), or
      # one of the second's), in probabilities, which stay in range where
      # the counts of orderings would grow huge.
      def u_lower_tail(m, n)
        cap = m * n / 2
        sum = 0.0
        u_probabilities(m, n, cap, {}).map { |p| sum += p }
      end

      # P(U = u) for u from 0 to +cap+, for samples of +i+ and +j+ (see
      # #u_lower_tail), each found once, in +found+.
      def u_probabilities(i, j, cap, found)
        found[[i, j]] ||= if i.zero? || j.zero?
          Array.new(cap + 1) { |u| u.zero? ? 1.0 : 0.0 } # (no samples of one: U is 0)
        else
          first = u_probabilities(i - 1, j, cap, found)
          second = u_probabilities(i, j - 1, cap, found)
          Array.new(cap + 1) do |u|
            from_first = (u >= j) ? first.fetch(u - j) * i : 0.0
            (from_first + (second.fetch(u) * j)) / (i + j)
          end
        end
      end

      # [low, high] bounds of the +confidence+ interval for the ratio of
      # +candidates+ (a version's samples) to +bases+ (the other's), or nil
      # (see #shift_rank).
      def shift_interval(bases, candidates, confidence)
        r = shift_rank(bases.size, candidates.size, confidence)
        return unless r

        ratios = cross_ratios(bases, candidates)
        [ratios.fetch(r - 1), ratios.fetch(-r)]
      end

      # The ratio of +candidates+ to +bases+ the interval is for: the
      # median of the cross ratios (the Hodges-Lehmann estimate).
      def shift(bases, candidates) = median(cross_ratios(bases, candidates))

      # Each of +candidates+ over each of +bases+, sorted.
      def cross_ratios(bases, candidates) = candidates.flat_map { |c| bases.map { |b| c.fdiv(b) } }.sort

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
