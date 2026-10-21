# frozen_string_literal: true

require_relative "test_helper"

class GVLTest < PluginTest
  cover "Duel::GVL*"

  # The plugin registers itself as :gvl, and c.use configures Duel for
  # it: its metric, and the extension, loaded in each worker.
  def test_used_by_name
    config = self.config

    assert_same Duel::GVL, Duel.plugins.fetch(:gvl)
    assert_equal [:gvl], config.plugins
    assert_same Duel::GVL::Wait, config.use(:gvl)
    assert_equal 1, config.in_workers.size
    assert_equal [Duel::GVL::Wait], config.metrics
    assert_equal({"gvl_wait" => {kind: :ratio, unit: "ns", plural: "ns", floor: 0, cpu_floor: 0.1, limit: 1.5, unit_ns: 1,
                                 sizes_samples: false, across: false, tolerance: 0, allowance: 0}},
      Duel::GVL::Wait.settings)
  end

  # Where the extension can't be loaded, there's no metric: another Ruby
  # mustn't try CRuby's, and a build may have failed.
  def test_loading_the_extension
    refute Duel::GVL.load_extension(engine: "jruby")
    refute Duel::GVL.load_extension(feature: "duel_gvl/nothing")
    assert Duel::GVL.load_extension
    assert_predicate Duel::GVL::Wait, :available?
  end

  # Loaded, but no Hook (another Hook, of someone else's, doesn't count):
  # nothing to measure with.
  def test_without_the_hook
    hook = Duel::GVL.send(:remove_const, :Hook)
    Object.const_set(:Hook, Module.new)

    refute Duel::GVL.load_extension
    refute_predicate Duel::GVL, :available?
    refute_predicate Duel::GVL::Wait, :available?
  ensure
    Object.send(:remove_const, :Hook) if Object.const_defined?(:Hook, false)
    Duel::GVL.const_set(:Hook, hook) if hook
  end

  # Each worker loads the extension (not the process that loads
  # .duel.rb, and uses the plugin).
  def test_loaded_in_workers
    loads = 0
    load_extension = Duel::GVL.method(:load_extension)
    Duel::GVL.define_singleton_method(:load_extension) { loads += 1 }
    config = self.config

    assert_equal 0, loads
    Duel::Testing.in_worker(config) { assert_equal 1, loads }
  ensure
    Duel::GVL.define_singleton_method(:load_extension, load_extension)
  end

  # A benchmark that only counts isn't measured.
  def test_not_for_counting
    assert_empty Duel::Testing.measure(config, only: :count) { busy(3, 0.05) }
  end

  def test_measures_threads_waiting
    measured = Duel::Testing.measure(config, only: :timing) { busy(3, 0.2) }

    refute_predicate Duel::GVL::Hook, :running?
    assert_operator measured.fetch("gvl_wait"), :>, 0.1e9
  end

  # Nothing but the waiting: one thread computing waits for nothing but
  # handoffs (its start and end), well below the floor, on a busy
  # machine too. And only its own sample's: the hook keeps one total, and
  # a sample of a lot of waiting came first.
  def test_measures_only_waiting
    Duel::Testing.in_worker(config) do
      Duel::Testing.measure(config, only: :timing) { busy(3, 0.2) }
      measured = Duel::Testing.measure(config, only: :timing) { busy(1, 0.2) }

      assert_operator measured.fetch("gvl_wait"), :<, Duel::GVL::Wait::CPU_FLOOR * 0.2e9
    end
  end

  # A sample's stretches (around an untimed block) add up: the hook is
  # out while it's paused.
  def test_paused
    hooked = nil
    measured = Duel::Testing.measure(config, only: :timing) do |sample|
      busy(2, 0.05)
      sample.untimed do
        hooked = Duel::GVL::Hook.running?
        busy(3, 1.0) # some two seconds of waiting, unmeasured
      end
      busy(2, 0.05)
    end

    refute hooked
    assert_operator measured.fetch("gvl_wait"), :>, 0.02e9, "both stretches"
    assert_operator measured.fetch("gvl_wait"), :<, 1e9
  end

  # A benchmark without threads of its own has none to wait: it isn't
  # measured, and the hook stays out of its way.
  def test_not_for_one_thread
    hooked = nil
    measured = Duel::Testing.measure(config) { hooked = Duel::GVL::Hook.running? }

    refute hooked
    assert_empty measured
  end
end

# (Too slow for mutation testing: the code they run is covered there by
# the faster tests above.)
class GVLComparisonTest < PluginTest
  # Whole comparisons, whose workers load the extension themselves: the
  # same code passes, judged on gvl_wait where its threads fight for the
  # GVL (above the floor), and not where one thread does the work (below
  # it); code whose threads hold the GVL while they wait in C fails on it
  # (its CPU time is the same), with how long they waited an iteration on
  # each version. Never across the board.
  def test_comparisons
    dir = Dir.mktmpdir("dg", "/tmp")
    base = project(dir, "base", held: false)
    same = compare(base, project(dir, "same", held: false))

    assert_predicate same, :passed?, same.output
    assert_includes same["fight"].timed, "gvl_wait", same.output
    refute_includes same["one thread"].timed, "gvl_wait", same.output
    refute same["fight"].timed.fetch("gvl_wait").fetch("across"), same.output
    held = compare(base, project(dir, "held", held: true))
    waited = held["wait"].timed.fetch("gvl_wait")

    refute_predicate held, :passed?, held.output
    assert_equal [["wait", ["gvl_wait"]]], held.results.map { |result| [result.name, result.regressed] }.reject { |_, worse| worse.empty? },
      held.output
    assert_operator waited.fetch("median"), :>, 3, held.output
    assert_operator waited.fetch("candidate"), :>, 3 * waited.fetch("baseline"), held.output
    assert_match(/^  gvl_wait: [\d.]+(ns|µs|ms|s) → [\d.]+(ns|µs|ms|s) an iteration \(\d+\.\d\dx\)$/, held.output)
    refute_match(/across the board: gvl_wait/, held.output + same.output)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
