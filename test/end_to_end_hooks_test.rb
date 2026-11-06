# frozen_string_literal: true

require_relative "support/end_to_end"

# A config file's plugins, hooks and metrics, in real workers.
class EndToEndHooksTest < DuelTest
  include EndToEnd

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
    assert_equal %w[base-1 base-2 base-3 head-1 head-2 head-3], Dir.children(stops).sort,
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
end
