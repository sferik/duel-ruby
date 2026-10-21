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
    assert_empty config.resources
    assert_empty config.metrics
  end

  def test_load_into_puts_lib_first_by_default
    config = Duel::Config.new(tmpdir) # no gemspec: nothing to require
    config.load_into("/version")

    assert_equal "/version/lib", $LOAD_PATH.first
  ensure
    $LOAD_PATH.delete("/version/lib")
  end

  def test_load_version_replaces_how
    config = Duel::Config.new(tmpdir)
    loaded = []
    config.load_version { |root| loaded << root }
    config.load_into("/version")

    assert_equal ["/version"], loaded
    refute_includes $LOAD_PATH, "/version/lib"
  end

  def test_resources_and_metrics
    config = Duel::Config.new
    resource = proc { 2 }
    config.resource(&resource)
    config.metric(Duel::Metric)

    assert_equal [resource], config.resources
    assert_equal [Duel::Metric], config.metrics
  end

  # Blocks for workers, and measures' settings changed by name.
  def test_worker_blocks_and_measures
    config = Duel::Config.new
    block = proc { 1 }
    config.worker(&block)
    config.measure("cpu", limit: 1.05)
    config.measure("cpu", floor: 5)
    config.measure("rows", skip: true)

    assert_equal [block], config.workers
    assert_equal({"cpu" => {limit: 1.05, floor: 5}, "rows" => {skip: true}}, config.measures)
    assert_equal [true, false, false], %w[rows cpu pages].map { |name| config.skip?(name) }
    config.measure("rows", skip: false)

    refute config.skip?("rows")
    assert_equal %w[cpu rows], config.measures.keys, "nothing added by asking"
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
  cover "Duel.setups"
  cover "Duel.teardowns"

  # The DSL, called from +file+ (as a file of benchmarks calls it).
  def in_file(file, code) = Object.new.extend(Duel::DSL).instance_eval(code, file)

  def test_duel_defines_one
    body = proc { 1 }
    definition = duel("one", &body)

    assert_equal Duel::Definition.new("one", nil, false, __FILE__, body), definition
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
  end

  def test_what_the_runner_learns
    definition = Duel::Definition.new("a", :timing, true, "/a_duel.rb", nil)

    assert_equal({"name" => "a", "only" => "timing", "peak_memory" => true}, definition.to_h)
    assert_nil Duel::Definition.new("b", nil, false, nil, nil).to_h.fetch("only")
  end

  # Setup and teardown blocks are their file's, wherever in it they are.
  def test_setup_and_teardown_are_the_files
    in_file("/duel/a_duel.rb", <<~RUBY)
      setup { (@log ||= []) << :first }
      duel("a") { |n| @log << n }
      setup { @log << :second }
      teardown { @log << :done }
      teardown { @log << :last }
    RUBY
    in_file("/duel/b_duel.rb", 'duel("b") { |n| (@log ||= []) << n }')

    assert_equal %i[first second] + [1] + %i[last done], run_benchmark("a")
    assert_equal [1], run_benchmark("b"), "none of a_duel.rb's"
    assert_equal ["/duel/a_duel.rb", "/duel/b_duel.rb"], Duel.benchmarks.values.map(&:file)
  end

  def run_benchmark(name)
    context = Duel::Context.new(Duel.benchmarks.fetch(name))
    context.prepare
    context.run(1, Duel::Sample.new(context.definition, [], n: 1, counting: false))
    context.finish
    context.instance_variable_get(:@log)
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
