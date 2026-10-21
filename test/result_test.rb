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

  # A measurement again whose every timing is too close to call, each
  # measure it regressed on among them, is set aside, up to
  # Runner::CONFIRM of them. Any other is a confirmation.
  def test_confirm
    r = result(timed: {"cpu" => "slower", "instructions" => "undecided"})
    close = result(timed: {"cpu" => "undecided", "instructions" => "undecided"})

    assert r.confirm(close)
    assert_equal [close], r.undecided
    assert_empty r.confirmations
    %w[slower same faster].map { |verdict| result(timed: {"cpu" => "undecided", "instructions" => verdict}) }
      .push(result(timed: {"instructions" => "undecided"}), result).each do |again|
      refute r.confirm(again)
      assert_same again, r.confirmations.pop
    end
    2.times { r.confirm(close) }

    refute r.confirm(close), "Runner::CONFIRM set aside at most"
    assert_equal 3, r.undecided.size
    both = result(timed: {"cpu" => "slower"}, counted: {"allocations" => [5, 6]})

    refute both.confirm(result(timed: {"cpu" => "undecided"})), "counts are exact"
  end

  def test_regressed_only_when_every_measurement_agrees
    r = result(timed: {"cpu" => "slower"}, counted: {"allocations" => [5, 6]})
    r.confirmations << result(timed: {"cpu" => "slower"}, counted: {"allocations" => [5, 6]})
    r.confirmations << result(timed: {"cpu" => "same"}, counted: {"allocations" => [5, 6]})

    assert_equal %w[allocations], r.regressed, "the CPU didn't hold up"
    r.confirmations.pop

    assert_equal %w[cpu allocations], r.regressed
  end

  # Slower in time in every measurement, on one timed metric or another,
  # and none saying it isn't (same, or faster): a regression, by those
  # slower in any.
  def test_slower_in_time_on_one_metric_or_another
    r = result(timed: {"cpu" => "slower", "instructions" => "undecided"})
    r.confirmations << result(timed: {"cpu" => "undecided", "instructions" => "slower"})
    r.confirmations << result(timed: {"cpu" => "slower", "instructions" => "slower"})

    assert_equal %w[cpu instructions], r.regressed
    assert_predicate r, :mixed?
    r.confirmations << result(timed: {"cpu" => "slower", "instructions" => "same"})

    assert_empty r.regressed, "one says it isn't"
    refute_predicate r, :mixed?
    r.confirmations[-1] = result(timed: {"cpu" => "faster", "instructions" => "slower"})

    assert_empty r.regressed, "nor faster"
    r.confirmations[-1] = result(timed: {"cpu" => "undecided", "instructions" => "undecided"}, counted: {"allocations" => [5, 6]})

    assert_empty r.regressed, "worse, but not slower"
  end

  # A process benchmark's (see DSL#duel_process): CPU time its one
  # timing, and peak memory. Slower in CPU time in one measurement and
  # in memory in the next isn't slower by one timing or another, and
  # one timing is never mixed, so it fails in CONFIRM measurements more.
  def test_a_process_benchmarks_one_timing_and_its_memory
    process = lambda do |cpu, candidate|
      result(timed: {"cpu" => cpu}).tap { |r| r.memory = {"baseline" => 10 * MB, "candidate" => candidate * MB} }
    end
    r = process.call("slower", 10)
    r.confirmations << process.call("undecided", 20)

    assert_empty r.regressed
    refute_predicate r, :confirming?
    r.confirmations[-1] = process.call("slower", 20)
    r.confirmations << process.call("slower", 10)

    assert_equal %w[cpu], r.regressed
    refute_predicate r, :mixed?
    assert_predicate r, :confirming?
    r.confirmations << process.call("slower", 10)

    refute_predicate r, :confirming?, "Runner::CONFIRM of them, not one more"
  end

  def test_slower_on_one_metric_isnt_mixed
    r = result(timed: {"cpu" => "slower", "instructions" => "undecided"})
    r.confirmations << result(timed: {"cpu" => "slower", "instructions" => "slower"})

    assert_equal %w[cpu], r.regressed
    refute_predicate r, :mixed?
  end

  def test_slower_in_time
    assert_predicate result(timed: {"cpu" => "slower", "x" => "undecided"}), :slower_in_time?
    refute_predicate result(timed: {"cpu" => "undecided"}), :slower_in_time?
    refute_predicate result(timed: {"cpu" => "slower", "x" => "same"}), :slower_in_time?
    refute_predicate result(timed: {"cpu" => "slower", "x" => "faster"}), :slower_in_time?
    assert_equal %w[cpu x], result(timed: {"cpu" => "slower", "x" => "slower", "y" => "same"}).slower
  end

  # Measured again until a measurement clears it, or CONFIRM agree on a
  # metric (one more, slower on one metric or another).
  def test_confirming
    refute_predicate result(timed: {"cpu" => "same"}), :confirming?
    r = result(timed: {"cpu" => "slower"})
    2.times do
      assert_predicate r, :confirming?
      r.confirmations << result(timed: {"cpu" => "slower"})
    end

    assert_predicate r, :confirming?
    r.confirmations << result(timed: {"cpu" => "slower", "instructions" => "undecided"})

    refute_predicate r, :confirming?, "three agree"
    r.confirmations[-1] = result(timed: {"cpu" => "undecided", "instructions" => "slower"})

    assert_predicate r, :confirming?, "one more, where they don't"
    r.confirmations << result(timed: {"instructions" => "slower"})

    refute_predicate r, :confirming?
    r.confirmations[-1] = result(timed: {"cpu" => "same"})

    refute_predicate r, :confirming?, "cleared"
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
