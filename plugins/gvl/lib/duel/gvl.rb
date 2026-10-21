# frozen_string_literal: true

require "duel"
require_relative "gvl/version"

module Duel
  # How long threads waited for the GVL during each sample: the cost of
  # the contention a change adds (holding the GVL longer around I/O, a C
  # call that stops releasing it, more threads fighting for it), which
  # CPU time doesn't show, since a thread waiting for the GVL uses none.
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :gvl }
  #
  # gvl_wait (a ratio metric, in nanoseconds) is measured for benchmarks with
  # threads of their own (only: :timing), and left out of the rest, whose
  # one thread has nothing to wait for. It needs CRuby and the gem's C
  # extension (Duel::GVL::Hook); elsewhere it's left out.
  module GVL
    Duel.plugin(:gvl, self)

    # Configures Duel for the plugin (c.use :gvl): the gvl_wait metric
    # (where it's available), and the extension, loaded in workers.
    # Returns the metric.
    def self.configure(config)
      config.in_worker { load_extension }
      config.metric(Wait)
    end

    # Whether the extension is loaded to measure with.
    def self.available? = const_defined?(:Hook, false)

    # Loads the extension (Hook) where it can be: only on CRuby (another
    # Ruby would try a build of CRuby's left in lib/), and only where it
    # was built. Whether it's loaded. (Each worker loads it, before its
    # metrics are made; the process that runs them needn't.)
    def self.load_extension(engine: RUBY_ENGINE, feature: "duel_gvl/duel_gvl")
      return false unless engine == "ruby"

      require feature
      available?
    rescue LoadError
      false
    end

    # gvl_wait: nanoseconds all threads waited for the GVL during a
    # sample of a benchmark with threads of its own.
    #
    # Threads that hardly wait still wait a little now and then, as the
    # scheduler has it (a thread's start and end are handoffs too), so a
    # sample is judged on it only when it waited a tenth of its CPU time
    # or more (CPU_FLOOR) on either version: code that starts waiting where it
    # hardly did is judged (its ratio is many times over), code that
    # hardly waits on both isn't judged on the noise. Threads that hardly
    # wait wait some 0.3-2.5% of their CPU time, on a busy machine too;
    # threads that fight for the GVL wait as long as they run, or longer
    # (a thread wanting it waits out the holder's time slice), and those
    # that only now and then want it at once, 5% to more than 100%, as
    # busy as the machine is. A share of CPU time, and not a time, since
    # a sample is as long as it takes for its CPU time to settle.
    #
    # How long threads wait depends on when the operating system runs
    # them, so on everything else the machine is doing: on a busy one,
    # the same code's samples can wait half or twice as long. What makes
    # threads wait much longer is a change that holds the GVL where it
    # didn't, which waits many times as long; so it's slower only past
    # half as much again (LIMIT), and it isn't judged across the board,
    # where the margin is a quarter of that (an eighth more).
    #
    # It doesn't size samples: four threads fighting for the GVL wait
    # three times as long as they run, and samples sized by that would be
    # too short for their CPU time to settle.
    class Wait < Metric
      CPU_FLOOR = 0.1

      LIMIT = 1.5

      def self.measures = {"gvl_wait" => {kind: :ratio, unit: "ns", cpu_floor: CPU_FLOOR, limit: LIMIT, sizes_samples: false, across: false}}

      def self.available? = GVL.available?

      def start_sample(sample)
        @measuring = sample.benchmark.only == :timing
        return unless @measuring

        Hook.start
        @waited = Hook.wait_ns
      end

      def stop_sample
        return unless @measuring

        Hook.stop
        Hook.wait_ns - @waited
      end
    end
  end
end
