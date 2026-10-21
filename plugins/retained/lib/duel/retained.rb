# frozen_string_literal: true

require "duel"
require "objspace"
require_relative "retained/version"

module Duel
  # What each benchmark leaves alive: the Ruby objects still there after
  # a full garbage collection that weren't before it (CRuby).
  #
  # - retained_objects: the objects a sample's iterations left alive
  #   (counted; beyond ALLOWANCE a sample, one more per two iterations is
  #   a regression)
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :retained }
  #
  # So a leak, a cache that grows with every call, or memoization keyed
  # by input that never repeats, fails, though it allocates no more and
  # takes no longer than before.
  #
  # Duel holds the garbage collector off during a sample, but GC.start
  # still collects: the metric collects, twice (what a finalizer or a
  # dynamic symbol keeps alive goes in the second), and counts the live
  # objects before the sample and again after it. It's outside the
  # built-in metrics, so none of that is in allocations or CPU time, and
  # only in the samples Duel counts in (a few a benchmark), not the timed
  # ones. When a sample retained more than Duel lets through, the metric
  # says what (Objects#details), by class and where it was made, under
  # the regression: "an iteration: 1 String (lib/my_cache.rb:12)".
  module Retained
    Duel.plugin(:retained, self)

    # The retained objects a sample is allowed (Duel's allowance) before
    # any is counted against it: Duel's own record of the metrics inside
    # this one, and what's still on the machine stack when the sample
    # stops (the last iteration's result, or the block's, given n),
    # which are the same few from sample to sample, but not always to the
    # object.
    ALLOWANCE = 16

    # Retained objects per iteration that still aren't a regression.
    TOLERANCE = 0.5

    # The kinds of object (by class, and where they were made) a sample
    # that retained more than its allowance shows, most first.
    SHOWN = 3

    # Configures Duel for the plugin (c.use :retained): the metric
    # (CRuby only: elsewhere the garbage collector can't be held off or
    # its live objects counted). Returns the metric.
    def self.configure(config) = config.metric(Objects)

    # Collects all the garbage there is: a full collection (GC.start's
    # own: a full mark, and an immediate sweep), twice (the first leaves
    # what has a finalizer to run, and a dynamic symbol's string, for the
    # second). It collects though the garbage collector is disabled, and
    # leaves it as it was.
    def self.collect = 2.times { GC.start }

    # The objects alive after collecting the garbage.
    def self.live
      collect
      GC.stat(:heap_live_slots)
    end

    # Where Duel's own files are: what it makes during a sample (its
    # record of the metrics inside this one) is in the allowance, and
    # isn't shown.
    # (Duel's metric.rb, written in Ruby: it has a source location.)
    metric_rb, = Metric.instance_method(:details).source_location #: [String, Integer]
    DUEL = File.join(File.dirname(metric_rb), "")

    # What each of the objects that a sample made (and Objects traced)
    # and left alive is, and where it was made: {[class, "file:line"] =>
    # how many}, most first, but Duel's own. A walk of every live object.
    def self.traced
      counts = Hash.new(0) #: Hash[[String, String], Integer]
      class_of = Kernel.instance_method(:class)
      here = File.join(Dir.pwd, "")
      ObjectSpace.each_object do |object|
        next unless ObjectSpace.allocation_generation(object)

        file = ObjectSpace.allocation_sourcefile(object)
        next if file.to_s.start_with?(DUEL)

        klass = class_of.bind_call(object)
        counts[[klass.name || klass.inspect, site(file, ObjectSpace.allocation_sourceline(object), here)]] += 1
      end
      counts.sort_by { |(klass, site), count| [-count, klass, site] }.to_h
    end

    # Where an object was made, from its +file+ and +line+ (nil where it
    # wasn't made in Ruby code): the file from +here+ (a directory, with
    # a trailing slash) where it's under it.
    def self.site(file, line, here) = file ? "#{file.delete_prefix(here)}:#{line}" : "?"

    # The metric: the objects alive after the sample less those before
    # it (fewer, when the sample let go of more than it kept). Duel takes
    # the allowance and the tolerance into account when it compares them.
    class Objects < Metric
      def self.measures = {"retained_objects" => {unit: %w[object objects], allowance: ALLOWANCE, tolerance: TOLERANCE}}

      # mutant:disable -- mutant runs on CRuby, where this is always true
      def self.available? = RUBY_ENGINE == "ruby"

      # It traces where objects are made (ObjectSpace's allocation
      # tracing) during the sample, for #details: what it retained, it
      # can tell apart from the rest.
      def start_sample(sample)
        @n = sample.n
        ObjectSpace.trace_object_allocations_clear
        ObjectSpace.trace_object_allocations_start
        @live = Retained.live
      end

      def stop_sample
        @retained = Retained.live - @live
      ensure
        ObjectSpace.trace_object_allocations_stop
      end

      # It goes on through an untimed block: stopping and starting would
      # collect the garbage, twice, on each, for every untimed block (an
      # iteration's, maybe). So it measures the whole sample, and what an
      # untimed block made (the input the benchmark works on, usually)
      # counts only if it's still alive when the sample is over.
      def pause_sample
      end

      def resume_sample(_sample)
      end

      # What the sample retained, an iteration, by class and where it was
      # made (the SHOWN most), when it retained more than Duel lets through
      # (its allowance a sample, and its tolerance an iteration, as
      # configured): only then is it worth walking every live object for
      # (Retained.traced). Nothing for one that retained less. Duel asks
      # once, after the sample: the trace is cleared either way.
      def details
        return if within?(@retained, @n)

        kinds = Retained.traced.first(SHOWN).map { |(klass, site), count| format("%.4g %s (%s)", count.fdiv(@n), klass, site) }
        "an iteration: #{kinds.join(", ")}" unless kinds.empty? # (none it can see: internal objects, or a trace cleared)
      ensure
        ObjectSpace.trace_object_allocations_clear
      end
    end
  end
end
