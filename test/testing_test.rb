# frozen_string_literal: true

require_relative "test_helper"
require "duel/testing"

# What a plugin's tests get (duel/testing).
class TestingTest < DuelTest
  cover "Duel::Testing*"
  cover "Duel::PerWorker*"
  cover "Duel::Config#per_worker"

  # (In a directory of its own: what lands where it shouldn't, as resources'
  # directories do under mutant, lands there.)
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

  # Its resources, started as a worker's would be, their environment set
  # while the block runs (and as it was after), and stopped, last first.
  def test_resources
    config = Duel::Config.new(tmpdir)
    log = []
    config.resource do |r|
      r.at_stop { log << [:stop, r.name, r.root, Dir.exist?(r.dir)] }
      {"DUEL_TESTING_A" => r.name}
    end
    config.resource do |r|
      r.at_stop { log << [:stop, File.basename(r.dir)] }
      {"DUEL_TESTING_B" => "b"}
    end
    ENV["DUEL_TESTING_B"] = "before"
    given = Duel::Testing.resources(config) do |env|
      log << [:block, ENV.fetch("DUEL_TESTING_A"), ENV.fetch("DUEL_TESTING_B")]
      env
    end

    assert_equal({"DUEL_TESTING_A" => "candidate-1", "DUEL_TESTING_B" => "b"}, given)
    assert_equal [[:block, "candidate-1", "b"], [:stop, "candidate-1-2"], [:stop, "candidate-1", tmpdir, true]], log
    assert_equal ["before", nil], [ENV.fetch("DUEL_TESTING_B"), ENV.fetch("DUEL_TESTING_A", nil)], "as it was"
  end

  # Each in a directory of its own, short as a lane's (for Unix sockets),
  # removed after.
  def test_resources_directories
    config = Duel::Config.new(tmpdir)
    dirs = []
    2.times { config.resource { |r| (dirs << r.dir) && {} } }
    Duel::Testing.resources(config, name: "baseline-2") { nil }

    lane = File.dirname(dirs.first)

    assert_equal %w[baseline-2-1 baseline-2-2], dirs.map { |dir| dir.delete_prefix("#{lane}/") }
    assert_equal Duel::Lane.short_tmp, File.dirname(lane)
    assert_match(/\Aduel/, File.basename(lane))
    refute Dir.exist?(lane), "removed"
  end

  # A resource waits as long as a worker's would: the run's timeout.
  def test_resources_timeout
    config = Duel::Config.new(tmpdir)
    config.resource { |r| r.wait_until { false } }
    defaults = Duel::Settings.defaults.tap { |s| s.timeout = 0.01 }
    error = stub(Duel::Settings, :defaults, -> { defaults }) do
      assert_raises(Duel::Failed) { Duel::Testing.resources(config) { flunk "not started" } }
    end

    assert_equal "candidate-1's resource: not ready within 0.01s", error.message
  end

  def test_resources_of_a_worker_and_version_of_its_own
    config = Duel::Config.new(tmpdir)
    config.resource { |r| {"WHO" => "#{r.name} #{r.root} #{r.cached("t") { |_| nil }}"} }
    cache = File.join(tmpdir, "cache")

    assert_equal "baseline-2 /old #{cache}/t", Duel::Testing.resources(config, name: "baseline-2", root: "/old", cache: cache) { ENV.fetch("WHO") }
    assert_equal File.join(Duel::Testing::CACHE, "t"), Duel::Testing.resources(config) { ENV.fetch("WHO").split.last }, "one for every test"
  end

  # Resources that fail, or clash, are stopped all the same.
  def test_resources_that_fail
    config = Duel::Config.new(tmpdir)
    stopped = []
    config.resource { |r| r.at_stop { stopped << r.name } && {"X" => "1"} }
    config.resource { |_| {"X" => "2"} }
    error = assert_raises(Duel::Failed) { Duel::Testing.resources(config) { flunk "not started" } }

    assert_equal "candidate-1: two resources set X (1, 2)", error.message
    assert_equal ["candidate-1"], stopped
  end

  # What its metrics measure of a block, as a counted sample would: in a
  # worker of its own, ended after, or in the one it's inside (whose
  # worker blocks run, and metrics are made, once).
  def test_measure
    config = Duel::Config.new(tmpdir)
    total = 0
    log = []
    config.worker { |w| (log << :started) && w.at_stop { log << :stopped } }
    config.metric("rows") { total }
    config.metric("time", kind: :ratio) { 10 }
    measured = Duel::Testing.measure(config) { total += 3 }

    assert_equal({"rows" => 3, "time" => 0}, measured)
    assert_equal %i[started stopped], log, "a worker of its own"
    Duel::Testing.worker(config) do
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

      define_method(:start) { |sample| seen << [sample.n, sample.benchmark.only] }
    end
    config = Duel::Config.new(tmpdir)
    config.metric(metric)
    Duel::Testing.measure(config) { 1 }
    Duel::Testing.measure(config, n: 4, only: :timing) { 1 }

    assert_equal [[1, nil], [4, :timing]], seen
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

  # The block can pause measuring, as a benchmark's untimed does; it's
  # measuring (Duel.measuring?) otherwise.
  def test_measure_with_untimed
    config = Duel::Config.new(tmpdir)
    total = 0
    config.metric("rows") { total }
    seen = []
    measured = Duel::Testing.measure(config) do |sample|
      total += 1
      seen << Duel.measuring?
      sample.untimed { (total += 10) && (seen << Duel.measuring?) }
      seen << Duel.measuring?
    end

    assert_equal({"rows" => 1}, measured)
    assert_equal [true, false, true], seen, "measuring, as in a benchmark: a plugin's guard can be tested"
    refute_predicate Duel, :measuring?
  end

  # A worker's blocks' stops run when it ends, last first (and a worker
  # of the config is made afresh after).
  def test_worker
    config = Duel::Config.new(tmpdir)
    log = []
    config.worker do |w|
      log << :started
      w.at_stop { log << :first }
      w.at_stop { log << :second }
    end
    config.metric("rows") { 1 }

    assert_equal :done, Duel::Testing.worker(config) { (log << :block) && :done }
    assert_equal %i[started block second first], log
    Duel::Testing.worker(config) { nil }

    assert_equal %i[started block second first started second first], log
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
  def test_per_worker
    config = Duel::Config.new(tmpdir)
    made = 0
    log = []
    connection = config.per_worker do |w|
      made += 1
      w.at_stop { log << :closed }
      "connection #{made}"
    end
    error = assert_raises(Duel::Error) { connection.value }

    assert_match(/\Amade in each worker only/, error.message)
    assert_equal "connection 1", Duel::Testing.worker(config) { connection.value }
    assert_equal [:closed], log
    assert_raises(Duel::Error) { connection.value }
    assert_equal "connection 2", Duel::Testing.worker(config) { connection.value }, "each worker's own"
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

  # A warm-up where a JIT needs one (see EndToEndTest#settings).
  def warm = Duel::JIT_WARM.zero? ? 0.0 : 1.5

  # Whole comparisons, in worker processes (two of each version, unless
  # the settings given say): the candidate's .duel.rb, its resources
  # started for each, and the configuration as it was after.
  def test_compare
    base = project(File.join(tmpdir, "base"))
    same = project(File.join(tmpdir, "same"))
    slower = project(File.join(tmpdir, "slower"), work: 6000)
    File.write(File.join(same, ".duel.rb"), <<~RUBY)
      Duel.configure do |c|
        c.measure("cpu", limit: 1.5)
        c.resource { |r| File.write(File.join(r.root, r.name), "") && {} }
      end
    RUBY
    config = Duel.config
    passed = Duel::Testing.compare(base, same, warm: warm)

    assert_predicate passed, :passed?
    assert_equal ["work"], passed.results.map(&:name)
    assert_in_delta 1.5, passed["work"].timed.fetch("cpu").fetch("limit")
    assert_equal %w[base/baseline-1 base/baseline-2 same/candidate-1 same/candidate-2], Dir[File.join(tmpdir, "*", "*-?")].map { |path| path.delete_prefix("#{tmpdir}/") }
    assert_includes passed.output, "1 benchmarks in"
    assert_same config, Duel.config
    failed = Duel::Testing.compare(base, slower, warm: warm, processes: 1, limit: 1.1)

    refute_predicate failed, :passed?
    assert_includes failed["work"].regressed, "cpu"
    assert_in_delta 1.1, failed["work"].timed.fetch("cpu").fetch("limit")
    assert_same config, Duel.config, "as it was"
  end
end
