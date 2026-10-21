# frozen_string_literal: true

require "json"
require "rbconfig"
require "socket"
require_relative "../duel"
require_relative "context"
require_relative "profile"

module Duel
  # A worker process: loads one version of the code and the candidate's
  # benchmarks, and answers the runner's requests. Started (see
  # WorkerProcess) with Worker.main(VERSION_ROOT, CANDIDATE_ROOT, CONTROL
  # [, CONFIG]), it gives its main object the DSL, loads the benchmarks,
  # connects to the runner's Unix socket at CONTROL, sends what it has
  # (see #hello), and answers one JSON request per line with one JSON
  # reply. (Not over stdin: a JRuby started by JRuby sees its stdin pipe
  # closed.)
  # @api private
  class Worker
    # The built-in metrics, outermost first: allocations inside
    # instructions, whose counter allocates as it's read (a sample's own
    # allocations are none but the benchmark's), and CPU time innermost.
    BUILT_IN = [Metrics::Instructions, Metrics::Allocations, Metrics::CPU].freeze

    def self.main(version_root, candidate_root, control, config_path = nil)
      config = config_path ? Duel.load_config(config_path) : (Duel.config = Config.new(candidate_root))
      config.load_into(File.expand_path(version_root))
      TOPLEVEL_BINDING.receiver.extend(DSL)
      config.benchmark_files.each { |file| load file }
      Context.check
      stops = Stops.new
      config.in_workers.each { |block| block.call(stops) }
      begin
        # The benchmarks are the only work in this process: it starts tidy.
        GC.start
        worker = new(config.metrics, config.measures, hooks: config.hooks)
        begin
          socket = UNIXSocket.new(control)
          socket.puts JSON.generate(worker.hello)
          socket.each_line { |line| socket.puts JSON.generate(worker.handle(JSON.parse(line))) }
        ensure
          worker.close
        end
      ensure
        stops.run
      end
    end

    # Its metric instances: the plugins' outermost, then the built-in
    # ones, CPU innermost (see Worker.made). +hooks+: the configuration's
    # (see Harness).
    def initialize(plugin_metrics = [], measures = {}, hooks: NO_HOOKS)
      @metrics, @specs = Worker.made(plugin_metrics + BUILT_IN, measures)
      @benchmarks = Duel.benchmarks
      @hooks = hooks
      @harnesses = {}
    end

    # Closes its metrics (see Metric#close), last first, as it ends.
    def close = @metrics.reverse_each(&:close)

    # +metrics+ (classes) made and opened (Metric#open), and their
    # measures' specs: only those available here, with +measures+
    # (Config#measure) changing their settings (each metric's own too:
    # Metric#settings), and leaving out those skipped (and a metric whose
    # measures all are). Two that measure the same name, a change to one
    # none measures, or a setting there isn't, fail.
    def self.made(metrics, measures)
      metrics.each { |metric| metric.measures.each { |name, settings| Metric.check(name, settings) } }
      names = metrics.flat_map { |metric| metric.measures.keys }
      twice = names.select { |name| names.count(name) > 1 }.uniq
      raise Error, "more than one metric measures #{twice.join(", ")}" unless twice.empty?
      unknown = measures.keys - names
      raise Error, "no metric measures #{unknown.join(", ")} (c.measure)" unless unknown.empty?

      skipped = measures.select { |_, settings| settings[:skip] }.keys
      made = metrics.select(&:available?).reject { |metric| (metric.measures.keys - skipped).empty? }.map(&:new)
      made.each do |metric|
        metric.settings = metric.class.settings(measures)
        metric.open
      end
      [made, made.flat_map { |metric| metric.class.specs(measures) }.reject { |spec| skipped.include?(spec.fetch("name")) }]
    end

    # What the runner learns first: the benchmarks, the metrics, whether
    # peak memory and profiles can be measured here, and whether YJIT is on.
    def hello
      {"benchmarks" => @benchmarks.values.map(&:to_h), "metrics" => @specs, "ruby" => RUBY_DESCRIPTION,
       "memory" => !Native::Memory.resident.nil?, "profiler" => Worker.profiler?, "yjit" => Worker.yjit?,
       "extensions" => Worker.extensions, "gem_dirs" => Worker.gem_dirs}
    end

    # The native extensions loaded (CRuby's and TruffleRuby's builds, and
    # JRuby's jars), as {feature => real path}: a feature is the path
    # from the directory on the load path it was found in (the deepest,
    # of several), "my_gem/my_gem.bundle", say, or else its file's name.
    # (For the runner to check each version loaded its own builds: see
    # Lane#check_builds.)
    def self.extensions(features = $LOADED_FEATURES, load_path = $LOAD_PATH)
      dirs = load_path.map { |dir| File.join(File.expand_path(dir), "") }
      features.select { |feature| File.absolute_path?(feature) && feature.end_with?(".#{RbConfig::CONFIG.fetch("DLEXT")}") }.to_h do |path|
        dir = dirs.select { |prefix| path.start_with?(prefix) }.max_by(&:size)
        [dir ? path.delete_prefix(dir) : File.basename(path), File.realpath(path)]
      end
    end

    # The directories gems are installed in, Gem.path's that are there, as
    # real paths ending in "/". Under Bundler, Gem.path is its bundle's
    # (vendor/bundle/ruby/4.0.0, say, with its git gems in bundler/gems).
    # (For the runner to tell an installed gem's extension from a build,
    # where the bundle is in a version's tree: see Lane#check_builds.)
    def self.gem_dirs(dirs = Gem.path)
      dirs.select { |dir| File.directory?(dir) }.map { |dir| File.join(File.realpath(dir), "") }.uniq
    end

    # Whether YJIT is on, by Ruby: JRuby and TruffleRuby have none, and a
    # CRuby built without it has no RubyVM::YJIT.
    YJIT = {"ruby" => -> { RubyVM.const_defined?(:YJIT) && RubyVM::YJIT.enabled? }}.fetch(RUBY_ENGINE, -> { false })

    # Whether YJIT is on (which the version may have turned on as it
    # loaded), for a longer warm-up (YJIT_WARM).
    def self.yjit? = YJIT.call

    # Whether StackProf is installed, for profiles: on CRuby (+engine+)
    # only. TruffleRuby installs it, but it fails to start there, and
    # JRuby can't install it.
    def self.profiler?(engine = RUBY_ENGINE)
      return false unless engine == "ruby"

      require "stackprof"
      true
    rescue LoadError
      false
    end

    # Answers a request: setup, sample or teardown of a benchmark. Errors
    # are answered, not raised.
    def handle(request)
      name = request.fetch("name")
      case request.fetch("op")
      when "setup" then setup(name, request.fetch("trial", true))
      when "sample" then sample(name, request.fetch("n"), request.fetch("count", false), request.fetch("runs", 1))
      when "memory" then memory(name, request.fetch("n"))
      when "profile" then profile(name, request.fetch("n"), request.fetch("runs"))
      when "teardown" then teardown(name)
      else raise ArgumentError, "unknown request #{request}"
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      {"error" => "#{e.class}: #{e}", "backtrace" => e.backtrace.first(5)}
    end

    private

    # Runs its setup hooks, then (if +trial+) the benchmark once,
    # unmeasured (see Harness#trial).
    def setup(name, trial)
      harness = Harness.new(@benchmarks.fetch(name), @hooks)
      harness.prepare
      harness.trial if trial
      @harnesses[name] = harness
      {"ok" => true}
    end

    # Runs +n+ iterations +runs+ times, less what pausing and resuming
    # around each iteration leaves (see Harness#leak), and reports each
    # timed metric's least (interference only ever adds time, so the
    # least is the closest to what the code itself costs) and the last
    # run's counts.
    def sample(name, n, count, runs)
      harness = @harnesses.fetch(name)
      leak = harness.leak(@metrics)
      samples = Array.new(runs) do
        harness.sample(@metrics, n: n, counting: count).tap do |sample|
          harness.run(n, sample)
          sample.less(leak)
        end
      end
      timed = samples.first.timed.to_h { |metric| [metric, samples.map { |s| s.timed.fetch(metric) }.min] }
      {"timed" => timed, "counted" => samples.last.counted, "heap" => samples.last.heap, "details" => samples.last.details}
    end

    # The peak memory of +n+ iterations (see MemorySample), in bytes.
    def memory(name, n)
      sample = MemorySample.new
      @harnesses.fetch(name).run_memory(n, sample)
      {"peak" => sample.peak}
    end

    # A profile of +runs+ samples of +n+ iterations (see ProfileSample
    # and Profile.of). StackProf runs throughout: started again for each
    # stretch, its timer would start again too, and never sample a
    # stretch shorter than its interval.
    def profile(name, n, runs)
      require "stackprof"
      harness = @harnesses.fetch(name)
      StackProf.start(mode: ProfileSample::MODE, interval: ProfileSample::INTERVAL, raw: true)
      begin
        runs.times { harness.run(n, ProfileSample.new) }
      ensure
        StackProf.stop
      end
      Profile.of(StackProf.results)
    end

    def teardown(name)
      @harnesses.delete(name)&.finish
      {"ok" => true}
    end
  end
end
