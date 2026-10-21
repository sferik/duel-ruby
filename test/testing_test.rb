# frozen_string_literal: true

require_relative "test_helper"
require "duel/testing"

# A worker is never started inside one of the same config: Testing.measure
# runs in the worker it's inside. A mutation that makes it start one all
# the same (no STOPS[config] = stops, say) would recurse until the stack
# overflowed, every frame's ensure chaining an error of its own to the
# last, gigabytes of them, and the process could be killed for the memory
# before it reported the test failed. This fails it at the first nested
# worker instead.
module NoNestedWorker
  ACTIVE = {}.compare_by_identity

  def in_worker(config)
    raise "a worker started inside a worker of the same config" if ACTIVE.key?(config)

    ACTIVE[config] = true
    begin
      super
    ensure
      ACTIVE.delete(config)
    end
  end
end
Duel::Testing.singleton_class.prepend(NoNestedWorker)

# What a plugin's tests get (duel/testing).
class TestingTest < DuelTest
  cover "Duel::Testing*"
  cover "Duel::InWorker*"
  cover "Duel::Config#in_worker"

  # (In a directory of its own: what lands where it shouldn't, as prepare
  # blocks' directories do under mutant, lands there.)
  def setup
    super
    @env = ENV.to_h
    @pwd = Dir.pwd
    Dir.chdir(tmpdir)
  end

  def teardown
    Dir.chdir(@pwd)
    ENV.replace(@env)
    super
  end

  # Its prepare blocks, run as a worker's would be, their environment set
  # while the block runs (and as it was after), and stopped, last first.
  def test_prepare
    config = Duel::Config.new(tmpdir)
    log = []
    config.prepare(:worker) do |w|
      w.at_stop { log << [:stop, w.name, w.root, Dir.exist?(w.dir)] }
      {"DUEL_TESTING_A" => w.name}
    end
    config.prepare(:worker) do |w|
      w.at_stop { log << [:stop, File.basename(w.dir)] }
      {"DUEL_TESTING_B" => "b"}
    end
    ENV["DUEL_TESTING_B"] = "before"
    given = Duel::Testing.prepare(config) do |env|
      log << [:block, ENV.fetch("DUEL_TESTING_A"), ENV.fetch("DUEL_TESTING_B")]
      env
    end

    assert_equal({"DUEL_TESTING_A" => "candidate-1", "DUEL_TESTING_B" => "b"}, given)
    assert_equal [[:block, "candidate-1", "b"], [:stop, "candidate-1-2"], [:stop, "candidate-1", tmpdir, true]], log
    assert_equal ["before", nil], [ENV.fetch("DUEL_TESTING_B"), ENV.fetch("DUEL_TESTING_A", nil)], "as it was"
  end

  # Each in a directory of its own, short as a lane's (for Unix sockets),
  # removed after.
  def test_prepare_directories
    config = Duel::Config.new(tmpdir)
    dirs = []
    2.times { config.prepare(:worker) { |w| (dirs << w.dir) && {} } }
    Duel::Testing.prepare(config, name: "baseline-2") { nil }

    lane = File.dirname(dirs.first)

    assert_equal %w[baseline-2-1 baseline-2-2], dirs.map { |dir| dir.delete_prefix("#{lane}/") }
    assert_equal Duel::Lane.short_tmp, File.dirname(lane)
    assert_match(/\Aduel/, File.basename(lane))
    refute Dir.exist?(lane), "removed"
  end

  # A prepare block waits as long as a worker's would: the run's timeout.
  def test_prepare_timeout
    config = Duel::Config.new(tmpdir)
    config.prepare(:worker) { |w| w.wait_until { false } }
    defaults = Duel::Settings.defaults.tap { |s| s.timeout = 0.01 }
    error = stub(Duel::Settings, :defaults, -> { defaults }) do
      assert_raises(Duel::Failed) { Duel::Testing.prepare(config) { flunk "not started" } }
    end

    assert_equal "candidate-1's resource: not ready within 0.01s", error.message
  end

  def test_prepare_a_worker_and_version_of_its_own
    config = Duel::Config.new(tmpdir)
    config.prepare(:worker) { |w| {"WHO" => "#{w.name} #{w.root} #{w.cached("t") { |_| nil }}"} }
    cache = File.join(tmpdir, "cache")

    assert_equal "baseline-2 /old #{cache}/t", Duel::Testing.prepare(config, name: "baseline-2", root: "/old", cache: cache) { ENV.fetch("WHO") }
    assert_equal File.join(Duel::Testing::CACHE, "t"), Duel::Testing.prepare(config) { ENV.fetch("WHO").split.last }, "one for every test"
  end

  # Its version's prepare blocks first (named for the version), their
  # environment under the worker's.
  def test_prepare_the_version_first
    config = Duel::Config.new(tmpdir)
    log = []
    config.prepare(:version) do |v|
      v.at_stop { log << [:stop, v.name, File.basename(v.dir)] }
      {"DUEL_TESTING_V" => v.name, "DUEL_TESTING_W" => "version"}
    end
    config.prepare(:worker) do |w|
      w.at_stop { log << [:stop, w.name, File.basename(w.dir)] }
      {"DUEL_TESTING_R" => ENV.fetch("DUEL_TESTING_V", "unset"), "DUEL_TESTING_W" => "version"}
    end
    given = Duel::Testing.prepare(config, name: "baseline-12", root: "/old") { |env| env }

    assert_equal({"DUEL_TESTING_V" => "baseline", "DUEL_TESTING_W" => "version", "DUEL_TESTING_R" => "unset"}, given)
    assert_equal [[:stop, "baseline-12", "baseline-12-2"], [:stop, "baseline", "baseline-1"]], log
  end

  # Prepare blocks that fail, or clash, are stopped all the same.
  def test_prepare_blocks_that_fail
    config = Duel::Config.new(tmpdir)
    stopped = []
    config.prepare(:worker) { |w| w.at_stop { stopped << w.name } && {"X" => "1"} }
    config.prepare(:worker) { |_| {"X" => "2"} }
    error = assert_raises(Duel::Failed) { Duel::Testing.prepare(config) { flunk "not started" } }

    assert_equal "candidate-1: two prepare blocks set X (1, 2)", error.message
    assert_equal ["candidate-1"], stopped
  end

  # What its metrics measure of a block, as a counted sample would: in a
  # worker of its own, ended after, or in the one it's inside (whose
  # in_worker blocks run, and metrics are made, once).
  def test_measure
    config = Duel::Config.new(tmpdir)
    total = 0
    log = []
    config.in_worker { |w| (log << :started) && w.at_stop { log << :stopped } }
    config.metric("rows") { total }
    config.metric("time", kind: :ratio) { 10 }
    measured = Duel::Testing.measure(config) { total += 3 }

    assert_equal({"rows" => 3, "time" => 0}, measured)
    assert_equal %i[started stopped], log, "a worker of its own"
    Duel::Testing.in_worker(config) do
      2.times { assert_equal({"rows" => 2, "time" => 0}, Duel::Testing.measure(config) { total += 2 }) }

      assert_equal %i[started stopped started], log, "the worker's"
    end

    assert_equal %i[started stopped started stopped], log
  end

  # A metric gets the sample: n and the benchmark (one with only:, say).
  def test_measure_n_iterations_of_a_benchmark
    seen = []
    metric = Class.new(Duel::Metric) do
      def self.metric_name = "seen"

      define_method(:start_sample) { |sample| seen << [sample.n, sample.benchmark.only] }
    end
    config = Duel::Config.new(tmpdir)
    config.metric(metric)
    Duel::Testing.measure(config) { 1 }
    Duel::Testing.measure(config, n: 4, only: :timing) { 1 }

    assert_equal [[1, nil], [4, :timing]], seen
    runs = 0
    Duel::Testing.measure(config, n: 3) { runs += 1 }

    assert_equal 1, runs, "once, without an around_iteration hook: n is for the metrics"
  end

  # As a worker makes them: with the config's changes to measures, and
  # its checks.
  def test_measure_as_a_worker_does
    config = Duel::Config.new(tmpdir)
    config.metric("rows" => {}, "pages" => {}) { {"rows" => 1, "pages" => 2} }
    config.measure("pages", skip: true)

    assert_equal({"rows" => 0, "pages" => 0}, Duel::Testing.measure(config) { nil }, "a metric measures what it reads")
    assert_equal 1, Duel::Testing.metrics(config).size
    config = Duel::Config.new(tmpdir)
    config.metric("rows") { 1 }
    config.measure("nope", limit: 2)
    error = assert_raises(Duel::Error) { Duel::Testing.measure(config) { nil } }

    assert_equal "no metric measures nope (c.measure)", error.message
  end

  # The block gets the benchmark's context, and can pause measuring, as a
  # benchmark's untimed does, once for an untimed block inside another,
  # and it's measuring (Duel.measuring?) otherwise.
  def test_measure_with_untimed
    config = Duel::Config.new(tmpdir)
    total = 0
    config.metric("rows") { total }.details { |stretches, _| "#{stretches.size} stretches" }
    seen = []
    measured = Duel::Testing.measure(config) do |sample|
      seen << sample.class
      total += 1
      seen << Duel.measuring?
      sample.untimed { (total += 10) && (seen << Duel.measuring?) && (seen << sample.untimed { (total += 100) && :inner }) }
      seen << Duel.measuring?
    end

    assert_equal({"rows" => 1}, measured)
    assert_equal({"rows" => "2 stretches"}, measured.details, "paused once")
    assert_equal [Duel::Context, true, false, :inner, true], seen, "measuring, as in a benchmark: a plugin's guard can be tested"
    refute_predicate Duel, :measuring?
  end

  # With around_iteration: (or the configuration's), the block is an
  # iteration, run n times, each inside the hooks, as a worker runs a
  # benchmark with them (its other hooks too), and the block keeps its
  # own self, and its hooks run in the benchmark's context: what the
  # hooks do isn't measured, whether a metric pauses around each
  # iteration or is costly to read (and read only at the sample's ends).
  # The block gets untimed, and is measuring. A metric gets the sample
  # (of a benchmark with only:, say), as it does without them.
  def test_measure_with_around_iteration
    [false, true].each do |costly|
      config = Duel::Config.new(tmpdir)
      total = 0
      seen = []
      metric = config.metric("rows") { total }
      metric.costly if costly
      benchmarks = []
      config.metric(Class.new(Duel::Metric) do
        def self.metric_name = "seen"

        define_method(:start_sample) { |sample| benchmarks << sample.benchmark.to_h.merge("n" => sample.n) }
      end)
      config.before_sample { |benchmark| (total += 1000) && (seen << benchmark.name) }
      config.after_iterations { total += 5 }
      around = lambda do |iteration|
        total += 100
        seen << [self.class, iteration.call]
        total += 10
      end
      measured = Duel::Testing.measure(config, n: 3, only: :timing, around_iteration: around) do |sample|
        sample.untimed { total += 50 }
        (total += 1) && [self.class, Duel.measuring?]
      end

      assert_equal({"rows" => 3 * 6}, measured, "costly: #{costly}")
      assert_equal({"name" => "test", "only" => "timing", "peak_memory" => false, "process" => nil, "n" => 3}, benchmarks.last)
      assert_equal [[Duel::Context, [TestingTest, true]]] * 3, seen.last(3)
      assert_equal "test", seen[-4]
    end
    config = Duel::Config.new(tmpdir)
    total = 0
    config.metric("rows") { total }
    config.around_iteration { |iteration| (total += 100) && iteration.call }

    assert_equal({"rows" => 3}, Duel::Testing.measure(config, n: 3) { total += 1 }, "the configuration's")
  end

  # Its own hooks, and the configuration's, as a benchmark's: setup first,
  # and teardown last, not measured. A hook that isn't one fails.
  def test_measure_with_hooks
    config = Duel::Config.new(tmpdir)
    total = 0
    log = []
    config.metric("rows") { total }
    config.setup { log << :config_setup }
    config.teardown { log << :config_teardown }
    measured = Duel::Testing.measure(config, setup: -> { (total += 10) && (log << :setup) }, teardown: -> { log << :teardown },
      before_sample: -> { total += 100 }) { (total += 1) && (log << :block) }

    assert_equal({"rows" => 1}, measured)
    assert_equal %i[config_setup setup block teardown config_teardown], log
    error = assert_raises(ArgumentError) { Duel::Testing.measure(config, around: -> {}) { nil } }

    assert_match(/\Aduel "test": no option around /, error.message)
  end

  # A worker's blocks' stops run when it ends, last first (and a worker
  # of the config is made afresh after).
  def test_in_worker
    config = Duel::Config.new(tmpdir)
    log = []
    config.in_worker do |w|
      log << :started
      w.at_stop { log << :first }
      w.at_stop { log << :second }
    end
    config.metric("rows") { 1 }

    assert_equal :done, Duel::Testing.in_worker(config) { (log << :block) && :done }
    assert_equal %i[started block second first], log
    Duel::Testing.in_worker(config) { nil }

    assert_equal %i[started block second first started second first], log
  end

  # As a sample of a benchmark is: after the config's before_sample
  # hooks (given the benchmark), not measured, and before its
  # after_iterations hooks, measured.
  def test_measure_with_before_sample_and_after_iterations
    config = Duel::Config.new(tmpdir)
    total = 0
    log = []
    config.metric("rows") { total }
    config.before_sample { |benchmark| (total += 100) && (log << [:before, benchmark.only, Duel.measuring?]) }
    config.after_iterations { (total += 5) && (log << [:after, Duel.measuring?]) }

    assert_equal({"rows" => 6}, Duel::Testing.measure(config, only: :timing) { (total += 1) && (log << :block) })
    assert_equal [[:before, :timing, false], :block, [:after, true]], log
  end

  # Its metrics are closed (last first) as its worker ends, before what
  # its blocks gave at_stop, and as they're made again.
  def test_metrics_closed
    config = Duel::Config.new(tmpdir)
    log = []
    config.in_worker { |w| w.at_stop { log << :stopped } }
    config.metric("a") { 1 }.close { log << :a }
    config.metric("b") { 2 }.close { log << :b }
    Duel::Testing.in_worker(config) { nil }

    assert_equal %i[b a stopped], log
    log.clear
    Duel::Testing.in_worker(config) do
      config.measure("a", limit: 2)
      Duel::Testing.metrics(config)

      assert_equal %i[b a], log, "made again"
    end
  end

  # Stand-ins for what Duel gives a metric: a sample (its n and its
  # benchmark), and readings of running totals, for what explains them.
  def test_stand_ins
    sample = Duel::Testing.sample

    assert_instance_of Duel::Sample, sample
    assert_equal [1, "test", nil, false], [sample.n, sample.benchmark.name, sample.benchmark.only, sample.benchmark.peak_memory]
    sample = Duel::Testing.sample(n: 4, name: "x", only: :timing, peak_memory: true)

    assert_equal [4, "x", :timing, true, :process], [sample.n, *sample.benchmark.to_a.first(3), sample.benchmark.cpu]
    assert_equal [File.expand_path("../lib/duel/testing.rb", __dir__), nil], [sample.benchmark.file, sample.benchmark.body.call]
    assert_equal [{}, nil], [Duel::Testing.reading.totals, Duel::Testing.reading.context]
    reading = Duel::Testing.reading({"rows" => 3}, :views)

    assert_equal [3, :views], [reading.total("rows"), reading.context]
    config = Duel::Config.new(tmpdir)
    metric = config.metric("rows") { 0 }.details do |stretches, given|
      "#{stretches.sum { |started, stopped| stopped.total("rows") - started.total("rows") }.fdiv(given.n)} an iteration"
    end
    stretches = [[Duel::Testing.reading({"rows" => 1}), reading], [Duel::Testing.reading({"rows" => 3}), Duel::Testing.reading({"rows" => 7})]]

    assert_equal "1.5 an iteration", Duel::Testing.details(metric, stretches, sample)
    assert_equal "6.0 an iteration", Duel::Testing.details(metric, stretches), "a sample of one"
    assert_nil Duel::Testing.details(config.metric("pages") { 0 }, stretches)
  end

  # What metrics said of what's measured comes back with it.
  def test_measure_with_details
    config = Duel::Config.new(tmpdir)
    total = 0
    config.metric("rows") { total }.details { |stretches, _| "#{stretches.last.last.total("rows")} rows" }
    measured = Duel::Testing.measure(config) { total += 2 }

    assert_equal({"rows" => 2}, measured)
    assert_equal({"rows" => "2 rows"}, measured.details)
  end

  # A change to a measure's settings after its metrics were made makes
  # them again: it isn't left to mean nothing.
  def test_metrics_made_again_after_a_change
    config = Duel::Config.new(tmpdir)
    config.metric("rows") { 1 }
    config.measure("rows", limit: 2)
    first = Duel::Testing.metrics(config)

    assert_same first, Duel::Testing.metrics(config)
    config.measure("rows", allowance: 4)
    again = Duel::Testing.metrics(config)

    refute_same first, again
    assert_equal [2, 4], again.first.settings.fetch("rows").values_at(:limit, :allowance)
    assert_same again, Duel::Testing.metrics(config)
  end

  # What each worker makes for itself: its own while it runs, gone (and
  # its stops run) when it ends.
  def test_in_worker_values
    config = Duel::Config.new(tmpdir)
    made = 0
    log = []
    connection = config.in_worker do |w|
      made += 1
      w.at_stop { log << :closed }
      "connection #{made}"
    end
    error = assert_raises(Duel::Error) { connection.value }

    assert_match(/\Amade in each worker only/, error.message)
    assert_equal "connection 1", Duel::Testing.in_worker(config) { connection.value }
    assert_equal [:closed], log
    assert_raises(Duel::Error) { connection.value }
    assert_equal "connection 2", Duel::Testing.in_worker(config) { connection.value }, "each worker's own"
  end

  def test_unavailable_metrics_measure_nothing
    config = Duel::Config.new(tmpdir)
    config.metric(Class.new(Duel::Metric) do
      def self.metric_name = "gone"

      def self.available? = false
    end)

    assert_empty Duel::Testing.measure(config) { 1 }
  end

  def test_project
    dir = File.join(tmpdir, "p")
    made = Duel::Testing.project(dir, "lib/p.rb" => "P = 1\n", "duel/p_duel.rb" => "duel('p') { P }\n")

    assert_equal dir, made
    assert_equal ["P = 1\n", "duel('p') { P }\n"], [File.read(File.join(dir, "lib/p.rb")), File.read(File.join(dir, "duel/p_duel.rb"))]
  end

  # A comparison passes when every benchmark does, and has each's Result.
  def test_comparison
    fast = Duel::Result.new("fast")
    broken = Duel::Result.new("broken")
    broken.error = "boom"
    comparison = Duel::Testing::Comparison.new([fast, broken], "", false)

    refute_predicate comparison, :passed?
    assert_predicate Duel::Testing::Comparison.new([fast], "", true), :passed?
    assert_equal [fast, broken, nil], %w[fast broken gone].map { |name| comparison[name] }
  end

  # A result slower in time in every measurement, by one timing in some
  # and another in the rest, regressed on both: what a plugin's test of a
  # comparison sees.
  def test_a_comparisons_result_slower_by_one_timing_or_another
    mixed = Duel::Result.new("mixed")
    measured = [%w[slower undecided], %w[undecided slower]].map do |cpu, instructions|
      Duel::Result.new("mixed").tap { |r| r.timed.update("cpu" => {"verdict" => cpu}, "instructions" => {"verdict" => instructions}) }
    end
    mixed.timed.update(measured.first.timed)
    mixed.confirmations.push(measured.last, measured.first, measured.last)
    comparison = Duel::Testing::Comparison.new([mixed], "", false)

    refute_predicate comparison["mixed"], :passed?
    assert_equal %w[cpu instructions], comparison["mixed"].regressed
  end

  # A warm-up where a JIT needs one (see EndToEndTest#settings).
  def warm = Duel::JIT_WARM.zero? ? 0.0 : 1.5

  # Whole comparisons, in worker processes (two of each version, unless
  # the settings given say): the candidate's .duel.rb, its workers
  # prepared, and the configuration as it was after.
  def test_compare
    base = project(File.join(tmpdir, "base"))
    same = project(File.join(tmpdir, "same"))
    slower = project(File.join(tmpdir, "slower"), work: 6000)
    File.write(File.join(same, ".duel.rb"), <<~RUBY)
      Duel.configure do |c|
        c.measure("cpu", limit: 1.5)
        c.prepare(:worker) { |w| File.write(File.join(w.root, w.name), "") && {} }
      end
    RUBY
    config = Duel.config
    passed = Duel::Testing.compare(base, same, warm: warm)

    assert_predicate passed, :passed?
    assert_equal ["work"], passed.results.map(&:name)
    assert_in_delta 1.5, passed["work"].timed.fetch("cpu").fetch("limit")
    assert_equal %w[base/baseline-1 base/baseline-2 same/candidate-1 same/candidate-2], Dir[File.join(tmpdir, "*", "*-?")].map { |path| path.delete_prefix("#{tmpdir}/") }
    assert_includes passed.output, "1 benchmark in"
    assert_same config, Duel.config
    failed = Duel::Testing.compare(base, slower, warm: warm, processes: 1, limit: 1.1)

    refute_predicate failed, :passed?
    assert_includes failed["work"].regressed, "cpu"
    assert_in_delta 1.1, failed["work"].timed.fetch("cpu").fetch("limit")
    assert_same config, Duel.config, "as it was"
  end
end
