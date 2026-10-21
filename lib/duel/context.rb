# frozen_string_literal: true

require_relative "native"

module Duel
  # What a benchmark's blocks run in (its file's setup and teardown
  # blocks too): its state lives in instance variables. Its #setup and
  # #untimed are a benchmark's to call; the rest is the worker's.
  class Context
    # @api private
    attr_reader :definition

    # @api private
    def initialize(definition)
      @definition = definition
    end

    # Runs the block the first time the benchmark runs: its trial (see
    # #trial), or, in a worker that ran none, its first peak memory sample
    # (see #run_memory), as an untimed block. Never when it's measured
    # otherwise.
    def setup(&)
      if @trial then yield
      elsif @set_up == false then untimed(&)
      end
    end

    # Runs the block with measuring paused (see DSL#duel); returns what it
    # does.
    def untimed(&)
      (@sample || raise(Error, "#{@definition.name}: untimed outside a sample")).pause { Duel.measured(false, &) }
    end

    # -- used by the worker --------------------------------------------------

    # Runs its file's setup blocks.
    # @api private
    def prepare = Duel.setups.fetch(@definition.file, []).each { |block| instance_exec(&block) }

    # Runs its file's teardown blocks, last first.
    # @api private
    def finish = Duel.teardowns.fetch(@definition.file, []).reverse_each { |block| instance_exec(&block) }

    # Runs the benchmark once, measuring nothing, with its setup blocks:
    # one that this version can't run (it uses something new) fails here.
    # @api private
    def trial
      @trial = true
      run(1, Trial.new)
    ensure
      @trial = false
      @set_up = true
    end

    # Runs one sample of +n+ iterations for its peak memory, measured by
    # +sample+ (a MemorySample). A worker that ran no trial (one doesn't,
    # for peak memory: see Worker#setup) runs the benchmark's setup blocks
    # in it.
    # @api private
    def run_memory(n, sample)
      @set_up ||= false # (nil, with no trial: set up in this sample)
      run(n, sample)
    ensure
      @set_up = true
    end

    # Runs one sample of +n+ iterations, measured by +sample+ (a Sample):
    # a block without a parameter n times, one with once, given n.
    # @api private
    def run(n, sample)
      @sample = sample
      body = @definition.body
      sample.start
      begin
        # (A trial measures nothing.)
        Duel.measured(!@trial) { (body.arity == 1) ? instance_exec(n, &body) : n.times { instance_exec(&body) } }
      ensure
        sample.stop
      end
    ensure
      @sample = nil
    end
  end

  # One measured stretch of a benchmark: every metric's measurement of it,
  # and (CRuby) about how many bytes it allocated (#heap), which pile up
  # while the garbage collector is held off. A metric's #start gets it:
  # its #benchmark and #n are the metric's to read; the rest is the
  # worker's.
  class Sample
    # Zero bytes allocated: what JRuby tells (see HEAP).
    # @api private
    NO_HEAP = -> { 0 }

    # Bytes allocated so far, roughly: objects (at the least an object
    # takes) and memory malloc'd. Zero on JRuby, whose collector isn't
    # held off (and doesn't tell).
    # @api private
    HEAP = {
      "ruby" => -> { (GC::INTERNAL_CONSTANTS.fetch(:BASE_SLOT_SIZE) * GC.stat(:total_allocated_objects)) + GC.stat(:malloc_increase_bytes) }
    }.fetch(RUBY_ENGINE, NO_HEAP)

    # Collects the garbage left so far, then holds off collecting until
    # the sample is over: when a collection lands is up to chance, so it
    # would only add noise. Its cost grows with what's allocated, which
    # is counted exactly instead. (JRuby's collector can't be held off.)
    # @api private
    QUIET_GC = {
      "ruby" => lambda do
        GC.start(full_mark: false)
        GC.disable
      end
    }.fetch(RUBY_ENGINE, -> {})

    # What a metric learns of the sample: its benchmark (a Definition:
    # name, only, peak_memory) and its iterations.
    attr_reader :benchmark, :n

    # @api private
    attr_reader :started, :stopped, :timed, :counted, :heap, :details

    # +metrics+: the worker's metric instances, outermost first (CPU, the
    # innermost, last); +counting+: whether counted measures are taken
    # too (ratio ones always are).
    # @api private
    def initialize(benchmark, metrics, n:, counting:)
      @benchmark = benchmark
      @n = n
      @counting = counting
      @metrics = metrics.select { |m| counting || m.class.kinds.value?(:ratio) }
      @timed = {}
      @counted = {}
      @details = {}
    end

    # @api private
    def start
      @started = true
      QUIET_GC.call
      @heap = -HEAP.call
      @metrics.each { |m| m.start(self) }
    end

    # @api private
    def stop
      @metrics.reverse_each { |m| record(m.class, m.stop) }
      @heap += HEAP.call
      GC.enable
      @metrics.each { |m| explain(m) }
      @stopped = true
    end

    # Runs the block with the metrics paused (what they measured so far
    # kept); returns what it does. The garbage collector stays off.
    # @api private
    def pause
      @metrics.reverse_each { |m| record(m.class, m.pause) }
      yield
    ensure
      @metrics.each { |m| m.resume(self) }
    end

    private

    # Keeps what a metric says of the sample (Metric#details), by measure.
    def explain(metric)
      case (said = metric.details)
      when Hash then @details.merge!(said)
      when String then @details.merge!(metric.class.kinds.transform_values { said })
      end
    end

    # Files a metric's measurement (or several, by name) by kind.
    def record(metric, value)
      # (A Hash of them, or one: Steep doesn't narrow by Hash.try_convert.)
      values = Hash.try_convert(value) || {metric.measures.keys.first => value} #: Hash[String, Metric::value?]
      values.each do |name, measured|
        next if measured.nil?

        kind = metric.kinds.fetch(name)
        next unless kind == :ratio || @counting

        totals = (kind == :ratio) ? @timed : @counted
        totals[name] = totals.fetch(name, 0) + measured
      end
    end
  end

  # A run of a benchmark that measures nothing: to see that it runs.
  # @api private
  class Trial
    attr_reader :started, :stopped

    def start = @started = true

    def stop = @stopped = true

    def pause = yield
  end

  # A stretch of a benchmark run for its peak memory: with the garbage
  # collector working as usual, the most resident memory the process
  # reached above where it started (after a full collection), watched
  # every millisecond.
  # @api private
  class MemorySample
    attr_reader :started, :stopped, :peak

    def start
      @started = true
      GC.start(full_mark: true, immediate_sweep: true)
      @base = resident
      @peak = 0
      @watcher = Thread.new do
        loop do
          watch
          sleep 0.001
        end
      end
    end

    def stop
      @watcher.kill
      @watcher.join
      watch
      @stopped = true
    end

    # Runs the block (an untimed one, or a benchmark's setup: see
    # Context#setup) unwatched, and what it leaves resident isn't counted:
    # the peak is the measured work's, as every other measure is.
    def pause
      @paused = true
      before = resident
      begin
        yield
      ensure
        @base += resident - before
        @paused = false
      end
    end

    private

    def resident
      # (Resident memory is known: see Lane#peak_memory.)
      Native::Memory.resident #: Integer
    end

    def watch
      return if @paused

      above = resident - @base
      @peak = above if above > @peak
    end
  end

  # A stretch of a benchmark profiled with StackProf (in CPU time).
  # @api private
  class ProfileSample
    INTERVAL = 100 # microseconds between samples

    attr_reader :started, :stopped, :results

    def start
      @started = true
      StackProf.start(mode: :cpu, interval: INTERVAL)
    end

    def stop
      StackProf.stop
      @results = StackProf.results
      @stopped = true
    end

    def pause = yield
  end
end
