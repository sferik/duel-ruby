# frozen_string_literal: true

require_relative "test_helper"

# Whole comparisons of a small project's two versions, in worker
# processes: the same code passes, and slower code, or code that
# allocates more, fails.
#
# (Too slow for mutation testing: the code they run is covered there by
# faster tests, with its worker processes faked.)
class EndToEndTest < DuelTest
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

  # Real workers: with a JIT that needs one (JRuby's, TruffleRuby's),
  # warmed up a little (the tests' code is quick to warm up).
  def settings(**overrides) = super(warm: Duel::JIT_WARM.zero? ? 0.0 : 1.5, **overrides)

  def compare(base, candidate, **overrides)
    config = Duel::Config.new(candidate)
    out = StringIO.new
    results = Duel::Runner.new(config, settings(candidate_dir: candidate, **overrides), base, out: out).run
    [results, out.string]
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

  # Peak memory, for a benchmark that asks: one that needs 24 MB more at
  # its peak fails, and the same memory passes.
  def test_peak_memory
    skip "no way to tell resident memory here" unless Duel::Native::Memory.resident

    # (With a setup of its own: the fresh workers measuring it run no trial.)
    benchmarks = %(require "sample"\nduel("big", peak_memory: true) { once { @more = 0 }\n Sample.big.size + @more }\n)
    base = project(File.join(tmpdir, "base"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(1 << 20)")
    same = project(File.join(tmpdir, "same"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(1 << 20)")
    bigger = project(File.join(tmpdir, "bigger"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(25 << 20)")
    passed, = compare(base, same, processes: 1)

    refute_includes passed.first.regressed, "peak_memory"
    assert_equal %w[baseline candidate], passed.first.memory.keys
    failed, out = compare(base, bigger, processes: 1)

    assert_includes failed.first.regressed, "peak_memory", out
    assert_match(/peak_memory \d+\.\dMB→\d+\.\dMB/, out)
  end

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
    assert_match(/not on the baseline \(baseline-1: NoMethodError/, results.first.skipped)
    assert_predicate results.first, :passed?
    assert_includes out, "skipped: not on the baseline"
  end

  # A config file's plugins: a resource per worker (a process it starts
  # and waits for, its environment and its stop), a counted metric of
  # running totals and a helper (a method of its own), with a benchmark
  # file's setup and code of its own.
  def test_plugins_from_the_config_file
    stops = File.join(tmpdir, "stops")
    FileUtils.mkdir_p(stops)
    calls = "class << self; attr_accessor :calls; end\n  self.calls = 0"
    base = project(File.join(tmpdir, "base"), extra: calls)
    candidate = project(File.join(tmpdir, "candidate"), extra: calls, benchmarks: nil)
    FileUtils.mkdir_p(File.join(candidate, "bench"))
    File.write(File.join(candidate, "bench", "work.rb"), <<~RUBY)
      Sample.singleton_class.prepend(Module.new { def work = (Sample.calls += 1) && super })

      setup { raise "no resource" unless resource_name }

      duel("work") { Sample.work }
    RUBY
    File.write(File.join(candidate, ".duel.rb"), <<~RUBY)
      def resource_name = ENV["DUEL_TEST_RESOURCE"]

      Duel.configure do |c|
        c.benchmarks = "bench/*.rb"
        c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) && require("sample") }
        c.metric("calls") { Sample.calls }
        c.prepare(:worker) do |r|
          ready = r.path("ready")
          r.spawn(RbConfig.ruby, "-e", "File.write(ARGV[0], '') && sleep", ready)
          r.wait_until { File.exist?(ready) }
          r.at_stop { File.write(File.join(#{stops.inspect}, r.name), "") }
          {"DUEL_TEST_RESOURCE" => r.name}
        end
      end
    RUBY
    config = Duel.load_config(File.join(candidate, ".duel.rb"))
    results = Duel::Runner.new(config, settings(config_path: File.join(candidate, ".duel.rb")), base, out: StringIO.new).run
    calls = results.first.counted.fetch("calls")

    assert_predicate results.first, :passed?
    assert_equal calls.fetch("n"), calls.fetch("baseline")
    assert_equal calls.fetch("n"), calls.fetch("candidate")
    assert_equal %w[baseline-1 baseline-2 baseline-3 candidate-1 candidate-2 candidate-3], Dir.children(stops).sort,
      "each worker's resource stopped"
  end

  # An around_iteration hook, and the config's before_sample and
  # after_iterations hooks, in real workers: only the iterations, and the
  # jobs they left to do, are counted (not what the around_iteration hook
  # allocates), and the same code passes.
  def test_around_iteration_before_sample_and_after_iterations
    queue = "class << self; attr_accessor :jobs; end\n  self.jobs = []"
    base = project(File.join(tmpdir, "base"), extra: queue)
    candidate = project(File.join(tmpdir, "candidate"), extra: queue, benchmarks: <<~RUBY)
      require "sample"

      duel("job", around_iteration: ->(iteration) { Array.new(100) { Object.new } && iteration.call }) do
        Sample.jobs << :job
        Sample.work
      end
    RUBY
    File.write(File.join(candidate, ".duel.rb"), <<~RUBY)
      Duel.configure do |c|
        c.before_sample { |_benchmark| Sample.jobs.clear }
        c.after_iterations { Object.new while Sample.jobs.pop } # (a job allocates one)
      end
    RUBY
    config = Duel.load_config(File.join(candidate, ".duel.rb"))
    result = Duel::Runner.new(config, settings(config_path: File.join(candidate, ".duel.rb")), base, out: StringIO.new).run.first

    assert_predicate result, :passed?
    if RUBY_ENGINE == "ruby"
      allocations = result.counted.fetch("allocations")

      assert_equal [allocations.fetch("n")] * 2, allocations.values_at("baseline", "candidate")
    end
  end

  # A timed metric of a plugin's: judged like CPU time, and sizing samples
  # too (CPU time too short to judge then goes unjudged).
  def test_a_timed_plugin_metric
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: nil)
    FileUtils.mkdir_p(File.join(candidate, "duel"))
    File.write(File.join(candidate, "duel", "tiny_duel.rb"), 'duel("tiny") { 1 }')
    File.write(File.join(candidate, ".duel.rb"), <<~RUBY)
      class Steady < Duel::Metric
        def self.measures = {"steady" => {kind: :ratio, unit_ns: 1000}}

        def stop_sample = 2000
      end
      Duel.configure { |c| c.metric Steady }
    RUBY
    config = Duel.load_config(File.join(candidate, ".duel.rb"))
    result = Duel::Runner.new(config, settings(config_path: File.join(candidate, ".duel.rb")), project(File.join(tmpdir, "base")),
      out: StringIO.new).run.first

    assert_equal %w[steady], result.timed.keys
    assert_equal "same", result.timed.fetch("steady").fetch("verdict")
    assert_equal 1, result.n, "2000 units of 1000 ns: enough at once"
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

  def test_a_worker_that_cant_load_fails_the_lane
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: "raise 'broken file'")
    error = nil
    config = Duel::Config.new(candidate)
    run = settings(candidate_dir: candidate)
    _, err = capture_subprocess_io do
      error = assert_raises(Duel::Failed) { Duel::Lane.new(config, run, Duel::Side.unprepared(config, run, base)) }
    end

    assert_equal "baseline-1 worker exited while loading", error.message
    assert_includes err, "broken file", "the worker's error is shown"
    assert_empty Dir.glob("/tmp/duel*/baseline.sock"), "its directory is cleaned up"
  end

  # A benchmark that hangs is an error after the timeout, not the end of
  # the run: its workers are killed, and the next benchmark gets new ones.
  def test_a_benchmark_that_hangs_is_an_error
    hangs = DEFAULT_BENCHMARKS + %(\nduel("hangs") { sleep }\n)
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: hangs)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Long enough for a worker to load: JRuby's and TruffleRuby's load
    # slowly.
    # (Their workers load at once, too.)
    timeout, most = (RUBY_ENGINE == "ruby") ? [1.0, 30] : [30.0, 150]
    results, out = compare(base, candidate, timeout: timeout, filter: /hangs|work/)
    hung = results.find { |r| r.name == "hangs" }

    assert_equal "Duel::Failed: candidate-1 worker didn't answer within #{timeout}s (killed: a benchmark that hangs?)", hung.error
    assert_predicate results.find { |r| r.name == "work" }, :passed?
    assert_includes out, "ERROR hangs"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, most
  end

  # A run that allocates a lot but takes little CPU is held to what fits
  # HEAP_CAP (64 MB), as the garbage collector is held off meanwhile.
  def test_allocation_heavy_benchmarks_are_capped
    skip "CRuby holds the collector off" unless RUBY_ENGINE == "ruby"

    benchmarks = %(duel("big") { String.new(capacity: 32 << 20) }\n)
    base = project(File.join(tmpdir, "base"), benchmarks: benchmarks)
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: benchmarks)
    result, = compare(base, candidate, processes: 1).first

    assert_operator result.n, :<=, 2
  end

  def test_a_worker_that_takes_too_long_to_load
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: "sleep")
    config = Duel::Config.new(candidate)
    run = settings(candidate_dir: candidate, timeout: 0.5)
    error = assert_raises(Duel::Failed) { Duel::Lane.new(config, run, Duel::Side.unprepared(config, run, base)) }

    assert_equal "baseline-1 worker didn't load within 0.5s (killed: a benchmark that hangs?)", error.message
  end

  def test_a_broken_benchmark_is_an_error
    broken = DEFAULT_BENCHMARKS + %(\nduel("broken") { raise "oops" }\n)
    base = project(File.join(tmpdir, "base"))
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: broken)
    results, out = compare(base, candidate)
    broken_result = results.find { |r| r.name == "broken" }

    assert_match(/candidate-1: RuntimeError: oops/, broken_result.error)
    refute_predicate broken_result, :passed?
    assert_predicate results.find { |r| r.name == "work" }, :passed?, "a new lane for the next one"
    assert_includes out, "ERROR broken"
  end
end
