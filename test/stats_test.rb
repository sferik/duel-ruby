# frozen_string_literal: true

require_relative "test_helper"

class StatsTest < DuelTest
  cover "Duel::Stats*"

  Stats = Duel::Stats

  # P(X <= k) for X ~ Binomial(n, 1/2), summed term by term: what the
  # ranks are checked against.
  def binomial_cdf(k, n) = (0..k).sum { |i| (1..i).reduce(1) { |product, j| product * (n - i + j) / j } }.fdiv(2**n)

  # The widest ranks whose interval still covers the median 99% of the
  # time: none below 8 samples (1/2^7 = 0.0078 > 0.005 in each tail).
  def test_median_ranks_at_99_percent
    assert_nil Stats.median_ranks(7, 0.99)
    assert_equal [1, 8], Stats.median_ranks(8, 0.99)
    assert_equal [1, 10], Stats.median_ranks(10, 0.99)
    assert_equal [4, 17], Stats.median_ranks(20, 0.99)
    assert_equal [20, 41], Stats.median_ranks(60, 0.99)
  end

  # Where a tail is exactly a binomial probability, that rank is in: the
  # interval may miss the median by at most the tail, each side.
  def test_a_tail_exactly_on_a_rank
    assert_equal [1, 3], Stats.median_ranks(3, 0.75), "P(X <= 0) = 1/8 = the tail"
    assert_nil Stats.median_ranks(2, 0.75)
  end

  def test_the_ranks_cover_the_median_as_promised
    [8, 10, 20, 37, 60].each do |n|
      low, = Stats.median_ranks(n, 0.99)

      assert_operator 2 * binomial_cdf(low - 1, n), :<=, 0.01, "n=#{n}"
      assert_operator 2 * binomial_cdf(low, n), :>, 0.01, "n=#{n}: the narrowest such"
    end
  end

  # The same ranks as the binomial sums give, at every size and
  # confidence (and so the same verdicts), however they're found.
  def test_the_ranks_are_the_binomial_sums
    [0.99, 0.95, 0.5].each do |confidence|
      tail = (1 - confidence) / 2
      (1..120).each do |n|
        k = (0..n).find { |i| binomial_cdf(i, n) > tail }
        ranks = Stats.median_ranks(n, confidence)

        k.zero? ? assert_nil(ranks, "n=#{n} at #{confidence}") : assert_equal([k, n + 1 - k], ranks, "n=#{n} at #{confidence}")
      end
    end
  end

  # A thousand benchmarks across the board, in a thousand steps.
  def test_ranks_of_many_samples
    assert_equal [459, 542], Stats.median_ranks(1000, 0.99)
    assert_equal [4871, 5130], Stats.median_ranks(10_000, 0.99)
  end

  def test_median_interval_ignores_any_one_outlier
    assert_equal [1.0, 50.0], Stats.median_interval([1.0] * 9 + [50.0], 0.99), "with 10, the extremes"
    assert_equal [1.0, 1.0], Stats.median_interval([1.0] * 19 + [50.0], 0.99)
    assert_equal [1.0, 3.0], Stats.median_interval([3.0, 1.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0], 0.99), "sorted"
    assert_nil Stats.median_interval([1.0] * 5, 0.99)
  end

  def test_median
    assert_in_delta 2.0, Stats.median([3.0, 1.0, 2.0]), 1e-12
    assert_in_delta 2.5, Stats.median([4.0, 1.0, 2.0, 3.0]), 1e-12
    assert_in_delta 3.5, Stats.median([6.0, 1.0, 5.0, 2.0, 4.0, 3.0]), 1e-12
  end

  def verdict(ratios) = Stats.verdict(ratios, limit: 1.02, confidence: 0.99)

  def test_verdicts
    assert_equal :undecided, verdict([1.5] * 7), "too few to tell"
    assert_equal :slower, verdict([1.05] * 20)
    assert_equal :faster, verdict([0.9] * 20)
    assert_equal :same, verdict([1.0] * 20)
    assert_equal :same, verdict([0.99] * 20), "a little faster is not slower: nothing more to prove"
    assert_equal :undecided, verdict([1.0] * 10 + [1.05] * 10), "straddles the limit"
    assert_equal :undecided, verdict([1.02] * 20), "at the limit is neither"
  end

  def test_decide
    assert_equal :undecided, Stats.decide(nil, 1.02), "too few"
    assert_equal :slower, Stats.decide([1.03, 1.04], 1.02)
    assert_equal :faster, Stats.decide([0.9, 0.97], 1.02)
    assert_equal :same, Stats.decide([0.99, 1.01], 1.02)
    assert_equal :undecided, Stats.decide([1.01, 1.03], 1.02)
  end

  def test_one_slow_sample_never_makes_a_benchmark_slower
    assert_equal :same, verdict([1.0] * 19 + [10.0])
    assert_equal :undecided, verdict([1.0] * 9 + [10.0]), "with 10 it can't be ruled out yet: more are taken"
  end
end
