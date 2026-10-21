# frozen_string_literal: true

require_relative "test_helper"

class ContextTest < DuelTest
  cover "Duel::Context*"
  cover "Duel::Harness*"
  cover "Duel::Sample*"
  cover "Duel::MemorySample*"
  cover "Duel::ProfileSample*"
  cover "Duel::Trial*"
  cover "Duel.measuring?"
  cover "Duel.measured"
  cover "Duel.unmeasured!"

  def definition(name = "x", &body) = Duel::Definition.new(name, nil, false, "/duel/x_duel.rb", body, {})

  def metrics = [Duel::Metrics::Allocations.new, Duel::Metrics::CPU.new].select { |m| m.class.available? }

  def sample(harness, counting: false) = Duel::Sample.new(harness.definition, metrics, n: 1, counting: counting)

  def test_setup_the_benchmark_and_teardown_share_the_contexts_state
    log = []
    Duel.file_hooks["/duel/x_duel.rb"][:setup].push(proc { @n = 0 }, proc { @n += 10 })
    Duel.file_hooks["/duel/x_duel.rb"][:teardown].push(proc { log << :first }, proc { log << [:second, @n] })
    harness = Duel::Harness.new(definition { log << (@n += 1) })
    harness.prepare
    harness.run(3, sample(harness))
    harness.finish

    assert_equal [11, 12, 13, [:second, 13], :first], log, "teardowns in reverse"
    assert_equal "x: untimed outside a sample", assert_raises(Duel::Error) { harness.untimed { 1 } }.message, "the sample is over"
  end

  # A benchmark's state lives beside the context's own: names Duel might
  # have used for its own are the benchmark's still.
  def test_a_benchmarks_state_is_its_own
    runs = []
    harness = Duel::Harness.new(definition do |n|
      once { (@definition = :mine) && (@trial = :mine) }
      @sample = untimed { (@once_done = :mine) && n }
      runs << [@definition, @trial, @once_done, @sample]
    end)
    harness.trial
    harness.run(2, sample(harness))

    assert_equal [[:mine, :mine, :mine, 1], [:mine, :mine, :mine, 2]], runs, "the benchmark's own body, its setup, untimed"
    assert_equal "x", harness.definition.name
  end

  def test_a_sample_times_the_benchmark
    harness = Duel::Harness.new(definition { 1000.times { Math.sqrt(2) } })
    s = sample(harness, counting: true)
    harness.run(5, s)

    assert_equal %w[cpu], s.timed.keys
    assert_operator s.timed.fetch("cpu"), :>, 0
    assert_equal((RUBY_ENGINE == "ruby") ? %w[allocations] : [], s.counted.keys)
    assert s.started
    assert s.stopped
  end

  def test_a_sample_tells_about_how_much_it_allocated
    harness = Duel::Harness.new(definition { "x" * (1 << 20) })
    s = sample(harness)
    harness.run(3, s)

    if RUBY_ENGINE == "ruby"
      # (About 3 MB: Ruby counts what's malloc'd in batches, so a little
      # can be left out, or in.)
      assert_includes (2 << 20)..(4 << 20), s.heap
    else
      assert_equal 0, s.heap
    end
  end

  def test_counted_metrics_only_when_counting
    harness = Duel::Harness.new(definition { 1 })
    s = sample(harness)
    harness.run(1, s)

    assert_empty s.counted
  end

  def test_a_sample_keeps_the_gc_off_while_it_runs
    skip "CRuby only" unless RUBY_ENGINE == "ruby"

    seen = []
    harness = Duel::Harness.new(definition { seen << GC.enable.tap { GC.disable } })
    harness.run(1, sample(harness))

    assert_equal [true], seen, "disabled (enable returns whether it was)"
    refute GC.disable.tap { GC.enable }, "enabled again after"
  end

  def test_a_sample_collects_only_the_young_garbage_first
    collections = []
    harness = Duel::Harness.new(definition { 1 })
    stub(GC, :start, ->(**options) { collections << options }) { harness.run(1, sample(harness)) }

    assert_equal((RUBY_ENGINE == "ruby") ? [{full_mark: false}] : [], collections)
  end

  # A metric of ticks, for counting what's measured exactly.
  class Ticks < Duel::Metric
    class << self
      attr_accessor :now
    end

    def start_sample(_definition) = @started = Ticks.now

    def stop_sample = Ticks.now - @started
  end

  def test_a_block_without_a_parameter_runs_n_times
    runs = []
    harness = Duel::Harness.new(definition { runs << :run })
    harness.run(3, sample(harness))

    assert_equal %i[run run run], runs
  end

  def test_a_block_with_one_runs_once_with_n
    runs = []
    harness = Duel::Harness.new(definition { |n| runs << n })
    harness.run(3, sample(harness))

    assert_equal [3], runs
  end

  def test_untimed_pauses_measuring
    Ticks.now = 0
    harness = Duel::Harness.new(definition do |n|
      Ticks.now += 1
      prepared = untimed { (Ticks.now += 100) && n }
      Ticks.now += prepared
    end)
    s = Duel::Sample.new(harness.definition, [Ticks.new], n: 1, counting: true)
    harness.run(5, s)

    assert_equal({"ticks" => 6}, s.counted, "1 before, 5 after: not the 100 between")
    assert s.stopped
  end

  # Measuring: inside a sample, but not its untimed blocks, its once,
  # or a trial, and not once it's over, however it ends.
  def test_measuring
    seen = []
    harness = Duel::Harness.new(definition do
      once { seen << [:setup, Duel.measuring?] }
      seen << [:timed, Duel.measuring?]
      untimed { seen << [:untimed, Duel.measuring?] }
      seen << [:again, Duel.measuring?]
    end)
    harness.trial

    assert_equal [[:setup, false], [:timed, false], [:untimed, false], [:again, false]], seen, "a trial measures nothing"
    seen.clear
    harness.run(1, sample(harness))

    assert_equal [[:timed, true], [:untimed, false], [:again, true]], seen
    refute_predicate Duel, :measuring?
    failing = Duel::Harness.new(definition { raise "no" })

    assert_raises(RuntimeError) { failing.run(1, sample(failing)) }
    refute_predicate Duel, :measuring?
  end

  # A helper meant for setting up fails while a benchmark's measured.
  def test_unmeasured
    assert_nil Duel.unmeasured!("Duel::X.reset")
    error = assert_raises(Duel::Error) { Duel.measured(true) { Duel.unmeasured!("Duel::X.reset") } }

    assert_equal "Duel::X.reset: in setup or untimed only (it would be counted)", error.message
    Duel.measured(true) { Duel.measured(false) { Duel.unmeasured!("Duel::X.reset") } }
  end

  def test_a_file_without_setup_or_teardown
    harness = Duel::Harness.new(definition { 1 })
    harness.prepare
    harness.finish

    refute Duel.file_hooks.key?("/duel/x_duel.rb")
  end

  def test_once_runs_only_in_the_trial
    runs = []
    harness = Duel::Harness.new(definition do
      once { runs << :setup }
      runs << :run
    end)
    harness.trial

    assert_equal %i[setup run], runs
    harness.run(2, sample(harness))

    assert_equal %i[setup run run run], runs, "not when measured"
  end

  def test_a_trial_measures_nothing
    trial = Duel::Trial.new
    harness = Duel::Harness.new(definition { @untimed = untimed { :ran } })
    harness.run(2, trial)

    assert_equal [true, true], [trial.started, trial.stopped]
    assert_equal :ran, harness.context.instance_variable_get(:@untimed)
  end

  def test_a_trial_runs_the_benchmark_once
    runs = []
    harness = Duel::Harness.new(definition { |n| runs << n })
    harness.trial

    assert_equal [1], runs
    assert_raises(RuntimeError) { Duel::Harness.new(definition { raise "new" }).trial }
  end

  def test_untimed_outside_a_sample
    harness = Duel::Harness.new(definition("out") { 1 })
    error = assert_raises(Duel::Error) { harness.untimed { 1 } }

    assert_equal "out: untimed outside a sample", error.message
  end

  def test_a_failing_benchmark_still_ends_the_sample
    harness = Duel::Harness.new(definition { raise "boom" })
    s = sample(harness)

    assert_raises(RuntimeError) { harness.run(1, s) }
    assert s.stopped
    refute GC.disable.tap { GC.enable }, "the GC is back on"
  end

  # A metric reporting several measures at once, and some not at all.
  class Several < Duel::Metric
    def self.measures = {"none" => {kind: :counted}, "c" => {kind: :counted}, "t" => {kind: :ratio}}

    def stop_sample = {"none" => nil, "c" => 2, "t" => 1}
  end

  # Counted, by default: its measures say nothing of their kind.
  class Partial < Duel::Metric
    def self.measures = {"p" => {}, "q" => {floor: 1}}

    def stop_sample = {"p" => 4, "q" => 5}
  end

  def test_measures_counted_by_default
    harness = Duel::Harness.new(definition { 1 })
    counting = Duel::Sample.new(harness.definition, [Partial.new], n: 1, counting: true)
    harness.run(1, counting)

    assert_equal({"p" => 4, "q" => 5}, counting.counted)
    assert_empty counting.timed
    timing = Duel::Sample.new(harness.definition, [Partial.new], n: 1, counting: false)
    harness.run(1, timing)

    assert_empty timing.counted
  end

  # A measurement of one, from a metric of several, is its first's, and
  # each is filed by its kind as the worker's settings have it.
  def test_one_measurement_of_a_metric_of_several
    one = Class.new(Duel::Metric) do
      def self.measures = {"p" => {}, "q" => {kind: :ratio}}

      def stop_sample = 4
    end
    harness = Duel::Harness.new(definition { 1 })
    sample = Duel::Sample.new(harness.definition, [one.new], n: 1, counting: true)
    harness.run(1, sample)

    assert_equal [{"p" => 4}, {}], [sample.counted, sample.timed]
    partial = Partial.new
    partial.settings = Partial.settings({"p" => {kind: :ratio}})
    sample = Duel::Sample.new(harness.definition, [partial], n: 1, counting: false)
    harness.run(1, sample)

    assert_equal [{}, {"p" => 4}], [sample.counted, sample.timed], "c.measure's kind"
  end

  class CountsOnly < Duel::Metric
    attr_reader :starts

    def start_sample(_definition) = @starts = :started

    def stop_sample = 3
  end

  def test_metrics_with_several_measures
    harness = Duel::Harness.new(definition { 1 })
    counting = Duel::Sample.new(harness.definition, [Several.new, CountsOnly.new], n: 1, counting: true)
    harness.run(1, counting)

    assert_equal({"t" => 1}, counting.timed)
    assert_equal({"c" => 2, "counts_only" => 3}, counting.counted, "none measured nothing")
    counts_only = CountsOnly.new
    timing = Duel::Sample.new(harness.definition, [Several.new, counts_only], n: 1, counting: false)
    harness.run(1, timing)

    assert_equal({"t" => 1}, timing.timed)
    assert_empty timing.counted
    assert_nil counts_only.starts, "a counts-only metric isn't even started"
  end

  # Logs when it starts and stops.
  class Logged < Duel::Metric
    def initialize(name, log)
      super()
      @name = name
      @log = log
    end

    def start_sample(_definition) = @log << [:start, @name]

    def stop_sample = (@log << [:stop, @name]) && nil
  end

  # A metric that records each start's sample.
  class Starts < Duel::Metric
    attr_reader :samples

    def start_sample(sample) = (@samples ||= []) << sample
  end

  # A metric that measures a sample whole: an untimed block doesn't stop
  # it (it's paused, and resumed, its own way).
  class Whole < Duel::Metric
    attr_reader :log

    def initialize
      super
      @log = []
    end

    def start_sample(sample) = @log << [:start, sample.n]

    def stop_sample = (@log << :stop) && 5

    def pause_sample = (@log << :pause) && 2

    def resume_sample(_sample) = @log << :resume
  end

  def test_untimed_stops_metrics_in_reverse_and_starts_them_again
    log = []
    starts = Starts.new
    harness = Duel::Harness.new(definition { untimed { log << :untimed } })
    sample = Duel::Sample.new(harness.definition, [Logged.new(:outer, log), Logged.new(:inner, log), starts], n: 1, counting: true)
    harness.run(1, sample)

    assert_equal [%i[start outer], %i[start inner], %i[stop inner], %i[stop outer], :untimed, %i[start outer],
      %i[start inner], %i[stop inner], %i[stop outer]], log
    assert_equal [sample] * 2, starts.samples, "started, then resumed after the untimed block"
    assert_equal [harness.definition, 1], [sample.benchmark, sample.n]
  end

  # Says something of the sample: text, or text by measure.
  class Says < Duel::Metric
    def self.measures = {"a" => {}, "b" => {}}

    def initialize(said)
      super()
      @said = said
    end

    def stop_sample = {"a" => 1, "b" => 2}

    attr_reader :said
    alias_method :details, :said
  end

  def test_what_metrics_say_of_a_sample
    harness = Duel::Harness.new(definition { 1 })
    [["leaked 3", {"a" => "leaked 3", "b" => "leaked 3"}], [{"b" => "just b"}, {"b" => "just b"}], [nil, {}]].each do |said, details|
      sample = Duel::Sample.new(harness.definition, [Says.new(said)], n: 1, counting: true)
      harness.run(1, sample)

      assert_equal details, sample.details
    end
  end

  def test_a_metric_can_pause_its_own_way
    whole = Whole.new
    harness = Duel::Harness.new(definition { untimed { nil } })
    sample = Duel::Sample.new(harness.definition, [whole], n: 2, counting: true)
    harness.run(2, sample)

    assert_equal [[:start, 2], :pause, :resume, :pause, :resume, :stop], whole.log
    assert_equal({"whole" => 9}, sample.counted, "what it paused with, and stopped with")
  end

  def test_metrics_stop_in_reverse
    log = []
    harness = Duel::Harness.new(definition { 1 })
    harness.run(1, Duel::Sample.new(harness.definition, [Logged.new(:outer, log), Logged.new(:inner, log)], n: 1, counting: true))

    assert_equal [%i[start outer], %i[start inner], %i[stop inner], %i[stop outer]], log
  end

  # Peak memory is the measured work's: what an untimed block holds
  # isn't in it (it's measured nowhere else either).
  def test_a_memory_sample_watches_resident_memory
    skip "no way to tell resident memory here" unless Duel::Native::Memory.resident
    # (A JVM's heap, JRuby's or TruffleRuby's, is the VM's to grow: one
    # allocation needn't show in resident memory.)
    skip "a VM's heap, not Ruby's allocations" unless RUBY_ENGINE == "ruby"

    memory = method(:fresh_memory)

    assert_operator watch_memory { |held| held << memory.call }, :>=, 48 << 20
    assert_operator watch_memory { |held| untimed { held << memory.call } }, :<, 8 << 20, "untimed"
  end

  # 64 MB of pages mapped afresh, and written, so they're resident. (Not
  # from malloc: past glibc's mmap threshold or not, it hands out a free
  # chunk big enough before it maps anything, and memory earlier tests
  # freed is still resident, so it needn't grow at all.)
  def fresh_memory
    # (Quietly: IO::Buffer warns that it's experimental.)
    experimental = Warning[:experimental]
    Warning[:experimental] = false
    IO::Buffer.new(64 << 20, IO::Buffer::MAPPED).tap { |memory| memory.clear(1) }
  ensure
    Warning[:experimental] = experimental
  end

  # A memory sample whose resident memory rises to 250 while the watcher
  # looks, falls to 150, and is +last+ at the sample's own last look (its
  # thread's), every look counted.
  def memory_sample(last)
    levels = {seen: 100, own: 100}
    looks = 0
    main = Thread.current
    resident = -> { (looks += 1) && levels.fetch((Thread.current == main) ? :own : :seen) }
    collections = []
    sample = Duel::MemorySample.new
    stub(Duel::Native::Memory, :resident, resident) do
      stub(GC, :start, ->(**options) { collections << options }) { sample.start }
      levels[:seen] = 250
      sleep 0.05
      levels[:seen] = 150
      sleep 0.01
      levels[:own] = last
      sample.stop
    end
    [sample, collections, looks]
  end

  def test_a_memory_sample_keeps_the_most_the_watcher_saw
    sample, collections, looks = memory_sample(120)

    assert_equal [{full_mark: true, immediate_sweep: true}], collections, "from a clean slate"
    assert_equal 150, sample.peak, "the most, above where it started"
    assert_includes 5..100, looks, "every millisecond or so"
    refute_predicate sample.instance_variable_get(:@watcher), :alive?
  end

  # A paused block isn't watched: a spike in it, gone by its end, isn't
  # the peak, nor is what it leaves. Memory that only falls peaks at 0.
  def test_a_memory_sample_doesnt_watch_paused_blocks
    level = 100
    peak = lambda do |&work|
      sample = Duel::MemorySample.new
      stub(Duel::Native::Memory, :resident, -> { level }) do
        stub(GC, :start, ->(**) {}) { sample.start }
        work.call(sample)
        sample.stop
      end
      sample.peak
    end

    assert_equal 3, peak.call { |sample|
      (level = 103) && sleep(0.01)
      sample.pause { (level = 500) && sleep(0.02) && (level = 120) }
      sleep(0.01)
    }
    assert_equal 0, peak.call { (level = 90) && sleep(0.01) }
  end

  def test_a_memory_sample_looks_once_more_at_the_end
    assert_equal 200, memory_sample(300).first.peak
  end

  # A worker that ran no trial (for peak memory) runs the once blocks in
  # its first memory sample: once, unmeasured, and what that leaves
  # resident isn't in the peak. One that ran a trial ran them then.
  def test_once_runs_in_the_first_memory_sample
    resident = 100
    seen = []
    harness = Duel::Harness.new(definition do
      once { (resident += 40) && (seen << [:setup, Duel.measuring?]) }
      resident += 5
      seen << [:run, Duel.measuring?]
    end)
    peaks = stub(Duel::Native::Memory, :resident, -> { resident }) do
      stub(GC, :start, ->(**) {}) { Array.new(2) { Duel::MemorySample.new.tap { |s| harness.run_memory(1, s) }.peak } }
    end

    assert_equal [[:setup, false], [:run, true], [:run, true]], seen, "set up once"
    assert_equal [5, 5], peaks, "not what setup left"
    seen.clear
    tried = Duel::Harness.new(definition { once { seen << :again } })
    tried.trial
    seen.clear
    # (Resident memory stubbed: JRuby can't tell it on macOS.)
    stub(Duel::Native::Memory, :resident, -> { resident }) { tried.run_memory(1, Duel::MemorySample.new) }

    assert_empty seen
    untried = Duel::Harness.new(definition { once { seen << :measured } })
    untried.run(1, sample(untried))

    assert_empty seen, "nor in a sample of any other kind"
  end

  # The peak of a benchmark that does what the block does (given where
  # to hold memory).
  def watch_memory(&work)
    held = []
    # (Sleeping lets the watcher look while the memory's held.)
    harness = Duel::Harness.new(definition { instance_exec(held, &work) && sleep(0.02) })
    sample = Duel::MemorySample.new
    harness.run(1, sample)

    assert sample.started
    assert sample.stopped
    sample.peak
  ensure
    held&.each(&:free)
  end

  # A profile's sample holds the garbage collector off, as a Sample does,
  # and runs an untimed block as it is, and an iteration inside its
  # around block (their frames mark what StackProf sampled in them: see
  # Duel::Profile.of).
  def test_a_profile_sample
    held = nil
    harness = Duel::Harness.new(definition { held = [GC.disable, untimed { :untimed }] })
    sample = Duel::ProfileSample.new
    harness.run(1, sample)

    assert sample.started
    assert sample.stopped
    # (JRuby's collector can't be held off.)
    assert_equal [RUBY_ENGINE == "ruby", :untimed], held
    refute GC.disable, "and let go"
    assert_equal :iteration, sample.unpause { :iteration }
  ensure
    GC.enable
  end

  # macOS signals that CPU time is up only as a thread enters the kernel:
  # elapsed time it is, there.
  def test_what_a_profile_samples_by
    assert_equal :wall, Duel::ProfileSample.mode("arm64-darwin24")
    assert_equal :cpu, Duel::ProfileSample.mode("x86_64-linux")
    assert_equal Duel::ProfileSample.mode(RUBY_PLATFORM), Duel::ProfileSample.mode
    assert_equal Duel::ProfileSample.mode, Duel::ProfileSample::MODE
  end
end
