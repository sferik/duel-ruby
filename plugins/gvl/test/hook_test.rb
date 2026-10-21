# frozen_string_literal: true

require_relative "test_helper"

# The C extension, on its own.
class HookTest < PluginTest
  def teardown
    Duel::GVL::Hook.stop if Duel::GVL.available?
  end

  def measure
    before = Duel::GVL::Hook.wait_ns
    Duel::GVL::Hook.start
    yield
    Duel::GVL::Hook.stop
    Duel::GVL::Hook.wait_ns - before
  end

  # Three threads that never let go of the GVL: while one runs, the other
  # two wait, for most of the 0.2s they run.
  def test_threads_that_fight_for_the_gvl
    started = monotonic
    waited = measure { busy(3, 0.2) }
    elapsed = monotonic - started

    assert_operator waited, :>, 0.1e9, "at least one thread waiting for half the time"
    assert_operator waited, :<, 3 * elapsed, "no more than all three the whole time"
  end

  def test_one_thread_waits_for_nothing
    started = monotonic
    computing = measure { busy(1, 0.2) }
    sleeping = measure { 20.times { sleep 0.001 } }

    assert_operator computing, :<, Duel::GVL::Wait::CPU_FLOOR * 0.2e9, "nothing else wants the GVL: below the floor, on a busy machine too"
    assert_operator sleeping, :<, (monotonic - started) / 4, "sleeping isn't waiting for the GVL"
  end

  def test_only_while_measuring
    Duel::GVL::Hook.start
    Duel::GVL::Hook.start

    assert_predicate Duel::GVL::Hook, :running?
    Duel::GVL::Hook.stop
    Duel::GVL::Hook.stop

    refute_predicate Duel::GVL::Hook, :running?
    before = Duel::GVL::Hook.wait_ns
    busy(2, 0.05)

    assert_equal before, Duel::GVL::Hook.wait_ns
  end

  # Threads that fight for the GVL through many short stretches of
  # measuring: a wait that began before a stretch (in an earlier one, its
  # end unseen) isn't counted in it, so what's counted fits in the
  # stretches.
  def test_waits_that_began_before_measuring
    stop = false
    threads = Array.new(3) { Thread.new { nil until stop } }
    stretches = 0
    waited = 0
    10.times do
      started = monotonic
      waited += measure { sleep 0.01 }
      stretches += monotonic - started
      sleep 0.15 # unmeasured: the threads take turns
    end
    stop = true
    threads.each(&:join)

    assert_operator waited, :>, 0
    assert_operator waited, :<=, 3 * stretches, "at most three threads waiting, and only in the stretches"
  end
end
