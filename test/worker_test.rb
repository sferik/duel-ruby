# frozen_string_literal: true

require_relative "test_helper"

# What a config file's hooks ran with (see test_main_reads_a_config_file).
module ConfigProbe
  class << self
    attr_accessor :loaded, :supported, :worker, :stopped
  end
end

class WorkerTest < DuelTest
  cover "Duel::Worker*"

  class Calls < Duel::Metric
    class << self
      attr_accessor :calls, :n
    end
    self.calls = 0

    def start(sample) = (@started = Calls.calls) && (Calls.n = sample.n)

    def stop = Calls.calls - @started

    def details = "#{Calls.calls - @started} calls"
  end

  class Unavailable < Duel::Metric
    def self.available? = false
  end

  def test_hello_lists_benchmarks_and_metrics
    duel("a", only: :count) { 1 }
    hello = Duel::Worker.new([Calls, Unavailable]).hello

    assert_equal [{"name" => "a", "only" => "count", "peak_memory" => false}], hello.fetch("benchmarks")
    names = %w[calls] + ((RUBY_ENGINE == "ruby") ? %w[allocations] : []) + (INSTRUCTIONS ? %w[instructions] : []) + %w[cpu]

    assert_equal names, hello.fetch("metrics").map { |m| m.fetch("name") }, "plugins outermost, CPU innermost"
    assert_equal RUBY_DESCRIPTION, hello.fetch("ruby")
  end

  # Config#measure: a measure's settings changed, or it left out (and a
  # metric whose measures all are, not made at all).
  def test_measures_changed_and_skipped
    specs = Duel::Worker.new([Calls], {"calls" => {tolerance: 3}, "cpu" => {limit: 1.05}}).hello.fetch("metrics")

    assert_equal [3, 1.05], [specs.first.fetch("tolerance"), specs.last.fetch("limit")]
    made = 0
    counted = Class.new(Calls) do
      def self.metric_name = "calls"

      define_method(:initialize) { made += 1 }
    end
    hello = Duel::Worker.new([counted], {"calls" => {skip: true}}).hello

    refute_includes hello.fetch("metrics").map { |m| m.fetch("name") }, "calls"
    assert_equal 0, made
  end

  class Pair < Duel::Metric
    def self.measures = {"rows" => {}, "pages" => {}}
  end

  # A metric with a measure skipped, and one not: it's made, with only
  # the other.
  def test_one_of_a_metrics_measures_skipped
    names = Duel::Worker.new([Pair], {"rows" => {skip: true}, "pages" => {skip: false}}).hello.fetch("metrics").map { |m| m.fetch("name") }

    assert_includes names, "pages"
    refute_includes names, "rows"
  end

  # Each metric gets its settings, with the config's changes; a metric's
  # own setting there isn't fails.
  def test_metrics_see_their_settings
    metrics, = Duel::Worker.made([Calls], {"calls" => {allowance: 32}})

    assert_equal 32, metrics.first.settings.fetch("calls").fetch(:allowance)
    typo = Class.new(Calls) { def self.measures = {"calls" => {alowance: 1}} }
    error = assert_raises(Duel::Error) { Duel::Worker.made([typo], {}) }

    assert_match(/\Acalls: no setting alowance/, error.message)
  end

  def test_measures_must_be_known_and_measured_once
    error = assert_raises(Duel::Error) { Duel::Worker.new([Calls], {"nope" => {limit: 2}, "nor" => {}}) }

    assert_equal "no metric measures nope, nor (c.measure)", error.message
    error = assert_raises(Duel::Error) { Duel::Worker.new([Calls, Pair, Class.new(Calls) { def self.metric_name = "calls" }, Pair]) }

    assert_equal "more than one metric measures calls, rows, pages", error.message
    Duel::Worker.new([Unavailable], {"unavailable" => {limit: 2}}) # (known, though not here)
  end

  def test_hello_tells_whether_memory_and_profiles_can_be_measured
    worker = Duel::Worker.new
    hello = stub(Duel::Native::Memory, :resident, -> { 1 }) { stub(Duel::Worker, :profiler?, -> { true }) { worker.hello } }

    assert_equal [true, true], hello.values_at("memory", "profiler")
    hello = stub(Duel::Native::Memory, :resident, -> {}) { stub(Duel::Worker, :profiler?, -> { false }) { worker.hello } }

    assert_equal [false, false], hello.values_at("memory", "profiler")
  end

  # Setting a benchmark up runs its file's setup blocks, then the
  # benchmark once (one iteration, nothing measured, with its own setup),
  # to see it runs.
  def test_setup_runs_the_benchmark_once
    runs = []
    Duel.setups[__FILE__] << -> { @prepared = true }
    duel("a") do |n|
      setup { runs << :setup }
      runs << [n, @prepared]
    end
    Duel::Worker.new.handle("op" => "setup", "name" => "a")

    assert_equal [:setup, [1, true]], runs
  end

  def test_setup_sample_and_teardown
    torn = []
    duel("a") { Calls.calls += 1 }
    Duel.teardowns[__FILE__] << -> { torn << :done }
    worker = Duel::Worker.new([Calls])

    assert_equal({"ok" => true}, worker.handle("op" => "setup", "name" => "a"))
    reply = worker.handle("op" => "sample", "name" => "a", "n" => 7, "runs" => 3, "count" => true)

    assert_equal timed_metrics.sort, reply.fetch("timed").keys.sort
    assert_equal 7, reply.fetch("counted").fetch("calls")
    assert_equal({"calls" => "7 calls"}, reply.fetch("details"), "what metrics said of it")
    assert_equal 7, Calls.n, "a sample of n"
    assert_equal({"ok" => true}, worker.handle("op" => "teardown", "name" => "a"))
    assert_equal [:done], torn
    assert_equal({"ok" => true}, worker.handle("op" => "teardown", "name" => "a"), "twice is harmless")
  end

  def test_a_sample_reports_each_timed_metrics_least
    times = [5, 3, 9, 8]
    fake = Class.new(Duel::Metric) do
      def self.measures = {"fake" => {kind: :ratio}}

      define_method(:stop) { times.shift }
    end
    duel("a") { 1 }
    worker = Duel::Worker.new([fake])
    worker.handle("op" => "setup", "name" => "a")
    reply = worker.handle("op" => "sample", "name" => "a", "n" => 1, "runs" => 3)

    assert_equal 3, reply.fetch("timed").fetch("fake")
    assert_empty reply.fetch("counted")
    assert_kind_of Integer, reply.fetch("heap")
    assert_equal 8, worker.handle("op" => "sample", "name" => "a", "n" => 1).fetch("timed").fetch("fake"), "one run by default"
  end

  def test_errors_are_answered
    duel("bad") { raise "oops" }
    worker = Duel::Worker.new
    reply = worker.handle("op" => "setup", "name" => "bad")

    assert_equal "RuntimeError: oops", reply.fetch("error")
    assert_equal 5, reply.fetch("backtrace").size, "where it went wrong, no more"
    assert_match(/worker_test\.rb/, reply.fetch("backtrace").first)
    assert_equal "KeyError: key not found: \"nope\"", worker.handle("op" => "setup", "name" => "nope").fetch("error")
    assert_equal 'ArgumentError: unknown request {"op" => "dance", "name" => "x"}',
      worker.handle("op" => "dance", "name" => "x").fetch("error")
  end

  # The worker's main loop, in this process, over a real socket.
  def test_main_loads_a_version_and_answers_over_the_socket
    root = project(File.join(tmpdir, "version"))
    File.write(File.join(root, "duel", "duel_helper.rb"), "ConfigProbe.supported = true\n")
    File.write(File.join(root, "duel", "probe_duel.rb"), %(require_relative "duel_helper"\n))
    control = File.join(short_tmpdir, "c.sock")
    server = UNIXServer.new(control)
    collections = []
    collect = GC.method(:start)
    worker = stub(GC, :start, ->(**options) { (collections << options) && collect.call(**options) }) do
      Thread.new { Duel::Worker.main(File.join(root, "..", "version"), root, control) }.tap { server = server.accept }
    end
    hello = JSON.parse(server.gets)

    assert_equal ["work"], hello.fetch("benchmarks").map { |b| b.fetch("name") }
    server.puts JSON.generate({"op" => "setup", "name" => "work"})

    assert_equal({"ok" => true}, JSON.parse(server.gets))
    server.close
    worker.join(5)

    refute_predicate worker, :alive?
    assert_equal File.join(root, "lib"), $LOAD_PATH.first, "the version's lib/, first"
    assert_equal root, Duel.config.root, "the conventions, from the candidate's root"
    assert ConfigProbe.supported, "a helper the benchmarks require"
    assert_includes collections, {}, "a full collection before it begins"
  ensure
    ConfigProbe.supported = nil
    $LOAD_PATH.delete(File.join(root, "lib"))
  end

  def test_main_reads_a_config_file
    root = project(File.join(tmpdir, "configured"), benchmarks: nil)
    FileUtils.mkdir_p(File.join(root, "perf"))
    File.write(File.join(root, "perf", "b.rb"), 'duel("configured") { 1 }')
    File.write(File.join(root, ".duel.rb"), <<~RUBY)
      class ProbeMetric < Duel::Metric; end

      Duel.configure do |c|
        c.benchmarks = "perf/*.rb"
        c.load_version { |r| ConfigProbe.loaded = r }
        c.metric ProbeMetric
        c.worker do |w|
          ConfigProbe.worker = Duel.benchmarks.keys
          w.at_stop { ConfigProbe.stopped = true }
        end
        c.measure("probe_metric", tolerance: 4)
      end
    RUBY
    control = File.join(short_tmpdir, "c.sock")
    server = UNIXServer.new(control)
    worker = Thread.new { Duel::Worker.main(root, root, control, File.join(root, ".duel.rb")) }
    socket = server.accept

    hello = JSON.parse(socket.gets)

    assert_equal ["configured"], hello.fetch("benchmarks").map { |b| b.fetch("name") }
    assert_equal ["probe_metric", 4], hello.fetch("metrics").first.values_at("name", "tolerance"), "the config's metrics, and its changes"
    assert_equal root, ConfigProbe.loaded
    assert_equal ["configured"], ConfigProbe.worker, "its worker blocks, once the benchmarks have loaded"
    refute ConfigProbe.stopped
    socket.close
    worker.join(5)

    assert ConfigProbe.stopped, "and their stops, once it's done"
  ensure
    ConfigProbe.loaded = nil
    ConfigProbe.worker = nil
    ConfigProbe.stopped = nil
  end
