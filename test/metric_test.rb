# frozen_string_literal: true

require_relative "test_helper"

class MetricTest < DuelTest
  cover "Duel::Metric*"
  cover "Duel::Metrics*"
  cover "Duel::Clock*"
  cover "Duel::Snapshot*"

  class QueryCount < Duel::Metric; end

  class Wall < Duel::Metric
    def self.measures = {"wall" => {kind: :ratio, floor: 50, unit_ns: 1000, limit: 1.05}}
  end

  def test_defaults_and_spec
    assert_equal({"metric" => {}}, Duel::Metric.measures, "one, named for the class, counted")
    assert_equal([{"name" => "query_count", "kind" => "counted", "unit" => nil, "plural" => nil, "floor" => 0, "unit_ns" => 1, "limit" => nil, "tolerance" => 0, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}],
      QueryCount.specs)
    assert_equal([{"name" => "wall", "kind" => "ratio", "unit" => nil, "plural" => nil, "floor" => 50, "unit_ns" => 1000, "limit" => 1.05, "tolerance" => 0, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}],
      Wall.specs)
    assert_predicate Duel::Metric, :available?
    refute_predicate Duel::Metric, :costly?
    assert_equal "http2_calls_made", Class.new(Duel::Metric) { def self.name = "X::HTTP2CallsMade" }.metric_name
  end

  class Partial < Duel::Metric
    def self.measures = {"a" => {kind: :ratio, floor: 5}, "b" => {}}
  end

  def test_kinds
    assert_equal({"a" => :ratio, "b" => :counted}, Partial.kinds)
    assert_equal({"wall" => :ratio}, Wall.kinds)
  end

  def test_measures_leave_out_what_they_take_by_default
    assert_equal [{"name" => "a", "kind" => "ratio", "unit" => nil, "plural" => nil, "floor" => 5, "unit_ns" => 1, "limit" => nil, "tolerance" => 0, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true},
      {"name" => "b", "kind" => "counted", "unit" => nil, "plural" => nil, "floor" => 0, "unit_ns" => 1, "limit" => nil, "tolerance" => 0, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}], Partial.specs
  end

  # Running totals: what they grew by in a sample, less what reading them
  # adds to a counted one (the least of CALIBRATION pairs of readings). A
  # timed one is left alone.
  def test_a_snapshot_measures_what_totals_grew_by
    totals = {"queries" => 0, "time" => 0}
    costs = [1, 3, 1, 1, 1, 2] # what each reading adds to "queries" (in pairs: 3, 1 and 2 more)
    reads = 0
    read = lambda do
      reads += 1
      totals["queries"] += costs.shift || 1
      totals["time"] += 2
      totals.dup
    end
    metric = Duel::Snapshot.define({"queries" => {}, "time" => {kind: :ratio}}, read).new

    assert_equal 0, reads, "none, as it's made"
    metric.open

    assert_equal 2 * Duel::Snapshot::CALIBRATION, reads, "pairs of readings, as it's opened"
    metric.start_sample(nil)
    totals["queries"] += 5
    totals["time"] += 10

    assert_equal({"queries" => 5, "time" => 12}, metric.stop_sample)
  end

  def test_each_snapshot_is_a_metric_of_its_own
    rows = Duel::Snapshot.define({"rows" => {}}, -> { 1 })
    time = Duel::Snapshot.define({"time" => {kind: :ratio}}, -> { 2 })

    assert_equal [Duel::Snapshot, Duel::Snapshot], [rows.superclass, time.superclass]
    assert_equal [{"rows" => :counted}, {"time" => :ratio}], [rows.kinds, time.kinds]
    assert_equal [{"rows" => 1}, {"time" => 2}], [rows.read.totals, time.read.totals]
  end

  def test_a_snapshot_of_one_total
    total = 0
    metric = Duel::Snapshot.define({"rows" => {}}, -> { total }).new.tap(&:open)
    metric.start_sample(nil)
    total += 7

    assert_equal({"rows" => 7}, metric.stop_sample)
    assert_equal({"rows" => 7}, Duel::Snapshot.define({"rows" => {}}, -> { 7 }).read.totals)
  end

  def test_a_snapshot_of_several_in_a_kind_of_hash
    totals = Class.new(Hash)[{"rows" => 4}]

    assert_same totals, Duel::Snapshot.define({"rows" => {}}, -> { totals }).read.totals
  end

  # A measure whose reading costs nothing (or a varying amount, taken
  # away by the block itself) isn't calibrated: nothing's taken away.
  def test_a_snapshot_without_calibrating
    reads = 0
    metric = Duel::Snapshot.define({"rows" => {calibrate: false}}, -> { reads += 1 }).new.tap(&:open)

    assert_equal 0, reads, "no pairs of readings"
    metric.start_sample(nil)

    assert_equal({"rows" => 1}, metric.stop_sample, "the stop's own reading, not taken away")
  end

  # Totals it couldn't read while calibrating cost nothing to read, and
  # one it can't read at either end of a sample measures nothing.
  def test_a_snapshot_of_totals_it_sometimes_cant_read
    pages = [nil, 5, 5, nil, nil, nil, 5, 8, 5, nil, nil, 9]
    metric = Duel::Snapshot.define({"pages" => {}}, -> { pages.shift }).new.tap(&:open)
    metric.start_sample(nil)

    assert_equal({"pages" => 3}, metric.stop_sample)
    metric.start_sample(nil)

    assert_equal({"pages" => nil}, metric.stop_sample)
    metric.start_sample(nil)

    assert_equal({"pages" => nil}, metric.stop_sample)
  end

  # A total it can't read this time is nil: nothing measured, and nothing
  # taken away.
  def test_a_snapshot_of_a_total_it_cant_read
    totals = {"rows" => 1, "pages" => nil}
    metric = Duel::Snapshot.define({"rows" => {}, "pages" => {}}, -> { totals }).new.tap(&:open)
    metric.start_sample(nil)

    assert_equal({"rows" => 0, "pages" => nil}, metric.stop_sample)
    totals = {"rows" => 1, "pages" => 3}

    assert_equal({"rows" => 0, "pages" => nil}, metric.stop_sample, "not since it started")
  end

  # A block must read what the metric measures, and only that.
  def test_a_snapshot_reads_what_it_measures
    error = assert_raises(Duel::Error) { Duel::Snapshot.define({"rows" => {}, "pages" => {}}, -> { {"rows" => 1, "hits" => 2} }).new.open }

    assert_equal "running totals of rows, pages: read rows, hits", error.message
    error = assert_raises(ArgumentError) { Duel::Snapshot.define({}, -> { 1 }) }

    assert_equal "a metric of running totals needs a name for what it measures", error.message
  end

  def test_a_snapshot_needs_a_block
    error = assert_raises(ArgumentError) { Duel::Snapshot.define({"rows" => {}}, nil) }

    assert_equal "a metric of running totals needs a block to read them", error.message
  end

  class Allowed < Duel::Metric
    def self.measures = {"allowed" => {allowance: 16, sizes_samples: false, across: false, cpu_floor: 0.1}}
  end

  # Measures' settings, changed by name (Config#measure).
  def test_settings_and_overrides
    assert_equal [16, false, false], Allowed.specs.first.values_at("allowance", "sizes_samples", "across")
    assert_equal({kind: :counted, unit: nil, plural: nil, floor: 0, cpu_floor: 0.1, limit: nil, unit_ns: 1, sizes_samples: false, across: false,
                  tolerance: 0, allowance: 16},
      Allowed.settings.fetch("allowed"), "the rest as by default")
    specs = Partial.specs({"b" => {tolerance: 3}, "c" => {tolerance: 9}})

    assert_equal [0, 3], specs.map { |spec| spec.fetch("tolerance") }, "b's alone"
  end

  # Paused (for an untimed block) and resumed: by default, stopped and
  # started.
  class Paused < Duel::Metric
    attr_reader :log

    def start_sample(sample) = (@log ||= []) << [:start, sample]

    def stop_sample = (@log << :stop) && 7
  end

  def test_pausing_by_default
    metric = Paused.new
    metric.start_sample(:sample)

    assert_equal 7, metric.pause_sample
    metric.resume_sample(:again)

    assert_equal [[:start, :sample], :stop, [:start, :again]], metric.log
  end

  # A setting there isn't, or a kind there isn't, fails: a typo isn't left
  # to mean nothing.
  def test_settings_are_checked
    Duel::Metric.check("rows", kind: :ratio, unit: "µs", calibrate: false, skip: true)
    error = assert_raises(Duel::Error) { Duel::Metric.check("rows", toleranse: 2, flor: 1) }

    assert_equal "rows: no setting toleranse, flor (settings: #{Duel::Metric::SETTINGS.join(", ")})", error.message
    error = assert_raises(Duel::Error) { Duel::Metric.check("rows", kind: :timed) }

    assert_equal "rows: kind is :ratio or :counted, not :timed", error.message
    error = assert_raises(Duel::Error) { Duel::Snapshot.define({"rows" => {kind: :count}}, -> { 1 }) }

    assert_equal "rows: kind is :ratio or :counted, not :count", error.message
    Duel::Metric.check("rows", unit: %w[row rows])
    Duel::Metric.check("rows", unit: nil)
    [:row, %w[row], %w[a b c], ["row", :rows], {"row" => "rows"}, Set["row", "rows"]].each do |unit|
      error = assert_raises(Duel::Error) { Duel::Metric.check("rows", unit: unit) }

      assert_equal "rows: unit is a String or [singular, plural], not #{unit.inspect}", error.message
    end
  end

  # A word as a unit comes with its plural: nothing guesses one.
  def test_a_word_needs_its_plural
    ["row", "round trip", "miss"].each do |word|
      error = assert_raises(Duel::Error) { Duel::Metric.check("rows", unit: word) }

      assert_equal "rows: a word as a unit needs its plural too: unit: [#{word.inspect}, plural]", error.message
    end
    %w[B KB op/s Rows ns ms s].each { |symbol| Duel::Metric.check("rows", unit: symbol) }
  end

  # A unit's singular and plural: as given, or a symbol's the same.
  def test_plurals
    units = Duel::Snapshot.define({"rows" => {unit: %w[row rows]}, "people" => {unit: %w[person people]}, "bytes" => {unit: "B"},
                                   "wait" => {kind: :ratio, unit: "ms"}, "none" => {}}, -> {})

    assert_equal({"rows" => %w[row rows], "people" => %w[person people], "bytes" => %w[B B], "wait" => %w[ms ms],
                  "none" => [nil, nil]}, units.settings.transform_values { |s| s.values_at(:unit, :plural) })
    assert_equal ["row", "rows"], units.specs.first.values_at("unit", "plural")
  end

  class Rows < Duel::Metric
    def self.measures = {"rows" => {tolerance: 0.5, allowance: 2}}
  end

  class RowsAndBlocks < Duel::Metric
    def self.measures = {"rows" => {allowance: 1}, "blocks" => {tolerance: 2}}
  end

  # A setting of the one measure a metric measures, or of one it names,
  # and whether a count is within what it allows.
  def test_a_setting_and_whats_within_it
    rows = Rows.new

    assert_equal [0.5, 2, :counted], [rows.setting(:tolerance), rows.setting(:allowance), rows.setting(:kind)]
    assert rows.within?(7, 10), "2 a sample, and half an iteration"
    assert rows.within?(2, 0)
    refute rows.within?(8, 10)
    rows.settings = Rows.settings({"rows" => {allowance: 3}})

    assert rows.within?(8, 10), "as configured"
    both = RowsAndBlocks.new

    assert_equal [1, 2], [both.setting(:allowance, "rows"), both.setting(:tolerance, "blocks")]
    assert both.within?(4, 2, "blocks")
    refute both.within?(2, 2, "rows")
    error = assert_raises(Duel::Error) { both.setting(:allowance) }

    assert_equal "MetricTest::RowsAndBlocks doesn't measure one thing (rows, blocks): name which", error.message
    assert_raises(Duel::Error) { both.within?(1, 1) }
    nothing = Class.new(Duel::Metric) { def self.measures = {} }.new

    assert_raises(Duel::Error) { nothing.setting(:kind) }
  end

  # Its one measure is found once, and again once its settings change.
  def test_the_one_measure_after_new_settings
    rows = Rows.new

    assert_equal 2, rows.setting(:allowance)
    rows.settings = {"lines" => Duel::Metric.resolve({allowance: 5})}

    assert_equal 5, rows.setting(:allowance)
  end

  # Asked every sample (to tell whether a count is worth explaining), it
  # allocates nothing.
  def test_within_allocates_nothing
    skip "no allocation count" unless RUBY_ENGINE == "ruby"
    rows = Rows.new
    both = RowsAndBlocks.new
    check = lambda do
      rows.within?(7, 10)
      rows.within?(7.5, 10)
      both.within?(4, 2, "blocks")
    end
    allocated(&check) # (once to warm up)

    assert_equal 0, allocated(&check)
  end

  def allocated
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end

  # Whether a count is within what's allowed: a tolerance an iteration,
  # and an allowance a sample, as Duel judges counts.
  def test_whats_within
    assert Duel::Metric.within?(3, 2, tolerance: 1, allowance: 1)
    refute Duel::Metric.within?(4, 2, tolerance: 1, allowance: 1)
    assert Duel::Metric.within?(1.5, 3, tolerance: 0.5, allowance: 0)
    assert Duel::Metric.within?(2, 2, tolerance: 1, allowance: 1), "less than allowed"
    assert Duel::Metric.within?(0, 0, tolerance: 0.5, allowance: 0.25)
    refute Duel::Metric.within?(1, 4, tolerance: 0.1, allowance: 0.5)
  end

  class InMicroseconds < Duel::Metric
    def self.measures = {"in_microseconds" => {kind: :ratio, unit: "µs"}}
  end

  # A unit that's time gives unit_ns, unless it's set. Settings, with
  # changes, are each metric's to see.
  def test_units_and_settings
    assert_equal ["µs", 1000], InMicroseconds.specs.first.values_at("unit", "unit_ns")
    totals = Duel::Snapshot.define({"wait" => {kind: :ratio, unit: "ms"}, "bytes" => {unit: "B", unit_ns: 0}}, -> { {"wait" => 1, "bytes" => 2} })

    assert_equal [1_000_000, 0], totals.specs.map { |spec| spec.fetch("unit_ns") }
    assert_equal 1000, InMicroseconds.new.settings.fetch("in_microseconds").fetch(:unit_ns)
    metric = InMicroseconds.new
    metric.settings = InMicroseconds.settings({"in_microseconds" => {limit: 1.1}})

    assert_equal [1.1, "µs"], metric.settings.fetch("in_microseconds").values_at(:limit, :unit)
  end

  # Running totals explained: the block is given each stretch of the
  # sample ([started, stopped] readings, with what was read with them)
  # and the sample (n, say).
  def test_a_snapshot_with_details
    total = 0
    explain = lambda do |stretches, sample|
      grew = stretches.sum { |started, stopped| stopped.totals.fetch("rows") - started.totals.fetch("rows") }
      "#{grew.fdiv(sample.n)} rows an iteration, by #{stretches.map { |_, stopped| stopped.context }.join(", ")}"
    end
    snapshot = Duel::Snapshot.define({"rows" => {calibrate: false}}, -> { [total, "reading #{total}"] })

    assert_same snapshot, snapshot.details(&explain), "the metric, to chain"
    metric = snapshot.new.tap(&:open)
    sample = Struct.new(:n).new(2)
    metric.start_sample(sample)
    total = 3
    metric.pause_sample
    total = 10 # (untimed: not measured)
    metric.resume_sample(sample)
    total = 13
    metric.stop_sample

    assert_equal "3.0 rows an iteration, by reading 3, reading 13", metric.details
    metric.start_sample(sample)
    metric.stop_sample

    assert_equal "0.0 rows an iteration, by reading 13", metric.details, "a sample of its own"
    assert_nil Duel::Snapshot.define({"rows" => {}}, -> { 1 }).new.details, "none without a block"
  end

  # A reading's total, by name: one it couldn't read (or one there isn't)
  # fails.
  def test_a_readings_total
    reading = Duel::Snapshot::Reading.new({"rows" => 3, "blocks" => nil, "pages" => 0}, nil)

    assert_equal [3, 0], [reading.total("rows"), reading.total("pages")]
    %w[blocks hits].each do |name|
      error = assert_raises(Duel::Error) { reading.total(name) }

      assert_equal "no total #{name} in this reading (rows, pages)", error.message
    end
  end

  def test_a_metric_does_nothing_by_default
    metric = Duel::Metric.new

    assert_nil metric.open
    assert_nil metric.start_sample(nil)
    assert_nil metric.stop_sample
    assert_nil metric.details
    assert_nil metric.close
  end

  # How a sample files what a metric measured: each measure's kind, and
  # the measure a measurement of one is (its first), by its settings (as
  # a worker sets them), worked out once.
  def test_kinds_and_first_measure_of_an_instance
    metric = Partial.new

    assert_equal({"a" => :ratio, "b" => :counted}, metric.kinds)
    assert_same metric.kinds, metric.kinds
    assert_equal "a", metric.first_measure
    metric.settings = Partial.settings({"a" => {kind: :counted}})

    assert_equal({"a" => :counted, "b" => :counted}, metric.kinds, "the worker's settings")
    metric.settings = Wall.settings

    assert_equal [{"wall" => :ratio}, "wall"], [metric.kinds, metric.first_measure]
  end

  # Running totals opened as each worker makes them (before they're
  # first read), and closed as it ends. Without the blocks, nothing.
  def test_a_snapshot_opened_and_closed
    log = []
    snapshot = Duel::Snapshot.define({"rows" => {}}, -> { (log << :read) && 1 })

    assert_same snapshot, snapshot.open { log << :open }
    assert_same snapshot, snapshot.close { log << :close }
    metric = snapshot.new

    assert_empty log, "not as it's made"
    metric.open

    assert_equal [:open] + ([:read] * 2 * Duel::Snapshot::CALIBRATION), log
    metric.close

    assert_equal :close, log.last
    assert_nil Duel::Snapshot.define({"rows" => {}}, -> { 1 }).new.tap(&:open).close
  end

  # Running totals are cheap to read, unless they say they're costly.
  def test_a_costly_snapshot
    snapshot = Duel::Snapshot.define({"rows" => {}}, -> { 1 })

    refute_predicate snapshot, :costly?
    assert_same snapshot, snapshot.costly
    assert_predicate snapshot, :costly?
    refute_predicate Duel::Snapshot.define({"rows" => {}}, -> { 1 }), :costly?
  end

  def sample(cpu) = Duel::Sample.new(Duel::Definition.new("x", (cpu == :process) ? :timing : nil, false, nil, nil), [], n: 1, counting: false)

  def test_cpu_measures_the_threads_or_the_processes_cpu_time
    assert_equal([{"name" => "cpu", "kind" => "ratio", "unit" => "ns", "plural" => "ns", "floor" => 300_000, "unit_ns" => 1, "limit" => nil, "tolerance" => 0, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}],
      Duel::Metrics::CPU.specs)
    cpu = Duel::Metrics::CPU.new
    before = Duel::Clock.thread
    cpu.start_sample(sample(:thread))
    50_000.times { Math.sqrt(2) }
    measured = cpu.stop_sample

    assert_includes 1..(Duel::Clock.thread - before), measured
    clock = [1_000, 1_250]
    measured = stub(Duel::Clock, :thread, -> { clock.shift }) { cpu.start_sample(sample(:thread)) && cpu.stop_sample }

    assert_equal 250, measured, "the clock's advance"
    other = Thread.new { 2_000_000.times { Math.sqrt(2) } }
    cpu.start_sample(sample(:thread))
    other.join
    thread = cpu.stop_sample
    cpu.start_sample(sample(:process))
    Thread.new { 2_000_000.times { Math.sqrt(2) } }.join

    assert_operator cpu.stop_sample, :>, thread * 10, "another thread's work counts for the process only"
  end

  def test_allocations_counts_objects
    assert_equal([{"name" => "allocations", "kind" => "counted", "unit" => nil, "plural" => nil, "floor" => 0, "unit_ns" => 1, "limit" => nil,
                   "tolerance" => 0.5, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}], Duel::Metrics::Allocations.specs)
    assert_equal RUBY_ENGINE == "ruby", Duel::Metrics::Allocations.available?
    skip "CRuby counts allocations" unless RUBY_ENGINE == "ruby"

    allocations = Duel::Metrics::Allocations.new
    counted = ->(&block) { allocations.start_sample(nil).then { block.call }.then { allocations.stop_sample } }
    3.times { counted.call { nil } } # warm
    overhead = counted.call { nil }

    assert_includes 0..10, overhead
    assert_includes 100..105, counted.call { 100.times { Object.new } } - overhead, "100, and the block's own"
  end

  def test_clocks_advance
    thread = Duel::Clock.thread
    process = Duel::Clock.process
    200_000.times { Math.sqrt(2) }

    assert_kind_of Integer, thread, "nanoseconds"
    assert_kind_of Integer, process

    assert_operator Duel::Clock.thread, :>, thread
    assert_operator Duel::Clock.process, :>, process
  end
