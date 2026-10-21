# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < DuelTest
  cover "Duel::Result*"

  def result(name = "x", timed: {}, counted: {})
    Duel::Result.new(name).tap do |r|
      timed.each { |metric, verdict| r.timed[metric] = {"verdict" => verdict} }
      counted.each do |metric, (base, candidate, n, tolerance, allowance)|
        r.counted[metric] = {"baseline" => base, "candidate" => candidate, "n" => n || 1, "tolerance" => tolerance || 0,
                             "allowance" => allowance || 0}
      end
    end
  end

  def test_worse_is_slower_or_more
    r = result(timed: {"cpu" => "slower", "db" => "same"}, counted: {"allocations" => [5, 6], "trips" => [2, 2]})

    assert_equal %w[cpu allocations], r.worse
    assert_empty result(timed: {"cpu" => "undecided"}, counted: {"allocations" => [6, 5]}).worse,
      "undecided and fewer aren't worse"
  end

  def test_a_counted_metric_may_rise_by_its_tolerance_per_iteration
    assert_empty result(counted: {"allocations" => [3647, 3670, 46, 0.5]}).worse, "half per iteration"
    assert_equal %w[allocations], result(counted: {"allocations" => [3647, 3671, 46, 0.5]}).worse
    assert_equal %w[trips], result(counted: {"trips" => [46, 47, 46, 0]}).worse, "one more"
  end

  # And by its allowance per sample, however many iterations it took.
  def test_a_counted_metric_may_rise_by_its_allowance_per_sample
    assert_empty result(counted: {"retained" => [0, 16, 1, 0, 16]}).worse
    assert_equal %w[retained], result(counted: {"retained" => [0, 17, 1, 0, 16]}).worse
    assert_empty result(counted: {"retained" => [0, 21, 10, 0.5, 16]}).worse, "and its tolerance"
    assert_equal %w[retained], result(counted: {"retained" => [0, 22, 10, 0.5, 16]}).worse
  end

  # What metrics said, by measure, by version: the latest.
  def test_notes
    r = Duel::Result.new("x")
    r.note({"details" => {"retained" => "2 String"}}, {"details" => {"retained" => "9 String", "other" => "x"}})
    r.note({}, {"details" => {"retained" => "10 String"}})

    assert_equal({"retained" => {"baseline" => "2 String", "candidate" => "10 String"}, "other" => {"candidate" => "x"}}, r.details)
    r.note({"details" => {"retained" => "3 String", "other" => "y"}}, {}, "retained")

    assert_equal({"baseline" => "3 String", "candidate" => "10 String"}, r.details.fetch("retained"))
    assert_equal({"candidate" => "x"}, r.details.fetch("other"), "only the measure's")
  end

  def memory(base, candidate) = Duel::Result.new("x").tap { |r| r.memory = {"baseline" => base, "candidate" => candidate} }

  MB = 1 << 20

  # Peak memory is worse by more than 10%, and 1 MB at least.
  def test_more_memory
    refute_predicate Duel::Result.new("x"), :more_memory?, "not measured"
    refute_predicate memory(MB, MB + MB - 1), :more_memory?, "under 1 MB more"
    assert_predicate memory(MB, MB + MB + 1), :more_memory?
    refute_predicate memory(100 * MB, 110 * MB), :more_memory?, "10% more"
    assert_predicate memory(100 * MB, 110 * MB + 1), :more_memory?
    assert_equal %w[peak_memory], memory(MB, 3 * MB).worse
    worse = memory(MB, 3 * MB).tap { |r| r.timed["cpu"] = {"verdict" => "slower"} }.worse

    assert_equal %w[cpu peak_memory], worse, "last"
  end

  def test_regressed_only_when_every_measurement_agrees
    r = result(timed: {"cpu" => "slower"}, counted: {"allocations" => [5, 6]})
    r.confirmations << result(timed: {"cpu" => "slower"}, counted: {"allocations" => [5, 6]})
    r.confirmations << result(timed: {"cpu" => "same"}, counted: {"allocations" => [5, 6]})

    assert_equal %w[allocations], r.regressed, "the CPU didn't hold up"
    r.confirmations.pop

    assert_equal %w[cpu allocations], r.regressed
  end

  def test_a_new_result
    r = Duel::Result.new("parse")

    assert_equal "parse", r.name
    assert_empty r.timed
    assert_empty r.counted
    assert_empty r.confirmations
  end

  def test_passed
    assert_predicate result, :passed?
    refute_predicate result(timed: {"cpu" => "slower"}), :passed?
    failed = result
    failed.error = "boom"

    refute_predicate failed, :passed?
  end

  def test_skipped_and_failed_benchmarks_never_regress
    skipped = result(timed: {"cpu" => "slower"})
    skipped.skipped = "not on the baseline"
    failed = result(timed: {"cpu" => "slower"})
    failed.error = "boom"

    assert_empty skipped.regressed
    assert_empty failed.regressed
  end

  def test_unsettled
    assert_predicate result(timed: {"cpu" => "same", "x" => "undecided"}), :unsettled?
    refute_predicate result(timed: {"cpu" => "same"}), :unsettled?
  end
end
