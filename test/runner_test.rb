# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# Whole runs, with their worker processes faked (see FakeWorkers): what
# a runner prints and decides.
class RunnerTest < DuelTest
  cover "Duel::Runner*"

  def candidate = File.join(tmpdir, "candidate")

  def run_duel(workers, config: Duel::Config.new(candidate), **overrides)
    runner = Duel::Runner.new(config, settings(**overrides), File.join(tmpdir, "base"), out: (out = StringIO.new))
    results = elsewhere { runner.run }
    # (Each benchmark's time, which a busy machine stretches, as no time.)
    [results, out.string.gsub(/ +\d+\.\ds n=/) { |time| "#{" " * (time.size - 7)}0.0s n=" }, runner]
  end

  def line(name, n, measures, mark: " ") = format("%s %-48s %5.1fs n=%-6d %s", mark, name, 0.0, n, measures)

  def test_a_run
    with_fake_workers do |workers|
      workers.benchmark("a")
      workers.benchmark("b")
      workers.benchmark("other")
      results, out, runner = run_duel(workers, filter: /\A[ab]\z/)

      assert_equal %w[a b], results.map(&:name)
      assert_equal [
        "Comparing 2 benchmarks, 1 at a time: baseline #{File.join(tmpdir, "base")} against candidate #{candidate} " \
        "(slower: a 99.0% interval above 1.02)",
        line("a", 12, "cpu 1.000 [1.000, 1.000] same  allocations 2"),
        line("b", 12, "cpu 1.000 [1.000, 1.000] same  allocations 2"),
        "",
        "2 benchmarks in 0s: 0 regressed, 0 errors, 0 with a timing too close to the limit to settle"
      ], out.lines(chomp: true)
      assert runner.passed?(results)
      assert_equal({"cpu" => {"median" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2, "verdict" => "undecided"}},
        runner.across)
      assert_empty runner.regressed_across
      assert_equal 6, workers.made.size, "one lane"
      assert_equal 6, workers.log.count { |_, op| op == "stop" }, "stopped"
    end
  end

  def test_the_candidate_by_default_is_the_configs
    with_fake_workers do |workers|
      workers.benchmark("a")
      runner = Duel::Runner.new(Duel::Config.new(candidate), settings(candidate_dir: File.join(tmpdir, "x", "..", "other"), jobs: 2,
        limit: 1.05, confidence: 0.95), "base", out: (out = StringIO.new))
      elsewhere { runner.run }

      assert_equal "Comparing 1 benchmark, 2 at a time: baseline base against candidate #{File.join(tmpdir, "other")} " \
        "(slower: a 95.0% interval above 1.05)", out.string.lines.first.chomp
      assert_equal 12, workers.made.size, "two lanes"
    end
  end

  # What's slower is measured again, in fresh lanes, and profiled.
  def test_a_regression
    with_fake_workers do |workers|
      workers.benchmark("a") do |side, n, _|
        candidate = side == "candidate"
        {"timed" => {"cpu" => n * (candidate ? 110_000 : 100_000)}, "counted" => {"allocations" => candidate ? n * 3 : n * 2},
         "heap" => 0, "details" => {"allocations" => candidate ? "3 String" : "2 String"}}
      end
      workers.profile("baseline", {"samples" => 100, "frames" => [["f", 10, 10]]})
      workers.profile("candidate", {"samples" => 110, "frames" => [["f", 20, 20]]})
      results, out, runner = run_duel(workers)
      a = line("a", 11, "cpu 1.100 [1.100, 1.100] slower  allocations 2→3", mark: "!")

      assert_equal [
        out.lines.first.chomp,
        a,
        "",
        "Measuring 1 benchmark that looked worse again, in fresh processes, up to 3 times each (4 if what's slower differs, and once more for each " \
          "too close to call):",
        a, a, a,
        "",
        "REGRESSION a: worse cpu, allocations in every measurement",
        "  cpu: 100µs → 110µs an iteration (1.10x)",
        "  allocations: 2 → 3 an iteration",
        "  allocations (candidate): 3 String",
        "  allocations (baseline): 2 String",
        "  where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
        "     +10.0%  +10.0%  f",
        "1 benchmark in 0s: 1 regressed, 0 errors, 0 with a timing too close to the limit to settle"
      ], out.lines(chomp: true)
      refute runner.passed?(results)
      assert_equal 3, results.first.confirmations.size
      assert_equal [["f", 0.1, 0.1]], results.first.profile.fetch("grew")
      assert_equal 6 + (3 * 6) + 2, workers.made.size, "a lane, three more, and one of a worker each to profile"
      assert_equal [["baseline-1", "a", {n: 11, runs: 500}], ["candidate-1", "a", {n: 11, runs: 500}]], workers.requests("profile")
    end
  end

  INSTRUCTIONS = FakeWorkers::CPU.merge("name" => "instructions", "unit" => nil, "plural" => nil, "floor" => 100_000, "limit" => 1.01,
    "sizes_samples" => false)

  # 3% slower in CPU time, and 2% more instructions, but in each
  # measurement one of them is too noisy to settle: CPU time in odd ones,
  # instructions in even ones. No one metric is slower in every
  # measurement, but the candidate is slower in every one.
  def test_slower_on_one_metric_in_some_measurements_and_another_in_the_rest
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, INSTRUCTIONS]
      noisy = 0
      workers.benchmark("a") do |side, n, _|
        measurement = (workers.made.size - 1) / 6 # (each lane's six workers made, in turn)
        cpu, instructions = (side == "candidate") ? [1.03, 1.02] : [1.0, 1.0]
        if side == "candidate"
          noisy += 1
          # (Its pairs' ratios alternate, above and below the limit.)
          swing = noisy.even? ? 0.97 : 1.03
          measurement.even? ? instructions *= swing : cpu *= swing
        end
        {"timed" => {"cpu" => n * 100_000 * cpu, "instructions" => n * 1_000_000 * instructions}, "counted" => {}, "heap" => 0}
      end
      workers.profile("baseline", {"samples" => 100, "frames" => []})
      workers.profile("candidate", {"samples" => 100, "frames" => []})
      results, out, runner = run_duel(workers)
      a = results.first

      assert_equal [%w[cpu], %w[instructions], %w[cpu], %w[instructions], %w[cpu]], [a, *a.confirmations].map(&:slower)
      assert_equal %w[cpu instructions], a.regressed
      refute runner.passed?(results)
      assert_includes out, "\nREGRESSION a: slower in every measurement, by one of cpu, instructions\n  cpu: 100µs → 103µs an iteration"
      assert_includes out, "\n1 benchmark in 0s: 1 regressed, 0 errors, 0 with a timing too close to the limit to settle\n",
        "its unsettled timings aren't counted again"
    end
  end

  # A regression's explanation: each worse measure an iteration, in its
  # unit, and what its metric said (the candidate's first).
  def test_explanations
    runner = Duel::Runner.new(Duel::Config.new(candidate), settings, File.join(tmpdir, "base"), out: StringIO.new)
    r = Duel::Result.new("x")
    r.n = 2
    r.timed["cpu"] = {"verdict" => "slower", "baseline" => 4_000_000, "candidate" => 5_000_000, "median" => 1.25, "unit" => "ns", "plural" => "ns"}
    r.timed["wait"] = {"verdict" => "slower", "baseline" => 3, "candidate" => 9, "median" => 3.0, "unit" => nil, "plural" => nil}
    r.counted["retained"] = {"baseline" => 0, "candidate" => 7, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "object", "plural" => "objects"}
    r.memory = {"baseline" => 0, "candidate" => 100 << 20}
    r.note({}, {"details" => {"retained" => "7 Hash"}})
    r.note({"details" => {"retained" => "nothing"}}, {})
    r.confirmations << r.dup

    assert_equal ["cpu: 2ms → 2.5ms an iteration (1.25x)", "wait: 1.5 → 4.5 an iteration (3.00x)",
      "retained: 0 objects → 3.5 objects an iteration", "retained (candidate): 7 Hash", "retained (baseline): nothing"],
      runner.send(:explanation, r)
    r.timed.clear
    r.seconds = 1.0
    r.counted["bytes"] = {"baseline" => 1700, "candidate" => 1700, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "B", "plural" => "B"}

    r.counted["round_trips_made"] = {"baseline" => 0, "candidate" => 2, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "round trip",
                                     "plural" => "round trips"}
    r.counted["round_trips"] = {"baseline" => 1, "candidate" => 1, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "round trip",
                                "plural" => "round trips"}

    assert_match(/  retained 0→3.5 objects  bytes 850 B  round_trips_made 0→1 round trip  round_trips 0.5  peak_memory/,
      runner.send(:line, r), "an iteration, with units on its line, but one its name ends in")
  end

  def test_counts_in_the_plural_but_for_one
    assert_equal ["0 benchmarks", "1 benchmark", "2 benchmarks", "1 query", "3 queries"],
      [[0, "benchmark"], [1, "benchmark"], [2, "benchmark"], [1, "query", "queries"], [3, "query", "queries"]].map { |args| Duel::Runner.count(*args) }
  end

  # Amounts an iteration, in their unit: time in the largest unit it
  # makes at least one of, and a word, singular for one.
  def test_amounts
    runner = Duel::Runner.new(Duel::Config.new(candidate), settings, File.join(tmpdir, "base"), out: StringIO.new)
    amount = lambda do |value, unit, n = 1|
      singular, plural = unit
      runner.send(:amount, value, n, {"unit" => singular, "plural" => plural || singular})
    end

    assert_equal ["2.5µs", "1ms", "999.9µs", "1.5s", "250ns", "0.5ns"],
      [amount[2_500_000, "ns", 1000], amount[1_000_000, "ns"], amount[999_900, "ns"], amount[1_500, "ms"], amount[250, "ns"],
        amount[1, "ns", 2]]
    assert_equal ["5e+06", "2.5 B", "3 queries"], [amount[5_000_000, nil, 0], amount[5, "B", 2], amount[3, %w[query queries]]],
      "as of one, of none; in a unit that isn't time"
    assert_equal ["1 row", "1.5 rows", "0 rows", "1 query", "1 B"],
      [amount[2, %w[row rows], 2], amount[3, %w[row rows], 2], amount[0, %w[row rows]], amount[1, %w[query queries]], amount[1, "B"]]
  end

  # A process benchmark that's slower has no profile: its samples are
  # processes of their own.
  def test_a_slower_process_isnt_profiled
    with_fake_workers do |workers|
      workers.benchmark("boot", process: {"command" => %w[boot], "ruby" => nil, "runs" => nil}) do |side, _, _|
        {"timed" => {"cpu" => (side == "candidate") ? 330_000_000 : 300_000_000}}
      end
      results, out, = run_duel(workers)

      assert_equal %w[cpu], results.first.regressed
      assert_equal Duel::Runner::CONFIRM, results.first.confirmations.size, "one timing: never one more"
      assert_nil results.first.profile
      assert_empty workers.requests("profile")
      assert_includes out, "REGRESSION boot: worse cpu in every measurement\n  cpu: 300ms → 330ms an iteration (1.10x)\n1 benchmark in"
    end
  end

  # Each version prepared once for the run, before its workers: its Ruby,
  # and its prepare(:version) blocks, given the version, whose environment
  # its workers get, and whose processes stop when the run ends.
  def test_each_version_prepared
    config = Duel::Config.new(candidate)
    given = []
    stopped = []
    config.prepare(:version) do |v|
      given << [v.name, v.root, v.ruby, v.dir, v.env]
      v.at_stop { stopped << v.name }
      {"BUNDLE_GEMFILE" => File.join(v.root, "Gemfile")}
    end
    config.prepare(:version) { |v| (given << v.dir) && {"SECOND" => v.cached("t") { |_| nil }} }
    ruby = File.join(tmpdir, "bin", "ruby")
    FileUtils.mkdir_p(File.dirname(ruby))
    File.write(ruby, "")
    File.chmod(0o755, ruby)
    config.ruby = ->(root) { root.end_with?("base") ? ruby : RbConfig.ruby }
    with_fake_workers do |workers|
      workers.benchmark("a")
      lanes = File.join(tmpdir, "lanes")
      made = []
      stub(Duel::Lane, :tmpdir, -> { File.join(lanes, (made << made.size).size.to_s).tap { |dir| FileUtils.mkdir_p(dir) } }) do
        elsewhere { Duel::Runner.new(config, settings, File.join(tmpdir, "base"), out: StringIO.new).run }
      end
      bundle = ->(root) { {"BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "SECOND" => File.join(candidate, "tmp", "duel", "cache", "t")} }

      run = File.join(lanes, "1")

      assert_equal [["baseline", File.join(tmpdir, "base"), ruby, File.join(run, "baseline-1"), Duel::Rubies.environment(ruby)],
        File.join(run, "baseline-2"), ["candidate", candidate, RbConfig.ruby, File.join(run, "candidate-1"), {}],
        File.join(run, "candidate-2")], given
      assert_equal %w[candidate baseline], stopped, "last first, once the run's done"
      assert_equal({env: Duel::Rubies.environment(ruby).merge(bundle.call(File.join(tmpdir, "base"))), ruby: ruby},
        workers.made.assoc("baseline-1").last.slice(:env, :ruby))
      assert_equal({env: bundle.call(candidate), ruby: RbConfig.ruby}, workers.made.assoc("candidate-1").last.slice(:env, :ruby))
      refute Dir.exist?(File.join(tmpdir, "lanes", "1")), "its directory removed"
    end
  end

  # A version's preparations wait as long as the run's timeout, and two
  # that set a variable differently fail, naming the version.
  def test_preparations_that_fail
    config = Duel::Config.new(candidate)
    config.prepare(:version) { |_| {"X" => "1"} }
    config.prepare(:version) { |_| {"X" => "2"} }
    with_fake_workers do
      error = assert_raises(Duel::Failed) { Duel::Runner.new(config, settings, "base", out: StringIO.new).run }

      assert_equal "baseline: two prepare blocks set X (1, 2)", error.message
      config.prepares.fetch(:version).clear
      config.prepare(:version) { |v| v.wait_until { false } }
      error = assert_raises(Duel::Failed) { Duel::Runner.new(config, settings(timeout: 0.01), "base", out: StringIO.new).run }

      assert_equal "baseline's resource: not ready within 0.01s", error.message
    end
  end

  # --ruby over c.ruby. A Ruby that isn't there fails before any worker
  # starts.
  def test_each_versions_ruby_as_the_settings_say
    config = Duel::Config.new(candidate)
    config.ruby = "/nope/a"
    with_fake_workers do |workers|
      error = assert_raises(Duel::Error) { Duel::Runner.new(config, settings(ruby: "/nope/b"), "base", out: StringIO.new).run }

      assert_equal "the baseline's Ruby (/nope/b) isn't there", error.message
      error = assert_raises(Duel::Error) { Duel::Runner.new(config, settings, "base", out: StringIO.new).run }

      assert_equal "the baseline's Ruby (/nope/a) isn't there", error.message
      assert_empty workers.made
    end
  end

  # Each version's Ruby is shown when they differ.
  def test_different_rubies
    with_fake_workers do |workers|
      workers.benchmark("a")
      workers.rubies["candidate"] = "ruby 4.0.0"
      _, out, = run_duel(workers)

      assert_equal ["  baseline on #{RUBY_DESCRIPTION}", "  candidate on ruby 4.0.0"], out.lines(chomp: true)[1, 2]
    end
  end

  # The plugins the configuration used are shown, in the order used.
  def test_plugins
    with_fake_workers do |workers|
      workers.benchmark("a")
      config = Duel::Config.new(candidate)
      config.define_singleton_method(:plugins) { %i[rails postgresql] }
      _, out, runner = run_duel(workers, config: config)

      assert_equal "  with plugins rails, postgresql", out.lines(chomp: true)[1]
      assert_equal %i[rails postgresql], runner.plugins
      _, out, runner = run_duel(workers)

      assert_empty runner.plugins
      refute_includes out, "plugins"
    end
  end

  # Only what's slower in time is profiled.
  def test_more_allocations_arent_profiled
    with_fake_workers do |workers|
      workers.benchmark("a") do |side, n, _|
        {"timed" => {"cpu" => n * 100_000}, "counted" => {"allocations" => (side == "candidate") ? n * 3 : n}, "heap" => 0}
      end
      results, out, = run_duel(workers)

      assert_equal %w[allocations], results.first.regressed
      assert_nil results.first.profile
      assert_empty workers.requests("profile")
      assert_includes out, "REGRESSION a: worse allocations in every measurement\n  allocations: 1 → 3 an iteration\n1 benchmark in"
    end
  end

  # A little slower at every benchmark: not enough for any one, but
  # across the board, measured again to be sure.
  def test_slower_across_the_board
    with_fake_workers do |workers|
      names = Array.new(8) { |i| "b#{i}" }
      names.each { |name| workers.benchmark(name) }
      workers.per_iteration["candidate"] = 101_000
      results, out, runner = run_duel(workers)

      assert results.all?(&:passed?)
      assert_includes out, "\nMeasuring every benchmark again, in fresh processes: slower across the board in cpu?\n" \
        "#{line("b0", 12, "cpu 1.010 [1.010, 1.010] same  allocations 2")}\n"
      assert_includes out, "across the board: cpu 1.010 [1.010, 1.010] slower (limit 1.0050, 8 benchmarks)\n" \
        "REGRESSION across the board: cpu slower in both measurements\n"
      assert_equal %w[cpu], runner.regressed_across
      refute runner.passed?(results)
      assert_equal 12, workers.made.size, "a lane for each measurement"
    end
  end

  def test_out_by_default
    with_fake_workers do |workers|
      workers.benchmark("a")
      out, = capture_io { elsewhere { Duel::Runner.new(Duel::Config.new(candidate), settings, "base").run } }

      assert_includes out, "1 benchmark in 0s"
    end
  end

  # A benchmark that fails is an error, and the next gets a new lane.
  def test_errors
    with_fake_workers do |workers|
      workers.benchmark("broken")
      workers.benchmark("gone")
      workers.benchmark("works")
      workers.fail("candidate-1", "setup", "broken")
      workers.fail("candidate-1", "setup", "gone", error: Errno::EPIPE.new)
      results, out, runner = run_duel(workers)

      assert_equal ["Duel::Failed: candidate-1: RuntimeError: oops", "Errno::EPIPE: Broken pipe", nil], results.map(&:error)
      assert_equal ["  #{"broken".ljust(48)} error", "  #{"gone".ljust(48)} error"], out.lines(chomp: true)[1, 2]
      assert_includes out, "\nERROR broken: Duel::Failed: candidate-1: RuntimeError: oops\nERROR gone: Errno::EPIPE: Broken pipe\n"
      assert_includes out, "3 benchmarks in 0s: 0 regressed, 2 errors"
      assert_equal 18, workers.made.size, "a new lane after each error"
      assert_equal 18, workers.log.count { |_, op| op == "stop" }
      refute runner.passed?(results)
    end
  end

  def test_other_errors_are_raised
    with_fake_workers do |workers|
      workers.benchmark("a")
      workers.fail("candidate-1", "setup", error: ArgumentError.new("a bug"))

      capture_io { assert_raises(ArgumentError) { run_duel(workers) } }
      assert_equal 6, workers.log.count { |_, op| op == "stop" }, "its lane stopped"
    end
  end

  def test_lines
    with_fake_workers do |workers|
      workers.benchmark("skipped")
      workers.fail("baseline-1", "setup", "skipped", error: Duel::Failed.new("baseline-1: NameError: no"))
      workers.benchmark("more", peak_memory: true) do |side, n, _|
        {"timed" => {"cpu" => n * 100_000}, "counted" => {"allocations" => (side == "baseline") ? n : n + 1}, "heap" => 0}
      end
      workers.peaks("baseline", *[1 << 20] * 12)
      workers.peaks("candidate", *[3 << 19] * 12)
      _, out, = run_duel(workers)

      assert_equal "  #{"skipped".ljust(48)} skipped: not on the baseline (baseline-1: NameError: no)", out.lines[1].chomp
      assert_equal line("more", 12, "cpu 1.000 [1.000, 1.000] same  allocations 1→1.083  peak_memory 1.0MB→1.5MB"),
        out.lines[2].chomp
    end
  end

  def test_unsettled
    with_fake_workers do |workers|
      workers.benchmark("a") { |side, n, _| {"timed" => {"cpu" => n * ((side == "baseline") ? 100_000 : 102_000)}, "counted" => {}, "heap" => 0} }
      _, out, = run_duel(workers)

      assert_includes out, "1 benchmark in 0s: 0 regressed, 0 errors, 1 with a timing too close to the limit to settle"
    end
  end
end

# A suspect's confirmations: it fails only if every one agrees, and the
# first that clears it ends them.
class ConfirmTest < DuelTest
  cover "Duel::Runner*"

  FakeLane = Struct.new(:results) do
    def compare(_name) = results.shift
  end

  # A result with these verdicts: of CPU time, or by metric.
  def suspect(verdicts)
    Duel::Result.new("x").tap do |r|
      (verdicts.is_a?(Hash) ? verdicts : {"cpu" => verdicts}).each do |metric, verdict|
        r.timed[metric] = {"verdict" => verdict, "median" => 1.0, "interval" => [1.0, 1.0], "pairs" => 10}
      end
      r.n = 1
      r.seconds = 0.0
    end
  end

  def confirm(*verdicts, first: "slower", out: StringIO.new)
    lane = FakeLane.new(verdicts.map { |v| suspect(v) })
    result = suspect(first)
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, tmpdir, out: out)
    original = Duel::Lane.method(:open)
    Duel::Lane.define_singleton_method(:open) { |*, &block| block.call(lane) }
    begin
      elsewhere { runner.send(:confirm, [result]) }
    ensure
      Duel::Lane.define_singleton_method(:open, original)
    end
    result
  end

  def test_every_confirmation_agrees
    result = confirm("slower", "slower", "slower", "slower")

    assert_equal 3, result.confirmations.size
    assert_equal %w[cpu], result.regressed
  end

  # Slower in CPU time in one measurement, in instructions in the next:
  # slower in time in all of them takes one more.
  def test_slower_on_one_metric_or_another
    slower = ->(metric) { {"cpu" => "undecided", "instructions" => "undecided", metric => "slower"} }
    result = confirm(slower["instructions"], slower["cpu"], slower["instructions"], slower["cpu"], slower["cpu"],
      first: slower["cpu"])

    assert_equal 4, result.confirmations.size
    assert_equal %w[cpu instructions], result.regressed
  end

  def test_the_first_that_clears_it_ends_them
    result = confirm("slower", "same", "slower")

    assert_equal 2, result.confirmations.size
    assert_empty result.regressed
  end

  # One too close to call neither confirms it nor clears it: it's
  # measured once more instead, up to CONFIRM times more.
  def test_one_too_close_to_call_is_measured_again
    out = StringIO.new
    result = confirm("slower", "undecided", "slower", "slower", out: out)

    assert_equal 3, result.confirmations.size
    assert_equal 1, result.undecided.size
    assert_equal %w[cpu], result.regressed
    assert_equal 1, out.string.scan("undecided  (too close to call: once more)\n").size
    result = confirm("undecided", "undecided", "undecided", "undecided", "slower")

    assert_equal 3, result.undecided.size
    assert_equal 1, result.confirmations.size
    assert_empty result.regressed, "the fourth, cleared"
  end
end

# What a runner does where profiles can't be had.
class UnavailableTest < DuelTest
  cover "Duel::Runner*"

  def runner_with_lane(lane)
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, tmpdir, out: StringIO.new)
    original = Duel::Lane.method(:open)
    Duel::Lane.define_singleton_method(:open) { |*, **, &block| block.call(lane) }
    yield runner
  ensure
    Duel::Lane.define_singleton_method(:open, original)
  end

  def test_a_regression_without_a_profile
    result = Duel::Result.new("x")
    result.n = 1
    no_profiler = Object.new
    no_profiler.define_singleton_method(:profile) { |*| nil }
    runner_with_lane(no_profiler) { |runner| elsewhere { runner.send(:profile, [result]) } }

    assert_equal({"unavailable" => Duel::Profile::UNAVAILABLE}, result.profile)
    failing = Object.new
    failing.define_singleton_method(:profile) { |*| raise Duel::Failed, "worker exited" }
    runner_with_lane(failing) { |runner| elsewhere { runner.send(:profile, [result]) } }

    assert_equal({"unavailable" => "Duel::Failed: worker exited"}, result.profile)
  end

  def test_profile_lines
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, tmpdir, out: StringIO.new)

    assert_empty runner.send(:profile_lines, nil)
    assert_equal ["profile: no"], runner.send(:profile_lines, {"unavailable" => "no"})
    assert_equal ["where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
      "   +11.5%  +18.0%  Slow#work"], runner.send(:profile_lines, {"grew" => [["Slow#work", 0.115, 0.18]], "gc" => 0.0})
    assert_equal "   +50.0%          in garbage collection, apart from the code",
      runner.send(:profile_lines, {"grew" => [], "gc" => 0.5}).last, "apart, when it changed"
  end
