# frozen_string_literal: true

require_relative "test_helper"

class StatsTest < DuelTest
  cover "Duel::Stats*"

  Stats = Duel::Stats

  def test_binomial_cdf
    assert_in_delta 1.0 / 1024, Stats.binomial_cdf(0, 10), 1e-12
    assert_in_delta 11.0 / 1024, Stats.binomial_cdf(1, 10), 1e-12
    assert_in_delta 1.0, Stats.binomial_cdf(10, 10), 1e-12
    assert_in_delta 0.5, Stats.binomial_cdf(2, 5), 1e-12
    assert_in_delta 0.0, Stats.binomial_cdf(-1, 10), 1e-12
  end

  def test_binomial
    assert_equal 1, Stats.binomial(10, 0)
    assert_equal 10, Stats.binomial(10, 1)
    assert_equal 252, Stats.binomial(10, 5)
  end

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

      assert_operator 2 * Stats.binomial_cdf(low - 1, n), :<=, 0.01, "n=#{n}"
      assert_operator 2 * Stats.binomial_cdf(low, n), :>, 0.01, "n=#{n}: the narrowest such"
    end
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

  def test_one_slow_sample_never_makes_a_benchmark_slower
    assert_equal :same, verdict([1.0] * 19 + [10.0])
    assert_equal :undecided, verdict([1.0] * 9 + [10.0]), "with 10 it can't be ruled out yet: more are taken"
  end
end
