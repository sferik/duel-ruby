# frozen_string_literal: true

require_relative "native"

module Duel
  # Something measured around every sample of every benchmark. A subclass
  # (Config#metric adds it) names what it measures, and how each is
  # judged, in +measures+: {"name" => settings}, each of these, any left
  # out as by default:
  #
  # - +kind+: :ratio (noisy: judged on paired ratios with a confidence
  #   interval) or :counted (exact: any increase beyond what's allowed is
  #   a regression, counted in separate samples).
  # - +unit+: what it's in, as reports show it: a time unit ("ns", "µs",
  #   "ms", "s"), shown as time (and giving +unit_ns+), or anything else,
  #   shown after the number, or nil for none. A word comes with its
  #   plural, [singular, plural] (%w[row rows]: 1 row, 2 rows), and a symbol ("B",
  #   "KB") is one String, the same for any number.
  # - +floor+: for a ratio metric, the least a sample must measure (in
  #   its own unit) on either version for it to be judged. Below it, it's
  #   mostly noise.
  # - +cpu_floor+: for a ratio metric measured in time (see +unit_ns+),
  #   the least share of the sample's CPU time it must be on either
  #   version to be judged (0.05: 5%): a floor that scales with the work.
  # - +limit+: for a ratio metric, its own ratio above which it's slower
  #   (nil: the run's, 1.02 by default).
  # - +unit_ns+: for a ratio metric, nanoseconds per unit, for comparing
  #   it with CPU time when sizing samples.
  # - +sizes_samples+: for a ratio metric, whether samples are made long
  #   enough for it to settle, as they are for CPU time (false for one
  #   that's noisy whatever the length, or not in step with the work).
  # - +across+: for a ratio metric, whether it's judged across the board
  #   too: false for one too noisy for so small a margin.
  # - +tolerance+: for a counted metric, the increase per iteration that
  #   still isn't one (0: one more is).
  # - +allowance+: for a counted metric, the increase per sample that
  #   still isn't one, whatever its length (noise that doesn't grow with
  #   the iterations).
  #
  # By default it measures one thing, named for the class, counted. One
  # that measures several (from one reading of a server's statistics,
  # say) returns a Hash of them, by name, from #stop_sample.
  # +available?+ says whether it can measure here at all.
  #
  # An instance lives as long as its worker: made once the worker's
  # blocks (Config#in_worker) have run, and opened (#open: what it reads
  # set up, a subscription, say), and closed (#close) when the worker
  # ends. Each sample calls #start_sample with the Sample (its benchmark
  # and its iterations, n), then #stop_sample, which returns the
  # measurement (nil: none this time). Around an +untimed+ block, and
  # around what a benchmark's around_iteration hooks do outside each
  # iteration, it's #pause_sample (by default, #stop_sample) and
  # #resume_sample (by default, #start_sample). Metrics start in the
  # order they were added and stop in reverse, around the built-in ones,
  # so a plugin's own work (reading a server's statistics, say) isn't
  # counted in allocations or CPU.
  #
  # One that's costly to read (+costly?+: a query of a server's
  # statistics, say) isn't paused around each iteration of a benchmark
  # with around_iteration hooks, but goes on measuring what they do too:
  # what that adds, an iteration, is learned in each worker, and taken
  # away (see Harness#leak).
  class Metric
    # Every setting there is (see Metric), as #settings resolves them, and
    # running totals' calibrate and Config#measure's skip.
    # @api private
    SETTINGS = %i[kind unit floor cpu_floor limit unit_ns sizes_samples across tolerance allowance calibrate skip].freeze

    # A unit that's a word (or words), which needs its plural given: one
    # that isn't (a symbol: "B", "KB", "op/s") is the same for any number.
    # @api private
    WORD = /\A[a-z]+( [a-z]+)*\z/

    # The units that are time, and the nanoseconds in each: a measure in
    # one is shown as time (and its unit_ns follows from it).
    # @api private
    TIME_UNITS = {"ns" => 1, "µs" => 1_000, "ms" => 1_000_000, "s" => 1_000_000_000}.freeze

    # No measure's settings changed.
    # @api private
    UNCHANGED = {} #: Hash[String, Hash[Symbol, untyped]]

    # No change to a measure's settings.
    # @api private
    NO_CHANGE = {} #: Hash[Symbol, untyped]

    class << self
      # Whether it can measure here at all (false leaves it out): by
      # default, it can.
      def available? = true

      # Whether reading it is costly (a round trip to a server, say), so
      # it isn't paused around each iteration of a benchmark with
      # around_iteration hooks (see Metric): by default, it isn't.
      def costly? = false

      # The metric's name in reports: by default, its class's, in snake
      # case ("QueryCount" is "query_count").
      def metric_name = name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

      # What it measures, and how each is judged: {name => settings}, by
      # default one, named metric_name, counted. The one place a metric
      # says so.
      def measures = {metric_name => {}}

      # Fails unless +settings+ (a measure's, named +name+) are settings
      # there are, with a kind there is and a unit that's one (a word with
      # its plural): a typo isn't left to mean nothing.
      # @api private
      def check(name, settings)
        unknown = settings.keys - SETTINGS
        raise Error, "#{name}: no setting #{unknown.join(", ")} (settings: #{SETTINGS.join(", ")})" unless unknown.empty?
        unless %i[ratio counted].include?(settings.fetch(:kind, :counted))
          raise Error, "#{name}: kind is :ratio or :counted, not #{settings.fetch(:kind).inspect}"
        end
        unit = settings.fetch(:unit, nil)
        if unit.instance_of?(String) && unit.match?(WORD) && !TIME_UNITS.key?(unit)
          raise Error, "#{name}: a word as a unit needs its plural too: unit: [#{unit.inspect}, plural]"
        end
        return if unit.nil? || unit.instance_of?(String) || (unit.instance_of?(Array) && unit.size == 2 && unit.all?(String))

        raise Error, "#{name}: unit is a String or [singular, plural], not #{unit.inspect}"
      end

      # Whether +more+ (what a count grew by, over +n+ iterations) is
      # still within what's allowed: +tolerance+ an iteration and
      # +allowance+ a sample. Duel judges counts so, and so can a metric, to
      # tell whether it's worth explaining one (see #within?).
      def within?(more, n, tolerance:, allowance:) = more <= allowance + (tolerance * n)

      # Each measure's settings, by name, every one of them filled in (as
      # declared, and the rest as by default): what a plugin's tests can
      # check. (+overrides+, by name, are Config#measure's: @api private.)
      def settings(overrides = UNCHANGED)
        measures.to_h do |name, declared|
          given = declared.merge(overrides.fetch(name, NO_CHANGE)) #: Hash[Symbol, untyped]
          [name, resolve(given)]
        end
      end

      # A measure's settings: those +given+, and the rest as by default (a
      # time unit gives unit_ns, unless it's given, and a symbol is its own
      # plural).
      # @api private
      def resolve(given)
        unit, plural = given.fetch(:unit, nil)
        {kind: given.fetch(:kind, :counted), unit: unit, plural: plural || unit, floor: given.fetch(:floor, 0),
         cpu_floor: given.fetch(:cpu_floor, 0),
         limit: given.fetch(:limit, nil), unit_ns: given.fetch(:unit_ns) { TIME_UNITS.fetch(unit, 1) },
         sizes_samples: given.fetch(:sizes_samples, true), across: given.fetch(:across, true),
         tolerance: given.fetch(:tolerance, 0), allowance: given.fetch(:allowance, 0)}
      end

      # Each measure's kind, :ratio or :counted, by name.
      # @api private
      def kinds = settings.transform_values { |settings| settings.fetch(:kind) }

      # Its measures as the runner learns them, with +overrides+ (see
      # Config#measure) by name.
      # @api private
      def specs(overrides = UNCHANGED)
        settings(overrides).map do |name, spec|
          {"name" => name, "kind" => spec.fetch(:kind).to_s, "unit" => spec.fetch(:unit), "plural" => spec.fetch(:plural),
           "floor" => spec.fetch(:floor),
           "cpu_floor" => spec.fetch(:cpu_floor), "limit" => spec.fetch(:limit), "unit_ns" => spec.fetch(:unit_ns),
           "sizes_samples" => spec.fetch(:sizes_samples), "across" => spec.fetch(:across), "tolerance" => spec.fetch(:tolerance),
           "allowance" => spec.fetch(:allowance)}
        end
      end
    end

    # Each measure's settings, by name, with Config#measure's changes (as
    # the worker it's in has them).
    def settings = @settings ||= self.class.settings

    # @api private
    def settings=(settings)
      @kinds = @first_measure = @only_measure = nil
      @settings = settings
    end

    # Each measure's kind, by name, as #settings has it, and the measure
    # that a measurement of one (not a Hash) is, the first: how a sample
    # files what it measured (asked of every stretch, so worked out once).
    # @api private
    def kinds = @kinds ||= settings.transform_values { |settings| settings.fetch(:kind) }

    # @api private
    def first_measure = @first_measure ||= settings.keys.first

    # The setting +key+ (:allowance, say) of +measure+: by default, of the
    # one it measures (one that measures several names it).
    def setting(key, measure = only_measure) = settings.fetch(measure).fetch(key)

    # Whether +more+ (what +measure+'s count grew by, over +n+
    # iterations) is still within its tolerance and allowance, as Duel
    # judges it (see Metric.within?): whether it's worth explaining.
    def within?(more, n, measure = only_measure)
      Metric.within?(more, n, tolerance: setting(:tolerance, measure), allowance: setting(:allowance, measure))
    end

    # Sets up what it reads (a subscription, say), once in each worker,
    # before it measures anything.
    def open
    end

    # Begins measuring a sample (a Duel::Sample: its benchmark, n).
    def start_sample(sample)
    end

    # Ends it, and returns the measurement, a Hash of them, or nil.
    def stop_sample
    end

    # Pauses it, for an +untimed+ block, and returns what it measured so
    # far.
    def pause_sample = stop_sample

    # Resumes it after an +untimed+ block.
    def resume_sample(sample) = start_sample(sample)

    # What it would say of the sample it last stopped, to explain a
    # regression in it ("100 String, 50 Hash", say): text, text by measure
    # name, or nil. Asked once a sample, right after #stop_sample (not
    # after #pause_sample).
    def details
    end

    # Lets go of what #open set up, when its worker ends. Metrics close
    # last first.
    def close
    end

    private

    # The one measure it measures. One that measures several (or none)
    # fails. Found once (see #settings=): #within? may be asked every
    # sample, and allocates nothing.
    def only_measure
      @only_measure ||= begin
        name, *others = settings.keys
        raise Error, "#{self.class} doesn't measure one thing (#{settings.keys.join(", ")}): name which" unless name && others.empty?

        name
      end
    end
  end

  # A metric of running totals (see Config#metric): its block reads them,
  # a number for one measure or a Hash of them by name (nil for one it
  # can't read this time), and a sample measures what they grew by.
  # Reading them can itself add to what's counted (a query that reads a
  # server's statistics is one more query), so each worker reads them
  # twice in a row, CALIBRATION times, and the least each counted total
  # grew by is taken from every sample's: unless a measure says
  # calibrate: false (its reading costs nothing, or a varying amount its
  # block takes away itself). A ratio one is left alone: its reading's
  # cost isn't steady enough to take away.
  #
  # Config#metric makes one, and returns it (to take .open, .close,
  # .details and .costly, the block forms of a Metric's #open, #close,
  # #details and .costly?). It isn't made or subclassed otherwise.
  class Snapshot < Metric
    # The pairs of readings each worker takes to learn what reading costs.
    # @api private
    CALIBRATION = 3

    # One reading: the totals, by name, and what else the block read with
    # them (+context+: whatever its details block needs, or nil). Its
    # writers, and making one, are @api private.
    Reading = Struct.new(:totals, :context)

    class Reading
      # The total named +name+: one this reading has (it fails for one it
      # couldn't read, or one there isn't).
      def total(name) = totals[name] || raise(Error, "no total #{name} in this reading (#{totals.compact.keys.join(", ")})")
    end

    class << self
      attr_reader :measures

      # A Snapshot for +measures+ ({name => settings}), read by +read+.
      # @api private
      def define(measures, read)
        raise ArgumentError, "a metric of running totals needs a block to read them" unless read
        raise ArgumentError, "a metric of running totals needs a name for what it measures" if measures.empty?

        measures.each { |name, settings| check(name, settings) }
        snapshot = Class.new(self) #: singleton(Snapshot)
        snapshot.reading(measures, read)
      end

      # Sets what it measures and how it reads them, and returns it.
      # @api private
      def reading(measures, read)
        @measures = measures
        @read = read
        @costly = false
        self
      end

      # Whether reading it is costly (see Metric.costly? and .costly).
      def costly? = @costly

      # Says that reading it is costly (a query of a server's statistics,
      # say): it isn't paused around each iteration of a benchmark with
      # around_iteration hooks, and what they add to it is taken away
      # instead (see Metric). Returns the metric.
      #
      #   c.metric("postgres_queries") { queries }.costly
      def costly
        @costly = true
        self
      end

      # Explains its samples by the block (see #details), given each one's
      # stretches and the sample: what Config#metric returns takes it.
      # Returns the metric.
      #
      #   c.metric("sql_queries") { [queries, statements] }.details { |stretches, sample| ... }
      def details(&explainer)
        @explainer = explainer
        self
      end

      # Runs the block in each worker as the metric is opened (see
      # Metric#open), before it reads anything: to set up what it reads
      # (subscribing to notifications, say). Returns the metric.
      #
      #   c.metric("sql_queries") { counter.queries }.open { counter.subscribe }.close { counter.unsubscribe }
      def open(&opener)
        @opener = opener
        self
      end

      # Runs the block when each worker ends (see Metric#close): to let go
      # of what .open set up. Returns the metric.
      def close(&closer)
        @closer = closer
        self
      end

      # What explains a sample (see .details), opens the metric in a
      # worker (.open) and closes it (.close), or nil.
      # @api private
      attr_reader :explainer, :opener, :closer

      # A Reading: the totals, by name (those it measures, or it fails,
      # naming them), and their context. The block returns the totals (a
      # number, for one), or [totals, context].
      # @api private
      def read
        # (A number or a Hash, alone, is the totals, without a context.)
        totals, context = @read.call
        # (A Hash of them, or one: as the block's type says.)
        totals = (totals.is_a?(Hash) ? totals : {measures.keys.first => totals}) #: totals[Metric::value]
        return Reading.new(totals, context) if totals.keys.sort == measures.keys.sort

        raise Error, "running totals of #{measures.keys.join(", ")}: read #{totals.keys.join(", ")}"
      end
    end

    # Runs its .open block, if it has one, then learns what reading its
    # counted totals costs.
    def open
      self.class.opener&.call
      calibrated = self.class.measures.filter_map do |name, settings|
        name if settings.fetch(:kind, :counted) == :counted && settings.fetch(:calibrate, true)
      end
      @overhead = calibrated.to_h { |name| [name, Array.new(CALIBRATION) { grew(self.class.read.totals, name) }.min] }
    end

    # A sample begins: its first stretch (see #details).
    def start_sample(sample)
      @sample = sample
      @stretches = [] #: Snapshot::stretches[Metric::value, untyped]
      @started = self.class.read
    end

    # Another stretch of the same sample, after an untimed block.
    def resume_sample(_sample) = @started = self.class.read

    def stop_sample
      stopped = self.class.read
      @stretches << [@started, stopped]
      stopped.totals.to_h do |name, total|
        started = @started.totals.fetch(name)
        [name, (total - started - @overhead.fetch(name, 0) if total && started)]
      end
    end

    # What its +details+ block says of the sample it last stopped, given
    # each stretch of it measured ([started, stopped] Readings: one, unless
    # untimed blocks paused it) and the Sample (its n, say).
    def details = self.class.explainer&.call(@stretches, @sample)

    # Runs its .close block, if it has one.
    def close = self.class.closer&.call

    private

    # What +name+'s total grew by in a reading after +before+ (nothing,
    # where it can't be read).
    def grew(before, name)
      after = self.class.read.totals.fetch(name)
      started = before.fetch(name)
      (after && started) ? after - started : 0
    end
  end

  # CPU time in nanoseconds: the benchmark thread's, or the process's.
  # @api private
  module Clock
    def self.thread = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :nanosecond)

    def self.process = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID, :nanosecond)
  end

  # simplecov:disable JRuby has no thread CPU clock of Ruby's, but the JVM's (JRuby's
  # test run covers these).
  if RUBY_ENGINE == "jruby"
    module Clock
      def self.thread = java.lang.management.ManagementFactory.getThreadMXBean.getCurrentThreadCpuTime

      def self.process = java.lang.management.ManagementFactory.getOperatingSystemMXBean.getProcessCpuTime
    end
  end
  # simplecov:enable

  # The built-in metrics: their measures are named ("cpu",
  # "instructions", "allocations"), as Config#measure takes them.
  # @api private
  module Metrics
    # CPU time (see Definition#cpu), in nanoseconds: what other
    # processes on the machine don't inflate. Always measured last, inside
    # every other metric.
    class CPU < Metric
      def self.measures = {"cpu" => {kind: :ratio, unit: "ns", floor: 300_000}}

      def start_sample(sample)
        @clock = sample.benchmark.cpu
        @started = Clock.public_send(@clock)
      end

      def stop_sample = Clock.public_send(@clock) - @started
    end

    # Instructions retired in user space, from the CPU's own counters:
    # nearly the same from run to run, so it catches slowdowns too small
    # for CPU time to settle (with a limit of its own, 1%). Where the
    # counters are: Linux (the benchmark thread's, unless a virtual
    # machine hides them, so not for benchmarks with threads of their
    # own) and macOS (the whole process's). It misses what instructions
    # don't show, like cache misses: CPU time is still judged.
    class Instructions < Metric
      def self.measures = {"instructions" => {kind: :ratio, floor: 100_000, sizes_samples: false, limit: 1.01}}

      def self.available? = !counter.nil?

      # This process's counter (see Native::Counter.open), or nil.
      def self.counter
        return @counter if instance_variable_defined?(:@counter)

        @counter = Native::Counter.open
      end

      def initialize
        # (There's one: it's made only where it's available?.)
        @counter = self.class.counter #: Native::Counter
      end

      def start_sample(sample)
        @counting = sample.benchmark.cpu == :thread || @counter.scope == "process"
        @started = @counter.read if @counting
      end

      def stop_sample = (@counter.read - @started if @counting)
    end

    # Ruby objects allocated (CRuby). The same code's count can differ by
    # a few from run to run (ids of random lengths, say), so it's one
    # more per two iterations, not one more, that's a regression.
    class Allocations < Metric
      def self.measures = {"allocations" => {tolerance: 0.5}}

      # mutant:disable -- mutant runs on CRuby, where this is always true
      def self.available? = RUBY_ENGINE == "ruby"

      def start_sample(_sample)
        @started = GC.stat(:total_allocated_objects)
      end

      def stop_sample = GC.stat(:total_allocated_objects) - @started
    end
  end
end