end

class ProfileTest < DuelTest
  cover "Duel::Profile*"

  def test_the_frames_whose_share_grew_most
    base = {"samples" => 100, "frames" => [["a", 50, 90], ["b", 10, 10], ["c", 40, 40]]}
    candidate = {"samples" => 130, "frames" => [["a", 50, 120], ["b", 20, 20], ["d", 30, 30], ["c", 30, 30]]}
    profile = Duel::Profile.new("baseline" => base, "candidate" => candidate)
    grew = [["d", 0.3, 0.3], ["b", 0.1, 0.1]]

    assert_equal grew, profile.grew, "the most gained first; a held, c lost"
    assert_equal grew, profile.to_h.fetch("grew")
    assert_equal base, profile.to_h.fetch("baseline")
    assert_equal candidate, profile.to_h.fetch("candidate")
  end

  # Garbage collection isn't the benchmark's code: what it gained is
  # apart, not ranked with the frames.
  def test_garbage_collection_apart
    base = {"samples" => 100, "frames" => [["(garbage collection)", 10, 30], ["(sweeping)", 20, 20], ["a", 70, 70]]}
    candidate = {"samples" => 150, "frames" => [["(garbage collection)", 20, 75], ["(marking)", 30, 30], ["(sweeping)", 25, 25],
      ["a", 75, 75]]}
    profile = Duel::Profile.new("baseline" => base, "candidate" => candidate)

    assert_equal [["a", 0.05, 0.05]], profile.grew
    assert_in_delta 0.45, profile.gc, 1e-12
    assert_in_delta 0.45, profile.to_h.fetch("gc"), 1e-12
    assert_in_delta(-0.45, Duel::Profile.new("baseline" => candidate, "candidate" => base).gc * 1.5, 1e-12, "or lost")
    none = {"samples" => 100, "frames" => [["a", 70, 70]]}

    assert_in_delta 0.0, Duel::Profile.new("baseline" => none, "candidate" => none).gc, 1e-12
    assert_in_delta 0.75, Duel::Profile.new("baseline" => none, "candidate" => candidate).gc, 1e-12, "none before"
    assert_in_delta(-0.3, Duel::Profile.new("baseline" => base, "candidate" => none).gc, 1e-12, "none after")
  end

  # StackProf's samples, each with its stack (outermost first): those of
  # the benchmark's work, inside Harness#iterate, and of garbage
  # collection are kept. A sample starting or stopping isn't, nor is the
  # worker's own work, nor what's paused: an untimed block, and an around
  # block's own work. An iteration inside its around block is kept, all
  # but pausing and resuming around it, and an untimed block inside it.
  def test_a_profile_of_stackprofs_samples
    names = {1 => "Duel::Worker#profile", 2 => "Duel::Harness#run", 3 => "Duel::Harness#iterate", 4 => "Sample.work",
             5 => "Sample.helper", 6 => "Duel::ProfileSample#start", 7 => "Duel::ProfileSample#pause",
             8 => "Duel::ProfileSample#stop", 9 => "(garbage collection)", 10 => "(sweeping)", 11 => "Sample.work",
             12 => "Untimed.work", 13 => "Duel::Iteration#run", 14 => "Around.undo", 15 => "Duel::Harness#iteration",
             16 => "Duel::Iteration#call", 17 => "Duel::ProfileSample#unpause"}
    raw = [
      5, 1, 2, 3, 4, 5, 4, # the work, and what it called (4 samples)
      4, 1, 2, 3, 4, 2, # the work itself
      4, 1, 2, 3, 11, 1, # the same method, from another place
      5, 1, 2, 3, 4, 4, 3, # a recursive call
      1, 1, 7, # the worker's
      3, 1, 2, 6, 1, # starting
      5, 1, 2, 3, 7, 12, 9, # untimed
      3, 1, 2, 8, 1, # stopping
      2, 9, 10, 2, # collecting
      1, 9, 1,
      6, 1, 2, 3, 13, 7, 14, 5, # around each iteration
      7, 1, 2, 3, 13, 7, 16, 17, 2, # resuming and pausing around an iteration
      9, 1, 2, 3, 13, 7, 16, 17, 15, 4, 3, # an iteration
      10, 1, 2, 3, 13, 7, 16, 17, 15, 7, 12, 4 # untimed, inside an iteration
    ]
    profile = Duel::Profile.of({frames: names.transform_values { |name| {name: name} }, raw: raw})
    iteration = %w[Duel::Iteration#run Duel::ProfileSample#pause Duel::Iteration#call Duel::ProfileSample#unpause
      Duel::Harness#iteration].map { |name| [name, 0, 3] }

    assert_equal 16, profile.fetch("samples")
    assert_equal [["Duel::Worker#profile", 0, 13], ["Duel::Harness#run", 0, 13], ["Duel::Harness#iterate", 0, 13],
      ["Sample.work", 9, 13], ["(garbage collection)", 1, 3], ["Sample.helper", 4, 4], ["(sweeping)", 2, 2], *iteration].sort,
      profile.fetch("frames").sort
    assert_equal profile.fetch("frames").map(&:last).sort.reverse, profile.fetch("frames").map(&:last), "most total first"
    assert_equal({"samples" => 0, "frames" => []}, Duel::Profile.of({frames: {}}), "no samples, no raw")
  end

  def test_a_baseline_without_samples
    profile = Duel::Profile.new("baseline" => {"samples" => 0, "frames" => []}, "candidate" => {"samples" => 3, "frames" => [["x", 3, 4]]})

    assert_equal [["x", 3.0, 4.0]], profile.grew
  end

  def test_keeps_the_top_frames
    frames = Array.new(300) { |i| ["f#{i}", 1, 1] }
    more = frames.map { |frame, own, total| [frame, own + 1, total + 1] }
    profile = Duel::Profile.new("baseline" => {"samples" => 300, "frames" => frames}, "candidate" => {"samples" => 600, "frames" => more})

    assert_equal Duel::Profile::KEPT, profile.to_h.fetch("baseline").fetch("frames").size
    assert_equal Duel::Profile::KEPT, profile.to_h.fetch("candidate").fetch("frames").size
    assert_equal Duel::Profile::TOP, profile.grew.size
  end
end
