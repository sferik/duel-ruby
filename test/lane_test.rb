# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# A lane's workings, with its worker processes faked (see FakeWorkers):
# every measure is exact, so every decision is too.
class LaneTest < DuelTest
  cover "Duel::Lane*"

  def config = @config ||= Duel::Config.new(File.join(tmpdir, "candidate"))

  # Each version, unprepared (see Duel::Side), the baseline at +base+.
  # (On CRuby, whatever the tests run on: see #test_counts_on_jruby.)
  def sides(run, base = File.join(tmpdir, "base")) = Duel::Side.unprepared(config, run, base).each_value { |side| side.engine = "ruby" }

  # A lane of fake workers, whose clock (for warming up and timing) ticks
  # once a look.
  def lane(workers, processes: nil, **overrides)
    options = processes ? {processes: processes} : {}
    run = settings(**overrides)
    Duel::Lane.new(config, run, sides(run), **options).tap do |lane|
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
    config.prepare(:worker) do |r|
      given << [r.dir, r.name]
      r.at_stop { stopped << [:first, r.name] }
      {"A" => r.name, "B" => "1"}
    end
    config.prepare(:worker) do |r|
      given << [r.dir, r.name]
      r.at_stop { stopped << [:second, r.name] }
      {"B" => "1", "C" => "2"} # (B as the other has it: no clash)
    end
    with_fake_workers do |workers|
      workers.profiler = :yes
      workers.benchmark("b")
      l = lane(workers, processes: 2, config_path: "/c/.duel.rb", timeout: 7.0)
      dir = File.dirname(given.first.first)

      labels = %w[base-1 base-2 head-1 head-2]

      assert_equal labels, workers.made.map(&:first).sort, "started at once"
      assert_equal labels.flat_map { |label| ["#{label}-1", "#{label}-2"] }, given.map { |resource_dir, _| File.basename(resource_dir) }.sort,
        "a directory of each resource's own"
      assert(given.all? { |resource_dir, _| File.dirname(resource_dir) == dir })
      assert_equal ["base-1", File.join(tmpdir, "base"), File.join(tmpdir, "candidate"), dir,
        {config_path: "/c/.duel.rb", env: {"A" => "base-1", "B" => "1", "C" => "2"}, timeout: 7.0, ruby: RbConfig.ruby,
         engine: "ruby"}], workers.made.assoc("base-1")
      assert_equal File.join(tmpdir, "candidate"), workers.made.assoc("head-2")[1]
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
      run = settings(candidate_dir: File.join(tmpdir, "x", "..", "other"), processes: 1)
      Duel::Lane.new(config, run, sides(run, File.join(tmpdir, "x", "..", "base"))).stop

      # (By label: the workers start at once, in any order.)
      assert_equal [File.join(tmpdir, "base"), File.join(tmpdir, "other")], workers.made.assoc("base-1")[1, 2]
      assert_equal File.join(tmpdir, "other"), workers.made.assoc("head-1")[1]
    end
  end

  def test_processes_by_default_from_the_settings
    with_fake_workers do |workers|
      Duel::Lane.new(config, settings(processes: 1), sides(settings, tmpdir)).stop

      assert_equal %w[base-1 head-1], workers.made.map(&:first).sort, "(in any order: at once)"
    end
  end

  # Two resources that set a variable differently can't both be right.
  def test_resources_that_clash
    config.prepare(:worker) { |_| {"DATABASE_URL" => "postgres:///a"} }
    config.prepare(:worker) { |_| {"DATABASE_URL" => "mysql2:///b"} }
    with_fake_workers do |workers|
      error = assert_raises(Duel::Failed) { lane(workers) }

      assert_equal "base-1: two prepare blocks set DATABASE_URL (postgres:///a, mysql2:///b)", error.message
    end
  end

  # Each resource gets the tree of the version its worker runs, and the
  # candidate's tmp/duel/cache for what it builds once.
  def test_resources_get_their_versions_root
    roots = SharedList.new
    cached = SharedList.new
    config.prepare(:worker) do |r|
      roots << [r.name, r.root]
      cached << r.cached("t") { |_| nil }
      {}
    end
    with_fake_workers do |workers|
      lane(workers, processes: 1).stop

      assert_equal [["base-1", File.join(tmpdir, "base")], ["head-1", File.join(tmpdir, "candidate")]], roots.sort
      assert_equal [File.join(config.state, "cache", "t")] * 2, cached
    end
  end

  # Workers start at once: one that fails doesn't stop the rest starting,
  # and every one is done before it fails.
  def test_in_parallel
    with_fake_workers do |workers|
      l = lane(workers, processes: 1)
      done = SharedList.new
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
    config.prepare(:worker) { |r| r.wait_until { false } }
    with_fake_workers do |workers|
      error = assert_raises(Duel::Failed) { lane(workers, timeout: 0.05) }

      assert_equal "base-1's resource: not ready within 0.05s", error.message
    end
  end

  def test_a_lane_that_cant_open_stops_what_it_started
    dirs = SharedList.new
    stopped = SharedList.new
    config.prepare(:worker) do |r|
      dirs << r.dir
      r.at_stop { stopped << r.name }
      {}
    end
    with_fake_workers do |workers|
      workers.fail("head-1", "new", error: Duel::Failed.new("head-1 worker exited while loading"))
      error = assert_raises(Duel::Failed) { lane(workers) }

      assert_equal "head-1 worker exited while loading", error.message
      # (Started at once, the others started too, but one after another, not.)
      started = Duel::Lane::PARALLEL ? %w[base-1 base-2 base-3 head-2 head-3] : %w[base-1 base-2 base-3]

      assert_equal started.map { |label| [label, "stop"] }, workers.log.sort
      assert_equal (started + %w[head-1]).sort, stopped.sort
      refute Dir.exist?(dirs.first)
    end
  end

  def test_open_yields_the_lane_and_always_stops_it
    with_fake_workers do |workers|
      assert_raises(RuntimeError) { Duel::Lane.open(config, settings, sides(settings), processes: 1) { raise "boom" } }

      assert_equal [%w[base-1 stop], %w[head-1 stop]], workers.log.sort, "(in any order: at once)"
      assert_kind_of Duel::Lane, Duel::Lane.open(config, settings, sides(settings), processes: 1) { |l| l }
      workers.fail("base-1", "new")

      assert_raises(Duel::Failed) { Duel::Lane.open(config, settings, sides(settings)) { flunk } }
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
    assert_equal ["/tmp/x", "/tmp", "/#{"x" * 39}"],
      ["/tmp/x", "/var/folders/18/4jzcjnnj3kx8x4nwvbjnydnm0000gn/T", "/#{"x" * 39}"].map { |tmp| Duel::Lane.short_tmp(tmp, windows: false) }
    assert_equal "/tmp", Duel::Lane.short_tmp("/#{"x" * 40}", windows: false)
    long = "C:/Users/#{"x" * 40}/AppData/Local/Temp"

    assert_equal [long, "/tmp"], [true, false].map { |windows| Duel::Lane.short_tmp(long, windows: windows) }, "Windows has no /tmp"
    assert_equal long, with_constants(Duel::Native, WINDOWS: true) { Duel::Lane.short_tmp(long) }, "by default, on Windows"
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

      assert_equal %w[head-1 base-1], setups.first(2)
      assert_equal %w[base-2 base-3 head-2 head-3], setups.drop(2).sort
      assert_equal %w[base-1 base-2 base-3 head-1 head-2 head-3],
        workers.requests("teardown").map(&:first).sort
      sampled = samples(workers)

      assert_equal [["base-1", 1, 3, false], ["head-1", 1, 3, false], ["base-1", 12, 3, false],
        ["head-1", 12, 3, false], ["base-1", 12, 3, false], ["head-1", 12, 3, false]], sampled.first(6),
        "sized on the first pair, twice in a row enough"
      assert_equal %w[base-1 base-2 base-3 head-1 head-2 head-3].map { |l| [l, 2] },
        sampled.select { |_, _, runs, count| runs == 1 && !count }.map(&:first).tally.sort, "warmed: twice each"
      assert_equal [%w[base-1 head-1], %w[head-2 base-2], %w[base-3 head-3],
        %w[head-2 base-1], %w[base-2 head-3]],
        sampled.select { |_, _, runs| runs == 5 }.first(10).map(&:first).each_slice(2).to_a, "each pair of workers in turn"
      assert_equal 2 * (5 + 10), sampled.count { |_, _, runs| runs == 5 }, "5 pairs to warm up, then 10"
      assert_equal [["base-1", 12, 1, true], ["head-1", 12, 1, true], ["head-2", 12, 1, true],
        ["base-2", 12, 1, true], ["base-3", 12, 1, true], ["head-3", 12, 1, true]],
        sampled.select { |*, count| count }
    end
  end

  def test_a_benchmark_the_baseline_cant_set_up_is_skipped
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.fail("base-1", "setup", "b", error: Duel::Failed.new("base-1: NoMethodError: undefined method 'newer'\n  x.rb:1\n"))
      result, = compare(workers)

      assert_equal "not on the baseline (base-1: NoMethodError: undefined method 'newer')", result.skipped
      assert_nil result.seconds
      assert_equal [%w[head-1 setup], %w[base-1 setup], %w[head-1 teardown]],
        workers.log.map { |l, op| [l, op] }.reject { |_, op| op == "stop" }
      assert_empty workers.requests("sample")
    end
  end

  def test_compare_tears_down_however_measuring_ends
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.fail("head-2", "sample", "b")

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
        pair = ["base-#{(i % 3) + 1}", "head-#{((i + (i / 3)) % 3) + 1}"]
        i.even? ? pair : pair.reverse
      end

      assert_equal pairs, samples(workers).select { |_, _, runs| runs == 5 }.drop(10).map(&:first).each_slice(2).to_a
    end
  end

  # With workers enough for it (5 of each, at 99%), the interval is over
  # them: rounds of a sample from every worker, the baseline's in order,
  # each with the candidate's in turn, decided from the second round, and
  # each worker's median kept for across the board.
  def test_judged_by_process
    with_fake_workers do |workers|
      workers.benchmark("b")
      result, l = compare(workers, processes: 5)
      cpu = result.timed.fetch("cpu")

      assert_equal({"median" => 1.0, "limit" => 1.02, "across" => true, "interval" => [1.0, 1.0], "pairs" => 20, "processes" => 5,
                    "verdict" => "same", "baseline" => 1_200_000.0, "candidate" => 1_200_000.0, "unit" => "ns", "plural" => "ns"}, cpu)
      rounds = (0...4).flat_map do |round|
        (0...5).map do |i|
          pair = ["base-#{i + 1}", "head-#{((i + round) % 5) + 1}"]
          (i + round).even? ? pair : pair.reverse
        end
      end

      assert_equal rounds, samples(workers).select { |_, _, runs| runs == 5 }.drop(10).map(&:first).each_slice(2).to_a
      assert(samples(workers).select { |_, _, runs| runs == 5 }.none? { |*, count| count }, "timed, not counted")
      assert_equal({"cpu" => {"lane" => l.instance_variable_get(:@id), "baseline" => [1_200_000.0] * 5, "candidate" => [1_200_000.0] * 5}},
        result.processes)
    end
  end

  def test_a_slower_candidate_by_process
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.per_iteration["candidate"] = 110_000
      cpu = compare(workers, processes: 5).first.timed.fetch("cpu")

      assert_equal ["slower", 20, [1.1, 1.1]], cpu.values_at("verdict", "pairs", "interval")
      assert_in_delta 1.1, cpu.fetch("median"), 1e-12
    end
  end

  # Each worker's luck (as where things landed in its memory gives it)
  # lasts its whole life, so the interval is as wide as the workers make
  # it: every pair says the candidate is a little faster or slower, and
  # an interval over pairs would call it, but the workers don't settle
  # it, so it takes every round (as many as make the most pairs).
  def test_a_workers_luck_widens_the_interval
    luck = {"base-1" => 1.0, "base-2" => 1.03, "base-3" => 0.98, "base-4" => 1.02, "base-5" => 0.99,
            "head-1" => 1.01, "head-2" => 0.97, "head-3" => 1.04, "head-4" => 1.0, "head-5" => 0.98}
    with_fake_workers do |workers|
      workers.benchmark("b") do |_, n, label|
        {"timed" => {"cpu" => (n * 100_000 * luck.fetch(label)).round}, "counted" => {}, "heap" => 0}
      end
      result, = compare(workers, processes: 5)
      cpu = result.timed.fetch("cpu")

      assert_equal ["undecided", 120], cpu.values_at("verdict", "pairs")
      low, high = cpu.fetch("interval")

      assert_operator low, :<, 0.95
      assert_operator high, :>, 1.05
    end
  end

  # Each round's samples count for each metric's workers: a worker's
  # median is of its own samples, those it took as the baseline's
  # worker, or the candidate's, in every pair it was in.
  def test_each_workers_median_is_its_own
    with_fake_workers do |workers|
      workers.benchmark("b") do |_, n, label|
        {"timed" => {"cpu" => n * 100_000 * Integer(label[/\d+/])}, "counted" => {}, "heap" => 0}
      end
      result, = compare(workers, processes: 5, limit: 100.0)
      each = result.processes.fetch("cpu")

      assert_equal [1, 2, 3, 4, 5], each.fetch("baseline").map { |median| median / each.fetch("baseline").first }
      assert_equal each.fetch("baseline"), each.fetch("candidate")
    end
  end

  # Judged by process, as over pairs: a ratio to nothing is one to 1,
  # what metrics said of the last pair is kept, and a metric's across is
  # its own.
  def test_by_process_as_over_pairs
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::CPU.merge("name" => "nothing", "floor" => 0, "across" => false)]
      workers.benchmark("b") do |side, n, label|
        {"timed" => {"cpu" => n * 100_000, "nothing" => (side == "baseline") ? 0 : 1}, "counted" => {}, "heap" => 0,
         "details" => {"cpu" => "said by #{label}"}}
      end
      result, = compare(workers, processes: 5)
      nothing = result.timed.fetch("nothing")

      assert_equal [1.0, [1.0, 1.0], "same", false], nothing.values_at("median", "interval", "verdict", "across")
      assert_equal({"baseline" => "said by base-5", "candidate" => "said by head-3"}, result.details.fetch("cpu"))
    end
  end

  # Too few workers (4 of each, at 99%), or a process benchmark (each of
  # whose samples is a fresh process already), is judged over pairs.
  def test_by_process_when_enough
    assert Duel::Lane.by_process?(5, 0.99)
    refute Duel::Lane.by_process?(4, 0.99)
    assert Duel::Lane.by_process?(4, 0.95)
    with_fake_workers do |workers|
      workers.benchmark("b")

      refute compare(workers, processes: 4).first.timed.fetch("cpu").key?("processes")
    end
  end

  # As many rounds as make the most pairs, and two at least.
  def test_rounds
    with_fake_workers do |workers|
      l = lane(workers, processes: 1)

      assert_equal [24, 20, 15, 4, 4], [5, 6, 8, 30, 31].map { |k| l.send(:rounds, k) }
    ensure
      l&.stop
    end
  end

  # Each lane its own number, from one more than the last.
  def test_each_lane_has_a_number_of_its_own
    with_fake_workers do |workers|
      first = lane(workers, processes: 1)
      second = lane(workers, processes: 1)

      assert_equal first.instance_variable_get(:@id) + 1, second.instance_variable_get(:@id)
    ensure
      first&.stop
      second&.stop
    end
  end

  # Only metrics either version measured above their floors in the
  # warm-up pairs (the median of them) are judged (one that rises from
  # next to nothing too), and ratios to nothing are to one.
  def test_what_is_judged
    workers_values = {
      # By baseline worker: warm-up pairs are of base-1, 2, 3, 1, 2.
      "low" => {"base-1" => 500, "base-2" => 500, "base-3" => 1500},
      "high" => {"base-1" => 500, "base-2" => 1500, "base-3" => 1500},
      "late" => {"base-1" => 1500, "base-2" => 500, "base-3" => 1500}
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
  # the sample's CPU time on either version, and whether it's judged
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
      l = Duel::Lane.new(config, settings, sides(settings))
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

  # Without --warm, a lane where a worker has YJIT on (an app turned it
  # on, say, or only the candidate did, upgraded) warms up for as long as
  # YJIT_WARM says at most, and else as JIT_WARM does (nothing on CRuby, 5
  # seconds on JRuby). --warm says otherwise.
  def test_warming_up_with_yjit
    with_fake_workers do |workers|
      workers.benchmark("b")
      warm = lambda do |seconds|
        l = lane(workers, processes: 1, warm: seconds)
        l.instance_variable_get(:@warm)
      ensure
        l&.stop
      end

      assert_equal Duel::JIT_WARM, warm.call(nil)
      workers.yjit = true

      assert_equal Duel::YJIT_WARM, warm.call(nil)
      workers.yjit = "candidate"

      assert_equal Duel::YJIT_WARM, warm.call(nil), "YJIT on in one version's workers"
      workers.yjit = true

      assert_in_delta 0.0, warm.call(0.0)
    end
    assert_in_delta 10.0, Duel::YJIT_WARM
  end

  # Without --warm, each worker warms up until the median of its samples
  # over half a second is no faster, by 1%, than over the half second
  # before: its samples, of +cpu+ in turn, until +cap+ seconds from now,
  # on a clock that ticks +tick+ seconds a look (a second: a sample a
  # half second).
  def steady(cpu, cap: 100, tick: 1.0)
    with_fake_workers do |workers|
      times = cpu.each
      workers.benchmark("b") { |*| {"timed" => {"cpu" => times.next}, "counted" => {}, "heap" => 0} }
      l = lane(workers, processes: 1)
      clock = 1000.0
      l.define_singleton_method(:monotonic) { clock += tick }
      worker = l.instance_variable_get(:@bases).first
      l.send(:steady, worker, "b", 3, l.send(:monotonic) + cap)
      l.stop

      assert_equal [3], samples(workers).map { |_, n, _| n }.uniq, "of its iterations"
      samples(workers).size
    end
  end

  def test_warming_up_until_steady
    assert_equal 4, steady([100] * 4), "three half seconds no faster"
    assert_equal 6, steady([100, 90, 80, 80, 80, 80]), "each faster by 1% or more starts them again"
    assert_equal 5, steady([100, 99, 99, 99, 99]), "1% exactly"
    assert_equal 4, steady([100, 101, 99.5, 99.5]), "slower, or faster by less than 1%, is no gain"
    assert_equal 6, steady([100, 120, 80, 80, 80, 80]), "one slow half second doesn't end it"
    assert_equal 8, steady([100, 99.5, 99.0, 98.5, 98.0, 97.5, 97.0, 96.5, 96.0], cap: 15),
      "creeping faster by less than 1% a half second isn't steady"
    assert_equal 3, steady([100, 90, 80, 70, 60, 50], cap: 5), "for at most the warm-up's seconds"
  end

  # Each half second's median, of every sample in it (three, on a clock
  # that ticks a fifth of a second a look), not its first, last, least
  # or most.
  def test_warming_up_by_each_half_seconds_median
    steady_after = [100] * 6

    assert_equal 12, steady([120, 100, 80, 70, 100, 130, *steady_after], tick: 0.2)
    assert_equal 12, steady([120, 100, 80, 130, 100, 70, *steady_after], tick: 0.2)
    assert_equal 12, steady([90, 100, 110, 80, 100, 105, *steady_after], tick: 0.2)
    assert_equal 1, steady([100, 90, 80], tick: 0.2, cap: 0.3), "ending where the warm-up's time does"
  end

  # Without --warm, every worker warms up until it's steady, or its time
  # is up: with none, a sample each, after the first two (where --warm
  # 0 takes none).
  def test_warming_up_without_warm
    with_fake_workers do |workers|
      workers.benchmark("b")
      l = lane(workers, warm: nil)
      l.instance_variable_set(:@warm, 0.0)
      l.compare("b")
      l.stop

      assert_equal 6 * 3, samples(workers).count { |_, _, runs, count| runs == 1 && !count }
    end
  end

  # What allocates a lot, while the garbage collector is held off, is
  # held to HEAP_CAP a run.
  def test_capped_by_what_it_allocates
    with_fake_workers do |workers|
      workers.benchmark("b") { |_, n, _| {"timed" => {"cpu" => n * 100_000}, "counted" => {}, "heap" => n * (32 << 20)} }

      assert_equal 2, compare(workers).first.n
      assert_equal [1, 2], samples(workers).select { |label, _, runs| runs == 3 && label == "head-1" }.map { |_, n| n }.uniq,
        "never more (sized again when its CPU time falls below the floor: in vain)"
      assert_equal 2 * Duel::Lane::WARMUP, samples(workers).count { |_, _, runs| runs == 5 }, "its floors taken once, not again in vain"
    end
  end

  def test_capped_again_after_warming_up
    with_fake_workers do |workers|
      looks = Hash.new(0)
      lock = Mutex.new # (workers answer at once: JRuby's Hash isn't safe for that)
      workers.benchmark("b") do |_, n, label|
        look = lock.synchronize { looks[label] += 1 }
        {"timed" => {"cpu" => n * 100_000}, "counted" => {}, "heap" => n * ((look > 3) ? (32 << 20) : 0)}
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
    counts = {"base-1" => 5, "base-2" => 3, "base-3" => 4, "head-1" => 9, "head-2" => nil, "head-3" => 7}
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

  # Where a version is on JRuby, a count is the fewest of JRUBY_COUNTS
  # samples (its bytes allocated take one of two values), not COUNTS.
  def test_counts_on_jruby
    with_fake_workers do |workers|
      workers.benchmark("b")
      run = settings
      on = sides(run)
      on.fetch("candidate").engine = "jruby"
      l = Duel::Lane.new(config, run, on)
      l.compare("b")
      l.stop

      assert_equal 2 * 10, samples(workers).count { |*, count| count }
    end
    assert_equal [3, 10], [Duel::Lane::COUNTS, Duel::Lane::JRUBY_COUNTS]
  end

  # With workers enough for an interval over them, each worker's count is
  # its fewest in three rounds of a sample from every worker (each
  # baseline worker with a candidate worker in turn), each version's is
  # the median of its workers', and what's judged is how much more the
  # candidate's are at least: none, where one worker's luck (a JVM's JIT
  # doing away with an allocation) is on one side.
  def count_by_process(counts)
    with_fake_workers do |workers|
      # (Each version's own first: neither ends the rest.)
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::ALLOCATIONS.merge("name" => "newer"), FakeWorkers::ALLOCATIONS.merge("name" => "older"),
        FakeWorkers::ALLOCATIONS.merge("unit" => "byte", "plural" => "bytes")]
      taken = Hash.new(0)
      workers.benchmark("b") do |_, n, label|
        value = counts.fetch(label).fetch(taken[label] % counts.fetch(label).size)
        taken[label] += 1
        counted = {"allocations" => value}.compact
        counted[label.start_with?("head") ? "newer" : "older"] = 1 # (one version's only)
        {"timed" => {"cpu" => n * 100_000}, "counted" => counted, "heap" => 0, "details" => {"allocations" => "by #{label}"}}
      end
      result, = compare(workers, processes: 5)
      counting = samples(workers).select { |*, count| count }

      assert_equal [[12, 1]], counting.map { |_, n, runs| [n, runs] }.uniq, "a run each"
      assert_equal %w[allocations], result.counted.keys, "not one version's only"
      [result.counted.fetch("allocations"), counting.map(&:first).each_slice(2).to_a, result]
    end
  end

  def test_counts_by_process
    same = (1..5).flat_map { |i| [["base-#{i}", [110, 100, 105]], ["head-#{i}", [100, 120, 101]]] }.to_h
    counted, pairs, = count_by_process(same)

    assert_equal({"baseline" => 100, "candidate" => 100, "more" => 0, "n" => 12, "tolerance" => 0.5, "allowance" => 0, "unit" => "byte",
                  "plural" => "bytes"}, counted, "each worker's fewest")
    rounds = (0...3).flat_map do |round|
      (0...5).map do |i|
        pair = ["base-#{i + 1}", "head-#{((i + round) % 5) + 1}"]
        (i.even? == round.even?) ? pair : pair.reverse
      end
    end

    assert_equal rounds, pairs
    lucky = same.merge("base-3" => [20])
    counted, _, result = count_by_process(lucky)

    assert_equal [100, 100, 0], counted.values_at("baseline", "candidate", "more"), "one baseline worker's luck"
    assert_empty result.worse
    more = same.to_h { |label, values| [label, label.start_with?("head") ? values.map { |v| v + 12 } : values] }
    counted, _, result = count_by_process(more)

    assert_equal [100, 112, 12], counted.values_at("baseline", "candidate", "more")
    assert_equal %w[allocations], result.worse, "one more an iteration (twelve a sample), in every worker"
    counted, = count_by_process(same.merge("base-1" => [nil], "base-2" => [nil]))

    assert_equal [100, 100, nil], counted.values_at("baseline", "candidate", "more"), "too few workers counted for an interval"
  end

  # A benchmark only counted, by process, keeps what its metric said of
  # its last pair of counted samples.
  def test_counts_only_by_process
    with_fake_workers do |workers|
      workers.metrics = [FakeWorkers::CPU, FakeWorkers::ALLOCATIONS]
      workers.benchmark("b", only: "count") do |_, n, label|
        {"timed" => {"cpu" => n * 100_000}, "counted" => {"allocations" => 2}, "heap" => 0, "details" => {"allocations" => "by #{label}"}}
      end
      result, = compare(workers, processes: 5)

      assert_equal({"baseline" => "by base-5", "candidate" => "by head-2"}, result.details.fetch("allocations"))
      assert_equal 0, result.counted.fetch("allocations").fetch("more")
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
    config.prepare(:worker) { |r| r.at_stop { stopped << r.name } && {} }
    config.prepare(:worker) { |r| r.at_stop { stopped << "#{r.name}'s other" } && {} }
    with_fake_workers do |workers|
      workers.benchmark("b", peak_memory: true)
      workers.peaks("baseline", 30, 10, 20)
      workers.peaks("candidate", 5, 6, 7)
      l = lane(workers)
      result = l.compare("b")

      assert_equal({"baseline" => 10, "candidate" => 5}, result.memory)
      assert_equal [["base-7", 12], ["head-7", 12], ["head-7", 12], ["base-7", 12], ["base-7", 12],
        ["head-7", 12]], workers.requests("memory").map { |label, _, args| [label, args.fetch(:n)] }
      assert_equal [{trial: false}] * 6, workers.requests("setup").filter_map { |label, _, args| args if label.end_with?("-7") },
        "no trial first: the allocator would keep what it freed"
      assert_equal 6, workers.log.count { |label, op| label.end_with?("-7") && op == "stop" }
      fresh = %w[base-7 head-7 head-7 base-7 base-7 head-7]

      assert_equal fresh.flat_map { |label| ["#{label}'s other", label] }, stopped, "in reverse"
      assert_equal %w[setup memory stop], workers.log.filter_map { |label, op| op if label == "head-7" }.first(3)
      stopped.clear
      l.stop

      labels = %w[base-1 base-2 base-3 head-1 head-2 head-3]

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
      assert_equal [["base-1", "setup", "b", {}], ["head-1", "setup", "b", {}],
        ["base-1", "profile", "b", {n: 3, runs: 500}], ["head-1", "profile", "b", {n: 3, runs: 500}],
        ["base-1", "teardown", "b", {}], ["head-1", "teardown", "b", {}]], workers.log
      l.stop
    end
  end

  def test_profile_tears_down_however_it_ends
    with_fake_workers do |workers|
      workers.benchmark("b")
      workers.profile("baseline", {"samples" => 1})
      workers.fail("head-1", "profile")
      l = lane(workers)

      assert_raises(Duel::Failed) { l.profile("b", 1) }
      assert_equal %w[base-1 head-1], workers.requests("teardown").map(&:first)
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

