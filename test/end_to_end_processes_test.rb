# frozen_string_literal: true

require_relative "support/end_to_end"

# Benchmarks of whole processes, and workers and benchmarks that fail: a
# worker that can't load, or takes too long to, and a benchmark that
# hangs or is broken.
class EndToEndProcessesTest < DuelTest
  include EndToEnd

  # A benchmark of a whole process: each version's own, fresh for every
  # sample, which passes against the same code. (How it decides is the
  # faster tests', with processes faked: a slower process fails there.)
  def test_a_process_benchmark
    skip "a JVM for every process: minutes of them (ProcessSampleTest runs real ones)" if RUBY_ENGINE == "jruby"

    benchmarks = %(duel_process "boot", ruby: 'require "sample"'\n)
    base = project(File.join(tmpdir, "base"), benchmarks: benchmarks)
    same = project(File.join(tmpdir, "same"), benchmarks: benchmarks)
    results, out = compare(base, same, processes: 1)
    result = results.first

    assert_predicate result, :passed?, out
    assert_equal [1, %w[cpu]], [result.n, result.timed.keys]
    if Duel::Native::FIDDLE
      assert_equal %w[baseline candidate], result.memory.keys
    else
      assert_nil result.memory, "no peak memory to tell"
    end
  end

  def test_a_worker_that_cant_load_fails_the_lane
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: "raise 'broken file'")
    error = nil
    config = Duel::Config.new(candidate)
    run = settings(candidate_dir: candidate)
    _, err = capture_subprocess_io do
      error = assert_raises(Duel::Failed) { Duel::Lane.new(config, run, Duel::Side.unprepared(config, run, base)) }
    end

    assert_equal "base-1 worker exited while loading", error.message
    assert_includes err, "broken file", "the worker's error is shown"
    assert_empty Dir.glob("/tmp/duel*/base-1.sock"), "its directory is cleaned up"
  end

  # A benchmark that hangs is an error after the timeout, not the end of
  # the run: its workers are killed, and the next benchmark gets new ones.
  def test_a_benchmark_that_hangs_is_an_error
    hangs = DEFAULT_BENCHMARKS + %(\nduel("hangs") { sleep }\n)
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: hangs)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Long enough for the work benchmark's every answer: JRuby's and
    # TruffleRuby's are slow until their JIT compilers have warmed up.
    timeout, most = (RUBY_ENGINE == "ruby") ? [1.0, 60] : [30.0, 150]
    # A worker loads with the default timeout, and is given the short one
    # once it has said hello: on a busy machine, loading Ruby can take
    # more than a second, and the hang is a benchmark's, not a load's.
    loading = Duel::WorkerProcess.method(:new)
    loaded = lambda do |*args, **options|
      loading.call(*args, **options, timeout: Duel::TIMEOUT).tap { |worker| worker.instance_variable_set(:@timeout, timeout) }
    end
    results, out = stub(Duel::WorkerProcess, :new, loaded) { compare(base, candidate, timeout: timeout, filter: /hangs|work/) }
    hung = results.find { |r| r.name == "hangs" }

    assert_equal "Duel::Failed: head-1 worker didn't answer within #{timeout}s (killed: a benchmark that hangs?)", hung.error
    assert_predicate results.find { |r| r.name == "work" }, :passed?
    assert_includes out, "ERROR hangs"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, most
  end

  def test_a_worker_that_takes_too_long_to_load
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: "sleep")
    config = Duel::Config.new(candidate)
    run = settings(candidate_dir: candidate, timeout: 0.5)
    error = assert_raises(Duel::Failed) { Duel::Lane.new(config, run, Duel::Side.unprepared(config, run, base)) }

    assert_equal "base-1 worker didn't load within 0.5s (killed: a benchmark that hangs?)", error.message
  end

  def test_a_broken_benchmark_is_an_error
    broken = DEFAULT_BENCHMARKS + %(\nduel("broken") { raise "oops" }\n)
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: broken)
    results, out = compare(base, candidate)
    broken_result = results.find { |r| r.name == "broken" }

    assert_match(/head-1: RuntimeError: oops/, broken_result.error)
    refute_predicate broken_result, :passed?
    assert_predicate results.find { |r| r.name == "work" }, :passed?, "a new lane for the next one"
    assert_includes out, "ERROR broken"
  end
end
