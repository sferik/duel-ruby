# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../duel"
require_relative "runner"
require_relative "worker"

module Duel
  # What a plugin's tests need: its resources started as a worker's would
  # be, its metrics measuring a block, and whole comparisons of two small
  # projects.
  #
  #   require "duel/testing"
  #
  #   config = Duel::Config.new
  #   MyPlugin.install(config)
  #   Duel::Testing.resources(config) do |env|
  #     Duel::Testing.measure(config) { MyClient.new(env.fetch("MY_URL")).get }
  #     # => {"my_requests" => 1, ...}
  #   end
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

    # Where resources' builds (Resource#cached) are kept, for every test of
    # this process.
    # @api private
    CACHE = Dir.mktmpdir("duel-cache")
    at_exit { FileUtils.rm_rf(CACHE) }

    # The benchmark a sample measures, by what it's judged on (+only:+).
    # @api private
    BENCHMARKS = ONLY.to_h { |only| [only, Definition.new("test", only, false, __FILE__, -> {})] }

    # (Its functions, called on it: Duel::Testing.measure.)
    extend self

    # Starts +config+'s resources as a worker's (+name+, running the
    # version at +root+) would be, with their builds (Resource#cached) in
    # +cache+ (by default, one for every test of this process), sets the
    # environment they give while the block runs, yields it, and stops
    # them after.
    def resources(config, name: "candidate-1", root: config.root, cache: CACHE)
      dir = Lane.tmpdir
      started = [] #: Array[Resource]
      begin
        none = {} #: Hash[String, String?]
        env = config.resources.each_with_index.reduce(none) do |vars, (block, i)|
          resource = Resource.new(File.join(dir, "#{name}-#{i + 1}"), name, root, timeout: Settings.defaults.timeout, cache: cache)
          started << resource
          Resource.environment(name, vars, block.call(resource))
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

    # What the block given to #measure gets: #untimed, as a benchmark has.
    # Its +sample+, and making one, are @api private.
    Untimed = Data.define(:sample)

    class Untimed
      # Runs the block with measuring paused, as a benchmark's untimed does
      # (Duel.measuring? is false in it).
      def untimed(&) = sample.pause { Duel.measured(false, &) }
    end

    # What +config+'s metrics (a plugin's: not Duel's own) measure of the
    # block, as one counted sample of +n+ iterations of a benchmark would
    # (one with +only:+, say :timing): {name => measured}, with what they
    # said of it (Measurement#details). The block gets
    # something with #untimed, and runs measured (Duel.measuring?), as a
    # benchmark's does. Inside #worker, it's that worker's; outside, it's
    # a worker of its own, ended after (what its blocks gave at_stop run).
    def measure(config, n: 1, only: nil, &)
      return worker(config) { measure(config, n: n, only: only, &) } unless STOPS.key?(config)

      sample = Sample.new(BENCHMARKS.fetch(only), metrics(config), n: n, counting: true)
      untimed = Untimed.new(sample) # (made first: not measured)
      sample.start
      begin
        Duel.measured(true) { yield untimed }
      ensure
        sample.stop
      end
      measured = Measurement[sample.timed.merge(sample.counted)]
      measured.details = sample.details
      measured
    end

    # +config+'s metrics, made once (its worker blocks run first), as a
    # worker makes them; made again if its measures' settings changed
    # since (Config#measure), so a change isn't left to mean nothing.
    def metrics(config)
      made = MADE[config]
      return made.last if made && made.first == config.measures

      stops = Stops.new
      STOPS[config] = stops
      config.workers.each { |block| block.call(stops) }
      MADE[config] = [config.measures.transform_values(&:dup), Worker.made(config.metrics, config.measures).first]
      MADE.fetch(config).last
    end

    # Runs the block as a worker of +config+ would run (its worker blocks
    # first, its metrics made: see #metrics), then ends it, as a worker
    # ends (what they gave at_stop). Returns what the block does.
    def worker(config)
      metrics(config)
      yield
    ensure
      MADE.delete(config)
      # (Registered before any worker block runs.)
      stops = STOPS.delete(config) #: Stops
      stops.run
    end

    # Each config's worker's Stops (see #worker).
    # @api private
    STOPS = {} #: Hash[Config, Stops]
    STOPS.compare_by_identity

    # Each config's metrics (see #metrics).
    # @api private
    MADE = {} #: Hash[Config, [Hash[String, Hash[Symbol, untyped]], Array[Metric]]]
    MADE.compare_by_identity

    # Compares the project at +base+ with the one at +candidate+ (its
    # .duel.rb, if any), in worker processes, as `duel` does: with
    # +settings+ (as `duel`'s options name them: processes:, timeout:,
    # filter:, limit:...) instead of the defaults, and two workers of each
    # version unless they say.
    def compare(base, candidate, **settings)
      config_path = File.join(candidate, ".duel.rb")
      saved = Duel.config
      begin
        config = File.exist?(config_path) ? Duel.load_config(config_path) : Config.new(candidate)
        run = Settings.defaults
        run.config_path = config_path if File.exist?(config_path)
        run.processes = 2
        settings.each { |setting, value| run[setting] = value }
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
