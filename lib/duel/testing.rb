# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../duel"
require_relative "runner"
require_relative "worker"

module Duel
  # What a plugin's tests need: its prepare blocks run as a worker's
  # would be, its metrics measuring a block, and whole comparisons of two
  # small projects.
  #
  #   require "duel/testing"
  #
  #   config = Duel::Config.new
  #   config.use :my_plugin
  #   Duel::Testing.prepare(config) do |env|
  #     Duel::Testing.measure(config) { MyClient.new(env.fetch("MY_URL")).get }
  #     # => {"my_requests" => 1, ...}
  #   end
  #
  # And stand-ins for what Duel gives a metric (#sample, #reading), to test
  # or benchmark what it says of a sample (#details).
  module Testing
    # What Testing.compare found: a Result for each benchmark (#passed?,
    # #regressed, #timed, #counted), what the run printed, and whether it
    # passed, as `duel` would have (no benchmark worse, and nothing worse
    # across the board): #results, #output and #passed?. Its +passed+, and
    # making one, are @api private.
    Comparison = Data.define(:results, :output, :passed)

    class Comparison
      def passed? = passed

      # The benchmark's Result.
      def [](name) = results.find { |result| result.name == name }
    end

    # Where prepare blocks' builds (Resource#cached) are kept, for every
    # test of this process.
    # @api private
    CACHE = Dir.mktmpdir("duel-cache")
    at_exit { FileUtils.rm_rf(CACHE) }

    # (Its functions, called on it: Duel::Testing.measure.)
    extend self

    # Runs +config+'s prepare blocks as they'd prepare a worker (+name+,
    # running the version at +root+): its version's (Config#prepare
    # (:version), named for the version: "head"), then the worker's,
    # with their builds (Resource#cached) in +cache+ (by default, one for
    # every test of this process). Sets the environment they give while
    # the block runs, yields it, and stops what they started after.
    def prepare(config, name: "head-1", root: config.root, cache: CACHE)
      dir = Lane.tmpdir
      started = [] #: Array[Resource]
      begin
        none = {} #: Hash[String, String?]
        version = name.sub(/-\d+\z/, "")
        blocks = config.prepares.fetch(:version).map { |block| [version, block] } +
          config.prepares.fetch(:worker).map { |block| [name, block] } #: Array[[String, Config::prepare]]
        env = blocks.each_with_index.reduce(none) do |vars, ((label, block), i)|
          resource = Resource.new(File.join(dir, "#{label}-#{i + 1}"), label, root, timeout: Settings.defaults.timeout, cache: cache)
          started << resource
          Resource.environment(label, vars, block.call(resource))
        end
        with_env(env) { yield env }
      ensure
        started.reverse_each(&:stop)
        FileUtils.rm_rf(dir)
      end
    end

    # Runs the block with +env+ set, and the environment as it was after.
    # @api private
    def with_env(env)
      saved = env.to_h { |var, _| [var, ENV.fetch(var, nil)] }
      begin
        ENV.update(env)
        yield
      ensure
        ENV.update(saved)
      end
    end

    # What #measure measured, by name, and what metrics said of it
    # (#details, by measure: see Metric#details).
    class Measurement < Hash
      attr_reader :details

      # @api private
      attr_writer :details
    end

    # What +config+'s metrics (a plugin's: not Duel's own) measure of the
    # block, as one counted sample of +n+ iterations of a benchmark would,
    # with +judge:+ (:timed, say) and its own +hooks+ (around_iteration:,
    # say), as DSL#duel takes them: {name => measured}, with what they
    # said of it (Measurement#details). It runs with the configuration's
    # hooks too, as a worker runs a benchmark: its setup hooks, then the
    # sample (its before_sample hooks, then the block, measured
    # (Duel.measuring?), then its after_iterations hooks, measured with
    # it), then its teardown hooks. The block gets the benchmark's
    # Context (with its #untimed), and keeps its own self.
    #
    # The block is one iteration, run +n+ times, as a benchmark's block
    # that takes no +n+ is: with around_iteration hooks (the
    # configuration's, or its own), each inside them, as a worker runs a
    # benchmark with them: what they do isn't measured, and what they add
    # to metrics costly to read (Metric.costly?) is learned first, and
    # taken away.
    #
    # Inside #in_worker, it's that worker's. Outside, it's a worker of its
    # own, ended after (its metrics closed, and what its blocks gave
    # at_stop run).
    def measure(config, n: 1, judge: JUDGE, **hooks, &block)
      return in_worker(config) { measure(config, n: n, judge: judge, **hooks, &block) } unless STOPS.key?(config)

      body = -> { block.call(self) } #: ^() [self: Context] -> void
      benchmark = Definition.new("test", DSL.judged("test", judge), __FILE__, body, DSL.hooks("test", hooks, body))
      harness = Harness.new(benchmark, config.hooks)
      metrics = metrics(config)
      sample = harness.sample(metrics, n: n)
      harness.prepare
      begin
        leak = harness.leak(metrics)
        harness.run(n, sample)
        sample.less(leak)
      ensure
        harness.finish
      end
      measured = Measurement[sample.timed.merge(sample.counted)]
      measured.details = sample.details
      measured
    end

    # +config+'s metrics, made once (its in_worker blocks run first), as a
    # worker makes them, and made again if its measures' settings changed
    # since (Config#measure), so a change isn't left to mean nothing.
    def metrics(config)
      made = MADE[config]
      return made.last if made && made.first == config.measures

      made&.last&.reverse_each(&:close)
      stops = Stops.new
      STOPS[config] = stops
      config.in_workers.each { |block| block.call(stops) }
      (MADE[config] = [config.measures.transform_values(&:dup), Worker.made(config.metrics, config.measures).first]).last
    end

    # Runs the block as a worker of +config+ would run (its in_worker
    # blocks first, its metrics made: see #metrics), then ends it, as a
    # worker ends (its metrics closed, last first, then what its blocks
    # gave at_stop). Returns what the block does.
    def in_worker(config)
      metrics(config)
      yield
    ensure
      MADE.delete(config)&.last&.reverse_each(&:close)
      # (Registered before any in_worker block runs.)
      stops = STOPS.delete(config) #: Stops
      stops.run
    end

    # Each config's worker's Stops (see #in_worker).
    # @api private
    STOPS = {} #: Hash[Config, Stops]
    STOPS.compare_by_identity

    # Each config's metrics (see #metrics).
    # @api private
    MADE = {} #: Hash[Config, [Hash[String, Hash[Symbol, untyped]], Array[Metric]]]
    MADE.compare_by_identity

    # A stand-in Sample of +n+ iterations of a benchmark named +name+
    # (judged on what +judge:+ says, as DSL#duel takes it), measuring
    # nothing: what a metric's #start_sample, and its details block
    # (Snapshot.details), are given.
    #
    #   metric.start_sample(Duel::Testing.sample(n: 10))
    def sample(n: 1, name: "test", judge: JUDGE)
      nothing = -> {} #: ^() [self: Context] -> void
      Sample.new(Definition.new(name, DSL.judged(name, judge), __FILE__, nothing), [], n: n)
    end

    # A stand-in reading of running totals (Snapshot::Reading): +totals+,
    # by name, and the +context+ read with them. A sample's stretches are
    # pairs of them, [started, stopped].
    #
    #   stretches = [[Duel::Testing.reading({"rows" => 1}), Duel::Testing.reading({"rows" => 4})]]
    def reading(totals = {}, context = nil) = Snapshot::Reading.new(totals, context)

    # What running totals' details block (Snapshot.details: +metric+ is
    # what Config#metric returned) says of +stretches+ of +sample+: nil,
    # without one.
    #
    #   Duel::Testing.details(metric, stretches, Duel::Testing.sample(n: 3))
    def details(metric, stretches, of = sample) = metric.explainer&.call(stretches, of)

    # Compares the project at +base+ with the one at +candidate+ (its
    # .duel.rb, if any), in worker processes, as `duel` does: with
    # +settings+ (as `duel`'s options name them: processes:, timeout:,
    # filter:, limit:...) instead of the defaults, and two workers of each
    # version unless they say.
    def compare(base, candidate, **settings)
      config_path = File.join(candidate, ".duel.rb")
      configured = File.exist?(config_path)
      saved = Duel.config
      begin
        config = configured ? Duel.load_config(config_path) : Config.new(candidate)
        run = Settings.defaults
        run.config_path = config_path if configured
        run.processes = 2
        # (.duel.rb's run settings, c.limit say, but where one's given, and
        # its processes: a test's are few.)
        config.run_settings.except(:processes).merge(settings).each { |name, value| run[name] = value }
        out = StringIO.new
        runner = Runner.new(config, run, base, out: out)
        results = runner.run
        Comparison.new(results, out.string, runner.passed?(results))
      ensure
        Duel.config = saved
      end
    end

    # Writes a project into +dir+: +files+, by path from it, with their
    # contents. Returns the directory.
    def project(dir, files)
      files.each do |path, contents|
        file = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, contents)
      end
      dir
    end
  end
end
