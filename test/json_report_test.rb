# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"
require "duel/json_report"

# A run's report as JSON (see Duel::JSONReport), from results made by
# hand, and from a whole run with its worker processes faked.
class JSONReportTest < DuelTest
  cover "Duel::JSONReport*"

  def candidate = File.join(tmpdir, "candidate")

  # A runner that ran (with these verdicts across the board, Rubies,
  # seconds and plugins), for results made by hand.
  def runner(across: {}, rubies: {"baseline" => "ruby 3.4", "candidate" => "ruby 4.0"}, seconds: 1.5, plugins: [])
    config = Duel::Config.new(candidate)
    config.define_singleton_method(:plugins) { plugins }
    Duel::Runner.new(config, settings, File.join(tmpdir, "base"), out: StringIO.new).tap do |r|
      r.instance_variable_set(:@across, across)
      r.instance_variable_set(:@rubies, rubies)
      r.instance_variable_set(:@seconds, seconds)
    end
  end

  BASELINE = {"ref" => "main", "commit" => "a" * 40, "root" => "/base"}.freeze
  CANDIDATE = {"commit" => "b" * 40, "uncommitted_changes" => false, "root" => "/candidate"}.freeze

  def report(results, runner: self.runner, exit: 0, comment: "change", **overrides)
    Duel::JSONReport.new(runner, results, settings: settings(**overrides), exit: exit, comment: comment, baseline: BASELINE,
      candidate: CANDIDATE).to_h
  end

  # A result made by hand, of +n+ iterations a sample: +timed+ ({metric
  # => verdict}, each with a ratio of 1.0) and +counted+ ({metric =>
  # [baseline, candidate]}, of +n+ iterations).
  def result(name, n: 2, timed: {"cpu" => "same"}, counted: {})
    Duel::Result.new(name).tap do |r|
      r.n = n
      r.seconds = 0.5
      timed.each do |metric, verdict|
        r.timed[metric] = {"median" => 1.0, "interval" => [0.99, 1.01], "verdict" => verdict, "baseline" => 1000, "candidate" => 1100,
                           "unit" => "ns", "plural" => "ns", "limit" => 1.02, "across" => true, "pairs" => 20}
      end
      counted.each do |metric, (base, candidate)|
        r.counted[metric] = {"baseline" => base, "candidate" => candidate, "n" => n, "tolerance" => 0, "allowance" => 0,
                             "unit" => "query", "plural" => "queries"}
      end
    end
  end

  def settings_json = {"confidence" => 0.99, "limit" => 1.02, "filter" => "", "jobs" => 1, "processes" => 3, "timeout" => 60.0,
                       "warm" => 0.0, "force" => false}

  # A run that passed, with every key, and a benchmark's every key.
  def test_a_run_that_passed
    expected = {
      "schema" => 1, "duel_version" => Duel::VERSION, "status" => "passed", "exit" => 0, "message" => nil, "comment" => "change",
      "settings" => settings_json, "seconds" => 1.5,
      "baseline" => {"ref" => "main", "commit" => "a" * 40, "root" => "/base", "ruby" => "ruby 3.4"},
      "candidate" => {"commit" => "b" * 40, "uncommitted_changes" => false, "root" => "/candidate", "ruby" => "ruby 4.0"},
      "plugins" => [],
      "benchmarks" => [
        {"name" => "a", "verdict" => "changed", "passed" => true, "regressed" => [], "unsettled" => false, "iterations" => 2,
         "seconds" => 0.5, "confirmations" => 0,
         "timed" => {"cpu" => {"ratio" => 1.0, "interval" => [0.99, 1.01], "limit" => 1.02, "pairs" => 20, "verdict" => "same",
                               "baseline" => 500.0, "candidate" => 550.0, "unit" => "ns", "plural" => "ns", "across" => true}},
         "counted" => {"queries" => {"baseline" => 1.5, "candidate" => 1.0, "unit" => "query", "plural" => "queries", "worse" => false}},
         "peak_memory" => nil, "details" => {}, "explanation" => [], "error" => nil, "skipped" => nil}
      ],
      "across" => {}, "errors" => []
    }

    assert_equal expected, report([result("a", counted: {"queries" => [3, 2]})])
  end

  # A run that failed: each regression explained, what metrics said, a
  # counted measure that's worse, peak memory, and the errors listed too.
  def test_a_run_that_failed
    slow = result("slow", timed: {"cpu" => "slower"}, counted: {"queries" => [2, 4], "rows" => [2, 2]})
    slow.details["queries"] = {"baseline" => "1 SELECT", "candidate" => "2 SELECT"}
    slow.memory = {"baseline" => 1 << 20, "candidate" => 5 << 20}
    slow.profile = {"unavailable" => "no StackProf"}
    3.times { slow.confirmations << result("slow", timed: {"cpu" => "slower"}, counted: {"queries" => [2, 4]}) }
    broken = Duel::Result.new("broken").tap { |r| r.error = "Duel::Failed: oops\n  at x" }
    report = report([slow, broken], exit: 1, comment: "post")
    benchmark = report.fetch("benchmarks").first

    assert_equal ["failed", 1, nil, "post"], report.values_at("status", "exit", "message", "comment")
    assert_equal ["regressed", false, %w[cpu queries], 3], benchmark.values_at("verdict", "passed", "regressed", "confirmations")
    assert_equal({"queries" => {"baseline" => 1.0, "candidate" => 2.0, "unit" => "query", "plural" => "queries", "worse" => true},
                  "rows" => {"baseline" => 1.0, "candidate" => 1.0, "unit" => "query", "plural" => "queries", "worse" => false}},
      benchmark.fetch("counted"))
    assert_equal({"baseline" => 1 << 20, "candidate" => 5 << 20, "unit" => "B", "worse" => true}, benchmark.fetch("peak_memory"))
    assert_equal({"queries" => {"baseline" => "1 SELECT", "candidate" => "2 SELECT"}}, benchmark.fetch("details"))
    assert_equal ["cpu: 500ns → 550ns an iteration (1.00x)", "queries: 1 query → 2 queries an iteration",
      "queries (candidate): 2 SELECT", "queries (baseline): 1 SELECT", "profile: no StackProf"], benchmark.fetch("explanation")
    assert_equal({"name" => "broken", "verdict" => "error", "passed" => false, "regressed" => [], "unsettled" => false,
                  "iterations" => nil, "seconds" => nil, "confirmations" => 0, "timed" => {}, "counted" => {}, "peak_memory" => nil,
                  "details" => {}, "explanation" => [], "error" => "Duel::Failed: oops\n  at x", "skipped" => nil},
      report.fetch("benchmarks").last)
    assert_equal [{"benchmark" => "broken", "message" => "Duel::Failed: oops\n  at x"}], report.fetch("errors")
  end

  # Peak memory that didn't grow too much, unsettled timings, and a
  # benchmark that was skipped.
  def test_the_rest_of_a_benchmark
    less = result("less", timed: {"cpu" => "undecided"})
    less.timed.fetch("cpu")["across"] = false
    less.memory = {"baseline" => 3 << 20, "candidate" => 1 << 20}
    skipped = Duel::Result.new("new").tap { |r| r.skipped = "not on the baseline (x)" }
    first, second = report([less, skipped]).fetch("benchmarks")

    assert_equal [{"baseline" => 3 << 20, "candidate" => 1 << 20, "unit" => "B", "worse" => false}, true, "unsettled"],
      first.values_at("peak_memory", "unsettled", "verdict")
    refute first.dig("timed", "cpu", "across")
    assert_equal ["skipped", true, "not on the baseline (x)", nil], second.values_at("verdict", "passed", "skipped", "error")
  end

  # Across the board: every metric, "confirmed" only where a second
  # measurement confirmed it slower, and no interval for too few.
  def test_across_the_board
    across = {"cpu" => {"median" => 1.01, "interval" => [1.006, 1.02], "limit" => 1.005, "benchmarks" => 8, "verdict" => "slower",
                        "confirmed" => true},
              "few" => {"median" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2, "verdict" => "undecided"}}

    assert_equal({"cpu" => {"ratio" => 1.01, "interval" => [1.006, 1.02], "limit" => 1.005, "benchmarks" => 8, "verdict" => "slower",
                            "confirmed" => true},
                  "few" => {"ratio" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2, "verdict" => "undecided",
                            "confirmed" => false}},
      report([result("a")], runner: runner(across: across), exit: 1).fetch("across"))
  end

  # The settings it ran with, and the plugins it used, by name.
  def test_settings_and_plugins
    report = report([], runner: runner(plugins: %i[rails activerecord]), limit: 1.05, confidence: 0.95, filter: /^parse:/,
      jobs: 4, processes: 2, timeout: 9.5, warm: nil, force: true)

    assert_equal({"confidence" => 0.95, "limit" => 1.05, "filter" => "^parse:", "jobs" => 4, "processes" => 2, "timeout" => 9.5,
                  "warm" => nil, "force" => true}, report.fetch("settings"))
    assert_equal %w[rails activerecord], report.fetch("plugins")
  end

  # A run that didn't compare: the same keys, with nothing compared.
  def test_note
    assert_equal({"schema" => 1, "duel_version" => Duel::VERSION, "status" => "error", "exit" => 2, "message" => "duel: no", "comment" => "post",
                  "settings" => settings_json, "seconds" => nil, "baseline" => nil, "candidate" => nil, "plugins" => [],
                  "benchmarks" => [], "across" => {}, "errors" => []},
      Duel::JSONReport.note("error", 2, "duel: no", settings, "post"))
    assert_equal report([]).keys, Duel::JSONReport.note("error", 2, "duel: no", settings, "none").keys, "in the same order"
  end

  # A whole run, as JSON: what JSON.generate takes, and gives back alike.
  def test_a_whole_run
    workers = FakeWorkers.new
    workers.benchmark("slow") do |side, n, _|
      {"timed" => {"cpu" => n * ((side == "candidate") ? 110_000 : 100_000)}, "counted" => {"allocations" => n * 2}, "heap" => 0}
    end
    workers.profile("baseline", {"samples" => 100, "frames" => [["f", 10, 10]]})
    workers.profile("candidate", {"samples" => 110, "frames" => [["f", 20, 20]]})
    runner = Duel::Runner.new(Duel::Config.new(candidate), settings, File.join(tmpdir, "base"), out: StringIO.new)
    results = stub(Duel::WorkerProcess, :new, ->(*args, **options) { workers.make(*args, **options) }) { elsewhere { runner.run } }
    report = report(results, runner: runner, exit: 1)

    assert_equal report, JSON.parse(JSON.generate(report))
    timed = report.dig("benchmarks", 0, "timed", "cpu")

    assert_equal [1.1, "slower", 100_000.0, 110_000.0], timed.values_at("ratio", "verdict", "baseline", "candidate")
    assert_equal({"baseline" => 2.0, "candidate" => 2.0, "unit" => nil, "plural" => nil, "worse" => false},
      report.dig("benchmarks", 0, "counted", "allocations"))
    assert_equal({"baseline" => RUBY_DESCRIPTION, "candidate" => RUBY_DESCRIPTION}, report.slice("baseline", "candidate").transform_values { |v| v.fetch("ruby") })
  end
end
