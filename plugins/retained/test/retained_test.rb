# frozen_string_literal: true

require_relative "test_helper"

class RetainedTest < PluginTest
  cover "Duel::Retained*"

  # What the tests leave alive on purpose.
  KEPT = []

  # How far a count may stray: the machine stack can still hold a few
  # objects a sample made (CRuby scans it conservatively), a few more on
  # Linux than on macOS. Far fewer than any difference these tests watch
  # for, and than Duel's allowance (Duel::Retained::ALLOWANCE).
  NOISE = 8

  # Something of a class of its own, for what it says it retained.
  class Kept; end

  def teardown
    KEPT.clear
    super
  end

  # The plugin registers itself as :retained, and c.use configures Duel
  # for it: its one metric.
  def test_used_by_name
    config = self.config

    assert_same Duel::Retained, Duel.plugins.fetch(:retained)
    assert_equal [:retained], config.plugins
    assert_same Duel::Retained::Objects, config.use(:retained)
    assert_equal [Duel::Retained::Objects], config.metrics

    assert_equal({"retained_objects" => {kind: :counted, unit: "object", plural: "objects", floor: 0, cpu_floor: 0, limit: nil, unit_ns: 1,
                                         sizes_samples: true, across: true, tolerance: 0.5, allowance: 16}},
      config.metrics.first.settings)
    assert_equal RUBY_ENGINE == "ruby", config.metrics.first.available?
  end

  # Each iteration of a leaky block leaves an object alive; a clean one's
  # are all garbage, though Duel holds the garbage collector off.
  def test_measures_what_is_left_alive
    cruby!
    config = self.config

    held_off = nil

    assert_in_delta 1000, measure(config) { 1000.times { KEPT << Object.new } }.first, NOISE
    assert_in_delta 0, measure(config) {
      held_off = GC.disable
      1000.times { Array.new(3) { Object.new } }
    }.first, NOISE
    assert held_off, "the garbage collector left off, as Duel had it"
  end

  # What's left alive is measured as it is: Duel takes the allowance
  # into account (and the tolerance) when it compares two versions.
  def test_the_allowance_is_duels
    cruby!

    assert_in_delta 50, measure(config) { 50.times { KEPT << Object.new } }.first, NOISE
  end

  def test_collects_what_finalizers_and_dynamic_symbols_keep
    cruby!
    config = self.config
    finalizer = proc {}

    assert_in_delta 0, measure(config) { 200.times { ObjectSpace.define_finalizer(Object.new, finalizer) } }.first, NOISE
    assert_in_delta 0, measure(config) { 200.times { |i| :"retained_#{i}_#{rand}" } }.first, NOISE
  end

  def test_collects_before_and_after_a_sample
    cruby!
    config = self.config
    measure(config) {}
    collections = GC.count
    Duel::Testing.measure(config) {}

    assert_equal 1 + 4, GC.count - collections, "Duel's own, then its two before and two after"
  end

  # Untimed blocks don't stop it (it would collect, twice, for each): it
  # measures the whole sample, so what one makes counts if it's kept, and
  # not if it isn't. (The comparisons' benchmark has one in every
  # iteration.)
  def test_untimed_blocks
    cruby!
    collections = []
    retained, = measure(config) do |sample|
      collections << GC.count
      sample.untimed do
        collections << GC.count
        300.times { KEPT << Object.new }
        # (Loose: an Array of them could stay on the machine stack, and
        # keep them all alive, as CRuby on Linux does.)
        300.times { Object.new }
        collections << GC.count
      end
      collections << GC.count
    end

    assert_in_delta 300, retained, NOISE
    assert_equal 1, collections.last(4).uniq.size, "nothing collected around it"
  end

  # What a sample retained beyond what Duel lets through, an iteration,
  # by class and where it was made: the few most, most first.
  def test_details
    cruby!
    config = self.config
    line = __LINE__ + 2
    retained, said = measure(config, n: 100) do
      300.times { KEPT << +"kept" << [] }
      200.times { KEPT << Kept.new }
      100.times { KEPT << {} }
      1000.times { +"garbage" }
    end
    here = "test/retained_test.rb"

    assert_in_delta 900, retained, NOISE
    assert_equal "an iteration: 3 Array (#{here}:#{line}), 3 String (#{here}:#{line}), 2 RetainedTest::Kept (#{here}:#{line + 1})", said
    assert_nil ObjectSpace.allocation_sourcefile(KEPT.last), "its trace cleared"
  end

  # What was traced before the sample (by the benchmark's own use of
  # ObjectSpace, say) isn't what it retained.
  def test_details_leave_out_what_was_traced_before
    cruby!
    config = self.config
    ObjectSpace.trace_object_allocations { 300.times { KEPT << Kept.new } }
    line = __LINE__ + 1
    said = Duel::Testing.measure(config) { 100.times { KEPT << Object.new } }.details["retained_objects"]

    assert_equal "an iteration: 100 Object (test/retained_test.rb:#{line})", said
  end

  # What it found, by class and where it was made, most first (then by
  # class, and where), but Duel's own: of every object ObjectSpace has,
  # those it traced.
  def test_traced
    cruby!
    line = __LINE__ + 3
    named = Class.new { def self.inspect = "named" }.tap { |c| self.class.const_set(:Named, c) }
    objects = ObjectSpace.trace_object_allocations do
      [Kept.new, Kept.new,
        Object.new,
        Object.new,
        named.new,
        Duel::Config.new.metrics] # (made in Duel's config.rb)
    end
    untraced = Object.new
    traced = stub(ObjectSpace, :each_object, ->(&block) { [untraced, *objects.reverse].each(&block) }) { Duel::Retained.traced }

    assert_instance_of Hash, traced
    assert_equal [[["RetainedTest::Kept", "test/retained_test.rb:#{line}"], 2], [["Object", "test/retained_test.rb:#{line + 1}"], 1],
      [["Object", "test/retained_test.rb:#{line + 2}"], 1], [["RetainedTest::Named", "test/retained_test.rb:#{line + 3}"], 1]], traced.to_a
    ObjectSpace.trace_object_allocations_clear
  ensure
    self.class.send(:remove_const, :Named) if self.class.const_defined?(:Named, false)
  end

  # Of an object not made in Ruby code, it can't say where; of a class
  # without a name, it says what it is.
  def test_traced_without_a_file_or_a_name
    cruby!
    anonymous = Class.new
    objects = ObjectSpace.trace_object_allocations { [anonymous.new] }
    traced = stub(ObjectSpace, :each_object, ->(&block) { objects.each(&block) }) do
      stub(ObjectSpace, :allocation_sourcefile, ->(_object) {}) { Duel::Retained.traced }
    end

    assert_equal({[anonymous.inspect, "?"] => 1}, traced)
    assert_instance_of String, traced.keys.first.first
    ObjectSpace.trace_object_allocations_clear
  end

  # What Duel makes (its record of the metrics inside this one) isn't
  # shown: here, what a Duel::Config holds, made in Duel's config.rb (but
  # the Config, made here).
  def test_details_leave_out_duels_own
    cruby!
    config = self.config
    line = __LINE__ + 1
    _, said = measure(config) { 20.times { KEPT << Duel::Config.new } }

    assert_match(/\Aan iteration: 20 Duel::Config \(test\/retained_test.rb:#{line}\)/, said)
    refute_match(%r{lib/duel/config.rb}, said, "its arrays and hash")
  end

  def test_details_of_classes_without_a_name
    cruby!
    config = self.config
    anonymous = Class.new
    _, said = measure(config, n: 10) { 100.times { KEPT << anonymous.new } }

    assert_match(/\Aan iteration: 10 #<Class:0x\h+> \(test\/retained_test.rb:\d+\)\z/, said)
  end

  # Within what Duel lets through (16 a sample, and one per two
  # iterations, unless c.measure changes them), it says nothing, and
  # walks no objects to say it.
  def test_no_details_within_the_allowance
    cruby!
    config = self.config

    assert_nil measure(config, n: 10) { 21.times { KEPT << Object.new } }.last
    refute_nil measure(config, n: 10) { 30.times { KEPT << Object.new } }.last
    allowing = self.config.tap { |c| c.measure("retained_objects", allowance: 100) }

    assert_nil measure(allowing, n: 10) { 50.times { KEPT << Object.new } }.last
    strict = self.config.tap { |c| c.measure("retained_objects", allowance: 0, tolerance: 0) }

    refute_nil measure(strict, n: 10) { 10.times { KEPT << Object.new } }.last
  end

  # What it can't see (internal objects; or what the benchmark's own use
  # of ObjectSpace cleared the trace of), it says nothing of; and of an
  # object not made in Ruby code, it can't say where.
  def test_details_of_what_it_cant_see
    cruby!
    config = self.config
    _, said = measure(config) do
      100.times { KEPT << Object.new }
      ObjectSpace.trace_object_allocations_clear
    end

    assert_nil said
    assert_equal "?", Duel::Retained.site(nil, nil, "/")
    assert_equal "/elsewhere/a.rb:1", Duel::Retained.site("/elsewhere/a.rb", 1, "/here/")
  end

  private

  # What the metric measures of the block, as a sample of +n+
  # iterations, run once first (as Duel's trial does: what's made the
  # first time, and kept, isn't a leak), and what it says of it. The
  # block gets #untimed.
  def measure(config, n: 1, &)
    Duel::Testing.measure(config, n:, &)
    measured = Duel::Testing.measure(config, n:, &)
    [measured.fetch("retained_objects"), measured.details["retained_objects"]]
  end
end

# Whole comparisons, in real worker processes. (Not for mutant: each
# takes seconds, and the tests above cover the same code.)
class RetainedComparisonTest < PluginTest
  # Whole comparisons: the same code passes, and keeps no more than a
  # sample's allowance; code that remembers everything it's given fails
  # on what it retains, though what its untimed blocks make isn't kept.
  def test_comparisons
    base = project("base", leak: false)
    same = compare(base, project("same", leak: false))

    assert_predicate same, :passed?, same.output
    retained = same["remember"].counted["retained_objects"]
    if RUBY_ENGINE == "ruby"
      assert_in_delta 0, retained.fetch("baseline"), Duel::Retained::ALLOWANCE, same.output
      assert_in_delta 0, retained.fetch("candidate"), Duel::Retained::ALLOWANCE, same.output
      assert_equal [0.5, 16], retained.values_at("tolerance", "allowance")
    else
      assert_nil retained, "measured on CRuby alone"
    end
    cruby!
    leak = compare(base, project("leak", leak: true))
    retained = leak["remember"].counted.fetch("retained_objects")

    assert_includes leak["remember"].regressed, "retained_objects", leak.output
    assert_in_delta retained.fetch("n"), retained.fetch("candidate"), Duel::Retained::ALLOWANCE, leak.output
    assert_match(/REGRESSION remember: worse .*retained_objects/, leak.output)
    assert_match(/^  retained_objects: -?[\d.e-]+ objects? → 1(\.\d+)? objects? an iteration$/, leak.output)
    assert_match(%r{^  retained_objects \(candidate\): an iteration: 1 String \(\S*/leak/lib/sample.rb:4\)$}, leak.output, "Duel's own objects left out")
    refute_match(/retained_objects \(baseline\)/, leak.output, "within its allowance")
  end

  private

  def compare(base, candidate) = Duel::Testing.compare(base, candidate, timeout: 300.0) # (a loaded machine)
end
