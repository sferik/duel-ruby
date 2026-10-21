# frozen_string_literal: true

require_relative "duel/version"
require_relative "duel/config"
require_relative "duel/metric"

# Performance regression guards: every benchmark runs on two versions of
# a codebase side by side, the baseline and the candidate, and the
# candidate fails if it's slower at any of them. See the README.
module Duel
  # What Duel raises when something is used wrong, or fails: a setting
  # there isn't, a helper called where it would be counted, a resource
  # that didn't start (Failed).
  class Error < StandardError; end

  # A benchmark (see DSL#duel), defined in +file+, whose setup and
  # teardown blocks (those defined there too) it gets. What a metric sees
  # of it (Sample#benchmark) is its +name+, +only+ and +peak_memory+;
  # its +file+ and +body+, and its writers, are @api private.
  Definition = Struct.new(:name, :only, :peak_memory, :file, :body)

  class Definition
    # Whose CPU time it takes: the benchmark thread's, or (judged on its
    # timings alone, as work on threads of its own is) the process's.
    # @api private
    def cpu = (only == :timing) ? :process : :thread

    # What the runner learns of it.
    # @api private
    def to_h = {"name" => name, "only" => only&.to_s, "peak_memory" => peak_memory}
  end

  # The iterations of a benchmark judged on its counts alone (see
  # DSL#duel).
  # @api private
  COUNTS_ONLY = 4

  # What a benchmark may be judged on (see DSL#duel): nil for both.
  # @api private
  ONLY = [nil, :count, :timing] #: Array[only?]

  # What a worker's blocks (Config#worker) are given: blocks to run when
  # the worker ends, last first.
  class Stops
    # @api private
    def initialize
      @blocks = []
    end

    # Runs the block when the worker ends.
    def at_stop(&block) = @blocks << block

    # Runs them, last first.
    # @api private
    def run = @blocks.reverse_each(&:call)
  end

  # What a worker makes for itself (see Config#per_worker): a connection,
  # say, that its metrics and its benchmarks use.
  class PerWorker
    # The worker's; outside a worker (the runner's process, or a test not
    # in Duel::Testing.worker), it fails.
    def value
      made = @made
      raise Error, "made in each worker only (c.per_worker): in tests, inside Duel::Testing.worker" unless made

      made.first
    end

    # @api private
    def made(value) = @made = [value]

    # @api private
    def forget = @made = nil
  end

  class << self
    # The configuration: the project's .duel.rb, or the conventions.
    def config = @config ||= Config.new

    # @api private
    attr_writer :config

    # Yields the configuration (see Config), as .duel.rb does.
    def configure = yield(config)

    # Whether a benchmark is being measured right now: in a worker, inside
    # a sample, but not in its +untimed+ blocks (or in setup). What a
    # plugin's helper does then would be counted (a query it runs, say),
    # so a helper meant for setting up can fail instead.
    def measuring? = @measuring == true

    # Fails while a benchmark is being measured (see #measuring?): a
    # plugin's helper meant for setting up, +name+d, calls it first, since
    # what it does then would be counted.
    #
    #   def self.flush
    #     Duel.unmeasured!("Duel::Redis.flush")
    #     ...
    def unmeasured!(name)
      raise Error, "#{name}: in setup or untimed only (it would be counted)" if measuring?
    end

    # Runs the block with #measuring? as +measuring+; returns what it does.
    # @api private
    def measured(measuring)
      was = @measuring
      begin
        @measuring = measuring
        yield
      ensure
        @measuring = was
      end
    end

    # Loads a config file (.duel.rb): a fresh configuration, rooted where
    # the file is.
    # @api private
    def load_config(path)
      path = File.expand_path(path)
      self.config = Config.new(File.dirname(path))
      load path
      config
    end

    # Every benchmark defined, by name.
    # @api private
    def benchmarks = @benchmarks ||= {}

    # Each file's setup and teardown blocks, by its path.
    # @api private
    def setups = @setups ||= Hash.new { |all, file| all[file] = [] }

    # @api private
    def teardowns = @teardowns ||= Hash.new { |all, file| all[file] = [] }
  end

  # What files of benchmarks call (the worker gives it to its main
  # object).
  module DSL
    # Defines a benchmark. Its block is timed, run as many times as a
    # sample needs; with a parameter, it's run once a sample and given
    # how many iterations to do:
    #
    #   duel "parse: a document" do
    #     setup { @input = File.read("doc.json") } # not timed: once, first
    #     MyLib.parse(@input)                       # timed
    #   end
    #
    #   duel "queue: drain the queue" do |n|
    #     queue = untimed { MyQueue.new(Array.new(n)) } # not timed: every sample
    #     queue.drain
    #   end
    #
    # Options: only: what it's judged on, if not both its timings and its
    # counts: :count for work too slow and light to time (waiting, say),
    # run a few iterations at a time; :timing for work done by
    # threads of its own, which make its counts vary (and whose CPU time
    # is the process's, not the benchmark thread's). peak_memory: true to
    # judge its peak memory too.
    def duel(name, only: nil, peak_memory: false, &body)
      raise ArgumentError, "duplicate benchmark #{name.inspect}" if Duel.benchmarks.key?(name)
      raise ArgumentError, "only: must be :count or :timing, not #{only.inspect}" unless ONLY.include?(only)

      Duel.benchmarks[name] = Definition.new(name, only, peak_memory, body.source_location.first, body)
    end

    # En garde.
    # @api private
    alias_method :⚔️, :duel
    # @api private
    alias_method :⚔, :duel

    # Runs the block once in each worker before the samples of every
    # duel in its file (setup), or after them (teardown).
    def setup(&block) = Duel.setups[block.source_location.first] << block

    def teardown(&block) = Duel.teardowns[block.source_location.first] << block
  end
end
