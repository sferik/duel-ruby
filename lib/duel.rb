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

  # The hooks, which run code around a benchmark's samples: in .duel.rb
  # (Config#setup, say), at the top of a file of benchmarks (DSL#setup),
  # or as an option of one benchmark (DSL#duel's setup:). Where several
  # give one, the configuration's run first, then the file's, then the
  # benchmark's (teardown's in reverse, and around_iteration's outermost
  # first):
  #
  # - setup: once in each worker, before the benchmark's samples
  # - teardown: once in each worker, after them
  # - before_sample: before every sample (the warm-up's too), not
  #   measured
  # - around_iteration: around each iteration, given it (an Iteration) to
  #   run: only the iteration is measured
  # - after_iterations: after each sample's iterations (inside each
  #   iteration, with around_iteration), measured with them
  HOOKS = %i[setup teardown before_sample around_iteration after_iterations].freeze

  # No hooks, by name.
  # @api private
  NO_HOOKS = HOOKS.to_h { |hook| [hook, Array.new(0).freeze] }.freeze #: Hash[Symbol, Array[hook]]

  # A benchmark (see DSL#duel), defined in +file+, whose hooks (those of
  # its file, and its own, +hooks+, by name) it gets. Or a benchmark of a
  # whole +process+ (see DSL#duel_process), with no +body+. What a
  # metric sees of it (Sample#benchmark), and its hooks are given, is
  # its +name+, +only+ and +peak_memory+. Its +file+, +body+, +hooks+
  # and +process+, and its writers, are @api private.
  Definition = Struct.new(:name, :only, :peak_memory, :file, :body, :hooks, :process)

  class Definition
    # Whose CPU time it takes: the benchmark thread's, or (judged on its
    # timings alone, as work on threads of its own is) the process's.
    # @api private
    def cpu = (only == :timing) ? :process : :thread

    # What the runner learns of it.
    # @api private
    def to_h = {"name" => name, "only" => only&.to_s, "peak_memory" => peak_memory, "process" => process}
  end

  # The iterations of a benchmark judged on its counts alone (see
  # DSL#duel).
  # @api private
  COUNTS_ONLY = 4

  # What a benchmark may be judged on (see DSL#duel): nil for both.
  # @api private
  ONLY = [nil, :count, :timing] #: Array[only?]

  # What a worker's blocks (Config#in_worker) are given: blocks to run
  # when the worker ends, last first.
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

  # What Config#in_worker returns: what its block returned in the worker
  # (a connection, say, that metrics and benchmarks use).
  class InWorker
    # The worker's. Outside a worker (the runner's process, or a test not
    # in Duel::Testing.in_worker), it fails.
    def value
      made = @made
      raise Error, "made in each worker only (c.in_worker): in tests, inside Duel::Testing.in_worker" unless made

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

    # Runs the block with #measuring? as +measuring+, and returns what it
    # does.
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

    # Where +method+ is defined ("file:line"), or, for one with no file,
    # whose it is (Kernel, say): for an error about it.
    # @api private
    def where(method) = method.source_location&.join(":") || method.owner.to_s

    # Every benchmark defined, by name.
    # @api private
    def benchmarks = @benchmarks ||= {}

    # Each file's hooks (see DSL#setup, say), by its path, then by name.
    # @api private
    def file_hooks = @file_hooks ||= Hash.new { |all, file| all[file] = HOOKS.to_h { |hook| [hook, []] } }

    # Adds +block+ as the hook +name+ (one of HOOKS) of the file of
    # benchmarks running (see #defining_file), or else of +file+, the one
    # that gave it (not where the block is: a lambda of a plugin's, say).
    # @api private
    def file_hook(name, block, file)
      hook = hook(name, block)
      file_hooks[defining_file || file].fetch(name) << hook
    end

    # +block+, a hook +name+d (one of HOOKS), or a failure if it isn't
    # one: a Proc (a block, or a lambda), and for around_iteration, one
    # that takes the iteration.
    # @api private
    def hook(name, block)
      raise ArgumentError, "#{name}: give a block (or a lambda), not #{block.inspect}" unless block.is_a?(Proc)
      return block unless name == :around_iteration
      return block if block.arity == 1

      raise ArgumentError, "around_iteration: take the iteration, and run it: { |iteration| ... iteration.call ... }"
    end

    # Registers a plugin, +name+d as its file is required (duel/+name+,
    # which Config#use requires): +plugin+, a module whose +configure+
    # Config#use calls, given the configuration and the options it's used
    # with. Returns its name.
    #
    #   module Duel
    #     module Redis
    #       Duel.plugin(:redis, self)
    #
    #       def self.configure(config, server: "redis-server")
    #         config.prepare(:worker) { |w| ... }
    #       end
    #     end
    #   end
    #
    # Its own kinds of benchmark, if it has any, are the methods of its
    # module's DSL module, which files of benchmarks get as .duel.rb uses
    # it (see DSL.add):
    #
    #   module Duel
    #     module MyApp
    #       Duel.plugin(:my_app, self)
    #
    #       module DSL
    #         def duel_request(name, path, **options) = duel(name, **options) { ::MyApp.get(path) }
    #       end
    #     end
    #   end
    def plugin(name, plugin)
      plugins[name] = plugin
      name
    end

    # Every plugin registered, by name.
    # @api private
    def plugins = @plugins ||= {} #: Hash[Symbol, Module & _Plugin]

    # The file of benchmarks that called the DSL method running (see
    # DSL.add), if one is: the file that what it defines is filed
    # under, so it gets that file's hooks, not those of the file the
    # method is in.
    # @api private
    attr_reader :defining_file

    # Runs the block with +file+ as #defining_file, unless a DSL method
    # that called this one gave one already (the outermost, a file of
    # benchmarks, is the one), and returns what it does.
    # @api private
    def defining(file)
      outer = @defining_file
      @defining_file = outer || file
      begin
        yield
      ensure
        @defining_file = outer
      end
    end
  end

  # What files of benchmarks call (the worker gives it to its main
  # object).
  module DSL
    # Adds the public methods of +methods+, a plugin's DSL module (see
    # Duel.plugin), to the DSL, as .duel.rb uses the plugin (see
    # Config#use): files of benchmarks call them on their main object,
    # so they can call #duel. Adding a module's again does nothing.
    #
    # A name the DSL has already fails, and so does one that every object
    # has (Kernel's +test+, say), which it would hide. What a method
    # defines (with #duel or #duel_process, or a hook: #setup, say) is
    # filed under the file of benchmarks that called it, not the
    # plugin's, so it gets that file's hooks, as a benchmark defined
    # there with #duel does.
    # @api private
    def self.add(methods) = methods.public_instance_methods(false).each { |name| define(name, methods) }

    # Adds +methods+' method +name+ to the DSL (see .add), unless it's
    # there already.
    # @api private
    def self.define(name, methods)
      return if DEFINED[name].equal?(methods)

      taken = [self, Object].find { |owner| owner.method_defined?(name) || owner.private_method_defined?(name) }
      raise Error, "#{methods}##{name}: the DSL has #{name} already (#{Duel.where((DEFINED[name] || taken).instance_method(name))})" if taken

      DEFINED[name] = methods
      define_method(name) do |*args, **options, &block|
        # @type var options: Hash[Symbol, untyped]
        # @type var block: (^(*untyped, **untyped) -> untyped)?
        # @type self: Object
        # (Where it's called from: the one frame there always is.)
        # @type var from: Thread::Backtrace::Location
        caller_locations(1, 1) => [from]
        # (The plugin's method as it is now, looked up each call.)
        Duel.defining(from.path) { methods.instance_method(name).bind_call(self, *args, **options, &block) }
      end
    end

    # The plugin's DSL module each method DSL.add added is from (for
    # where it's defined).
    # @api private
    DEFINED = {} #: Hash[Symbol, Module]

    # Defines a benchmark. Its block is timed, run as many times as a
    # sample needs. With a parameter, it's run once a sample and given
    # how many iterations to do:
    #
    #   duel "parse: a document" do
    #     once { @input = File.read("doc.json") } # not timed: once, first
    #     MyLib.parse(@input)                      # timed
    #   end
    #
    #   duel "queue: drain the queue" do |n|
    #     queue = untimed { MyQueue.new(Array.new(n)) } # not timed: every sample
    #     queue.drain
    #   end
    #
    # Options: only: what it's judged on, if not both its timings and its
    # counts: :count for work too slow and light to time (waiting, say),
    # run a few iterations at a time, or :timing for work done by
    # threads of its own, which make its counts vary (and whose CPU time
    # is the process's, not the benchmark thread's). peak_memory: true to
    # judge its peak memory too. And its own hooks (see HOOKS), lambdas
    # run in its context, after its configuration's and its file's: an
    # around_iteration one takes the iteration (an Iteration) and runs
    # it, and only the iteration is measured, so what it does before and
    # after (rolling back what the iteration wrote, say) isn't.
    #
    #   duel "posts: create", around_iteration: ->(iteration) { rolled_back { iteration.call } } do
    #     Post.create!(title: "Hi")
    #   end
    def duel(name, only: nil, peak_memory: false, **hooks, &body)
      raise ArgumentError, "duplicate benchmark #{name.inspect}" if Duel.benchmarks.key?(name)
      raise ArgumentError, "only: must be :count or :timing, not #{only.inspect}" unless ONLY.include?(only)

      Duel.benchmarks[name] = Definition.new(name, only, peak_memory, Duel.defining_file || body.source_location.first, body,
        DSL.hooks(name, hooks, body))
    end

    # A benchmark's own hooks (+hooks+, by name), each one a hook there
    # is (see Duel.hook): an around_iteration one runs around each
    # iteration, so +body+ (the benchmark's block) can't take them.
    # @api private
    def self.hooks(name, hooks, body)
      unknown = hooks.keys - HOOKS
      raise ArgumentError, "duel #{name.inspect}: no option #{unknown.join(", ")} (only, peak_memory, #{HOOKS.join(", ")})" unless unknown.empty?

      hooks.each { |hook, block| Duel.hook(hook, block) }
      if hooks.key?(:around_iteration) && body.arity == 1
        raise ArgumentError, "duel #{name.inspect}: around_iteration runs around each iteration: give the benchmark's block no parameter"
      end

      hooks
    end

    # Defines a benchmark of a whole process, booting an app or requiring
    # a library, say: each of its samples is a fresh process for each
    # version, in turn, started in the version's tree with its
    # environment (and on its Ruby: see Config#ruby), and it's judged on
    # the process's CPU time (its children's too) and, where Duel can tell
    # it, its peak memory.
    #
    #   duel_process "boot: the app", "bin/rails", "runner", "1"
    #   duel_process "boot: require the library", ruby: %(require "my_gem")
    #
    # A +command+ is run as Process.spawn takes it (one String with
    # spaces is a shell command). Code given as +ruby+ is run by the
    # version's Ruby, with the version's lib/ first on the load path. A
    # process that fails (a status other than 0) is an error. Each sample
    # is the fastest of +runs+ processes: by default, as many as take about
    # a second of CPU time, up to 3.
    #
    # It isn't run in a worker, so what runs there doesn't apply to it:
    # hooks (the configuration's, and its file's), and plugins' metrics.
    # Nor do #duel's options: given one (around_iteration:, say), it
    # fails.
    def duel_process(name, *command, ruby: nil, runs: nil, **options)
      raise ArgumentError, "duplicate benchmark #{name.inspect}" if Duel.benchmarks.key?(name)
      raise ArgumentError, "duel_process #{name.inspect}: give a command, or ruby: code, not both" if command.empty? == ruby.nil?
      counted = runs.nil? || (runs.instance_of?(Integer) && runs.positive?)
      raise ArgumentError, "duel_process #{name.inspect}: runs: is a number of processes a sample, 1 or more, not #{runs.inspect}" unless counted
      unless options.empty?
        raise ArgumentError, "duel_process #{name.inspect}: #{options.keys.join(", ")} #{(options.size == 1) ? "is" : "are"} duel's, " \
          "for a benchmark run in a worker: a process benchmark runs no hooks, and is judged on its CPU time and peak memory alone"
      end

      process = {"command" => (command unless command.empty?), "ruby" => ruby, "runs" => runs} #: Definition::process
      Duel.benchmarks[name] = Definition.new(name, nil, false, Duel.defining_file || caller_locations.fetch(0).path, nil, {}, process)
    end

    # En garde.
    # @api private
    alias_method :⚔️, :duel
    # @api private
    alias_method :⚔, :duel

    # The file's hooks (see HOOKS), for every benchmark in it: run in each
    # benchmark's context, after the configuration's and before the
    # benchmark's own. setup runs once in each worker before a
    # benchmark's samples, and teardown after them (last first).
    # before_sample runs before every sample (the warm-up's too), not
    # measured: to put back what earlier samples changed (data they
    # wrote, say), so that every sample starts alike. The first three
    # are given the benchmark, if they take it.
    def setup(&block) = Duel.file_hook(:setup, block, DSL.caller_file)

    def teardown(&block) = Duel.file_hook(:teardown, block, DSL.caller_file)

    def before_sample(&block) = Duel.file_hook(:before_sample, block, DSL.caller_file)

    # Runs the block around each iteration of every benchmark in the
    # file, given the iteration (an Iteration) to run, once: only the
    # iteration is measured.
    def around_iteration(&block) = Duel.file_hook(:around_iteration, block, DSL.caller_file)

    # Runs the block after each sample's iterations of every benchmark in
    # the file (inside each iteration, with around_iteration), measured
    # with them: to do the work they left to be done later.
    def after_iterations(&block) = Duel.file_hook(:after_iterations, block, DSL.caller_file)

    # The file that called the DSL method calling this (the one frame
    # there always is, past it).
    # @api private
    def self.caller_file
      # @type var from: Thread::Backtrace::Location
      caller_locations(2, 1) => [from]
      from.path
    end
  end
end
