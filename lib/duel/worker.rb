# frozen_string_literal: true

require "json"
require "socket"
require_relative "../duel"
require_relative "context"

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
    BUILT_IN = [Metrics::Allocations, Metrics::Instructions, Metrics::CPU].freeze

    def self.main(version_root, candidate_root, control, config_path = nil)
      config = config_path ? Duel.load_config(config_path) : (Duel.config = Config.new(candidate_root))
      config.load_into(File.expand_path(version_root))
      TOPLEVEL_BINDING.receiver.extend(DSL)
      config.benchmark_files.each { |file| load file }
      stops = Stops.new
      config.workers.each { |block| block.call(stops) }
      begin
        # The benchmarks are the only work in this process: it starts tidy.
        GC.start
        worker = new(config.metrics, config.measures)
        socket = UNIXSocket.new(control)
        socket.puts JSON.generate(worker.hello)
        socket.each_line { |line| socket.puts JSON.generate(worker.handle(JSON.parse(line))) }
      ensure
        stops.run
      end
    end

    # Its metric instances: the plugins' outermost, then the built-in
    # ones, CPU innermost (see Worker.made).
    def initialize(plugin_metrics = [], measures = {})
      @metrics, @specs = Worker.made(plugin_metrics + BUILT_IN, measures)
      @benchmarks = Duel.benchmarks
      @contexts = {}
    end

    # +metrics+ (classes) made, and their measures' specs: only those
    # available here, with +measures+ (Config#measure) changing their
    # settings (each metric's own too: Metric#settings), and leaving out
    # those skipped (and a metric whose measures all are). Two that
    # measure the same name, a change to one none measures, or a setting
    # there isn't, fail.
    def self.made(metrics, measures)
      metrics.each { |metric| metric.measures.each { |name, settings| Metric.check(name, settings) } }
      names = metrics.flat_map { |metric| metric.measures.keys }
      twice = names.select { |name| names.count(name) > 1 }.uniq
      raise Error, "more than one metric measures #{twice.join(", ")}" unless twice.empty?
      unknown = measures.keys - names
      raise Error, "no metric measures #{unknown.join(", ")} (c.measure)" unless unknown.empty?

      skipped = measures.select { |_, settings| settings[:skip] }.keys
      made = metrics.select(&:available?).reject { |metric| (metric.measures.keys - skipped).empty? }.map(&:new)
      made.each { |metric| metric.settings = metric.class.settings(measures) }
      [made, made.flat_map { |metric| metric.class.specs(measures) }.reject { |spec| skipped.include?(spec.fetch("name")) }]
    end

    # What the runner learns first: the benchmarks, the metrics, and
    # whether peak memory and profiles can be measured here.
    def hello
      {"benchmarks" => @benchmarks.values.map(&:to_h), "metrics" => @specs, "ruby" => RUBY_DESCRIPTION,
       "memory" => !Native::Memory.resident.nil?, "profiler" => Worker.profiler?}
    end

    # Whether StackProf (CRuby) is installed, for profiles.
    def self.profiler?
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

    # Runs its file's setup blocks, then (if +trial+) the benchmark once,
    # unmeasured (see Context#trial).
    def setup(name, trial)
      context = Context.new(@benchmarks.fetch(name))
      context.prepare
      context.trial if trial
      @contexts[name] = context
      {"ok" => true}
    end

    # Runs +n+ iterations +runs+ times; reports each timed metric's least
    # (interference only ever adds time, so the least is the closest to
    # what the code itself costs) and the last run's counts.
    def sample(name, n, count, runs)
      context = @contexts.fetch(name)
      samples = Array.new(runs) { Sample.new(context.definition, @metrics, n: n, counting: count).tap { |s| context.run(n, s) } }
      timed = samples.first.timed.to_h { |metric| [metric, samples.map { |s| s.timed.fetch(metric) }.min] }
      {"timed" => timed, "counted" => samples.last.counted, "heap" => samples.last.heap, "details" => samples.last.details}
    end

    # The peak memory of +n+ iterations (see MemorySample), in bytes.
    def memory(name, n)
      sample = MemorySample.new
      @contexts.fetch(name).run_memory(n, sample)
      {"peak" => sample.peak}
    end

    # A CPU profile of +n+ iterations, +runs+ times over: every frame's
    # samples [name, self, total], most total first, and how many samples
    # there were.
    def profile(name, n, runs)
      require "stackprof"
      # @type var frames: Hash[String, [Integer, Integer]]
      frames = Hash.new do |h, k|
        h[k] = [0, 0] #: [Integer, Integer]
      end
      samples = 0
      runs.times do
        sample = ProfileSample.new
        @contexts.fetch(name).run(n, sample)
        samples += sample.results.fetch(:samples)
        sample.results.fetch(:frames).each_value do |frame|
          counts = frames[frame.fetch(:name)]
          counts[0] += frame.fetch(:samples)
          counts[1] += frame.fetch(:total_samples)
        end
      end
      {"samples" => samples, "frames" => frames.sort_by { |_, (_, total)| -total }.map { |frame, (own, total)| [frame, own, total] }}
    end

    def teardown(name)
      @contexts.delete(name)&.finish
      {"ok" => true}
    end
  end
end
