# frozen_string_literal: true

require_relative "test_helper"

# What a config file's hooks ran with (see test_main_reads_a_config_file).
module ConfigProbe
  class << self
    attr_accessor :loaded, :supported, :worker, :stopped, :ended
  end
end

class WorkerTest < DuelTest
  cover "Duel::Worker*"

  class Calls < Duel::Metric
    class << self
      attr_accessor :calls, :n
    end
    self.calls = 0

    def start_sample(sample) = (@started = Calls.calls) && (Calls.n = sample.n)

    def stop_sample = Calls.calls - @started

    def details = "#{Calls.calls - @started} calls"
  end

  class Unavailable < Duel::Metric
    def self.available? = false
  end

  def test_hello_lists_benchmarks_and_metrics
    duel("a", only: :count) { 1 }
    hello = Duel::Worker.new([Calls, Unavailable]).hello

    assert_equal [{"name" => "a", "only" => "count", "peak_memory" => false, "process" => nil}], hello.fetch("benchmarks")
    names = %w[calls] + (INSTRUCTIONS ? %w[instructions] : []) + ((RUBY_ENGINE == "ruby") ? %w[allocations] : []) + %w[cpu]

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

  # Each metric gets its settings, with the config's changes. A metric's
  # own setting there isn't fails.
  def test_metrics_see_their_settings
    metrics, = Duel::Worker.made([Calls], {"calls" => {allowance: 32}})

    assert_equal [32, :counted], metrics.first.settings.fetch("calls").values_at(:allowance, :kind), "resolved: the rest as by default"
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
    hello = stub(Duel::Native::Memory, :resident, -> { 1 }) do
      stub(Duel::Worker, :profiler?, -> { true }) { stub(Duel::Worker, :yjit?, -> { true }) { worker.hello } }
    end

    assert_equal [true, true, true], hello.values_at("memory", "profiler", "yjit")
    hello = stub(Duel::Native::Memory, :resident, -> {}) do
      stub(Duel::Worker, :profiler?, -> { false }) { stub(Duel::Worker, :yjit?, -> { false }) { worker.hello } }
    end

    assert_equal [false, false, false], hello.values_at("memory", "profiler", "yjit")
  end

  # The native extensions loaded, by feature (from the directory on the
  # load path they were found in, or by name), at their real paths: what
  # the runner checks each version's are its own by.
  def test_extensions
    dlext = RbConfig::CONFIG["DLEXT"]
    lib = FileUtils.mkdir_p(File.join(tmpdir, "real", "lib", "my_gem")).first.then { |dir| File.dirname(dir) }
    File.symlink(File.join(tmpdir, "real"), File.join(tmpdir, "linked"))
    linked = File.join(tmpdir, "linked", "lib")
    elsewhere = short_tmpdir
    built = [File.join(linked, "my_gem", "ext.#{dlext}"), File.join(elsewhere, "other.#{dlext}"), File.join(lib, "plain.rb"),
      File.join(lib, "not.#{dlext}.rb")].each { |path| File.write(path, "") }
    features = ["enumerator.#{dlext}", *built]
    extensions = Duel::Worker.extensions(features, [tmpdir, File.join(tmpdir, "linked", "x", "..", "lib"), "/nowhere", File.join(tmpdir, "linked")])

    assert_equal({"my_gem/ext.#{dlext}" => File.join(File.realpath(lib), "my_gem", "ext.#{dlext}"),
                  "other.#{dlext}" => File.realpath(File.join(elsewhere, "other.#{dlext}"))}, extensions)
    hello = Duel::Worker.new.hello

    assert_equal Duel::Worker.extensions($LOADED_FEATURES, $LOAD_PATH), Duel::Worker.extensions, "this process's"
    assert_equal Duel::Worker.extensions, hello.fetch("extensions")
  end

  # The directories gems are installed in (that are there), at their
  # real paths, each once: what the runner tells an installed gem's
  # extension from a build by.
  def test_gem_dirs
    real = FileUtils.mkdir_p(File.join(tmpdir, "vendor", "bundle", "ruby", "4.0.0")).first
    File.symlink(File.join(tmpdir, "vendor"), File.join(tmpdir, "linked"))
    File.write(File.join(tmpdir, "file"), "")
    dirs = [File.join(tmpdir, "linked", "bundle", "ruby", "4.0.0"), "/nowhere", File.join(tmpdir, "file"), real]

    assert_equal [File.join(File.realpath(real), "")], Duel::Worker.gem_dirs(dirs)
    assert_equal Duel::Worker.gem_dirs(Gem.path), Duel::Worker.gem_dirs, "this process's"
    assert_equal Duel::Worker.gem_dirs, Duel::Worker.new.hello.fetch("gem_dirs")
  end

  # Setting a benchmark up runs its setup hooks, then the benchmark once
  # (one iteration, nothing measured, with its once blocks), to see it
  # runs.
  def test_setup_runs_the_benchmark_once
    runs = []
    Duel.file_hooks[__FILE__][:setup] << -> { @prepared = true }
    duel("a") do |n|
      once { runs << :setup }
      runs << [n, @prepared]
    end
    Duel::Worker.new.handle("op" => "setup", "name" => "a")

    assert_equal [:setup, [1, true]], runs
  end

  def test_setup_sample_and_teardown
    torn = []
    duel("a") { Calls.calls += 1 }
    Duel.file_hooks[__FILE__][:teardown] << -> { torn << :done }
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

      define_method(:stop_sample) { times.shift }
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
        c.load { |r| ConfigProbe.loaded = r }
        c.metric ProbeMetric
        c.in_worker do |w|
          ConfigProbe.worker = Duel.benchmarks.keys
          w.at_stop { (ConfigProbe.ended << :stopped) && (ConfigProbe.stopped = true) }
        end
        c.measure("probe_metric", tolerance: 4)
        c.metric("probe_totals") { 1 }.open { ConfigProbe.ended << :opened }.close { ConfigProbe.ended << :closed }
        c.setup { ConfigProbe.ended << :setup }
        c.before_sample { |_| ConfigProbe.ended << :before }
        c.after_iterations { ConfigProbe.ended << :after }
      end
    RUBY
    ConfigProbe.ended = []
    control = File.join(short_tmpdir, "c.sock")
    server = UNIXServer.new(control)
    worker = Thread.new { Duel::Worker.main(root, root, control, File.join(root, ".duel.rb")) }
    socket = server.accept

    hello = JSON.parse(socket.gets)

    assert_equal ["configured"], hello.fetch("benchmarks").map { |b| b.fetch("name") }
    assert_equal ["probe_metric", 4], hello.fetch("metrics").first.values_at("name", "tolerance"), "the config's metrics, and its changes"
    assert_equal root, ConfigProbe.loaded
    assert_equal ["configured"], ConfigProbe.worker, "its in_worker blocks, once the benchmarks have loaded"
    refute ConfigProbe.stopped
    socket.puts JSON.generate({"op" => "setup", "name" => "configured"})

    assert_equal({"ok" => true}, JSON.parse(socket.gets))
    socket.close
    worker.join(5)

    assert ConfigProbe.stopped, "and their stops, once it's done"
    assert_equal %i[opened setup before after closed stopped], ConfigProbe.ended,
      "its metrics opened, the config's hooks, in the trial, and its metrics closed first"
  ensure
    ConfigProbe.ended = nil
    ConfigProbe.loaded = nil
    ConfigProbe.worker = nil
    ConfigProbe.stopped = nil
  end
