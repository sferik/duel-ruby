# frozen_string_literal: true

# What each piece of a sample's CPU reading allocates, a call, here: for
# finding what a platform's measuring allocates (Windows's, say), which
# the count of allocations around it takes for the benchmark's.
#
#   ruby -Ilib tasks/allocations_check.rb
require "duel"
require "duel/worker"

def per_call(label, calls = 1000)
  2.times { yield } # (warmed: Ruby makes a call site's cache the first time it runs)
  before = GC.stat(:total_allocated_objects)
  calls.times { yield }
  puts format("%-28s %6.2f", label, (GC.stat(:total_allocated_objects) - before).fdiv(calls))
end

per_call("nothing") {}
per_call("GC.stat") { GC.stat(:total_allocated_objects) }
per_call("monotonic clock") { Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) }
per_call("thread CPU clock (Ruby's)") { Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :nanosecond) }
per_call("Duel::Clock.thread") { Duel::Clock.thread }
exit unless Duel::Native::WINDOWS

Duel::CycleClock.rate
per_call("CycleClock.thread") { Duel::CycleClock.thread }
cycles = Duel::Native::Windows::Cycles.new(:thread)
per_call("Cycles#read") { cycles.read }
query = Duel::Native.function("QueryThreadCycleTime", %i[INTPTR_T INTPTR_T], :INT, library: "kernel32")
count = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
address = count.to_i
per_call("Fiddle call") { query.call(-2, address) }
per_call("Pointer#[]") { count[0] }
per_call("Fiddle.last_error") { Fiddle.last_error }
per_call("CycleClock.ns") { Duel::CycleClock.ns(123_456_789) }