# What a lane takes of the versions as the run prepared them, the builds
# each version's workers loaded, and benchmarks of whole processes.
class LaneVersionsTest < DuelTest
  cover "Duel::Lane*"
  cover "Duel::Side*"

  def config = @config ||= Duel::Config.new(File.join(tmpdir, "candidate"))

  def base = File.join(tmpdir, "base")

  def lane(**overrides) = Duel::Lane.new(config, settings(processes: 1, **overrides), Duel::Side.unprepared(config, settings, base))

  # Each version's workers, and their resources, get its tree, its Ruby
  # and its environment (under the resources').
  def test_the_versions_as_prepared
    given = SharedList.new
    config.prepare(:worker) do |r|
      r.run(RbConfig.ruby, "-e", "File.write(ARGV[0], ENV.fetch('V'))", File.join(tmpdir, r.name))
      given << [r.name, r.root, r.ruby]
      {"R" => r.name}
    end
    sides = {"baseline" => Duel::Side.new("baseline", "/b", "/ruby-b", {"V" => "b"}, "jruby"),
             "candidate" => Duel::Side.new("candidate", "/c", "/ruby-c", {"V" => "c"}, "ruby")}
    with_fake_workers do |workers|
      Duel::Lane.open(config, settings(processes: 1), sides) { nil }

      assert_equal ["base-1", "/b", "/c"], workers.made.assoc("base-1").first(3)
      assert_equal({env: {"V" => "b", "R" => "base-1"}, ruby: "/ruby-b", engine: "jruby"},
        workers.made.assoc("base-1").last.slice(:env, :ruby, :engine))
      assert_equal({env: {"V" => "c", "R" => "head-1"}, ruby: "/ruby-c", engine: "ruby"},
        workers.made.assoc("head-1").last.slice(:env, :ruby, :engine))
      assert_equal [["base-1", "/b", "/ruby-b"], ["head-1", "/c", "/ruby-c"]], given.sort
      assert_equal %w[b c], %w[base-1 head-1].map { |name| File.read(File.join(tmpdir, name)) }
    end
  end

  # Unprepared, each version's tree, on the runner's Ruby.
  def test_the_versions_unprepared
    sides = Duel::Side.unprepared(config, settings(candidate_dir: File.join(tmpdir, "x", "..", "other")), File.join(tmpdir, "y", "..", "b"))

    assert_equal({"baseline" => Duel::Side.new("baseline", File.join(tmpdir, "b"), RbConfig.ruby, {}, RUBY_ENGINE),
                  "candidate" => Duel::Side.new("candidate", File.join(tmpdir, "other"), RbConfig.ruby, {}, RUBY_ENGINE)}, sides)
    assert_equal File.join(tmpdir, "candidate"), Duel::Side.unprepared(config, settings, base).fetch("candidate").root
  end

  def test_each_versions_ruby
    with_fake_workers do |workers|
      workers.rubies["baseline"] = "ruby 3.3.6"
      l = lane

      assert_equal({"baseline" => "ruby 3.3.6", "candidate" => RUBY_DESCRIPTION}, l.rubies)
      l.stop
    end
  end

  def dlext = RbConfig::CONFIG["DLEXT"]

  # Builds in each version's tree (made, for their real paths), and
  # elsewhere.
  def built(*paths) = paths.to_h { |path| [File.basename(path), path] }

  def check(baseline, candidate, gem_dirs = {})
    [base, File.join(tmpdir, "candidate")].each { |root| FileUtils.mkdir_p(root) }
    with_fake_workers do |workers|
      workers.extensions.update("baseline" => baseline, "candidate" => candidate)
      workers.gem_dirs.update(gem_dirs)
      lane.stop
      workers.log
    end
  end

  # Each its own build, and the same gem's from elsewhere: fine.
  def test_each_version_loads_its_own_builds
    json = "/gems/json/lib/json/ext/parser.#{dlext}"
    FileUtils.mkdir_p([base, config.root])
    real = ->(root) { File.join(File.realpath(root), "lib", "my_gem", "ext.#{dlext}") }

    check({"my_gem/ext.#{dlext}" => real.call(base), "json/ext/parser.#{dlext}" => json},
      {"my_gem/ext.#{dlext}" => real.call(config.root), "json/ext/parser.#{dlext}" => json})
    pass "they're the versions' own"
  end

  def assert_not_its_own(side, path, feature, baseline, candidate, message = nil, gem_dirs: {})
    error = nil
    log = with_fake_workers do |workers|
      [base, config.root].each { |root| FileUtils.mkdir_p(root) }
      workers.extensions.update("baseline" => baseline, "candidate" => candidate)
      workers.gem_dirs.update(gem_dirs)
      error = assert_raises(Duel::Failed) { lane }
      workers.log
    end
    root = (side == "baseline") ? base : config.root

    assert_equal "the #{side} loaded #{path}, not a build of its own: #{feature} isn't built in #{root}. Set c.build in .duel.rb to " \
      "build each version (by default, it's `bundle exec rake compile` for a project with ext/ and a Rakefile)", error.message, message
    assert_equal [%w[base-1 stop], %w[head-1 stop]], log.sort, "its workers stopped"
  end

  # A baseline without a build of its own loads the candidate's, or (one
  # the candidate built itself) an installed gem's: a candidate likewise.
  def test_a_version_that_loads_anothers_build
    feature = "my_gem/ext.#{dlext}"
    candidates = File.join(File.realpath(tmpdir), "candidate", "lib", feature)
    bases = File.join(File.realpath(tmpdir), "base", "lib", feature)
    installed = "/gems/my_gem/lib/#{feature}"

    assert_not_its_own("baseline", candidates, feature, {feature => candidates}, {feature => candidates})
    assert_not_its_own("baseline", installed, feature, {feature => installed}, {feature => candidates})
    assert_not_its_own("candidate", bases, feature, {feature => bases}, {feature => bases})
    assert_not_its_own("candidate", installed, feature, {feature => bases}, {feature => installed})
    assert_not_its_own("baseline", candidates, "other.#{dlext}", {"other.#{dlext}" => candidates}, {})
    gem = "/gems/json/lib/json/ext/parser.#{dlext}"

    assert_not_its_own("baseline", candidates, feature, {"json/ext/parser.#{dlext}" => gem, feature => candidates}, {}, "after another")
    beside = File.join(File.realpath(tmpdir), "base-old", "lib", feature)

    assert_not_its_own("baseline", beside, feature, {feature => beside}, {feature => candidates}, "next to its tree, not in it")
  end

  # A bundle in the candidate's tree (vendor/bundle, as setup-ruby's
  # bundler-cache installs it), that both versions load an installed
  # gem's extension from: in neither version's tree.
  def test_an_installed_gem_in_the_candidates_tree
    FileUtils.mkdir_p(File.join(config.root, "vendor", "bundle", "ruby", "4.0.0"))
    bundle = File.join(File.realpath(config.root), "vendor", "bundle", "ruby", "4.0.0", "")
    json = File.join(bundle, "gems", "json-3.1.0", "lib", "json", "ext", "parser.#{dlext}")
    loaded = {"json/ext/parser.#{dlext}" => json}

    check(loaded, loaded, "baseline" => [bundle], "candidate" => [bundle])
    pass "an installed gem's, for both"
  end

  # A bundle in a version's tree is no build of its own, for the version
  # that has it either: one that loads the gem under test from there,
  # installed, isn't loading its own build. And the rest of the tree is
  # still the version's.
  def test_a_bundle_in_a_tree_and_the_rest_of_it
    feature = "my_gem/ext.#{dlext}"
    bundle = File.join(File.realpath(tmpdir), "candidate", "vendor", "bundle", "ruby", "4.0.0", "")
    installed = File.join(bundle, "gems", "my_gem-1.0.0", "lib", feature)
    candidates = File.join(File.realpath(tmpdir), "candidate", "lib", feature)
    bases = File.join(File.realpath(tmpdir), "base", "lib", feature)
    gem_dirs = {"baseline" => [bundle], "candidate" => [bundle]}

    assert_not_its_own("baseline", installed, feature, {feature => installed}, {feature => candidates}, gem_dirs: gem_dirs)
    assert_not_its_own("candidate", installed, feature, {feature => bases}, {feature => installed}, gem_dirs: gem_dirs)
    assert_not_its_own("baseline", candidates, feature, {feature => candidates}, {feature => candidates}, gem_dirs: gem_dirs)
  end

  # A baseline in the candidate's tree (one --base-dir names, say) has
  # builds of its own there. And a tree reached by a symlink is where it leads.
  def test_a_baseline_inside_the_candidate
    inside = File.join(config.root, "tmp", "duel", "base")
    FileUtils.mkdir_p(inside)
    File.symlink(config.root, File.join(tmpdir, "linked"))
    feature = "my_gem/ext.#{dlext}"
    with_fake_workers do |workers|
      workers.extensions.update("baseline" => {feature => File.join(File.realpath(inside), "lib", feature)},
        "candidate" => {feature => File.join(File.realpath(config.root), "lib", feature)})
      run = settings(processes: 1, candidate_dir: File.join(tmpdir, "linked"))
      Duel::Lane.new(config, run, Duel::Side.unprepared(config, run, inside)).stop
    end
    pass "each its own"
  end

  # A version that loaded an extension twice (the candidate's, that a
  # plugin required before the version loaded, and its own over it)
  # fails, whatever its last is.
  def test_a_version_that_loaded_an_extension_twice
    feature = "my_gem/ext.#{dlext}"
    paths = [File.join(config.root, "lib", feature), File.join(base, "lib", feature)]
    error = nil
    log = with_fake_workers do |workers|
      workers.extensions.update("baseline" => {feature => paths.last}, "candidate" => {})
      workers.twice.update("baseline" => {feature => paths})
      error = assert_raises(Duel::Failed) { lane }
      workers.log
    end

    assert_equal "the baseline loaded #{feature} twice, from #{paths.join(" and ")}: something required it before Duel loaded " \
      "the baseline, and both stay loaded. Require what loads it in a block that runs once the version has loaded " \
      "(c.in_worker, in .duel.rb), not as .duel.rb or a plugin loads", error.message
    assert_equal [%w[base-1 stop], %w[head-1 stop]], log.sort, "its workers stopped"

    log = with_fake_workers do |workers|
      workers.twice.update("candidate" => {feature => paths})
      error = assert_raises(Duel::Failed) { lane }
      workers.log
    end

    assert_match(/\Athe candidate loaded #{Regexp.escape(feature)} twice/, error.message)
    assert_equal [%w[base-1 stop], %w[head-1 stop]], log.sort
  end

  # A tree that isn't there (yet) is where its path says.
  def test_a_tree_that_isnt_there
    feature = "x.#{dlext}"
    with_fake_workers do |workers|
      workers.extensions.update("baseline" => {feature => File.join(base, feature)}, "candidate" => {feature => File.join(base, feature)})
      error = assert_raises(Duel::Failed) { lane }

      assert_match(/\Athe candidate loaded #{Regexp.escape(File.join(base, feature))}, not a build of its own/, error.message)
    end
  end

  # A process benchmark: no setup or teardown in the workers, and each
  # sample the fastest of a few fresh processes for each version, theirs
  # taking turns, paired as any benchmark's are, after a warm-up of its
  # own (a process each), judged on its CPU time, with each version's
  # least peak memory.
  # A process benchmark is judged over its pairs, however many workers:
  # each of its samples is a process of its own already.
  def test_a_process_benchmark_by_pairs
    with_fake_workers do |workers|
      workers.benchmark("boot", process: {"command" => %w[bin/boot], "ruby" => nil, "runs" => 1}) do |_, n, _|
        {"timed" => {"cpu" => n * 1_000_000}, "peak" => 1 << 20}
      end
      l = lane(processes: 5)
      result = l.compare("boot")
      l.stop

      refute result.timed.fetch("cpu").key?("processes")
    end
  end

  def test_a_process_benchmark
    process = {"command" => %w[bin/boot], "ruby" => nil, "runs" => nil}
    with_fake_workers do |workers|
      cpu = {"baseline" => [31, 30, 32].cycle, "candidate" => [34.5, 33, 36, 34].cycle}
      # (The least, a measured sample's, neither the first nor the last.)
      peaks = {"baseline" => [30, 20, *[30] * 40].each, "candidate" => [40, 40, 40, 35, *[40] * 40].each}
      workers.benchmark("boot", process: process) do |side, n, _|
        {"timed" => {"cpu" => (n * cpu.fetch(side).next * 1_000_000).to_i}, "peak" => peaks.fetch(side).next << 20}
      end
      l = lane(processes: 2)
      result = l.compare("boot")
      l.stop

      assert_equal 1, result.n
      assert_equal %w[slower 10], result.timed.fetch("cpu").values_at("verdict", "pairs").map(&:to_s)
      assert_equal({"baseline" => 20 << 20, "candidate" => 35 << 20}, result.memory)
      runs = workers.requests("run")

      assert_equal 2 * (Duel::Lane::PROCESS_WARMUP + (Duel::Lane::STEP * Duel::Lane::PROCESS_RUNS)), runs.size
      assert_equal [{process: process}], runs.map(&:last).uniq, "a process a run"
      assert_equal [30_000_000, 33_000_000], result.timed.fetch("cpu").values_at("baseline", "candidate"), "the fastest of each sample's"
      assert_kind_of Float, result.seconds
      assert_equal [%w[base-1 head-1], %w[base-1 head-1] * 3, %w[head-2 base-2] * 3,
        %w[base-1 head-2] * 3], [runs.first(2).map(&:first), *runs.drop(2).map(&:first).each_slice(6).first(3)],
        "the warm-up's pair, then measured ones, each of the fastest of PROCESS_RUNS a version, theirs in turn"
      assert_equal %w[run stop], workers.log.map { |entry| entry[1] }.uniq.sort, "nothing else"
    end
  end

  # A process benchmark's sample takes as many runs as take
  # PROCESS_SAMPLE_NS of CPU time on the slower version in the warm-up,
  # up to PROCESS_RUNS, and one at least, unless it says.
  def test_a_process_benchmarks_runs
    {[1, nil] => 3, [300, nil] => 3, [400, nil] => 2, [454, nil] => 2, [455, nil] => 1, [1_500, nil] => 1, [1, 1] => 1,
     [400, 5] => 5, [-455, nil] => 1, [-454, nil] => 2}.each do |(ms, runs), taken|
      with_fake_workers do |workers|
        process = {"command" => nil, "ruby" => "1", "runs" => runs}
        # (The candidate 10% slower, or with -ms, faster.)
        workers.benchmark("boot", process: process) do |side, n, _|
          {"timed" => {"cpu" => n * ms.abs * (((side == "candidate") == ms.positive?) ? 1_100_000 : 1_000_000)}}
        end
        l = lane(processes: 2)
        l.compare("boot")
        l.stop

        # (A faster one is settled after 8 pairs.)
        pairs = ms.positive? ? Duel::Lane::STEP : 8

        assert_equal 2 * (Duel::Lane::PROCESS_WARMUP + (pairs * taken)), workers.requests("run").size, "#{ms}ms, runs: #{runs.inspect}"
      end
    end

    assert_equal [1, 3, 1_000_000_000], [Duel::Lane::PROCESS_WARMUP, Duel::Lane::PROCESS_RUNS, Duel::Lane::PROCESS_SAMPLE_NS]
    with_fake_workers do |workers|
      workers.benchmark("boot", process: {"command" => nil, "ruby" => "1", "runs" => nil})
      l = lane(processes: 2)

      assert_equal 3, l.send(:process_runs, [[{"timed" => {"cpu" => 0}}, {"timed" => {"cpu" => 0}}]]), "none at all, as good as nothing"
      assert_equal "2", l.send(:process_runs, [[{"timed" => {"cpu" => 400_000_000}}, {"timed" => {"cpu" => 0}}]]).inspect, "a whole number"
      l.stop
    end
  end

  # A process benchmark that isn't slower stops as soon as that's
  # settled (the same or faster, after any pair: 8 pairs, the fewest an
  # interval takes), not at the end of a round of STEP pairs, as one
  # that's slower does (see test_a_process_benchmark).
  def test_a_process_benchmark_stops_once_its_not_slower
    {"same" => 300_000_000, "faster" => 270_000_000}.each do |verdict, cpu|
      with_fake_workers do |workers|
        workers.benchmark("boot", process: {"command" => nil, "ruby" => "1", "runs" => nil}) do |side, n, _|
          {"timed" => {"cpu" => n * ((side == "candidate") ? cpu : 300_000_000)}, "peak" => 1 << 20}
        end
        l = lane(processes: 2)
        result = l.compare("boot")
        l.stop

        assert_equal [verdict, "8"], result.timed.fetch("cpu").values_at("verdict", "pairs").map(&:to_s)
        assert_equal 2 * (Duel::Lane::PROCESS_WARMUP + (8 * Duel::Lane::PROCESS_RUNS)), workers.requests("run").size
      end
    end
  end

  # Where peak memory can't be told (JRuby's), there's none.
  def test_a_process_benchmark_without_peak_memory
    with_fake_workers do |workers|
      workers.benchmark("boot", process: {"command" => nil, "ruby" => "1", "runs" => nil}) do |_, _, label|
        {"timed" => {"cpu" => 1_000_000}, "peak" => (1 unless label == "head-1")}
      end
      l = lane(processes: 2)

      assert_nil l.compare("boot").memory
      l.stop
    end
  end
end