end

class WorkerHooksTest < DuelTest
  cover "Duel::Worker*"

  # A helper named as one of Duel's own methods fails the worker, once
  # the benchmarks have loaded.
  def test_main_checks_the_helpers
    root = project(File.join(tmpdir, "clash"))
    File.write(File.join(root, "duel", "duel_helper.rb"), "def untimed = :mine\n")
    File.write(File.join(root, "duel", "helped_duel.rb"), %(require_relative "duel_helper"\n))
    error = assert_raises(Duel::Error) { Duel::Worker.main(root, root, File.join(short_tmpdir, "c.sock")) }

    assert_equal "#{File.join(File.realpath(root), "duel", "duel_helper.rb")}:1: a helper can't be named untimed, Duel's is: rename it", error.message
  ensure
    Object.send(:remove_method, :untimed) if Object.private_method_defined?(:untimed, false)
    $LOAD_PATH.delete(File.join(root, "lib"))
  end

  # A worker whose metrics can't be made still runs its blocks' stops.
  def test_main_with_metrics_it_cant_make
    root = project(File.join(tmpdir, "unmade"))
    File.write(File.join(root, ".duel.rb"), <<~RUBY)
      Duel.configure do |c|
        c.in_worker { |w| w.at_stop { ConfigProbe.stopped = true } }
        c.measure("nope", limit: 2)
      end
    RUBY
    error = assert_raises(Duel::Error) { Duel::Worker.main(root, root, File.join(short_tmpdir, "c.sock"), File.join(root, ".duel.rb")) }

    assert_equal "no metric measures nope (c.measure)", error.message
    assert ConfigProbe.stopped
  ensure
    ConfigProbe.stopped = nil
    $LOAD_PATH.delete(File.join(root, "lib"))
  end

  # Logs when it's closed.
  class Closed < Duel::Metric
    def initialize(log)
      super()
      @log = log
    end

    def close = @log << self.class
  end

  class Other < Closed; end

  # Closing a worker closes its metrics, last first.
  def test_close
    log = []
    worker = Duel::Worker.new
    worker.instance_variable_set(:@metrics, [Closed.new(log), Other.new(log)])
    worker.close

    assert_equal [Other, Closed], log
  end

  # A metric that measures 3 every stretch.
  class Three < Duel::Metric
    def self.measures = {"three" => {kind: :ratio}}

    def stop_sample = 3
  end

  # The config's hooks, around every sample. With around_iteration hooks,
  # what pausing and resuming leaves is taken from each iteration (none
  # left of Three's 3 a stretch).
  def test_hooks_and_around
    log = []
    duel("a") { log << :iteration }
    duel("around", around_iteration: ->(iteration) { iteration.call }) { nil }
    hooks = Duel::NO_HOOKS.merge(before_sample: [->(benchmark) { log << benchmark.name }], after_iterations: [-> { log << :after }])
    worker = Duel::Worker.new([Three], hooks: hooks)
    worker.handle("op" => "setup", "name" => "a", "trial" => false)
    worker.handle("op" => "sample", "name" => "a", "n" => 2)

    assert_equal ["a", :iteration, :iteration, :after], log
    worker.handle("op" => "setup", "name" => "around", "trial" => false)
    reply = worker.handle("op" => "sample", "name" => "around", "n" => 5, "runs" => 2)

    assert_equal 6, reply.fetch("timed").fetch("three"), "two stretches' worth: to the start, and from the stop"
  end

  # A server, on a thread of its own, that counts the commands it's sent
  # (a line each), and answers STATS, itself one, with how many so far.
  class Server
    def initialize
      @client, server = UNIXSocket.pair
      @thread = Thread.new do
        commands = 0
        while (line = server.gets)
          commands += 1
          server.puts commands if line == "STATS\n"
        end
      end
    end

    def command(text) = @client.puts(text)

    def stats
      @client.puts "STATS"
      Integer(@client.gets)
    end

    def close
      @client.close
      @thread.join
    end
  end

  # Running totals read from a server (Server), costly or not, count only
  # what each iteration sent it: not what its around_iteration hook sent
  # (BEGIN and ROLLBACK) around it, nor the readings' own STATS. Costly to read,
  # they're read only at a sample's ends, not around each iteration.
  def test_a_costly_server_metric_counts_only_the_iterations
    server = Server.new
    reads = 0
    around = lambda do |iteration|
      server.command("BEGIN")
      iteration.call
      server.command("ROLLBACK")
    end
    duel("insert", around_iteration: around) { server.command("INSERT") }
    [false, true].map do |costly|
      config = Duel::Config.new
      metric = config.metric("commands") { (reads += 1) && server.stats }
      metric.costly if costly
      worker = Duel::Worker.new(config.metrics)
      worker.handle("op" => "setup", "name" => "insert")
      worker.handle("op" => "sample", "name" => "insert", "n" => 50, "count" => true) # (learning what the block adds)
      reads = 0
      reply = worker.handle("op" => "sample", "name" => "insert", "n" => 50, "count" => true)

      assert_equal 50, reply.fetch("counted").fetch("commands"), "costly: #{costly}"
      assert_equal costly ? 2 : 104, reads, "around the sample, and the hook, and each iteration"
      worker.close
    end
  ensure
    server&.close
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
      once { @input = "x" * 1024 }
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

  # A profile, from a StackProf faked: started once, for every sample
  # (and stopped, however they end), with each sample's stack.
  def test_profile_runs_stackprof_throughout
    results = {frames: {1 => {name: "Duel::Harness#iterate"}, 2 => {name: "a"}}, raw: [2, 1, 2, 3, 1, 1, 1]}
    started = []
    stopped = []
    stack_prof = Module.new do
      define_singleton_method(:start) { |**options| started << options }
      define_singleton_method(:stop) { stopped << GC.enable }
      define_singleton_method(:results) { results }
    end
    runs = 0
    duel("count") { runs += 1 }
    duel("broken") { raise "oops" }
    w = Duel::Worker.new
    w.handle("op" => "setup", "name" => "count", "trial" => false)
    w.handle("op" => "setup", "name" => "broken", "trial" => false)
    required = []
    w.define_singleton_method(:require) { |feature| required << feature }
    reply = with_constants(Object, StackProf: stack_prof) { w.handle("op" => "profile", "name" => "count", "n" => 3, "runs" => 2) }

    assert_equal({"samples" => 4, "frames" => [["Duel::Harness#iterate", 1, 4], ["a", 3, 3]]}, reply)
    assert_equal [{mode: Duel::ProfileSample::MODE, interval: Duel::ProfileSample::INTERVAL, raw: true}], started
    assert_equal [false], stopped, "after every sample (the collector let go)"
    assert_equal 6, runs, "two samples of three"
    assert_equal ["stackprof"], required
    reply = with_constants(Object, StackProf: stack_prof) { w.handle("op" => "profile", "name" => "broken", "n" => 1, "runs" => 1) }

    assert_equal "RuntimeError: oops", reply.fetch("error")
    assert_equal 2, stopped.size, "stopped all the same"
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

  # Untimed work, a large share of the run, isn't in its profile.
  def test_a_profile_leaves_untimed_work_out
    skip "StackProf is CRuby's" unless RUBY_ENGINE == "ruby"

    duel("partly untimed") do
      untimed { 20_000.times { Math.cbrt(2) } }
      20_000.times { Math.sqrt(2) }
    end
    w = Duel::Worker.new
    w.handle("op" => "setup", "name" => "partly untimed")
    names = w.handle("op" => "profile", "name" => "partly untimed", "n" => 1, "runs" => 20).fetch("frames").map(&:first)

    assert_includes names, "Math.sqrt"
    refute_includes names, "Math.cbrt"
  end

  # YJIT is on where Ruby has it, and it's enabled (by an app, say).
  def test_yjit
    skip "no YJIT here" unless defined?(RubyVM::YJIT)

    assert stub(RubyVM::YJIT, :enabled?, -> { true }) { Duel::Worker.yjit? }
    refute stub(RubyVM::YJIT, :enabled?, -> { false }) { Duel::Worker.yjit? }
  end

  def test_no_yjit_without_it
    skip "YJIT here" if defined?(RubyVM::YJIT)

    refute_predicate Duel::Worker, :yjit?
  end

  # StackProf, where it's installed (it is, here, on CRuby: the bundle
  # has it on CRuby's platforms only).
  def test_profiler
    assert_equal RUBY_ENGINE == "ruby", Duel::Worker.profiler?
    assert_equal RUBY_ENGINE == "ruby", Duel::Worker.profiler?("ruby")
    Duel::Worker.define_singleton_method(:require) { |_| raise LoadError }

    refute_predicate Duel::Worker, :profiler?
    refute Duel::Worker.profiler?("ruby")
  ensure
    Duel::Worker.singleton_class.remove_method(:require)
  end

  # No profiles on JRuby or TruffleRuby, even with StackProf loadable
  # (TruffleRuby installs it, but it fails to start there): it isn't
  # even required.
  def test_no_profiler_but_on_cruby
    required = []
    Duel::Worker.define_singleton_method(:require) { |feature| required << feature }

    assert Duel::Worker.profiler?("ruby")
    assert_equal ["stackprof"], required
    %w[jruby truffleruby].each { |engine| refute Duel::Worker.profiler?(engine), engine }
    assert_equal ["stackprof"], required, "not required elsewhere"
  ensure
    Duel::Worker.singleton_class.remove_method(:require)
  end
end
