# frozen_string_literal: true

require_relative "test_helper"

class AcrossTest < DuelTest
  cover "Duel::Across*"

  def result(name, medians, limit: 1.02, error: nil, skipped: nil, across: true)
    Duel::Result.new(name).tap do |r|
      medians.each { |metric, median| r.timed[metric] = {"median" => median, "limit" => limit, "across" => across, "verdict" => "same"} }
      r.error = error
      r.skipped = skipped
    end
  end

  def verdicts(results) = Duel::Across.new(results, confidence: 0.99).verdicts

  def test_the_limit_is_a_quarter_of_the_metrics_margin
    assert_in_delta 1.005, Duel::Across.limit(1.02), 1e-12
    assert_in_delta 1.0025, Duel::Across.limit(1.01), 1e-12
  end

  def test_a_slowdown_too_small_for_any_one_benchmark
    results = Array.new(12) { |i| result("b#{i}", {"cpu" => 1.01 + (i * 0.0001)}) }
    cpu = verdicts(results).fetch("cpu")

    assert_equal "slower", cpu.fetch("verdict")
    assert_equal 12, cpu.fetch("benchmarks")
    assert_in_delta 1.005, cpu.fetch("limit"), 1e-12
    assert_in_delta 1.01055, cpu.fetch("median"), 1e-9
    assert_equal 2, cpu.fetch("interval").size
  end

  def test_each_metric_on_its_own
    results = Array.new(10) { |i| result("b#{i}", {"cpu" => 1.0, "instructions" => 1.0}) }
    results.each { |r| r.timed["instructions"]["limit"] = 1.01 }
    v = verdicts(results)

    assert_equal %w[same same], v.values.map { |m| m.fetch("verdict") }
    assert_in_delta 1.0025, v.fetch("instructions").fetch("limit"), 1e-12
  end

  def test_too_few_to_tell_and_failures_left_out
    results = [result("b", {"cpu" => 9.0}, error: "boom"), result("c", {"cpu" => 9.0}, skipped: "new"), result("a", {"cpu" => 1.5})]
    cpu = verdicts(results).fetch("cpu")

    assert_equal ["undecided", 1, nil], cpu.values_at("verdict", "benchmarks", "interval")
  end

  # A metric that says across: false isn't judged across the board.
  def test_a_metric_left_out
    results = Array.new(10) do |i|
      result("b#{i}", {"noisy" => 1.5, "cpu" => 1.0}).tap { |r| r.timed.fetch("noisy")["across"] = false }
    end

    assert_equal %w[cpu], Duel::Across.new(results, confidence: 0.99).verdicts.keys, "the rest still are"
  end
end

# Slower across the board, then measured again: confirmed only if the
# second measurement agrees.
class AcrossConfirmTest < DuelTest
  cover "Duel::Runner*"

  def results(median, metrics = %w[cpu]) = Array.new(10) { |i| AcrossTest.allocate.result("b#{i}", metrics.to_h { |m| [m, median] }) }

  # A runner whose second measurement is +again+ (of the same names).
  def runner(again)
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, tmpdir, out: (@out = StringIO.new))
    runner.define_singleton_method(:with_lanes) { |&block| block.call([:lane]) }
    runner.define_singleton_method(:measure_all) do |lanes, names|
      raise "not the same" unless lanes == [:lane] && names == %w[b0]

      again
    end
    runner
  end

  def test_confirmed_when_slower_again
    verdicts = elsewhere { runner(results(1.02, %w[cpu db_cpu])).send(:judge_across, results(1.02, %w[cpu db_cpu]), %w[b0]) }

    assert verdicts.fetch("cpu").fetch("confirmed")
    assert verdicts.fetch("db_cpu").fetch("confirmed")
    assert_includes @out.string, "slower across the board in cpu, db_cpu?"
  end

  def test_cleared_when_not
    runner = runner(results(1.0))
    verdicts = elsewhere { runner.send(:judge_across, results(1.02), %w[b0]) }
    runner.instance_variable_set(:@across, verdicts)

    refute verdicts.fetch("cpu").fetch("confirmed")
    assert_empty runner.regressed_across
  end

  def test_cleared_when_not_measured_again
    verdicts = runner(results(1.02, %w[other])).send(:judge_across, results(1.02), %w[b0])

    refute verdicts.fetch("cpu").fetch("confirmed")
  end

  def test_not_measured_again_when_nothing_is_slower
    verdicts = runner(nil).send(:judge_across, results(1.0), %w[b0])

    refute verdicts.fetch("cpu").key?("confirmed")
    assert_empty @out.string
  end

  def test_reported
    runner = runner(nil)
    runner.instance_variable_set(:@across, {"db_cpu" => {"median" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2,
                                                         "verdict" => "undecided"},
                                            "cpu" => {"median" => 1.02, "interval" => [1.01, 1.03], "limit" => 1.005,
                                                      "benchmarks" => 10, "verdict" => "slower", "confirmed" => true}})
    elsewhere { runner.send(:report, [], 1.0) }

    assert_includes @out.string, "across the board: cpu 1.020 [1.010, 1.030] slower (limit 1.0050, 10 benchmarks)"
    refute_includes @out.string, "db_cpu", "too few benchmarks to say"
    assert_includes @out.string, "REGRESSION across the board: cpu slower in both measurements"
    refute runner.passed?([])
  end
end
