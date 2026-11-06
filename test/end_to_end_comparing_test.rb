# frozen_string_literal: true

require_relative "support/end_to_end"

# Comparing two versions: the same code passes, and slower code, or code
# that allocates more, fails.
class EndToEndComparingTest < DuelTest
  include EndToEnd

  # The duel command, on two directories.
  def test_the_duel_command
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"))
    # (Twice the work, four times under a JIT, whose timings on a shared
    # machine swing too far to tell twice from noise every time.)
    slower = project(File.join(tmpdir, "slower"), work: Duel::JIT_WARM.zero? ? 6000 : 12_000)
    duel = lambda do |dir|
      out = StringIO.new
      [Dir.chdir(dir) { Duel::CLI.new(["--base", base, "--jobs", "1"], env: {}, out: out).run }, out.string]
    end

    assert_equal 0, duel.call(candidate).first
    status, out = duel.call(slower)

    assert_equal 1, status
    assert_includes out, "REGRESSION work"
  end

  def test_the_same_code_passes
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"))
    results, out = compare(base, candidate)

    assert_equal ["work"], results.map(&:name)
    assert_empty results.reject(&:passed?), out
    assert_includes out, "1 benchmark in"
    assert_includes out, "0 regressed, 0 errors"
    refute_path_exists File.join(candidate, "tmp", "duel"), "nothing written"
  end

  def test_slower_code_fails_in_every_measurement
    base = project(File.join(tmpdir, "base"), work: 3000)
    # (Twice the work, three times under a JIT: a shared machine's timings
    # swing too far to confirm less every time.)
    candidate = project(File.join(tmpdir, "candidate"), work: Duel::JIT_WARM.zero? ? 6000 : 9000)
    results, out = compare(base, candidate)
    result = results.first

    refute_predicate result, :passed?
    assert_equal timed_metrics, result.regressed, "and instructions, where they're counted"
    assert_equal Duel::Runner::CONFIRM, result.confirmations.size
    assert_includes out, "REGRESSION work: worse #{timed_metrics.join(", ")} in every measurement"
    if RUBY_ENGINE == "ruby"
      assert_includes out, "where the extra CPU went"
      grew = result.profile.fetch("grew")

      refute_empty grew, result.profile.inspect
      assert(grew.all? { |_, own, _| own.positive? })
    else
      assert_equal({"unavailable" => Duel::Profile::UNAVAILABLE}, result.profile, "no StackProf")
    end
  end

  def test_more_allocations_fail
    skip "CRuby counts allocations" unless RUBY_ENGINE == "ruby"

    base = project(File.join(tmpdir, "base"), allocations: 1)
    candidate = project(File.join(tmpdir, "candidate"), allocations: 2)
    result, = compare(base, candidate).first

    assert_includes result.regressed, "allocations"
    counted = result.counted.fetch("allocations")

    assert_operator counted.fetch("candidate") - counted.fetch("baseline"), :>=, counted.fetch("n")
  end

  def test_a_benchmark_the_baseline_cant_run_is_skipped
    benchmarks = DEFAULT_BENCHMARKS + %(\nduel("new") { once { Sample.newer } }\n)
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: benchmarks, extra: "def self.newer = 1")
    results, out = compare(base, candidate, filter: /new/)

    assert_equal ["new"], results.map(&:name)
    assert_match(/not on the baseline \(base-1: NoMethodError/, results.first.skipped)
    assert_predicate results.first, :passed?
    assert_includes out, "skipped: not on the baseline"
  end

  # Warming up (as on JRuby) runs pairs for a while, then sizes samples
  # again, and a counts-only benchmark skips all that.
  def test_warm_up_and_counts_only
    benchmarks = DEFAULT_BENCHMARKS + <<~RUBY
      duel("counts", only: :count) { Object.new }
      duel("process", only: :timing) { Sample.work }
    RUBY
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: benchmarks)
    results, = compare(base, candidate, warm: 0.2)
    counts = results.find { |r| r.name == "counts" }

    process = results.find { |r| r.name == "process" }

    assert results.all?(&:passed?)
    assert_empty process.counted, "only: :timing"
    assert_equal timed_metrics(cpu: :process), process.timed.keys
    assert_equal Duel::COUNTS_ONLY, counts.n
    assert_empty counts.timed
    assert_equal (RUBY_ENGINE == "ruby") ? %w[allocations] : [], counts.counted.keys
  end
end
