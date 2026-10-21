# frozen_string_literal: true

require_relative "duel_helper"

# What the hook adds to a benchmark's own timed code: while it measures,
# Ruby calls it every time a thread takes the GVL, after waiting for it
# or not.
#
# One thread letting go of the GVL around a C call (getpid, through
# Fiddle, without the GVL) and taking it back: a microsecond or so, of
# which the hook's two calls are some 5%, with no other thread to wait
# for. (Handing the GVL from one thread to another instead costs the
# operating system's switching threads, some 5 microseconds, as busy as
# the machine is: the hook's share of that is too small, and too
# unsteady, to settle.)
setup do
  load_hook
  require "fiddle"
  @getpid = Fiddle::Function.new(Fiddle::Handle::DEFAULT["getpid"], [], Fiddle::TYPE_INT, need_gvl: false)
end

duel "hook: one thread letting go of the GVL and taking it back 100 times" do |n|
  Duel::GVL::Hook.start
  (n * 100).times { @getpid.call }
  Duel::GVL::Hook.stop
end
