# frozen_string_literal: true

require_relative "test_helper"

# How a worker runs a benchmark (Harness): with its hooks (the
# configuration's, its file's and its own), around each iteration
# (around_iteration), before each sample (before_sample) and after its
# iterations (after_iterations), and with what's Duel's apart from what's
# a benchmark's (Context).
class HarnessTest < DuelTest
  cover "Duel::Harness*"
  cover "Duel::Iteration*"
  cover "Duel::Context*"
  cover "Duel::Sample*"
  cover "Duel::MemorySample*"
  cover "Duel::Trial*"
  cover "Duel::ProfileSample*"
  cover "Duel::Hooked*"
  cover "Duel::DSL.add"
  cover "Duel::DSL.define"
  cover "Duel.where"

  # A metric of ticks, for counting exactly what's measured.
  class Ticks < Duel::Metric
    class << self
      attr_accessor :now
    end

    def start_sample(_sample) = @started = Ticks.now

    def stop_sample = Ticks.now - @started
  end

  def setup
    super
    Ticks.now = 0
  end

  # A benchmark in /duel/x_duel.rb, with its own +hooks+.
  def definition(name = "x", **hooks, &body) = Duel::Definition.new(name, nil, false, "/duel/x_duel.rb", body, hooks)

  # The configuration's hooks: +hooks+, by name, and none of the rest.
  def config_hooks(**hooks) = Duel::NO_HOOKS.merge(hooks)

  # The ticks a sample of +n+ iterations counted.
  def ticks(harness, n)
    sample = Duel::Sample.new(harness.definition, [Ticks.new], n: n, counting: true)
    harness.run(n, sample)
    sample.counted.fetch("ticks")
  end

  # Where #helpers defines them.
  HELPER = __LINE__ + 6

  # Defines a helper, as a def at the top of a file does (a private
  # method of Object's), during the block.
  def helpers(names, owner: Object, visibility: :private)
    names.each do |name|
      owner.send(:define_method, name) { |*| "helper #{name}" }
      owner.send(visibility, name)
    end
    yield
  ensure
    names.each { |name| owner.send(:remove_method, name) }
  end

  # A helper named as the worker's own methods are (as Context's were,
  # which hid it) is the benchmark's to call.
  def test_helpers_named_as_the_workers_own_methods
    names = %i[run trial prepare finish definition run_memory iteration hooks given leak]
    seen = []
    helpers(names) do
      Duel::Harness.new(definition { seen.concat(names.map { |name| send(name) }) }).trial
    end

    assert_equal names.map { |name| "helper #{name}" }, seen
  end

  # One named as a method Duel gives benchmarks (a Context's, or the
  # DSL's) would be hidden by Duel's: it fails, saying where it is. One
  # every object gets from elsewhere (Kernel, say) isn't a helper.
  def test_a_helper_named_as_duels_own_fails
    Duel::Context.check
    %i[once setup untimed duel duel_process before_sample around_iteration after_iterations ⚔️].each do |name|
      error = assert_raises(Duel::Error) { helpers([name]) { Duel::Context.check } }

      assert_equal "#{__FILE__}:#{HELPER}: a helper can't be named #{name}, Duel's is: rename it", error.message
    end
    assert_raises(Duel::Error) { helpers([:untimed], visibility: :public) { Duel::Context.check } }
    helpers([:untimed], owner: Kernel) { Duel::Context.check }
    helpers([:untimed], owner: Kernel, visibility: :public) { Duel::Context.check }
  end

  # A plugin's own DSL methods (its DSL module's public ones): each is
  # given what the files of benchmarks that call it give it, and can call
  # duel. Adding a module's again does nothing, and a name that's taken
  # fails, saying by what.
  def test_a_plugins_dsl_methods
    line = __LINE__ + 4
    methods = Module.new do
      include(Module.new { def included_helper = nil })

      def duel_twice(name, &body) = %w[a b].map { |side| duel("#{name} #{side}", &body) }

      private def helper = nil
    end

    assert_equal [:duel_twice], Duel::DSL.add(methods)
    assert_equal [:duel_twice], Duel::DSL.add(methods), "again"
    DSL.duel_twice("x") { 1 }

    assert_equal ["x a", "x b"], Duel.benchmarks.keys
    refute Duel::DSL.private_method_defined?(:helper), "only its public methods"
    refute Duel::DSL.method_defined?(:included_helper), "only its own"
    {duel_twice: "#{__FILE__}:#{line}", duel: Duel.where(Duel::DSL.instance_method(:duel)),
     duel_process: Duel.where(Duel::DSL.instance_method(:duel_process)), test: "Kernel", respond_to?: "Kernel"}.each do |name, by|
      clash = Module.new { define_method(name) { nil } }
      error = assert_raises(Duel::Error) { Duel::DSL.add(clash) }

      assert_equal "#{clash.inspect}##{name}: the DSL has #{name} already (#{by})", error.message
    end
    assert_match(%r{/lib/duel\.rb:\d+\z}, Duel.where(Duel::DSL.instance_method(:duel)))
    assert_equal "Kernel", Duel.where(Kernel.instance_method(:respond_to?))
  end

  # A sample's iterations allocate nothing of Duel's, an iteration or at
  # all (once warmed up, as a worker is: Ruby makes a call site's cache
  # the first time it's run): a benchmark that allocates nothing counts
  # none, around_iteration hooks and all.
  def test_iterations_allocate_nothing
    skip "CRuby's allocations" unless RUBY_ENGINE == "ruby"

    [definition { nil }, definition(around_iteration: ->(iteration) { iteration.call }) { nil }].each do |benchmark|
      harness = Duel::Harness.new(benchmark)
      counted = [1, 1, 1000].map do |n|
        sample = Duel::Sample.new(benchmark, [Duel::Metrics::Allocations.new, Duel::Metrics::CPU.new], n: n, counting: true)
        harness.run(n, sample)
        sample.counted.fetch("allocations")
      end

      assert_equal [0, 0], counted.drop(1), benchmark.hooks.empty? ? "plain" : "around"
    end
  end

  # Only the iteration is measured (and Duel.measuring?): what its
  # around_iteration hook, run in the benchmark's context, does before
  # and after it isn't. A trial measures neither.
  def test_around_measures_only_the_iteration
    seen = []
    around = lambda do |iteration|
      Ticks.now += 100
      seen << [:around, Duel.measuring?, @state]
      seen << [:ran, iteration.call]
      Ticks.now += 1000
    end
    harness = Duel::Harness.new(definition(around_iteration: around) { (Ticks.now += 1) && (seen << [:iteration, Duel.measuring?]) && :done })
    harness.context.instance_variable_set(:@state, :mine)

    assert_equal 3, ticks(harness, 3)
    assert_equal [[:around, false, :mine], [:iteration, true], [:ran, :done]] * 3, seen
    seen.clear
    harness.trial

    assert_equal [[:around, false, :mine], [:iteration, false], [:ran, :done]], seen
    refute_predicate Duel, :measuring?
  end

  # An around_iteration hook runs its iteration once: twice, or not at
  # all, fails, and so does an inner one's, inside an outer one.
  def test_around_runs_its_iteration_once
    twice = Duel::Harness.new(definition("twice", around_iteration: ->(iteration) { 2.times { iteration.call } }) { 1 })

    assert_equal "twice: around_iteration ran its iteration twice", assert_raises(Duel::Error) { twice.trial }.message
    never = Duel::Harness.new(definition("never", around_iteration: ->(_iteration) {}) { 1 })

    assert_equal "never: around_iteration didn't run its iteration", assert_raises(Duel::Error) { never.trial }.message
    inner = Duel::Harness.new(definition("inner", around_iteration: ->(_iteration) {}) { 1 }, config_hooks(around_iteration: [->(iteration) { iteration.call }]))

    assert_equal "inner: around_iteration didn't run its iteration", assert_raises(Duel::Error) { inner.trial }.message
  end

  # An around_iteration hook takes the iteration (a proc, or any kind of
  # one), around a benchmark that runs once an iteration: one with a
  # parameter, given hooks of its configuration's or its file's, fails.
  def test_around_needs_an_iteration
    error = assert_raises(ArgumentError) { duel("symbol", around_iteration: :rollback) { 1 } }

    assert_equal "around_iteration: give a block (or a lambda), not :rollback", error.message
    assert_raises(ArgumentError) { duel("two", around_iteration: ->(iteration, _) { iteration.call }) { 1 } }
    assert_empty Duel.benchmarks
    around = proc { |iteration| iteration.call }

    assert_same around, duel("proc", around_iteration: around) { 1 }.hooks.fetch(:around_iteration)
    around = Class.new(Proc).new { |iteration| iteration.call }

    assert_same around, duel("a kind of proc", around_iteration: around) { 1 }.hooks.fetch(:around_iteration)
    once = Duel::Definition.new("once", nil, false, "/duel/x_duel.rb", proc { |n| n }, {})
    error = assert_raises(Duel::Error) { Duel::Harness.new(once, config_hooks(around_iteration: [around])) }

    assert_equal "once: around_iteration runs around each iteration: give the benchmark's block no parameter", error.message
    Duel.file_hooks["/duel/x_duel.rb"][:around_iteration] << around

    assert_raises(Duel::Error) { Duel::Harness.new(once) }
  end

  # Each hook, from each level: the configuration's (as they are, given
  # the benchmark if they take it), then its file's, then its own (in its
  # context, given the benchmark if they take it), but teardown's in
  # reverse, and around_iteration's outermost first.
  def test_hooks_of_every_level
    log = []
    config = Duel::HOOKS.to_h do |hook|
      [hook, (hook == :around_iteration) ? [->(i) { (log << [hook, :config]) && i.call }] : [proc { |b| log << [hook, :config, b&.name] }]]
    end
    config.fetch(:teardown) << -> { log << %i[teardown config2] }
    file = Duel.file_hooks["/duel/x_duel.rb"]
    file[:setup] << -> { log << [:setup, :file, @mine] }
    file[:teardown] << proc { |b| log << [:teardown, :file, b.name] } << proc { log << %i[teardown file2] }
    file[:before_sample] << -> { log << %i[before_sample file] }
    file[:around_iteration] << ->(i) { (log << %i[around_iteration file]) && i.call }
    file[:after_iterations] << -> { log << %i[after_iterations file] }
    own = {setup: ->(b) { log << [:setup, :own, b.name, @mine] }, teardown: -> { log << %i[teardown own] },
           before_sample: -> { log << %i[before_sample own] }, after_iterations: -> { log << %i[after_iterations own] }}
    harness = Duel::Harness.new(definition(around_iteration: ->(i) { (log << %i[around_iteration own]) && i.call }, **own) { log << :iteration }, config)
    harness.context.instance_variable_set(:@mine, :mine)
    harness.prepare
    harness.run(1, Duel::Trial.new)
    harness.finish

    assert_equal [[:setup, :config, "x"], [:setup, :file, :mine], [:setup, :own, "x", :mine],
      [:before_sample, :config, "x"], %i[before_sample file], %i[before_sample own],
      %i[around_iteration config], %i[around_iteration file], %i[around_iteration own], :iteration,
      [:after_iterations, :config, nil], %i[after_iterations file], %i[after_iterations own],
      %i[teardown own], %i[teardown file2], [:teardown, :file, "x"], %i[teardown config2], [:teardown, :config, "x"]], log
  end

  # Inside nested around_iteration hooks, each one's iteration.call
  # returns what the iteration itself returned, whatever the hooks inside
  # return.
  def test_iteration_call_returns_what_the_iteration_returns
    seen = []
    outer = [->(iteration) { (seen << [:outer, iteration.call]) && :outer }]
    harness = Duel::Harness.new(definition(around_iteration: ->(iteration) { (seen << [:inner, iteration.call]) && :inner }) { :done },
      config_hooks(around_iteration: outer))
    harness.run(1, Duel::Trial.new)

    assert_equal [%i[inner done], %i[outer done]], seen
  end

  # Where measuring's paused already (in an around_iteration hook, or
  # another untimed block), an untimed block pauses nothing more.
  def test_untimed_where_measuring_is_paused
    around = ->(iteration) { untimed { Ticks.now += 100 } && iteration.call }
    harness = Duel::Harness.new(definition(around_iteration: around) { (Ticks.now += 1) && untimed { untimed { Ticks.now += 10 } } })

    assert_equal 2, ticks(harness, 2)
  end

  # What iterations left to do (after_iterations hooks) is done after
  # them, measured with them: once a sample, or, with around_iteration
  # hooks, inside each iteration. A trial measures neither.
  def test_after_iterations
    pending = 0
    log = []
    after = config_hooks(after_iterations: [-> { (Ticks.now += pending) && (log << [:after, pending, Duel.measuring?]) && (pending = 0) }])
    plain = Duel::Harness.new(definition { pending += 10 }, after)

    assert_equal 30, ticks(plain, 3)
    assert_equal [[:after, 30, true]], log
    log.clear
    plain.trial

    assert_equal [[:after, 10, false]], log
    log.clear
    around = Duel::Harness.new(definition(around_iteration: ->(iteration) { iteration.call && (log << :around) }) { pending += 10 }, after)

    assert_equal 20, ticks(around, 2)
    assert_equal [[:after, 10, true], :around] * 2, log
    log.clear
    once = Duel::Harness.new(Duel::Definition.new("n", nil, false, "/duel/x_duel.rb", proc { |n| pending += n }, {}), after)

    assert_equal 4, ticks(once, 4)
    assert_equal [[:after, 4, true]], log
  end

  # Before every sample (the trial's too), not measured: the config's
  # hooks, given the benchmark, then its file's, in its context.
  def test_before_sample
    log = []
    Duel.file_hooks["/duel/x_duel.rb"][:before_sample] << proc { (Ticks.now += 100) && (log << [:file, @mine, Duel.measuring?]) }
    Duel.file_hooks["/duel/other_duel.rb"][:before_sample] << proc { log << :other }
    configs = config_hooks(before_sample: [->(benchmark) { (Ticks.now += 100) && (log << [:config, benchmark.name]) }])
    harness = Duel::Harness.new(definition { (Ticks.now += 1) && (log << :iteration) }, configs)
    harness.context.instance_variable_set(:@mine, :mine)
    harness.trial

    assert_equal 2, ticks(harness, 2)
    assert_equal [[:config, "x"], [:file, :mine, false], :iteration, [:config, "x"], [:file, :mine, false], :iteration, :iteration], log
    memory = Duel::MemorySample.new
    stub(Duel::Native::Memory, :resident, -> { 1 }) { harness.run_memory(1, memory) }

    assert_equal [[:config, "x"], [:file, :mine, false], :iteration], log.last(3), "a peak memory sample's too"
  end

  # In an around_iteration hook, what the iteration leaves resident
  # counts, and what the hook leaves around it doesn't.
  def test_a_memory_sample_watches_only_iterations
    level = 100
    around = lambda do |iteration|
      level += 50
      iteration.call
      level -= 20
    end
    harness = Duel::Harness.new(definition(around_iteration: around) { (level += 5) && sleep(0.005) })
    sample = Duel::MemorySample.new
    stub(Duel::Native::Memory, :resident, -> { level }) { stub(GC, :start, ->(**) {}) { harness.run_memory(3, sample) } }

    assert_equal 15, sample.peak, "5 an iteration"
  end

  # Logs when it starts and stops.
  class Logged < Duel::Metric
    def initialize(name, log)
      super()
      @name = name
      @log = log
    end

    def start_sample(_sample) = @log << [:start, @name]

    def stop_sample = (@log << [:stop, @name]) && nil
  end

  # Around each iteration, metrics stop in reverse, and start again in
  # order, as they do around a sample.
  def test_metrics_stop_in_reverse_around_each_iteration
    log = []
    harness = Duel::Harness.new(definition(around_iteration: ->(iteration) { (log << :around) && iteration.call }) { log << :iteration })
    harness.run(1, Duel::Sample.new(harness.definition, [Logged.new(:outer, log), Logged.new(:inner, log)], n: 1))
    start = [%i[start outer], %i[start inner]]
    stop = [%i[stop inner], %i[stop outer]]

    assert_equal start + stop + [:around] + start + [:iteration] + stop + start + stop, log
  end

  # Work that keeps the CPU busy for a while, in methods of their own
  # names: what a profile can tell apart.
  module Busy
    def self.spin(seconds = 0.002)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    end

    def self.before = spin

    def self.iteration = spin

    def self.untimed = spin

    def self.after = spin

    def self.undone = spin
  end

  # A profile (StackProf's, for real) of a benchmark with around_iteration
  # hooks is of what's measured: its iterations, and what they left to
  # do. Not what runs before the sample, an untimed block, or the hooks'
  # own work, and not the pausing and resuming around each iteration.
  def test_a_profile_of_iterations_inside_their_around_block
    skip "StackProf is CRuby's" unless RUBY_ENGINE == "ruby"

    require "stackprof"
    benchmark = definition(around_iteration: ->(iteration) { iteration.call && Busy.undone }) { Busy.iteration || untimed { Busy.untimed } }
    harness = Duel::Harness.new(benchmark, config_hooks(before_sample: [->(_) { Busy.before }], after_iterations: [-> { Busy.after }]))
    StackProf.start(mode: Duel::ProfileSample::MODE, interval: Duel::ProfileSample::INTERVAL, raw: true)
    begin
      harness.run(10, Duel::ProfileSample.new)
    ensure
      StackProf.stop
    end
    frames = Duel::Profile.of(StackProf.results).fetch("frames").to_h { |frame, own, total| [frame, [own, total]] }

    assert_operator frames.fetch("HarnessTest::Busy.iteration").last, :>, 0
    assert_operator frames.fetch("HarnessTest::Busy.after").last, :>, 0
    assert_empty frames.keys & %w[HarnessTest::Busy.before HarnessTest::Busy.untimed HarnessTest::Busy.undone]
    # (Only the iteration in them: on a busy machine, a sample can still
    # land in one now and then, as it calls the next. With CPU time, as
    # on Linux, there are few samples in all.)
    iteration = frames.fetch("HarnessTest::Busy.iteration").last

    frames.values_at("Duel::ProfileSample#unpause", "Duel::Iteration#call").each do |own, _|
      assert_operator own, :<=, [iteration / 50, 1].max, "only the iteration in them"
    end
  end

  # A metric that measures +cost+ every stretch (what its reading costs,
  # say), and one of its counts: its cost changes after every sample.
  class Costly < Duel::Metric
    attr_reader :samples

    def self.measures = {"costly" => {kind: :ratio}, "reads" => {}}

    def initialize(costs)
      super()
      @costs = costs
      @samples = 0
    end

    def stop_sample = {"costly" => @costs.first, "reads" => 1}

    def details = (@samples += 1) && @costs.rotate! && nil
  end

  # A metric that measures only as a sample stops: its iterations and
  # two (nothing paused).
  class Ends < Duel::Metric
    def self.measures = {"ends" => {kind: :ratio}}

    def start_sample(sample) = @n ||= sample.n

    def pause_sample = 0

    def stop_sample = @n + 2
  end

  # What pausing and resuming around each iteration leaves (the least of
  # a few samples of empty iterations), learned once, an iteration: none
  # without around_iteration hooks.
  def test_what_pausing_and_resuming_leaves
    costly = Costly.new([5, 2, 7])
    harness = Duel::Harness.new(definition(around_iteration: ->(iteration) { iteration.call }) { nil })
    leak = harness.leak([costly, Ends.new, Duel::Metrics::CPU.new])

    assert_equal({"costly" => 2.0, "reads" => 1.0, "ends" => 1.0}, leak.except("cpu"))
    assert_operator leak.fetch("cpu"), :>, 0
    assert_equal 3, costly.samples
    assert_same leak, harness.leak([costly])
    assert_same Duel::Harness::NO_LEAK, Duel::Harness.new(definition { nil }).leak([costly])
  end

  # Taken away an iteration, rounded, but no further than nothing.
  def test_a_sample_less_what_pausing_leaves
    harness = Duel::Harness.new(definition(around_iteration: ->(iteration) { iteration.call }) { nil })
    sample = Duel::Sample.new(harness.definition, [Costly.new([3])], n: 4, counting: true, around: true)
    harness.run(4, sample)

    assert_equal [{"costly" => 18}, {"reads" => 6}], [sample.timed, sample.counted], "4 iterations, and to the start and from the stop"
    sample.less({"costly" => 0.6, "reads" => 2.0})

    assert_equal [{"costly" => 16}, {"reads" => 0}], [sample.timed, sample.counted]
    sample.less({"reads" => 1.0})

    assert_equal [{"costly" => 16}, {"reads" => 0}], [sample.timed, sample.counted]
  end

  # Ticks, costly to read: it counts its readings, and keeps the samples
  # it's started with (their benchmark's name and n).
  class CostlyTicks < Ticks
    class << self
      attr_accessor :reads, :samples
    end

    def self.measures = {"costly_ticks" => {}}

    def self.costly? = true

    def start_sample(sample)
      CostlyTicks.reads += 1
      CostlyTicks.samples << [sample.benchmark.name, sample.n]
      super
    end

    def stop_sample
      CostlyTicks.reads += 1
      super
    end
  end

  # Ticks too, timed.
  class CostlyTime < CostlyTicks
    def self.measures = {"costly_time" => {kind: :ratio}}
  end

  # +n+ iterations' ticks, costly to read and not, less what the
  # around_iteration hooks left (Harness#leak), and the costly ticks'
  # readings.
  def costly_sample(harness, n)
    metrics = [CostlyTicks.new, Ticks.new]
    leak = harness.leak(metrics)
    CostlyTicks.reads = 0
    sample = Duel::Sample.new(harness.definition, metrics, n: n, counting: true, around: true)
    harness.run(n, sample)
    sample.less(leak)
    [sample.counted, CostlyTicks.reads]
  end

  # A metric costly to read isn't paused around each iteration of a
  # benchmark with around_iteration hooks, so it's read only as the
  # sample starts and stops. What the hooks add to it is learned in
  # samples of their own, as any sample is run (after its before_sample
  # hooks), with the iterations paused: the least of them, an iteration.
  # Taken away, it leaves only the iterations', as pausing does.
  def test_a_costly_metric_reads_around_the_sample_and_leaves_out_its_hooks
    CostlyTicks.reads = 0
    CostlyTicks.samples = []
    extras = [9, 5, 7]
    before = [->(_) { (Ticks.now += 1000) && extras.rotate! }]
    around = lambda do |iteration|
      Ticks.now += extras.first
      iteration.call
      Ticks.now += 30
    end
    harness = Duel::Harness.new(definition("hooked", around_iteration: around) { Ticks.now += 1 }, config_hooks(before_sample: before))
    leak = harness.leak([CostlyTime.new, CostlyTicks.new, Ticks.new])

    assert_equal({"ticks" => 0.0, "costly_time" => 35.0, "costly_ticks" => 35.0}, leak, "the least: 5 and 30")
    assert_equal Duel::Snapshot::CALIBRATION * ((Duel::Harness::HOOKED * 2) + 2) * 2, CostlyTicks.reads, "paused around each iteration"
    assert_equal [["hooked", Duel::Harness::HOOKED]], CostlyTicks.samples.uniq, "samples of the benchmark, of HOOKED iterations"
    assert_equal [{"costly_ticks" => 4 + 0, "ticks" => 4}, 2], costly_sample(harness, 4)
  end

  # What an around_iteration hook adds that depends on its iteration
  # (rolling back what it wrote, say) is learned too: the calibration
  # runs the real iterations. An untimed block inside one pauses the
  # costly metric as well.
  def test_what_an_around_iteration_hook_adds_for_its_iteration
    CostlyTicks.reads = 0
    CostlyTicks.samples = []
    around = ->(iteration) { Ticks.now += iteration.call }
    harness = Duel::Harness.new(definition(around_iteration: around) { (Ticks.now += 1) && untimed { Ticks.now += 100 } && 3 })

    assert_equal [{"costly_ticks" => 2, "ticks" => 2}, 2 + 4], costly_sample(harness, 2), "an untimed block's two readings each"
  end

  # Without a metric costly to read, nothing's run to learn what
  # around_iteration hooks add, and a sample pauses all its metrics
  # around each iteration, the same Array (nothing more made for each
  # sample), as one of a benchmark without the hooks does whatever its
  # metrics: with one, and the hooks, all but those costly to read.
  def test_no_costly_metric_runs_nothing_more
    runs = 0
    harness = Duel::Harness.new(definition(around_iteration: ->(iteration) { iteration.call }) { runs += 1 })

    assert_equal ["cpu"], harness.leak([Duel::Metrics::CPU.new]).keys
    assert_equal 0, runs
    cheap = Ticks.new
    sample = harness.sample([CostlyTicks.new, cheap], n: 3)

    assert_equal [[cheap], 3, true], [sample.instance_variable_get(:@paused), sample.n, sample.instance_variable_get(:@counting)]
    refute harness.sample([cheap], n: 1, counting: false).instance_variable_get(:@counting)
    plain = Duel::Harness.new(definition { nil })

    [harness.sample([cheap], n: 1), plain.sample([CostlyTicks.new, cheap], n: 1),
      Duel::Sample.new(harness.definition, [CostlyTicks.new, cheap], n: 1)].each do |made|
      assert_same(*%i[@metrics @paused].map { |name| made.instance_variable_get(name) })
    end
    assert_equal [true, false], [harness, plain].map(&:around?)
    assert_same plain.definition, plain.sample([], n: 1).benchmark
  end
end