end

class WorkerRequestsTest < DuelTest
  cover "Duel::Worker*"

  def worker
    @worker ||= new_worker
  end

  def new_worker
    duel("hold") { ("x" * (8 << 20)).size }
    duel("spin") { 50_000.times { Math.sqrt(2) } }
    Duel::Worker.new.tap do |w|
      w.handle("op" => "setup", "name" => "hold")
      w.handle("op" => "setup", "name" => "spin")
    end
  end

  # Set up without its trial (for peak memory), a benchmark hasn't run.
  def test_setup_without_a_trial
    runs = 0
    duel("counted") { runs += 1 }
    w = Duel::Worker.new
    w.handle("op" => "setup", "name" => "counted", "trial" => false)

    assert_equal 0, runs
    w.handle("op" => "setup", "name" => "counted")

    assert_equal 1, runs
  end

  # Without a trial, a benchmark's own setup runs in its memory sample.
  def test_memory_without_a_trial
    skip "no way to tell resident memory here" unless Duel::Native::Memory.resident

    duel("set up") do
      setup { @input = "x" * 1024 }
      @input.size
    end
    w = Duel::Worker.new
    w.handle("op" => "setup", "name" => "set up", "trial" => false)
    reply = w.handle("op" => "memory", "name" => "set up", "n" => 2)

    assert_kind_of Integer, reply.fetch("peak"), reply.inspect
  end

  def test_memory
    skip "no way to tell resident memory here" unless Duel::Native::Memory.resident

    reply = worker.handle("op" => "memory", "name" => "hold", "n" => 3)

    assert_kind_of Integer, reply.fetch("peak")
    assert_operator reply.fetch("peak"), :>=, 0
    assert worker.hello.fetch("memory")
  end

  # Profiles of two runs, from a StackProf faked.
  def test_profile_merges_every_runs_frames_exactly
    profiles = [
      {samples: 3, frames: {1 => {name: "a", samples: 1, total_samples: 3}, 2 => {name: "b", samples: 2, total_samples: 2}}},
      {samples: 2, frames: {3 => {name: "a", samples: 0, total_samples: 2}}}
    ]
    required = []
    stack_prof = Module.new do
      define_singleton_method(:start) { |**| nil }
      define_singleton_method(:stop) { nil }
      define_singleton_method(:results) { profiles.shift }
    end
    w = worker
    w.define_singleton_method(:require) { |feature| required << feature }
    reply = with_constants(Object, StackProf: stack_prof) { w.handle("op" => "profile", "name" => "spin", "n" => 1, "runs" => 2) }

    assert_equal({"samples" => 5, "frames" => [["a", 1, 5], ["b", 2, 2]]}, reply)
    assert_equal ["stackprof"], required
  end

  def test_profile_merges_every_runs_frames
    skip "StackProf is CRuby's" unless RUBY_ENGINE == "ruby"

    reply = worker.handle("op" => "profile", "name" => "spin", "n" => 4, "runs" => 3)
    frames = reply.fetch("frames")

    assert_operator reply.fetch("samples"), :>, 0
    assert(frames.all? { |frame, own, total| frame.is_a?(String) && own <= total })
    assert_equal frames.sort_by { |_, _, total| -total }, frames, "most total first"
    refute_empty frames
  end

  def test_profiler
    assert_equal RUBY_ENGINE == "ruby", Duel::Worker.profiler?
    Duel::Worker.define_singleton_method(:require) { |_| raise LoadError }

    refute_predicate Duel::Worker, :profiler?
  ensure
    Duel::Worker.singleton_class.remove_method(:require)
  end
end
