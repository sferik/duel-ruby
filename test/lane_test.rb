# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# A lane's workings, with its worker processes faked (see FakeWorkers):
# every measure is exact, so every decision is too.
class LaneTest < DuelTest
  cover "Duel::Lane*"

  def config = @config ||= Duel::Config.new(File.join(tmpdir, "candidate"))

  # A lane of fake workers; its clock (for warming up and timing) ticks
  # once a look.
  def lane(workers, processes: nil, **overrides)
    options = processes ? {processes: processes} : {}
    Duel::Lane.new(config, settings(**overrides), File.join(tmpdir, "base"), **options).tap do |lane|
      clock = 1000
      lock = Mutex.new
      lane.define_singleton_method(:monotonic) { lock.synchronize { clock += 1 } }
    end
  end

  def compare(workers, name = "b", **overrides)
    l = lane(workers, **overrides)
    [l.compare(name), l]
  ensure
    l&.stop
  end

  # Samples taken, as [label, n, runs, count].
  def samples(workers) = workers.requests("sample").map { |label, _, args| [label, *args.values_at(:n, :runs, :count)] }

  def test_spawns_each_versions_workers_with_their_resources
    stopped = SharedList.new
    given = SharedList.new
    config.resource do |r|
      given << [r.dir, r.name]
      r.at_stop { stopped << [:first, r.name] }
      {"A" => r.name, "B" => "1"}
    end
    config.resource do |r|
      given << [r.dir, r.name]
      r.at_stop { stopped << [:second, r.name] }
      {"B" => "1", "C" => "2"} # (B as the other has it: no clash)
    end
    with_fake_workers do |workers|
      workers.profiler = :yes
      workers.benchmark("b")
      l = lane(workers, processes: 2, config_path: "/c/.duel.rb", timeout: 7.0)
      dir = File.dirname(given.first.first)

      labels = %w[baseline-1 baseline-2 candidate-1 candidate-2]

      assert_equal labels, workers.made.map(&:first).sort, "started at once"
      assert_equal labels.flat_map { |label| ["#{label}-1", "#{label}-2"] }, given.map { |resource_dir, _| File.basename(resource_dir) }.sort,
        "a directory of each resource's own"
      assert(given.all? { |resource_dir, _| File.dirname(resource_dir) == dir })
      assert_equal ["baseline-1", File.join(tmpdir, "base"), File.join(tmpdir, "candidate"), dir,
        {config_path: "/c/.duel.rb", env: {"A" => "baseline-1", "B" => "1", "C" => "2"}, timeout: 7.0}], workers.made.assoc("baseline-1")
      assert_equal File.join(tmpdir, "candidate"), workers.made.assoc("candidate-2")[1]
      assert_equal labels, given.map(&:last).uniq.sort
      assert Dir.exist?(dir)
      assert_equal :yes, l.profiler
      assert_equal ["b"], l.benchmarks.keys
      l.stop

      assert_equal labels.map { |label| [label, "stop"] }, workers.log.sort
      assert_equal labels.flat_map { |label| [[:first, label], [:second, label]] }.sort, stopped.sort
      assert(labels.all? { |label| stopped.index([:second, label]) < stopped.index([:first, label]) }, "each worker's last first")
      refute Dir.exist?(dir)
    end
  end

  def test_the_roots
    with_fake_workers do |workers|
      Duel::Lane.new(config, settings(candidate_dir: File.join(tmpdir, "x", "..", "other"), processes: 1),
        File.join(tmpdir, "x", "..", "base")).stop

      assert_equal [File.join(tmpdir, "base"), File.join(tmpdir, "other")], workers.made.first[1, 2]
      assert_equal File.join(tmpdir, "other"), workers.made.last[1]
    end
  end

  def test_processes_by_default_from_the_settings
    with_fake_workers do |workers|
      Duel::Lane.new(config, settings(processes: 1), tmpdir).stop

      assert_equal %w[baseline-1 candidate-1], workers.made.map(&:first)
    end
  end

  # Two resources that set a variable differently can't both be right.
  def test_resources_that_clash
    config.resource { |_| {"DATABASE_URL" => "postgres:///a"} }
    config.resource { |_| {"DATABASE_URL" => "mysql2:///b"} }
    with_fake_workers do |workers|
      error = assert_raises(Duel::Failed) { lane(workers) }

      assert_equal "baseline-1: two resources set DATABASE_URL (postgres:///a, mysql2:///b)", error.message
    end
  end

  # Each resource gets the tree of the version its worker runs, and the
  # candidate's tmp/duel/cache for what it builds once.
  def test_resources_get_their_versions_root
    roots = SharedList.new
    cached = SharedList.new
    config.resource do |r|
      roots << [r.name, r.root]
      cached << r.cached("t") { |_| nil }
      {}
    end
    with_fake_workers do |workers|
      lane(workers, processes: 1).stop

      assert_equal [["baseline-1", File.join(tmpdir, "base")], ["candidate-1", File.join(tmpdir, "candidate")]], roots.sort
      assert_equal [File.join(tmpdir, "candidate", "tmp", "duel", "cache", "t")] * 2, cached
    end
  end

  # Workers start at once: one that fails doesn't stop the rest starting,
  # and every one is done before it fails.
  def test_in_parallel
    with_fake_workers do |workers|
      l = lane(workers, processes: 1)
      done = []
      error = nil
      _, err = capture_io do
        error = assert_raises(RuntimeError) do
          l.send(:in_parallel, [1, 2, 3]) do |i|
            raise "no #{i}" if i == 1

            sleep 0.05
            done << i
          end
        end
      end

      assert_empty err, "the failure is raised, not reported too"

      assert_equal "no 1", error.message
      assert_equal Duel::Lane::PARALLEL ? [2, 3] : [], done.sort, "the rest, when they start at once"
      assert Thread.report_on_exception, "only its own threads keep quiet"
      assert_equal [2, 4], l.send(:in_parallel, [1, 2]) { |i| i * 2 }
      threads = with_constants(Duel::Lane, PARALLEL: false) { l.send(:in_parallel, [1, 2]) { Thread.current } }

      assert_equal [Thread.current] * 2, threads, "one after another, where they can't start at once"
      l.stop
    end
  end

  # A resource waits as long as the run's timeout.
  def test_resources_wait_as_long_as_the_timeout
    config.resource { |r| r.wait_until { false } }
    with_fake_workers do |workers|
      error = assert_raises(Duel::Failed) { lane(workers, timeout: 0.05) }

      assert_equal "baseline-1's resource: not ready within 0.05s", error.message
    end
  end

  def test_a_lane_that_cant_open_stops_what_it_started
    dirs = SharedList.new
    stopped = SharedList.new
    config.resource do |r|
      dirs << r.dir
      r.at_stop { stopped << r.name }
      {}
    end
    with_fake_workers do |workers|
      workers.fail("candidate-1", "new", error: Duel::Failed.new("candidate-1 worker exited while loading"))
      error = assert_raises(Duel::Failed) { lane(workers) }

      assert_equal "candidate-1 worker exited while loading", error.message
      # (Started at once, the others started too; one after another, not.)
      started = Duel::Lane::PARALLEL ? %w[baseline-1 baseline-2 baseline-3 candidate-2 candidate-3] : %w[baseline-1 baseline-2 baseline-3]

      assert_equal started.map { |label| [label, "stop"] }, workers.log.sort
      assert_equal (started + %w[candidate-1]).sort, stopped.sort
      refute Dir.exist?(dirs.first)
    end
  end

  def test_open_yields_the_lane_and_always_stops_it
    with_fake_workers do |workers|
      assert_raises(RuntimeError) { Duel::Lane.open(config, settings, tmpdir, processes: 1) { raise "boom" } }

      assert_equal [%w[baseline-1 stop], %w[candidate-1 stop]], workers.log
      assert_kind_of Duel::Lane, Duel::Lane.open(config, settings, tmpdir, processes: 1) { |l| l }
      workers.fail("baseline-1", "new")

      assert_raises(Duel::Failed) { Duel::Lane.open(config, settings, tmpdir) { flunk } }
    end
  end

  # Lanes' directories: in TMPDIR if its path is short enough for Unix
  # sockets (the tests' is), else in /tmp.
  def test_short_tmp
    dir = Duel::Lane.tmpdir

    assert dir.start_with?(File.join(Dir.tmpdir, "duel"))
    elsewhere = File.join(tmpdir, "short")
    FileUtils.mkdir_p(elsewhere)
    other = stub(Duel::Lane, :short_tmp, -> { elsewhere }) { Duel::Lane.tmpdir }

    assert_equal elsewhere, File.dirname(other), "where short_tmp says"
    assert_equal ["/tmp/x", "/tmp", "/#{"x" * 39}"], ["/tmp/x", "/var/folders/18/4jzcjnnj3kx8x4nwvbjnydnm0000gn/T", "/#{"x" * 39}"].map { |tmp| Duel::Lane.short_tmp(tmp) }
    assert_equal "/tmp", Duel::Lane.short_tmp("/#{"x" * 40}")
  ensure
    FileUtils.rm_rf(dir)
  end

  # The whole of one comparison: set up (the first candidate, the first
  # baseline, then the rest), sized, warmed, measured, counted, judged,
  # torn down.
  def test_compare
    with_fake_workers do |workers|
      workers.benchmark("b")
      result, = compare(workers)

      assert_equal "b", result.name
      assert_equal 12, result.n, "100 µs an iteration: 12 make 1.2 ms"
      assert_equal({"cpu" => {"median" => 1.0, "limit" => 1.02, "across" => true, "interval" => [1.0, 1.0], "pairs" => 10,
                              "verdict" => "same", "baseline" => 1_200_000, "candidate" => 1_200_000, "unit" => "ns", "plural" => "ns"}}, result.timed)
      assert_equal({"allocations" => {"baseline" => 24, "candidate" => 24, "n" => 12, "tolerance" => 0.5, "allowance" => 0, "unit" => nil, "plural" => nil}}, result.counted)
      assert_nil result.memory
      assert_includes 1..30, result.seconds
      setups = workers.requests("setup").map(&:first)

      assert_equal %w[candidate-1 baseline-1], setups.first(2)
      assert_equal %w[baseline-2 baseline-3 candidate-2 candidate-3], setups.drop(2).sort
      assert_equal %w[baseline-1 baseline-2 baseline-3 candidate-1 candidate-2 candidate-3],
        workers.requests("teardown").map(&:first).sort
      sampled = samples(workers)

      assert_equal [["baseline-1", 1, 3, false], ["candidate-1", 1, 3, false], ["baseline-1", 12, 3, false],
        ["candidate-1", 12, 3, false], ["baseline-1", 12, 3, false], ["candidate-1", 12, 3, false]], sampled.first(6),
        "sized on the first pair, twice in a row enough"
      assert_equal %w[baseline-1 baseline-2 baseline-3 candidate-1 candidate-2 candidate-3].map { |l| [l, 2] },
        sampled.select { |_, _, runs, count| runs == 1 && !count }.map(&:first).tally.sort, "warmed: twice each"
      assert_equal [%w[baseline-1 candidate-1], %w[candidate-2 baseline-2], %w[baseline-3 candidate-3],
        %w[candidate-2 baseline-1], %w[baseline-2 candidate-3]],
        sampled.select { |_, _, runs| runs == 5 }.first(10).map(&:first).each_slice(2).to_a, "each pair of workers in turn"
      assert_equal 2 * (5 + 10), sampled.count { |_, _, runs| runs == 5 }, "5 pairs to warm up, then 10"
      assert_equal [["baseline-1", 12, 1, true], ["candidate-1", 12, 1, true], ["candidate-2", 12, 1, true],
        ["baseline-2", 12, 1, true], ["baseline-3", 12, 1, true], ["candidate-3", 12, 1, true]],
        sampled.select { |*, count| count }
    end
  end

  def test_a_benchmark_the_baseline_cant_set_up_is_skipped
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.fail("baseline-1", "setup", "b", error: Duel::Failed.new("baseline-1: NoMethodError: undefined method 'newer'\n  x.rb:1\n"))
      result, = compare(workers)

      assert_equal "not on the baseline (baseline-1: NoMethodError: undefined method 'newer')", result.skipped
      assert_nil result.seconds
      assert_equal [%w[candidate-1 setup], %w[baseline-1 setup], %w[candidate-1 teardown]],
        workers.log.map { |l, op| [l, op] }.reject { |_, op| op == "stop" }
      assert_empty workers.requests("sample")
    end
  end

  def test_compare_tears_down_however_measuring_ends
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.fail("candidate-2", "sample", "b")

      capture_io { assert_raises(Duel::Failed) { compare(workers) } } # (its thread's report too)
      assert_equal 6, workers.requests("teardown").size
    end
  end

  def test_a_slower_candidate
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.per_iteration["candidate"] = 110_000
      result, = compare(workers)

      assert_equal({"median" => 1.1, "limit" => 1.02, "across" => true, "interval" => [1.1, 1.1], "pairs" => 10, "verdict" => "slower",
                    "baseline" => 1_100_000, "candidate" => 1_210_000, "unit" => "ns", "plural" => "ns"}, result.timed.fetch("cpu"), "and each version's (the median)")
      assert_equal 11, result.n, "sized on the candidate: 110 µs an iteration"
    end
  end

  def test_a_faster_candidate
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.per_iteration["baseline"] = 110_000

      assert_equal "faster", compare(workers).first.timed.fetch("cpu").fetch("verdict")
    end
  end

  # Right at the limit is never settled: pairs are taken until there
  # are MAX_PAIRS, of every metric judged, each pair of workers in turn.
  def test_unsettled_until_the_most_pairs
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::CPU.merge("name" => "other", "limit" => 1.05)]
      workers.benchmark("b") do |side, n, _|
        cpu = n * ((side == "baseline") ? 100_000 : 102_000)
        {"timed" => {"cpu" => cpu, "other" => cpu}, "counted" => {}, "heap" => 0}
      end
      timed = compare(workers, limit: 1.02).first.timed

      assert_equal %w[undecided 60], timed.fetch("cpu").values_at("verdict", "pairs").map(&:to_s)
      assert_equal %w[same 60], timed.fetch("other").values_at("verdict", "pairs").map(&:to_s), "its own limit"
      assert_equal [1.02, 1.05], timed.values.map { |t| t.fetch("limit") }
      pairs = (0...60).map do |i|
        pair = ["baseline-#{(i % 3) + 1}", "candidate-#{((i + (i / 3)) % 3) + 1}"]
        i.even? ? pair : pair.reverse
      end

      assert_equal pairs, samples(workers).select { |_, _, runs| runs == 5 }.drop(10).map(&:first).each_slice(2).to_a
    end
  end

  # Only metrics either version measured above their floors in the
  # warm-up pairs (the median of them) are judged (one that rises from
  # next to nothing too); ratios to nothing are to one.
  def test_what_is_judged
    workers_values = {
      # By baseline worker: warm-up pairs are of baseline-1, 2, 3, 1, 2.
      "low" => {"baseline-1" => 500, "baseline-2" => 500, "baseline-3" => 1500},
      "high" => {"baseline-1" => 500, "baseline-2" => 1500, "baseline-3" => 1500},
      "late" => {"baseline-1" => 1500, "baseline-2" => 500, "baseline-3" => 1500}
    }
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, *%w[low high late rising].map { |name| FakeWorkers::CPU.merge("name" => name, "floor" => 1000) },
        *%w[nothing older newer].map { |name| FakeWorkers::CPU.merge("name" => name, "floor" => 0) }]
      workers.benchmark("b") do |side, n, label|
        timed = {"cpu" => n * 100_000, "nothing" => (side == "baseline") ? 0 : 1, "rising" => (side == "baseline") ? 0 : 1000}
        workers_values.each { |metric, values| timed[metric] = (side == "baseline") ? values.fetch(label) : 999 }
        timed[(side == "baseline") ? "older" : "newer"] = 5000
        {"timed" => timed, "counted" => {}, "heap" => 0}
      end
      timed = compare(workers).first.timed

      assert_equal %w[cpu high late nothing rising], timed.keys.sort, "not what either version doesn't measure"
      assert_equal "slower", timed.fetch("rising").fetch("verdict"), "1000 over at least 1"
      assert_equal [1.0, "same"], timed.fetch("nothing").values_at("median", "verdict"), "1 over at least 1"
    end
  end

  def test_sized_by_the_largest_timed_metric_in_its_own_units
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::CPU.merge("name" => "steady", "unit_ns" => 1000)]
      workers.benchmark("b") { |_, n, _| {"timed" => {"cpu" => n * 100_000, "steady" => 2000}, "counted" => {}, "heap" => 0} }

      assert_equal 1, compare(workers).first.n, "2000 units of 1000 ns"
    end
  end

  # What metrics said of the samples (Metric#details), timed and counted.
  def test_details_noted
    with_fake_workers do |workers|
      workers.benchmark("b", only: "timing") do |side, n, _| # (so no counting samples)
        {"timed" => {"cpu" => n * 100_000}, "counted" => {}, "heap" => 0, "details" => {"cpu" => "#{side} timed"}}
      end
      workers.benchmark("c", only: "count") do |side, n, _|
        {"timed" => {"cpu" => n}, "counted" => {"allocations" => n}, "heap" => 0, "details" => {"allocations" => "#{side} counted"}}
      end
      l = lane(workers)

      assert_equal({"cpu" => {"baseline" => "baseline timed", "candidate" => "candidate timed"}}, l.compare("b").details)
      assert_equal({"allocations" => {"baseline" => "baseline counted", "candidate" => "candidate counted"}}, l.compare("c").details)
      l.stop
    end
  end

  # A count's details are its sample's: the one with the fewest (each
  # measure's own).
  def test_a_counts_details_are_its_samples
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::ALLOCATIONS.merge("name" => "rising", "unit" => "object", "plural" => "objects"),
        FakeWorkers::ALLOCATIONS.merge("name" => "falling")]
      counts = Hash.new(0)
      lock = Mutex.new
      workers.benchmark("c", only: "count") do |side, n, _|
        count = lock.synchronize { counts[side] += 1 } # (the fewest rising are the first, falling the latest)
        {"timed" => {"cpu" => n}, "counted" => {"rising" => count, "falling" => 100 - count}, "heap" => 0,
         "details" => {"rising" => "#{side} #{count}", "falling" => "#{side} #{100 - count}"}}
      end
      l = lane(workers)
      result = l.compare("c")

      %w[rising falling].each do |metric|
        assert_equal(%w[baseline candidate].to_h { |side| [side, "#{side} #{result.counted.fetch(metric).fetch(side)}"] },
          result.details.fetch(metric))
      end
      assert_equal %w[object objects], result.counted.fetch("rising").values_at("unit", "plural")
      l.stop
    end
  end

  # A floor that's a share of CPU time: judged where it's that much of
  # the sample's CPU time on either version; and whether it's judged
  # across the board, in the result.
  def test_a_floor_of_cpu_time
    with_fake_workers do |workers|
      share = FakeWorkers::CPU.merge("floor" => 0, "cpu_floor" => 0.1, "unit_ns" => 1000, "across" => false)
      workers.metrics = [FakeWorkers::CPU, share.merge("name" => "under"), share.merge("name" => "over"),
        share.merge("name" => "exactly"), share.merge("name" => "rising")]
      workers.benchmark("b") do |side, n, _|
        cpu = n * 100_000 # 10% of it: n * 10 units of 1000 ns
        {"timed" => {"cpu" => cpu, "under" => n * 9, "over" => n * 11, "exactly" => n * 10, "rising" => (side == "baseline") ? 0 : n * 20},
         "counted" => {}, "heap" => 0}
      end
      timed = compare(workers).first.timed

      assert_equal %w[cpu exactly over rising], timed.keys.sort
      assert_equal [true, false], [timed.fetch("cpu").fetch("across"), timed.fetch("over").fetch("across")]
    end
  end

  # Work that gets faster once it's sized (a JIT gets to it) is sized
  # again, rather than left below CPU time's floor, unjudged.
  def test_sized_again_when_cpu_falls_below_its_floor
    with_fake_workers do |workers|
      # (CPU time last, as in a worker: what's first is judged anyway.)
      workers.metrics = [FakeWorkers::CPU.merge("name" => "other", "floor" => 0, "sizes_samples" => false), FakeWorkers::CPU]
      samples = 0
      lock = Mutex.new
      workers.benchmark("b") do |_, n, _|
        fast = lock.synchronize { (samples += 1) > 20 }
        {"timed" => {"other" => 1, "cpu" => n * (fast ? 20_000 : 100_000)}, "counted" => {}, "heap" => 0}
      end
      result = compare(workers).first

      assert_equal 60, result.n, "20 µs an iteration: 60 make 1.2 ms"
      assert_includes result.timed.keys, "cpu"
    end
  end

  # A timed metric that doesn't size samples is left out of sizing them.
  def test_a_metric_that_doesnt_size_samples
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::CPU.merge("name" => "noisy", "unit_ns" => 1000, "sizes_samples" => false),
        FakeWorkers::CPU.merge("name" => "absent", "unit_ns" => 1000)]
      workers.benchmark("b") { |_, n, _| {"timed" => {"cpu" => n * 100_000, "noisy" => 2000}, "counted" => {}, "heap" => 0} }

      assert_equal 12, compare(workers).first.n, "by CPU time alone (one that sizes them but isn't measured, neither)"
    end
  end

  def test_threads_of_its_own_need_ten_times_the_cpu
    with_fake_workers do |workers|
      workers.benchmark("b", only: "timing")
      workers.per_iteration.transform_values! { 95_000 }

      assert_equal 200, compare(workers).first.n, "at most a hundredfold at a time: 100 make 9.5 ms"
    end
  end

  def test_ten_times_exactly
    with_fake_workers do |workers|
      workers.benchmark("b", only: "timing")
      workers.per_iteration.transform_values! { 105_000 }

      assert_equal 100, compare(workers).first.n
    end
  end

  def test_exactly_enough
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.per_iteration.transform_values! { 1_000_000 }

      assert_equal 1, compare(workers).first.n
    end
  end

  def test_the_clock
    with_fake_workers do |workers|
      workers.benchmark("b")
      l = Duel::Lane.new(config, settings, tmpdir)
      result = l.compare("b")
      l.stop

      assert_kind_of Float, result.seconds
      assert_includes 0.0..5.0, result.seconds
    end
  end

  def test_enough_at_once
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.per_iteration.transform_values! { 2_000_000 }

      assert_equal 1, compare(workers).first.n
      assert_equal [1, 1], samples(workers).select { |_, _, runs| runs == 3 }.map { |_, n| n }.each_slice(2).map(&:first),
        "twice in a row"
    end
  end

  # Sizes grow at least twofold a step (and are sized again after
  # warming up, which may make code faster).
  def test_sized_again_after_warming_up
    with_fake_workers do |workers|
      looks = Hash.new(0)
      lock = Mutex.new # warm-up samples are taken at once (in parallel, on JRuby)
      workers.benchmark("b") do |_, n, label|
        look = lock.synchronize { looks[label] += 1 }
        {"timed" => {"cpu" => n * ((look > 3) ? 80_000 : 100_000)}, "counted" => {}, "heap" => 0}
      end

      assert_equal 12, compare(workers, warm: 0.0).first.n
      lock.synchronize { looks.clear }

      assert_equal 24, compare(workers, warm: 2.5).first.n, "960 µs short of 1 ms: twice as many"
    end
  end

  # Warming up takes samples on every worker, at once, until the warm-up
  # time is over (here, on a clock that ticks once a look: two looks).
  def test_warming_up_for_a_while
    with_fake_workers do |workers|
      workers.benchmark("b")
      compare(workers, warm: 2.5)

      assert_equal 6 * 2 + 2, samples(workers).count { |_, _, runs, count| runs == 1 && !count }
    end
  end

  # What allocates a lot, while the garbage collector is held off, is
  # held to HEAP_CAP a run.
  def test_capped_by_what_it_allocates
    with_fake_workers do |workers|
      workers.benchmark("b") { |_, n, _| {"timed" => {"cpu" => n * 100_000}, "counted" => {}, "heap" => n * (32 << 20)} }

      assert_equal 2, compare(workers).first.n
      assert_equal [1, 2], samples(workers).select { |label, _, runs| runs == 3 && label == "candidate-1" }.map { |_, n| n }.uniq,
        "never more (sized again when its CPU time falls below the floor: in vain)"
      assert_equal 2 * Duel::Lane::WARMUP, samples(workers).count { |_, _, runs| runs == 5 }, "its floors taken once, not again in vain"
    end
  end

  def test_capped_again_after_warming_up
    with_fake_workers do |workers|
      looks = Hash.new(0)
      workers.benchmark("b") do |_, n, label|
        looks[label] += 1
        {"timed" => {"cpu" => n * 100_000}, "counted" => {}, "heap" => n * ((looks.fetch(label) > 3) ? (32 << 20) : 0)}
      end

      assert_equal 2, compare(workers, warm: 2.5).first.n
    end
  end

  def test_most_iterations
    lane = Duel::Lane.allocate

    assert_equal Float::INFINITY, lane.send(:most_iterations, 10, 0), "allocated nothing"
    assert_equal 64, lane.send(:most_iterations, 10, 10 << 20), "1 MB each"
    assert_equal 1, lane.send(:most_iterations, 1, 1 << 30), "at least one"
  end

  # Counts are each version's least of COUNTS samples, of what both
  # versions report.
  def test_counts
    counts = {"baseline-1" => 5, "baseline-2" => 3, "baseline-3" => 4, "candidate-1" => 9, "candidate-2" => nil, "candidate-3" => 7}
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::ALLOCATIONS.merge("name" => "older", "tolerance" => 0),
        FakeWorkers::ALLOCATIONS.merge("name" => "dropped"), FakeWorkers::ALLOCATIONS.merge("name" => "some")]
      workers.benchmark("b") do |side, n, label|
        counted = {"some" => counts.fetch(label)}.compact
        counted[(side == "baseline") ? "dropped" : "older"] = 1
        {"timed" => {"cpu" => n * 100_000}, "counted" => counted, "heap" => 0}
      end

      assert_equal({"some" => {"baseline" => 3, "candidate" => 7, "n" => 12, "tolerance" => 0.5, "allowance" => 0, "unit" => nil, "plural" => nil}}, compare(workers).first.counted)
    end
  end

  def test_counts_only
    with_fake_workers do |workers|
      workers.benchmark("b", only: "count")
      result, = compare(workers)

      assert_equal 4, result.n, "Duel::COUNTS_ONLY"
      assert_empty result.timed
      assert_equal({"allocations" => {"baseline" => 8, "candidate" => 8, "n" => 4, "tolerance" => 0.5, "allowance" => 0, "unit" => nil, "plural" => nil}}, result.counted)
      assert_equal [4], samples(workers).map { |_, n| n }.uniq
    end
  end

  def test_threads_of_its_own_arent_counted
    with_fake_workers do |workers|
      workers.benchmark("b", only: "timing")
      result, = compare(workers)

      assert_empty result.counted
      assert_empty(samples(workers).select { |*, count| count })
    end
  end

  # Peak memory: each version's least in MEMORY_SAMPLES fresh workers,
  # turn about, each stopped (and its resources) after.
  def test_peak_memory
    stopped = SharedList.new
    config.resource { |r| r.at_stop { stopped << r.name } && {} }
    config.resource { |r| r.at_stop { stopped << "#{r.name}'s other" } && {} }
    with_fake_workers do |workers|
      workers.benchmark("b", peak_memory: true)
      workers.peaks("baseline", 30, 10, 20)
      workers.peaks("candidate", 5, 6, 7)
      l = lane(workers)
      result = l.compare("b")

      assert_equal({"baseline" => 10, "candidate" => 5}, result.memory)
      assert_equal [["baseline-7", 12], ["candidate-7", 12], ["candidate-7", 12], ["baseline-7", 12], ["baseline-7", 12],
        ["candidate-7", 12]], workers.requests("memory").map { |label, _, args| [label, args.fetch(:n)] }
      assert_equal [{trial: false}] * 6, workers.requests("setup").filter_map { |label, _, args| args if label.end_with?("-7") },
        "no trial first: the allocator would keep what it freed"
      assert_equal 6, workers.log.count { |label, op| label.end_with?("-7") && op == "stop" }
      fresh = %w[baseline-7 candidate-7 candidate-7 baseline-7 baseline-7 candidate-7]

      assert_equal fresh.flat_map { |label| ["#{label}'s other", label] }, stopped, "in reverse"
      assert_equal %w[setup memory stop], workers.log.filter_map { |label, op| op if label == "candidate-7" }.first(3)
      stopped.clear
      l.stop

      labels = %w[baseline-1 baseline-2 baseline-3 candidate-1 candidate-2 candidate-3]

      assert_equal labels.flat_map { |label| [label, "#{label}'s other"] }.sort, stopped.sort
      assert(labels.all? { |label| stopped.index("#{label}'s other") < stopped.index(label) }, "each worker's last first")
    end
  end

  def test_no_peak_memory_without_a_way_to_tell
    with_fake_workers do |workers|
      workers.benchmark("b", peak_memory: true)
      workers.memory = false

      assert_nil compare(workers).first.memory
      assert_empty workers.requests("memory")
    end
  end

  def test_profile
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.profile("baseline", {"samples" => 1})
      workers.profile("candidate", {"samples" => 2})
      l = lane(workers)
      profiles = l.profile("b", 3)

      assert_equal({"baseline" => {"samples" => 1}, "candidate" => {"samples" => 2}}, profiles)
      assert_equal [["baseline-1", "setup", "b", {}], ["candidate-1", "setup", "b", {}],
        ["baseline-1", "profile", "b", {n: 300, runs: 5}], ["candidate-1", "profile", "b", {n: 300, runs: 5}],
        ["baseline-1", "teardown", "b", {}], ["candidate-1", "teardown", "b", {}]], workers.log
      l.stop
    end
  end

  def test_profile_tears_down_however_it_ends
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.profile("baseline", {"samples" => 1})
      workers.fail("candidate-1", "profile")
      l = lane(workers)

      assert_raises(Duel::Failed) { l.profile("b", 1) }
      assert_equal %w[baseline-1 candidate-1], workers.requests("teardown").map(&:first)
      l.stop
    end
  end

  def test_no_profile_without_stackprof
    with_fake_workers do |workers|
      workers.profiler = false
      l = lane(workers)

      assert_nil l.profile("b", 1)
      assert_empty workers.log
      l.stop
    end
  end
end
