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

  def verdicts(results, by_process: false) = Duel::Across.new(results, confidence: 0.99, by_process: by_process).verdicts

  # A run's that judged benchmarks over workers.
  def over_workers(results) = verdicts(results, by_process: true)

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

  # A result judged by process: its median ratio, and each worker's
  # median, by version (+luck+, each worker's factor, the same at every
  # benchmark, times +slower+ for the candidate's), in +lane+.
  def by_process(name, luck, slower: 1.0, lane: 1, base: 1000.0)
    result(name, {"cpu" => slower}).tap do |r|
      r.processes["cpu"] = {"lane" => lane, "baseline" => luck.fetch("baseline").map { |f| base * f },
                            "candidate" => luck.fetch("candidate").map { |f| base * f * slower }}
    end
  end

  LUCK = {"baseline" => [1.0, 1.03, 0.98, 1.02, 0.99], "candidate" => [1.01, 0.97, 1.04, 1.0, 0.98]}.freeze

  # Every benchmark's median says the candidate is 1% slower, and an
  # interval over the benchmarks would call it, but the same workers
  # measured every one, and their luck (the same at each) leaves it
  # undecided: the interval is over the workers' scores.
  def test_by_process_the_workers_luck_counts_once
    results = Array.new(12) { |i| by_process("b#{i}", LUCK, slower: 1.01, base: 1000.0 * (i + 1)) }
    cpu = over_workers(results).fetch("cpu")

    assert_equal ["undecided", 12, 5], cpu.values_at("verdict", "benchmarks", "processes")
    low, high = cpu.fetch("interval")

    assert_operator low, :<, 1.0
    assert_operator high, :>, 1.02
    plain = results.map { |r| result(r.name, {"cpu" => 1.01}) }

    assert_equal "slower", over_workers(plain).dig("cpu", "verdict"), "by benchmark"
    assert_equal verdicts(plain), over_workers(plain), "by benchmark, as a run over pairs is"
    refute Duel::Across.new(results, confidence: 0.99).verdicts.fetch("cpu").key?("processes"), "over pairs, unless it says"
  end

  # Without luck (every worker alike), a 1% slowdown everywhere shows.
  def test_by_process_a_slowdown_across_the_board
    even = {"baseline" => [1.0] * 5, "candidate" => [1.0] * 5}
    results = Array.new(8) { |i| by_process("b#{i}", even, slower: 1.01, base: 100.0 * (i + 1)) }
    # (Failed, skipped, and a measure not judged across the board, whatever
    # their workers measured, are left out, wherever they are.)
    results = [by_process("error", even, slower: 9.0).tap { |r| r.error = "boom" }, by_process("new", even, slower: 9.0).tap { |r| r.skipped = "new" },
      by_process("noisy", even, slower: 9.0).tap { |r| r.timed.fetch("cpu")["across"] = false }] + results
    cpu = over_workers(results).fetch("cpu")

    assert_equal ["slower", 8, 5], cpu.values_at("verdict", "benchmarks", "processes")
    assert_in_delta 1.005, cpu.fetch("limit"), 1e-12
    assert_in_delta 1.01, cpu.fetch("median"), 1e-9
    cpu.fetch("interval").each { |bound| assert_in_delta 1.01, bound, 1e-9 }
    assert_equal "same", over_workers(Array.new(8) { |i| by_process("b#{i}", even, base: 100.0 * (i + 1)) }).dig("cpu", "verdict")
  end

  # Each lane's workers are their own (a worker of one lane is no other
  # lane's), and fewer than 8 benchmarks by process are judged by
  # benchmark, as are the rest where some weren't judged by process.
  def test_by_process_each_lanes_workers
    even = {"baseline" => [1.0] * 5, "candidate" => [1.0] * 5}
    results = Array.new(8) { |i| by_process("b#{i}", even, lane: (i % 2) + 1, base: i.even? ? 1.0 : 1000.0) }

    assert_equal 10, over_workers(results).dig("cpu", "processes")
    refute verdicts(results, by_process: false).fetch("cpu").key?("processes"), "a run over pairs looks for no workers"
    assert_equal [1.0, [1.0, 1.0], "same"], over_workers(results).fetch("cpu").values_at("median", "interval", "verdict"),
      "each to its own lane's, at its own benchmarks"
    refute over_workers(results.first(7)).fetch("cpu").key?("processes")
    assert_equal 8, over_workers(results.first(7) + [result("p", {"cpu" => 1.0})]).dig("cpu", "benchmarks")
    refute over_workers(results.first(7) + [result("p", {"cpu" => 1.0})]).fetch("cpu").key?("processes")
  end

  # A score is a ratio to its lane's every worker's median, so a worker
  # that measured nothing (zero) is at 1, as a ratio to nothing is.
  def test_a_worker_that_measured_nothing
    zero = {"baseline" => [0.0] * 5, "candidate" => [0.0] * 5}
    results = Array.new(8) { |i| by_process("b#{i}", zero) }

    assert_equal [1.0, [1.0, 1.0], "same"], over_workers(results).fetch("cpu").values_at("median", "interval", "verdict")
    small = Array.new(8) { |i| by_process("b#{i}", {"baseline" => [1.0] * 5, "candidate" => [1.0] * 5}, slower: 2.0, base: 1.0) }

    assert_equal "slower", over_workers(small).dig("cpu", "verdict"), "at least 1, and no more"
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

  # Out of time: slower in the one measurement, so slower, and none
  # measured again.
  def test_confirmed_out_of_time
    runner = runner(nil)
    runner.define_singleton_method(:out_of_time?) { true }
    verdicts = elsewhere { runner.send(:judge_across, results(1.02, %w[cpu db_cpu]), %w[b0]) }

    assert verdicts.fetch("cpu").fetch("confirmed")
    assert verdicts.fetch("db_cpu").fetch("confirmed")
    assert_equal "\nSlower across the board in cpu, db_cpu, not measured again: the run reached its time limit " \
      "(1800s, --time-limit)\n", @out.string
    assert_equal({"unmeasured" => [], "unconfirmed" => [], "across" => true}, runner.cut_short)
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
