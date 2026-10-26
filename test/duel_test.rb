# frozen_string_literal: true

require_relative "test_helper"

class DuelModuleTest < DuelTest
  cover "Duel.config"
  cover "Duel.configure"
  cover "Duel.load_config"
  cover "Duel.benchmarks"

  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Duel::VERSION)
  end

  def test_config_defaults_and_configure
    Duel.config = nil

    assert_equal Dir.pwd, Duel.config.root
    Duel.configure { |c| c.build = "make" }

    assert_equal "make", Duel.config.build
  end

  def test_load_config_roots_it_where_the_file_is
    path = File.join(tmpdir, "project", ".duel.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'Duel.configure { |c| c.benchmarks = "perf/*.rb" }')
    config = Duel.load_config(path)

    assert_same config, Duel.config
    assert_equal File.join(tmpdir, "project"), config.root
    assert_equal "perf/*.rb", config.benchmarks
  end

  def test_load_config_from_a_relative_path
    FileUtils.mkdir_p(File.join(tmpdir, "lib"))
    File.write(File.join(tmpdir, "lib", ".duel.rb"), 'Duel.configure { |c| c.benchmarks = "wrong/*.rb" }')
    File.write(File.join(tmpdir, ".duel.rb"), 'Duel.configure { |c| c.benchmarks = "right/*.rb" }')
    $LOAD_PATH.unshift(File.join(tmpdir, "lib"))
    config = Dir.chdir(tmpdir) { Duel.load_config(".duel.rb") }

    assert_equal [File.realpath(tmpdir), "right/*.rb"], [File.realpath(config.root), config.benchmarks]
    assert_equal config.root, File.expand_path(config.root), "absolute"
  ensure
    $LOAD_PATH.delete(File.join(tmpdir, "lib"))
  end
end

class ConfigTest < DuelTest
  cover "Duel::Config*"
  cover "Duel.plugin"
  cover "Duel.plugins"

  def test_defaults
    assert_equal Dir.pwd, Duel::Config.new.root
    config = Duel::Config.new("/project")

    assert_equal "/project", config.root
    assert_equal "duel/**/*_duel.rb", config.benchmarks
    assert_equal %w[lib ext], config.watch
    assert_nil config.build, "no ext/"
    assert_nil config.main_branch, "origin/HEAD's"
    assert_nil config.library, "no gemspec"
    assert_equal "v*", config.release_tags
    assert_equal({version: [], worker: []}, config.prepares)
    assert_equal Duel::HOOKS.to_h { |hook| [hook, []] }, config.hooks
    assert_empty config.in_workers
    assert_empty config.plugins
    assert_empty config.metrics
  end

  def test_load_into_puts_lib_first_by_default
    config = Duel::Config.new(tmpdir)
    # (No gemspec: nothing to require.)
    assert_equal [tmpdir, nil], [config.root, config.library]
    config.load_into("/version")

    assert_equal "/version/lib", $LOAD_PATH.first
  ensure
    $LOAD_PATH.delete("/version/lib")
  end

  def test_load_replaces_how
    config = Duel::Config.new(tmpdir)
    loaded = []
    config.load { |root| loaded << root }
    config.load_into("/version")

    assert_equal ["/version"], loaded
    refute_includes $LOAD_PATH, "/version/lib"
  end

  def test_prepare_blocks_and_metrics
    config = Duel::Config.new
    worker = proc { 2 }
    version = proc { 3 }
    config.prepare(:worker, &worker)
    config.prepare(:version, &version)
    config.metric(Duel::Metric)

    assert_equal({version: [version], worker: [worker]}, config.prepares)
    assert_equal [Duel::Metric], config.metrics
    error = assert_raises(ArgumentError) { config.prepare(:run) { {} } }

    assert_equal "prepare(:version) or prepare(:worker), not prepare(:run)", error.message
    error = assert_raises(ArgumentError) { config.prepare(:worker) }

    assert_equal "prepare(:worker): give a block", error.message
    assert_equal({version: [version], worker: [worker]}, config.prepares, "nothing added")
  end

  # When the workflow comments on a pull request: on failures unless set,
  # and only when set to a mode there is.
  def test_comment
    config = Duel::Config.new

    assert_equal :failures, config.comment
    config.comment = :results

    assert_equal :results, config.comment
    error = assert_raises(Duel::Error) { config.comment = "never" }

    assert_equal 'c.comment = "never": give :always, :results, :failures, :never', error.message
    assert_equal :results, config.comment, "unchanged"
    assert_equal %i[always results failures never], Duel::Config::COMMENTS
    assert_predicate Duel::Config::COMMENTS, :frozen?
  end

  # Which runs a regression fails: every run unless set, and only when
  # set to runs there are.
  def test_fail_on
    config = Duel::Config.new

    assert_equal :every_run, config.fail_on
    config.fail_on = :pull_requests

    assert_equal :pull_requests, config.fail_on
    error = assert_raises(Duel::Error) { config.fail_on = "every_run" }

    assert_equal 'c.fail_on = "every_run": give :every_run, :pull_requests', error.message
    assert_equal :pull_requests, config.fail_on, "unchanged"
    assert_equal %i[every_run pull_requests], Duel::Config::FAIL_ON
    assert_predicate Duel::Config::FAIL_ON, :frozen?
  end

  # Each version's Ruby: the runner's unless set.
  def test_ruby
    config = Duel::Config.new

    assert_nil config.ruby
    config.ruby = :version_file

    assert_equal :version_file, config.ruby
  end

  # Blocks for workers, and measures' settings changed by name.
  def test_in_worker_blocks_and_measures
    config = Duel::Config.new
    made = config.in_worker { |w| w }
    config.measure("cpu", limit: 1.05)
    config.measure("cpu", floor: 5)
    config.measure("rows", skip: true)

    assert_instance_of Duel::InWorker, made
    assert_equal 1, config.in_workers.size
    assert_equal({"cpu" => {limit: 1.05, floor: 5}, "rows" => {skip: true}}, config.measures)
    assert_equal [true, false, false], %w[rows cpu pages].map { |name| config.skip?(name) }
    config.measure("rows", skip: false)

    refute config.skip?("rows")
    assert_equal %w[cpu rows], config.measures.keys, "nothing added by asking"
  end

  # What an in_worker block returns, in the worker it ran in (its Stops),
  # forgotten when the worker ends, after what the block gave at_stop.
  def test_in_worker_values
    config = Duel::Config.new
    log = []
    made = config.in_worker do |w|
      w.at_stop { log << [:closed, made.value] }
      :connection
    end
    error = assert_raises(Duel::Error) { made.value }

    assert_equal "made in each worker only (c.in_worker): in tests, inside Duel::Testing.in_worker", error.message
    stops = Duel::Stops.new
    config.in_workers.each { |block| block.call(stops) }

    assert_equal :connection, made.value
    assert_raises(Duel::Error) { stops.run }
    assert_empty log, "forgotten first"
    nothing = config.in_worker { |_| nil }
    config.in_workers.last.call(Duel::Stops.new)

    assert_nil nothing.value, "nil, made"
  end

  # The hooks, in the order they were given, by name: a hook is a block,
  # and around_iteration's takes the iteration.
  def test_hooks
    config = Duel::Config.new
    hooks = Duel::HOOKS.to_h { |hook| [hook, (hook == :around_iteration) ? proc { |_iteration| hook } : proc { hook }] }
    hooks.each { |hook, block| config.public_send(hook, &block) }
    config.setup(&hooks.fetch(:setup))

    assert_equal hooks.transform_values { |block| [block] }.merge(setup: [hooks.fetch(:setup)] * 2), config.hooks
    error = assert_raises(ArgumentError) { config.after_iterations }

    assert_equal "after_iterations: give a block (or a lambda), not nil", error.message
    error = assert_raises(ArgumentError) { config.around_iteration { nil } }

    assert_equal "around_iteration: take the iteration, and run it: { |iteration| ... iteration.call ... }", error.message
    assert_raises(ArgumentError) { config.around_iteration { |iteration, _more| iteration.call } }
    assert_equal 1, config.hooks.fetch(:around_iteration).size, "nothing added"
  end

  # A plugin, by name: required (duel/<name>), and configured with its
  # options, once (using it again returns what that did), and listed.
  # Its DSL module's methods (its own, not one it includes) are the
  # DSL's from then on, however many configurations use it.
  def test_use
    config = Duel::Config.new
    lib = tmpdir
    FileUtils.mkdir_p(File.join(lib, "duel"))
    File.write(File.join(lib, "duel", "fake_cache.rb"), <<~RUBY)
      module FakeShared
        module DSL
          def duel_shared = nil
        end
      end

      module FakeCache
        include FakeShared

        def self.configure(config, size: 1, ttl: nil)
          config.measure("cpu", limit: size)
          [:installed, size, ttl, config.use(:fake_store)]
        end
      end
      Duel.plugin(:fake_cache, FakeCache)
    RUBY
    File.write(File.join(lib, "duel", "fake_store.rb"), <<~RUBY)
      module FakeStore
        module DSL
          def duel_stored(name) = duel(name) { :stored }
        end

        def self.configure(config) = config.use(:fake_cache)
      end
      Duel.plugin(:fake_store, FakeStore)
    RUBY
    $LOAD_PATH.unshift(lib)

    refute Duel::DSL.method_defined?(:duel_stored)
    assert_equal [:installed, 2, nil, nil], config.use(:fake_cache, size: 2)
    assert_equal({"cpu" => {limit: 2}}, config.measures)
    assert_equal %i[fake_cache fake_store], config.plugins, "in the order first used"
    DSL.duel_stored("stored")

    assert_equal :stored, Duel.benchmarks.fetch("stored").body.call
    refute Duel::DSL.method_defined?(:duel_shared)
    Duel::Config.new.use(:fake_store)

    assert_equal [:installed, 2, nil, nil], config.use(:fake_cache), "once"
    assert_equal [:installed, 2, nil, nil], config.use(:fake_cache, size: 2), "with the same options"
    error = assert_raises(Duel::Error) { config.use(:fake_cache, size: 3, ttl: 4) }

    assert_equal "c.use :fake_cache: used already, without size: 3, ttl: 4: give a plugin's options the first time it's used", error.message
    assert_raises(ArgumentError) { Duel::Config.new.use(:fake_cache, sise: 2) }
  ensure
    $LOAD_PATH.delete(lib)
    $LOADED_FEATURES.reject! { |feature| feature.start_with?(lib) }
    %i[FakeShared FakeCache FakeStore].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
  end

  # A plugin that isn't there, or doesn't register itself, fails, saying
  # so, and one whose own requires fail fails as they do.
  def test_use_fails
    lib = tmpdir
    FileUtils.mkdir_p(File.join(lib, "duel"))
    File.write(File.join(lib, "duel", "fake_nothing.rb"), "")
    File.write(File.join(lib, "duel", "fake_broken.rb"), "require \"no_such_library_anywhere\"\n")
    $LOAD_PATH.unshift(lib)
    error = assert_raises(Duel::Error) { Duel::Config.new.use(:fake_missing) }

    assert_equal "c.use :fake_missing: no duel/fake_missing to require: add the duel-fake_missing gem to the Gemfile", error.message
    error = assert_raises(Duel::Error) { Duel::Config.new.use(:fake_nothing) }

    assert_equal "c.use :fake_nothing: duel/fake_nothing registers no plugin :fake_nothing (Duel.plugin)", error.message
    error = assert_raises(LoadError) { Duel::Config.new.use(:fake_broken) }

    assert_equal "no_such_library_anywhere", error.path
    assert_equal :fake, Duel.plugin(:fake, Duel)
    assert_same Duel, Duel.plugins.fetch(:fake)
  ensure
    $LOAD_PATH.delete(lib)
    $LOADED_FEATURES.reject! { |feature| feature.start_with?(lib) }
  end

  # Running totals, one by name (with its settings) or several.
  def test_metrics_of_running_totals
    config = Duel::Config.new
    config.metric("queries") { 1 }
    config.metric("wait", kind: :ratio, floor: 5) { 2 }
    config.metric("a" => {kind: :ratio}, "b" => {}) { {"a" => 3, "b" => 4} }
    one, timed, several = config.metrics

    assert_equal [Duel::Snapshot] * 3, config.metrics.map(&:superclass)
    assert_equal({"queries" => {}}, one.measures)
    assert_equal({"wait" => {kind: :ratio, floor: 5}}, timed.measures)
    assert_equal({"a" => {kind: :ratio}, "b" => {}}, several.measures)
    assert_equal [{"queries" => 1}, {"wait" => 2}, {"a" => 3, "b" => 4}], config.metrics.map { |metric| metric.read.totals }
    config.metric({"c" => {}}) { 5 }

    assert_equal({"c" => {}}, config.metrics.last.measures)
    said = ->(*) { "said" }
    config.metric("d") { 6 }.details(&said)
    config.metric("e" => {}) { {"e" => 7} }.details(&said)

    assert_equal [said, said], config.metrics.last(2).map(&:explainer), "and what explains them"
    assert_same Duel::Metrics::CPU, config.metric(Duel::Metrics::CPU), "a class, as it is"
    assert_raises(Duel::Error) { config.metric("f", toleranse: 1) { 8 } }
    error = assert_raises(Duel::Error) { config.measure("cpu", limt: 1.1) }

    assert_match(/\Acpu: no setting limt/, error.message)
  end

  def test_benchmark_files_are_sorted_from_the_root
    root = project(tmpdir, benchmarks: "")
    File.write(File.join(root, "duel", "a_duel.rb"), "")
    FileUtils.mkdir_p(File.join(root, "duel", "sub"))
    File.write(File.join(root, "duel", "sub", "b_duel.rb"), "")
    File.write(File.join(root, "duel", "duel_helper.rb"), "")

    assert_equal %w[duel/a_duel.rb duel/sample_duel.rb duel/sub/b_duel.rb].map { |f| File.join(root, f) },
      Duel::Config.new(root).benchmark_files, "files named *_duel.rb"
  end
end

class DSLTest < DuelTest
  cover "Duel::DSL*"
  cover "Duel::Definition*"
  cover "Duel.file_hooks"
  cover "Duel.file_hook"
  cover "Duel.hook"
  cover "Duel.defining"
  cover "Duel.defining_file"
  cover "Duel::DSL.add"
  cover "Duel::DSL.define"

  # The DSL, called from +file+ (as a file of benchmarks calls it).
  def in_file(file, code) = Object.new.extend(Duel::DSL).instance_eval(code, file)

  def test_duel_defines_one
    body = proc { 1 }
    definition = duel("one", &body)

    assert_equal Duel::Definition.new("one", nil, false, __FILE__, body, {}), definition
    assert_same definition, Duel.benchmarks.fetch("one")
    assert_equal :thread, definition.cpu
  end

  def test_options
    timings = duel("timings", only: :timing, peak_memory: true) { 1 }
    counts = duel("counts", only: :count) { 1 }

    assert_equal [:timing, true, :process], [timings.only, timings.peak_memory, timings.cpu]
    assert_equal [:count, false, :thread], [counts.only, counts.peak_memory, counts.cpu]
    assert_equal 4, Duel::COUNTS_ONLY
  end

  def test_only_counts_or_timings
    error = assert_raises(ArgumentError) { duel("x", only: :memory) { 1 } }

    assert_equal "only: must be :count or :timing, not :memory", error.message
    refute Duel.benchmarks.key?("x")
  end

  def test_en_garde
    in_file("/duel/swords_duel.rb", <<~RUBY)
      ⚔️ "crossed swords" do
        1
      end
      ⚔("crossed swords, in text") { 2 }
    RUBY

    assert_equal ["crossed swords", "crossed swords, in text"], Duel.benchmarks.keys
  end

  def test_names_are_unique
    duel("one") { nil }
    error = assert_raises(ArgumentError) { duel("one") { nil } }

    assert_equal 'duplicate benchmark "one"', error.message
    error = assert_raises(ArgumentError) { DSL.duel_process("one", "true") }

    assert_equal 'duplicate benchmark "one"', error.message
  end

  # A benchmark of a whole process: a command, or Ruby code, from its
  # file.
  def test_duel_process_defines_one
    in_file("/duel/boot_duel.rb", <<~RUBY)
      duel_process "boot", "bin/rails", "runner", "1"
      duel_process "shell", "bin/rails runner 1"
      duel_process "require", ruby: %(require "my_gem"), runs: 5
    RUBY

    assert_equal [Duel::Definition.new("boot", nil, false, "/duel/boot_duel.rb", nil, {},
      {"command" => %w[bin/rails runner 1], "ruby" => nil, "runs" => nil}),
      Duel::Definition.new("shell", nil, false, "/duel/boot_duel.rb", nil, {}, {"command" => ["bin/rails runner 1"], "ruby" => nil, "runs" => nil}),
      Duel::Definition.new("require", nil, false, "/duel/boot_duel.rb", nil, {}, {"command" => nil, "ruby" => %(require "my_gem"), "runs" => 5})],
      Duel.benchmarks.values
    assert_equal({"command" => nil, "ruby" => %(require "my_gem"), "runs" => 5}, Duel.benchmarks.fetch("require").to_h.fetch("process"))
    [["neither"], ["both", "true", {ruby: "1"}]].each do |name, *command|
      options = command.last.is_a?(Hash) ? command.pop : {}
      error = assert_raises(ArgumentError) { DSL.duel_process(name, *command, **options) }

      assert_equal %(duel_process "#{name}": give a command, or ruby: code, not both), error.message
    end
    refute Duel.benchmarks.key?("neither")
  end

  # Its runs a sample: a number, 1 or more.
  def test_duel_process_runs
    DSL.duel_process("one", "true", runs: 1)

    [0, -1, 2.0, "3", false].each do |runs|
      error = assert_raises(ArgumentError) { DSL.duel_process("boot", "true", runs: runs) }

      assert_equal %(duel_process "boot": runs: is a number of processes a sample, 1 or more, not #{runs.inspect}), error.message
    end
    assert_equal ["one"], Duel.benchmarks.keys
  end

  # What runs a benchmark in a worker doesn't run a process: duel's
  # options fail, saying why.
  def test_duel_process_takes_none_of_duels_options
    error = assert_raises(ArgumentError) { DSL.duel_process("boot", "true", around_iteration: ->(iteration) { iteration.call }) }

    assert_equal 'duel_process "boot": around_iteration is duel\'s, for a benchmark run in a worker: a process benchmark runs no ' \
      "hooks, and is judged on its CPU time and peak memory alone", error.message
    error = assert_raises(ArgumentError) { DSL.duel_process("boot", ruby: "1", only: :count, peak_memory: true) }

    assert_match(/: only, peak_memory are duel's, /, error.message)
    assert_empty Duel.benchmarks
  end

  def test_what_the_runner_learns
    definition = Duel::Definition.new("a", :timing, true, "/a_duel.rb", nil)

    assert_equal({"name" => "a", "only" => "timing", "peak_memory" => true, "process" => nil}, definition.to_h)
    assert_nil Duel::Definition.new("b", nil, false, nil, nil).to_h.fetch("only")
  end

  # A benchmark's own hooks: lambdas (or procs), one of each there is,
  # and around_iteration's takes the iteration, which a benchmark's block
  # with a parameter can't run.
  def test_hooks_of_a_benchmark
    log = []
    hooks = {setup: -> { log << :setup }, teardown: ->(benchmark) { log << benchmark.name }, before_sample: proc { log << :before },
             around_iteration: ->(iteration) { iteration.call }, after_iterations: -> { log << :after }}
    definition = duel("hooked", **hooks) { log << :iteration }

    assert_equal hooks, definition.hooks
    error = assert_raises(ArgumentError) { duel("x", around: -> {}, drain: -> {}) { nil } }

    assert_equal 'duel "x": no option around, drain (only, peak_memory, setup, teardown, before_sample, around_iteration, after_iterations)',
      error.message
    error = assert_raises(ArgumentError) { duel("x", setup: :prepare) { nil } }

    assert_equal "setup: give a block (or a lambda), not :prepare", error.message
    kind = Class.new(Proc).new { |iteration| iteration.call }

    assert_same kind, duel("a kind of proc", around_iteration: kind) { nil }.hooks.fetch(:around_iteration)
    error = assert_raises(ArgumentError) { duel("x", around_iteration: -> {}) { nil } }

    assert_match(/\Aaround_iteration: take the iteration/, error.message)
    error = assert_raises(ArgumentError) { duel("x", around_iteration: ->(iteration) { iteration.call }) { |n| n } }

    assert_equal 'duel "x": around_iteration runs around each iteration: give the benchmark\'s block no parameter', error.message
    assert_equal ["hooked", "a kind of proc"], Duel.benchmarks.keys
  end

  # An around_iteration hook made elsewhere (a plugin's lambda, say).
  AROUND = ->(iteration) { ((@log ||= []) << :around) && iteration.call }

  # A file's hooks are its own, wherever in it they are (and wherever
  # their blocks are made).
  def test_hooks_are_the_files
    in_file("/duel/a_duel.rb", <<~RUBY)
      setup { (@log ||= []) << :first }
      duel("a") { |n| @log << n }
      setup { |benchmark| @log << benchmark.name }
      before_sample { @log << :before }
      teardown { @log << :done }
      teardown { @log << :last }
      after_iterations { @log << :after }
    RUBY
    in_file("/duel/b_duel.rb", 'duel("b") { |n| (@log ||= []) << n }')
    in_file("/duel/c_duel.rb", <<~RUBY)
      around_iteration(&AROUND)
      duel("c") { @log << :c }
    RUBY

    assert_equal [:first, "a", :before, 1, :after, :last, :done], run_benchmark("a")
    assert_equal [1], run_benchmark("b"), "none of a_duel.rb's"
    assert_equal %i[around c], run_benchmark("c")
    assert_equal ["/duel/a_duel.rb", "/duel/b_duel.rb", "/duel/c_duel.rb"], Duel.benchmarks.values.map(&:file)
    assert_equal [2, 2, 1, 0, 1], Duel::HOOKS.map { |hook| Duel.file_hooks.fetch("/duel/a_duel.rb").fetch(hook).size }
    error = assert_raises(ArgumentError) { in_file("/duel/d_duel.rb", "before_sample") }

    assert_equal "before_sample: give a block (or a lambda), not nil", error.message
    refute Duel.file_hooks.key?("/duel/d_duel.rb")
  end

  # A plugin's DSL method, in a file of its own, defines a benchmark of
  # the file that calls it: it gets that file's hooks, its own and all,
  # and so does one that a DSL method calling another defines, and a
  # process benchmark, and hooks that a DSL method adds are the calling
  # file's too. Once it's over, a benchmark is its own block's file's
  # again.
  def test_a_dsl_methods_benchmarks_are_the_calling_files
    in_file("/plugin/duel_thing.rb", <<~RUBY)
      Duel::DSL.add(Module.new do
        def duel_thing(name, **options, &body) = duel(name, **options) { instance_exec(&body) }
        def duel_things(name, &body) = %w[a b].each { |side| duel_thing("\#{name} \#{side}", &body) }
        def duel_boot(name) = duel_process(name, "true")
        def log_samples = before_sample { @log << :logged }
      end)
    RUBY
    in_file("/duel/a_duel.rb", <<~RUBY)
      setup { (@log ||= []) << :setup }
      before_sample { @log << :before }
      teardown { @log << :teardown }
      duel_thing("thing") { @log << :thing }
      duel_thing("around", around_iteration: ->(iteration) { (@log << :around) && iteration.call }) { @log << :iteration }
      duel_things("things") { @log << :thing }
      duel_boot("boot")
      duel("plain") { @log << :plain }
      log_samples
    RUBY

    assert_equal %i[setup before logged thing teardown], run_benchmark("thing")
    assert_equal %i[setup before logged around iteration teardown], run_benchmark("around")
    assert_equal [%i[setup before logged thing teardown]] * 2, ["things a", "things b"].map { |name| run_benchmark(name) }
    assert_equal ["/duel/a_duel.rb"] * 6, Duel.benchmarks.values.map(&:file)
    assert_nil Duel.defining_file
  end

  # The file a DSL method's benchmarks are filed under: the outermost
  # given, and none again after (however the block ends).
  def test_defining
    assert_equal [:a, "/a.rb"], Duel.defining("/a.rb") { Duel.defining("/b.rb") { [:a, Duel.defining_file] } }
    assert_nil Duel.defining_file
    assert_raises(RuntimeError) { Duel.defining("/a.rb") { raise "oops" } }
    assert_nil Duel.defining_file
    assert_equal "/b.rb", Duel.defining(nil) { Duel.defining("/b.rb") { Duel.defining_file } }
  end

  def run_benchmark(name)
    harness = Duel::Harness.new(Duel.benchmarks.fetch(name))
    harness.prepare
    harness.run(1, Duel::Sample.new(harness.definition, [], n: 1, counting: false))
    harness.finish
    harness.context.instance_variable_get(:@log)
  end
end

class ConventionsTest < DuelTest
  cover "Duel::Config*"
  cover "Duel::QuietRedefinition*"

  def config(root = @root) = Duel::Config.new(root)

  def setup
    super
    @root = File.join(tmpdir, "gem")
    FileUtils.mkdir_p(File.join(@root, "lib"))
  end

  def test_the_library_is_the_gemspecs
    File.write(File.join(@root, "thing.gemspec"), "")

    assert_equal "thing", config.library
    File.delete(File.join(@root, "thing.gemspec"))
    File.write(File.join(@root, "my-thing.gemspec"), "")

    assert_equal "my/thing", config.library, "dashes are directories"
    File.write(File.join(@root, "lib", "my-thing.rb"), "")

    assert_equal "my-thing", config.library, "unless there's a file by its name"
    File.write(File.join(@root, "other.gemspec"), "")

    assert_nil config.library, "two gemspecs: no telling"
    c = config
    c.library = "explicit"

    assert_equal "explicit", c.library
  end

  def test_a_project_with_ext_and_a_rakefile_is_compiled
    assert_nil config.build
    FileUtils.mkdir_p(File.join(@root, "ext"))

    assert_nil config.build, "no Rakefile"
    File.write(File.join(@root, "Rakefile"), "")
    FileUtils.rm_rf(File.join(@root, "ext"))

    assert_nil config.build, "no ext/"
    FileUtils.mkdir_p(File.join(@root, "ext"))

    assert_equal "bundle exec rake compile", config.build
    c = config
    c.build = "make"

    assert_equal "make", c.build
    c.build = nil

    assert_nil c.build
  end

  def write(root, version)
    FileUtils.mkdir_p(File.join(root, "lib", "probe"))
    File.write(File.join(root, "probe.gemspec"), "")
    File.write(File.join(root, "lib", "probe", "version.rb"), "module Probe; VERSION = #{version.inspect}; end\n")
    File.write(File.join(root, "lib", "probe.rb"), "require_relative \"probe/version\"\nmodule Probe; LOADED = #{version.inspect}; end\n")
    root
  end

  # Under `bundle exec`, the candidate's gemspec has already loaded its
  # version file: the baseline loads its own over it, quietly.
  def test_loading_a_baseline_over_the_candidates_files
    candidate = write(File.join(tmpdir, "candidate"), "2.0")
    base = write(File.join(tmpdir, "base"), "1.0")
    require File.join(candidate, "lib", "probe", "version")
    _, err = capture_io { Duel::Config.new(candidate).load_into(base) }

    assert_equal ["1.0", "1.0"], [Probe::VERSION, Probe::LOADED]
    assert_empty err, "no warning about redefining VERSION"
    assert_equal File.join(base, "lib"), $LOAD_PATH.first
    refute_includes $LOADED_FEATURES, File.join(candidate, "lib", "probe", "version.rb")
  ensure
    Object.send(:remove_const, :Probe) if defined?(Probe)
    $LOAD_PATH.delete(File.join(base, "lib"))
    $LOADED_FEATURES.reject! { |f| f.include?("/probe") }
  end

  # Features (fake ones) of the candidate's lib/, and near it.
  def features(root) = %w[lib/probe/a.rb libs/probe/b.rb probe/c.rb].map { |f| File.join(root, f) }

  # The candidate as it's loaded however its root is written: its files
  # already loaded stay loaded.
  def test_loading_the_candidate
    candidate = write(File.join(tmpdir, "candidate"), "2.0")
    roundabout = File.join(tmpdir, "candidate", "..", "candidate")
    [[roundabout, candidate], [candidate, roundabout]].each do |root, version_root|
      $LOADED_FEATURES.concat(features(candidate))
      Duel::Config.new(root).load_into(version_root)

      assert_equal "2.0", Probe::LOADED
      assert_empty features(candidate) - $LOADED_FEATURES
      Object.send(:remove_const, :Probe)
      $LOADED_FEATURES.reject! { |f| f.include?("/probe") }
    end
  ensure
    Object.send(:remove_const, :Probe) if defined?(Probe)
    $LOAD_PATH.delete(File.join(candidate, "lib"))
    $LOAD_PATH.delete(File.join(roundabout, "lib"))
    $LOADED_FEATURES.reject! { |f| f.include?("/probe") }
  end

  def test_loading_a_baseline_forgets_the_candidates_lib_only
    candidate = write(File.join(tmpdir, "candidate"), "2.0")
    base = write(File.join(tmpdir, "base"), "1.0")
    $LOADED_FEATURES.concat(features(candidate))
    Duel::Config.new(File.join(tmpdir, "base", "..", "candidate")).load_into(base)

    assert_equal "1.0", Probe::LOADED
    assert_equal features(candidate).drop(1), features(candidate) & $LOADED_FEATURES
  ensure
    Object.send(:remove_const, :Probe) if defined?(Probe)
    $LOAD_PATH.delete(File.join(base, "lib"))
    $LOADED_FEATURES.reject! { |f| f.include?("/probe") }
  end

  def test_quiet_redefinition_only_silences_redefinitions_and_only_while_loading
    _, err = capture_io do
      Duel::QuietRedefinition.during do
        Warning.warn("x: warning: already initialized constant X\n")
        Warning.warn("y: warning: something else\n")
      end
      Warning.warn("z: warning: already initialized constant Z\n")
    end

    assert_equal "y: warning: something else\nz: warning: already initialized constant Z\n", err
  end
end
