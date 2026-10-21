# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# Whole runs, with their worker processes faked (see FakeWorkers): what
# a runner prints and decides.
class RunnerTest < DuelTest
  cover "Duel::Runner*"

  def candidate = File.join(tmpdir, "candidate")

  def run_duel(workers, **overrides)
    runner = Duel::Runner.new(Duel::Config.new(candidate), settings(**overrides), File.join(tmpdir, "base"),
      out: (out = StringIO.new))
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
        "Comparing 2 benchmarks: baseline #{File.join(tmpdir, "base")} against candidate #{candidate} (1 at a time; " \
        "slower means a 99.0% interval above 1.02)",
        line("a", 12, "cpu 1.000 [1.000, 1.000] same  allocations 24"),
        line("b", 12, "cpu 1.000 [1.000, 1.000] same  allocations 24"),
        "",
        "across the board: cpu 1.000 undecided (limit 1.0050, 2 benchmarks)",
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

      assert_equal "Comparing 1 benchmarks: baseline base against candidate #{File.join(tmpdir, "other")} (2 at a time; " \
        "slower means a 95.0% interval above 1.05)", out.string.lines.first.chomp
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
      a = line("a", 11, "cpu 1.100 [1.100, 1.100] slower  allocations 22→33", mark: "!")

      assert_equal [
        out.lines.first.chomp,
        a,
        "",
        "Measuring 1 that looked worse again, up to 3 times each, in fresh processes:",
        a, a, a,
        "",
        "across the board: cpu 1.100 undecided (limit 1.0050, 1 benchmarks)",
        "REGRESSION a: worse cpu, allocations in every measurement",
        "  cpu: 100µs → 110µs an iteration (1.10x)",
        "  allocations: 2 → 3 an iteration",
        "  allocations (candidate): 3 String",
        "  allocations (baseline): 2 String",
        "  where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
        "     +10.0%  +10.0%  f",
        "1 benchmarks in 0s: 1 regressed, 0 errors, 0 with a timing too close to the limit to settle"
      ], out.lines(chomp: true)
      refute runner.passed?(results)
      assert_equal 3, results.first.confirmations.size
      assert_equal [["f", 0.1, 0.1]], results.first.profile.fetch("grew")
      assert_equal 6 + (3 * 6) + 2, workers.made.size, "a lane, three more, and one of a worker each to profile"
      assert_equal [["baseline-1", "a", {n: 1100, runs: 5}], ["candidate-1", "a", {n: 1100, runs: 5}]], workers.requests("profile")
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

    r.counted["round_trips_made"] = {"baseline" => 0, "candidate" => 1, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "round trip",
                                     "plural" => "round trips"}
    r.counted["round_trips"] = {"baseline" => 1, "candidate" => 1, "n" => 2, "tolerance" => 0, "allowance" => 0, "unit" => "round trip",
                                "plural" => "round trips"}

    assert_match(/  retained 0→7 objects  bytes 1700 B  round_trips_made 0→1 round trip  round_trips 1  peak_memory/, runner.send(:line, r),
      "with units on its line, but one its name ends in")
  end

  # Amounts an iteration, in their unit: time in the largest unit it
  # makes at least one of; a word, singular for one.
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
      assert_includes out, "REGRESSION a: worse allocations in every measurement\n  allocations: 1 → 3 an iteration\n1 benchmarks"
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
        "#{line("b0", 12, "cpu 1.010 [1.010, 1.010] same  allocations 24")}\n"
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

      assert_includes out, "1 benchmarks in 0s"
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
      assert_equal line("more", 12, "cpu 1.000 [1.000, 1.000] same  allocations 12→13  peak_memory 1.0MB→1.5MB"),
        out.lines[2].chomp
    end
  end

  def test_unsettled
    with_fake_workers do |workers|
      workers.benchmark("a") { |side, n, _| {"timed" => {"cpu" => n * ((side == "baseline") ? 100_000 : 102_000)}, "counted" => {}, "heap" => 0} }
      _, out, = run_duel(workers)

      assert_includes out, "1 benchmarks in 0s: 0 regressed, 0 errors, 1 with a timing too close to the limit to settle"
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

  def suspect(verdict)
    Duel::Result.new("x").tap do |r|
      r.timed["cpu"] = {"verdict" => verdict, "median" => 1.0, "interval" => [1.0, 1.0], "pairs" => 10}
      r.n = 1
      r.seconds = 0.0
    end
  end

  def confirm(*verdicts)
    lane = FakeLane.new(verdicts.map { |v| suspect(v) })
    result = suspect("slower")
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, tmpdir, out: StringIO.new)
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

  def test_the_first_that_clears_it_ends_them
    result = confirm("slower", "same", "slower")

    assert_equal 2, result.confirmations.size
    assert_empty result.regressed
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
      "   +11.5%  +18.0%  Slow#work"], runner.send(:profile_lines, {"grew" => [["Slow#work", 0.115, 0.18]]})
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
