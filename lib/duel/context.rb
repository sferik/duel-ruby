# frozen_string_literal: true

require_relative "native"

module Duel
  # What a benchmark's blocks run in (its file's hooks, and its own, too):
  # its state lives in instance variables. Its methods are the two a
  # benchmark calls, #once and #untimed, and the helpers that files of
  # benchmarks define: what the worker does with it is its Harness's, so
  # a helper's name is never Duel's (see .check).
  class Context
    # (Its one instance variable is named so that a benchmark's, which
    # live beside it, never clash with it.)

    # @api private
    def initialize(harness)
      @__duel_harness = harness
    end

    # Runs the block the first time the benchmark runs: its trial (see
    # Harness#trial), or, in a worker that ran none, its first peak
    # memory sample (see Harness#run_memory), as an untimed block. Never
    # when it's measured otherwise. (Not the setup hook, which runs
    # before the benchmark, outside its block: see HOOKS.)
    def once(&) = @__duel_harness.once(&)

    # Runs the block with measuring paused (see DSL#duel), and returns
    # what it does.
    def untimed(&) = @__duel_harness.untimed(&)

    # Fails if a helper that files of benchmarks define (a method of
    # Object's own: a def at the top of a file) has the name of a method
    # Duel gives them, a Context's or the DSL's: Duel's would hide it, and
    # its callers would call Duel's instead.
    # @api private
    def self.check
      (public_instance_methods(false) + DSL.instance_methods).each do |name|
        next unless Object.method_defined?(name, false) || Object.private_method_defined?(name, false)

        raise Error, "#{Duel.where(Object.instance_method(name))}: a helper can't be named #{name}, Duel's is: rename it"
      end
    end
  end

  # A benchmark as a worker runs it: its Context, its hooks (the
  # configuration's, its file's and its own: see HOOKS), its trial and
  # its samples.
  # @api private
  class Harness
    # Nothing left by pausing and resuming (see #leak).
    NO_LEAK = {} #: Hash[String, Float]

    # The iterations that each of a calibration's CALIBRATION samples
    # pauses and resumes (see #leak).
    STRETCHES = 1000

    # The iterations of each of the CALIBRATION samples that learn what
    # around_iteration hooks add to the metrics that are costly to read
    # (see #leak).
    HOOKED = 10

    attr_reader :definition, :context

    # +hooks+: the configuration's (Config#hooks), by name.
    def initialize(definition, hooks = NO_HOOKS)
      @definition = definition
      @context = Context.new(self)
      body = definition.body
      @body = bound(body)
      @given_n = body.arity == 1
      @setup = hooks(:setup, hooks).map { |hook| given(hook) }
      @teardown = hooks(:teardown, hooks).map { |hook| given(hook) }.reverse
      @before_sample = hooks(:before_sample, hooks).map { |hook| given(hook) }
      @after = hooks(:after_iterations, hooks)
      # (Each around_iteration hook's Iteration, innermost first, made once:
      # running one allocates nothing.)
      iteration = nil #: Iteration?
      hooks(:around_iteration, hooks).reverse_each { |hook| iteration = Iteration.new(self, hook, iteration) }
      @iteration = iteration
      raise Error, "#{definition.name}: around_iteration runs around each iteration: give the benchmark's block no parameter" if @given_n && @iteration
    end

    # (See Context#once.)
    def once(&)
      if @trial then yield
      elsif @once_done == false then untimed(&)
      end
    end

    # (See Context#untimed.)
    def untimed(&)
      sample = @sample || raise(Error, "#{@definition.name}: untimed outside a sample")
      # (Inside an around_iteration hook, or another untimed block, it's
      # paused already.)
      Duel.measuring? ? sample.pause { Duel.measured(false, &) } : yield
    end

    # Runs its setup hooks.
    def prepare = @setup.each(&:call)

    # Runs its teardown hooks (each level's last first, the benchmark's
    # first).
    def finish = @teardown.each(&:call)

    # Runs the benchmark once, measuring nothing, with its once blocks:
    # one that this version can't run (it uses something new) fails here.
    def trial
      @trial = true
      run(1, Trial.new)
    ensure
      @trial = false
      @once_done = true
    end

    # Runs one sample of +n+ iterations for its peak memory, measured by
    # +sample+ (a MemorySample). A worker that ran no trial (one doesn't,
    # for peak memory: see Worker#setup) runs the benchmark's once blocks
    # in it.
    def run_memory(n, sample)
      @once_done ||= false # (nil, with no trial: once blocks run in this sample)
      run(n, sample)
    ensure
      @once_done = true
    end

    # Runs one sample of +n+ iterations, measured by +sample+ (a Sample),
    # once its before_sample hooks have run: a block without a parameter
    # n times, or one with once, given n, and then its after_iterations
    # hooks.
    def run(n, sample)
      @sample = sample
      @before_sample.each(&:call)
      sample.start
      begin
        # (A trial measures nothing.)
        Duel.measured(!@trial) { iterate(n, sample) }
      ensure
        sample.stop
      end
    ensure
      @sample = nil
    end

    # Whether it runs inside around_iteration hooks.
    def around? = !@iteration.nil?

    # A Sample of +n+ iterations of it, measured by +metrics+ (see
    # Sample.new).
    def sample(metrics, n:, counting: true) = Sample.new(@definition, metrics, n: n, counting: counting, around: around?)

    # What a benchmark with around_iteration hooks leaves in each of
    # +metrics+' measures, an iteration, that isn't the iteration's own,
    # learned once in each worker: for those paused around each
    # iteration (see Iteration), what pausing and resuming leaves (the
    # readings' own cost, mostly), and for those costly to read
    # (Metric.costly?), which aren't, what the hooks add (see #hooked).
    # Taken from each sample's measures (Sample#less), it doesn't water a
    # regression down. Nothing, for a benchmark without them.
    def leak(metrics)
      return NO_LEAK unless @iteration

      @leak ||= begin
        costly, cheap = metrics.partition { |metric| metric.class.costly? }
        paused(cheap).merge(hooked(costly))
      end
    end

    # Runs one iteration, measured, then its after_iterations hooks
    # (inside the innermost Iteration), and returns what the iteration
    # does.
    def iteration
      Duel.measured(!@trial) do
        sample = @sample #: _Sample
        sample.unpause do
          done = @body.call
          @after.each(&:call)
          done
        end
      end
    end

    private

    # The hooks +name+d: +hooks+' (the configuration's, as they are), then
    # its file's and its own (run in its context).
    def hooks(name, hooks)
      file = Duel.file_hooks.fetch(@definition.file, NO_HOOKS).fetch(name)
      hooks.fetch(name) + [*file, *@definition.hooks[name]].map { |hook| bound(hook) }
    end

    # +hook+, given the benchmark, if it takes it.
    def given(hook)
      return hook if hook.arity.zero?

      definition = @definition
      -> { hook.call(definition) }
    end

    # What pausing and resuming leaves in each of +metrics+' measures, an
    # iteration: the least of what CALIBRATION samples of STRETCHES empty
    # iterations left.
    def paused(metrics)
      runs = Array.new(Snapshot::CALIBRATION) do
        sample = Sample.new(@definition, metrics, n: STRETCHES)
        sample.start
        sample.between { STRETCHES.times { sample.unpause {} } }
        sample.stop
        sample.timed.merge(sample.counted)
      end
      # (Two stretches more: from the start, and to the stop.)
      least(runs, STRETCHES + 2)
    end

    # What the around_iteration hooks add to each of +metrics+' measures
    # (those costly to read), an iteration: the least of what CALIBRATION
    # samples of HOOKED iterations (each run as any sample's, hooks and
    # all) measured with every iteration left out (see Hooked). What a
    # hook does that depends on its iteration (rolling back what it
    # wrote, say) is in it too. Nothing, without such metrics.
    def hooked(metrics)
      return NO_LEAK if metrics.empty?

      runs = Array.new(Snapshot::CALIBRATION) do
        sample = Sample.new(@definition, metrics, n: HOOKED)
        run(HOOKED, Hooked.new(sample))
        sample.timed.merge(sample.counted)
      end
      least(runs, HOOKED)
    end

    # Each measure's least in +runs+, over +stretches+.
    def least(runs, stretches) = runs.first.to_h { |name, _| [name, runs.map { |run| run.fetch(name) }.min.fdiv(stretches)] }

    # Runs +n+ iterations, then its after_iterations hooks, each inside
    # the around_iteration hooks if it has them, with +sample+ paused
    # (Sample#between) but while each iteration runs. (Nothing allocated
    # an iteration: a bound method's call allocates nothing, where
    # instance_exec would.)
    def iterate(n, sample)
      iteration = @iteration
      if iteration
        sample.between do
          Duel.measured(false) do
            i = 0
            while i < n
              iteration.run
              i += 1
            end
          end
        end
      elsif @given_n
        @body.call(n)
        @after.each(&:call)
      else
        i = 0
        while i < n
          @body.call
          i += 1
        end
        @after.each(&:call)
      end
    end

    # +block+ as a method of the context's (of a module of its own, not
    # the context's class: no name of a helper's is taken).
    def bound(block) = Module.new { define_method(:call, &block) }.instance_method(:call).bind(@context)
  end

  # An iteration of a benchmark with around_iteration hooks, which a hook
  # is given to run, by #call: the iteration, and its after_iterations
  # hooks, are measured, and the rest of the hook isn't. Making one is
  # @api private.
  class Iteration
    # Given to +hook+, it runs the hook given +inner+ (the next
    # around_iteration hook's Iteration), or, innermost (+inner+ nil),
    # +harness+'s iteration.
    # @api private
    def initialize(harness, hook, inner)
      @harness = harness
      @hook = hook
      @inner = inner
    end

    # Runs the iteration, measured (inside any hooks inner to this one),
    # and returns what it does. Once, and only once, each time the hook
    # is called.
    def call
      raise Error, "#{@harness.definition.name}: around_iteration ran its iteration twice" if @ran

      @ran = true
      inner = @inner
      @done = inner ? inner.run : @harness.iteration
    end

    # Runs its hook, given it, and returns what its iteration did: a hook
    # that didn't run it fails.
    # @api private
    def run
      @ran = false
      @hook.call(self)
      raise Error, "#{@harness.definition.name}: around_iteration didn't run its iteration" unless @ran

      @done
    end
  end

  # One measured stretch of a benchmark: every metric's measurement of it,
  # and (CRuby) about how many bytes it allocated (#heap), which pile up
  # while the garbage collector is held off. A metric's #start_sample gets it:
  # its #benchmark and #n are the metric's to read, and the rest is the
  # worker's.
  class Sample
    # Zero bytes allocated: what JRuby tells (see HEAP).
    # @api private
    NO_HEAP = -> { 0 }

    # Bytes allocated so far, roughly: objects (at the least an object
    # takes, heap 0's slot) and memory malloc'd. Zero on JRuby, whose collector isn't
    # held off (and doesn't tell).
    # @api private
    HEAP = {
      "ruby" => -> { (GC.stat_heap(0, :slot_size) * GC.stat(:total_allocated_objects)) + GC.stat(:malloc_increase_bytes) }
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
    # innermost, last). +counting+: whether counted measures are taken
    # too (ratio ones always are). +around+: whether its benchmark runs
    # inside around_iteration hooks (see Harness#around?).
    # @api private
    def initialize(benchmark, metrics, n:, counting: true, around: false)
      @benchmark = benchmark
      @n = n
      @counting = counting
      @metrics = metrics.select { |m| m.kinds.value?(:ratio) || counting }
      # (Those paused around each iteration, inside around_iteration hooks:
      # not those costly to read. Without such hooks, or such a metric, the
      # same Array: nothing more is allocated, or worked out for every
      # sample.)
      @paused = (around && @metrics.any? { |m| m.class.costly? }) ? @metrics.reject { |m| m.class.costly? } : @metrics
      # (How a measurement is filed is worked out now, not while measuring.)
      @metrics.each(&:first_measure)
      @timed = {}
      @counted = {}
      @details = {}
    end

    # @api private
    def start
      @started = true
      QUIET_GC.call
      @heap = -HEAP.call
      @metrics.each { |m| m.start_sample(self) }
    end

    # @api private
    def stop
      @metrics.reverse_each { |m| record(m, m.stop_sample) }
      @heap += HEAP.call
      GC.enable
      @metrics.each { |m| explain(m) }
      @stopped = true
    end

    # Runs the block with the metrics paused (what they measured so far
    # kept), and returns what it does. The garbage collector stays off.
    # @api private
    def pause
      @metrics.reverse_each { |m| record(m, m.pause_sample) }
      yield
    ensure
      @metrics.each { |m| m.resume_sample(self) }
    end

    # Runs the block (around_iteration hooks, around each iteration: see
    # Iteration) with the metrics paused, but those costly to read
    # (Metric.costly?), which go on measuring (what the hooks add to them
    # is taken away instead: see Harness#leak). Returns what it does.
    # @api private
    def between
      @paused.reverse_each { |m| record(m, m.pause_sample) }
      yield
    ensure
      @paused.each { |m| m.resume_sample(self) }
    end

    # Runs the block measured, inside #between's (an iteration inside its
    # around_iteration hooks), and returns what it does. Neither this nor #between
    # allocates anything, so the allocations counted around it are the
    # block's own.
    # @api private
    def unpause
      @paused.each { |m| m.resume_sample(self) }
      yield
    ensure
      @paused.reverse_each { |m| record(m, m.pause_sample) }
    end

    # Takes +leak+ (Harness#leak) away from each measure, once an
    # iteration, but no further than nothing.
    # @api private
    def less(leak)
      [@timed, @counted].each do |totals|
        totals.each { |name, total| totals[name] = [total - (leak.fetch(name, 0) * @n).round, 0].max }
      end
    end

    private

    # Keeps what a metric says of the sample (Metric#details), by measure.
    def explain(metric)
      case (said = metric.details)
      when Hash then @details.merge!(said)
      when String then @details.merge!(metric.kinds.transform_values { said })
      end
    end

    # Files a metric's measurement (a Hash of them, by name, or one: its
    # first measure's) by kind.
    def record(metric, value)
      kinds = metric.kinds
      case value
      when Hash then value.each { |name, measured| file(kinds, name, measured) }
      else file(kinds, metric.first_measure, value)
      end
    end

    # Adds +measured+ (nil: nothing this time) to +name+'s total, of its
    # kind (counted ones only when counting).
    def file(kinds, name, measured)
      return if measured.nil?

      kind = kinds.fetch(name)
      return unless kind == :ratio || @counting

      totals = (kind == :ratio) ? @timed : @counted
      totals[name] = totals.fetch(name, 0) + measured
    end
  end

  # A sample of what a benchmark's around_iteration hooks add to the
  # metrics that are costly to read (Metric.costly?), which go on
  # measuring around each iteration: +sample+ (a Sample of those)
  # measures all but the iterations (see Harness#leak).
  # @api private
  class Hooked
    def initialize(sample)
      @sample = sample
    end

    def start = @sample.start

    def stop = @sample.stop

    # Runs the block (an untimed one, inside an iteration): paused
    # already.
    def pause = yield

    # Runs the block (the around_iteration hooks): measured.
    def between = yield

    # Runs the block (an iteration, inside its hooks) paused.
    def unpause(&) = @sample.pause(&)
  end

  # A run of a benchmark that measures nothing: to see that it runs.
  # @api private
  class Trial
    attr_reader :started, :stopped

    def start = @started = true

    def stop = @stopped = true

    def pause = yield

    def between = yield

    def unpause = yield
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

    # Runs the block (an untimed one, or a benchmark's once: see
    # Context#once) unwatched, and what it leaves resident isn't counted:
    # the peak is the measured work's, as every other measure is.
    def pause
      unwatched
      begin
        yield
      ensure
        watched
      end
    end

    # Runs the block (around_iteration hooks, around each iteration)
    # unwatched, as #pause does.
    def between(&) = pause(&)

    # Runs the block watched, inside #between's (an iteration inside its
    # around_iteration hooks): what it leaves resident is counted after
    # all.
    def unpause
      watched
      begin
        yield
      ensure
        unwatched
      end
    end

    private

    # From now on, nothing is watched, and what's left resident isn't
    # counted.
    def unwatched
      @paused = true
      @unwatched = resident
    end

    # From now on, what's resident is watched again, above what was left
    # while it wasn't.
    def watched
      @base += resident - @unwatched
      @paused = false
    end

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

  # A stretch of a benchmark profiled, as a Sample measures it: with the
  # garbage collector held off until it's over (its cost shows in the
  # allocation count). StackProf runs throughout (see Worker#profile), and
  # what it samples outside the iterations (Harness#iterate), or in
  # #pause but not in an iteration inside it, is left out (see
  # Profile.of).
  # @api private
  class ProfileSample
    INTERVAL = 100 # microseconds between StackProf's samples

    # What StackProf samples by on +platform+: CPU time, but on macOS,
    # elapsed time. macOS signals that CPU time is up only as the thread
    # enters the kernel, so its samples pile up on whatever makes system
    # calls, the most CPU-hungry code or not. A benchmark busy on the CPU
    # spends elapsed time the same way.
    def self.mode(platform = RUBY_PLATFORM) = platform.include?("darwin") ? :wall : :cpu

    MODE = mode

    attr_reader :started, :stopped

    def start
      @started = true
      Sample::QUIET_GC.call
    end

    def stop
      GC.enable
      @stopped = true
    end

    # Runs the block (an untimed one, or the around_iteration hooks of a
    # benchmark with them: see #between): what it does is sampled in this
    # method, so it's left out, all but an iteration inside it (see
    # #unpause).
    def pause = yield

    # Runs the block (a benchmark's around_iteration hooks) in #pause.
    def between(&) = pause(&)

    # Runs the block (an iteration, inside its around_iteration hooks:
    # see Iteration): what it does is sampled in Harness#iteration, inside
    # #pause, so it's kept.
    def unpause = yield
  end
end