end

class InstructionsTest < DuelTest
  cover "Duel::Metrics::Instructions*"

  FakeCounter = Struct.new(:scope, :value) do
    def read = self.value += 100
  end

  def counter(scope) = FakeCounter.new(scope, 1000)

  def with_counter(counter)
    saved = Duel::Metrics::Instructions.instance_variable_get(:@counter)
    Duel::Metrics::Instructions.instance_variable_set(:@counter, counter)
    yield
  ensure
    Duel::Metrics::Instructions.instance_variable_set(:@counter, saved)
  end

  def sample(cpu) = Duel::Sample.new(Duel::Definition.new("x", (cpu == :process) ? :timing : nil, false, nil, nil), [], n: 1, counting: false)

  def test_spec
    assert_equal([{"name" => "instructions", "kind" => "ratio", "unit" => nil, "plural" => nil, "floor" => 100_000, "unit_ns" => 1, "limit" => 1.01,
                   "tolerance" => 0, "sizes_samples" => false, "allowance" => 0, "cpu_floor" => 0, "across" => true}], Duel::Metrics::Instructions.specs)
  end

  def test_a_threads_counter_counts_thread_benchmarks_only
    thread = counter("thread")
    with_counter(thread) do
      metric = Duel::Metrics::Instructions.new
      metric.start_sample(sample(:thread))

      assert_equal 100, metric.stop_sample
      metric.start_sample(sample(:process))

      assert_equal 1200, thread.value, "not even read"
      assert_nil metric.stop_sample, "other threads' instructions aren't counted"
      assert_predicate Duel::Metrics::Instructions, :available?
    end
  end

  def test_a_processs_counter_counts_every_benchmark
    with_counter(counter("process")) do
      metric = Duel::Metrics::Instructions.new
      metric.start_sample(sample(:process))

      assert_equal 100, metric.stop_sample
    end
  end

  def test_unavailable_without_a_counter
    with_counter(nil) { refute_predicate Duel::Metrics::Instructions, :available? }
  end

  def test_the_counter_is_opened_once
    saved = Duel::Metrics::Instructions.instance_variable_get(:@counter)
    Duel::Metrics::Instructions.remove_instance_variable(:@counter)
    opened = []

    stub(Duel::Native::Counter, :open, -> { (opened << :counter) && opened.size }) do
      assert_equal [1, 1], [Duel::Metrics::Instructions.counter, Duel::Metrics::Instructions.counter]
    end
    Duel::Metrics::Instructions.remove_instance_variable(:@counter)
    stub(Duel::Native::Counter, :open, -> { (opened << :none) && nil }) do
      assert_nil Duel::Metrics::Instructions.counter
      assert_nil Duel::Metrics::Instructions.counter
    end

    assert_equal %i[counter none], opened, "nil too"
  ensure
    Duel::Metrics::Instructions.instance_variable_set(:@counter, saved)
  end
end
