# frozen_string_literal: true

module Duel
  # What Duel knows about a project. Most of it follows from conventions,
  # so most projects need no configuration at all:
  #
  # - benchmarks are in files named *_duel.rb in duel/ (see
  #   Duel::DSL#duel)
  # - the library is the gem the project's .gemspec names, required from
  #   each version's lib/ (so benchmarks needn't require it)
  # - a project with ext/ is built with `bundle exec rake compile` when
  #   a baseline is checked out
  # - a change is compared with where it left the branch origin/HEAD
  #   points to (origin/main, say), when lib/ or ext/ changed
  # - releases are tagged v*
  #
  # .duel.rb, at the root, changes what doesn't fit:
  #
  #   Duel.configure do |c|
  #     c.benchmarks = "perf/**/*_duel.rb"
  #     c.build = "make"
  #     c.metric MyMetric                   # see Duel::Metric
  #   end
  #
  # The file is the candidate's, and every worker loads it too: the
  # baseline's worker runs the candidate's benchmarks and plugins against
  # the baseline's code.
  class Config
    # Where the project is (and its config file).
    attr_reader :root

    # A glob, from the root, of the files defining benchmarks.
    attr_accessor :benchmarks

    # Paths, from the root, whose changes a comparison is about: when none
    # of them changed since the baseline, there's nothing to compare.
    attr_accessor :watch

    # The library to require from each version, as `require` takes it;
    # nil for none (benchmarks require what they need).
    attr_writer :library

    # A shell command that builds a checked-out tree, run in it; nil for
    # none.
    attr_writer :build

    # The branch a comparison defaults to (nil: the one origin/HEAD names).
    attr_accessor :main_branch

    # The glob release tags match (for `--base last-release`).
    attr_accessor :release_tags

    # The metrics #metric added, in order (classes: a Duel::Metric
    # subclass, or running totals' Snapshot), for a plugin's tests to
    # look at (their .measures and .settings).
    attr_reader :metrics

    # What #resource, #worker and #measure were given.
    # @api private
    attr_reader :resources, :workers, :measures

    # A configuration of the conventions, for the project at +root+ (a
    # plugin's tests make one to install it in).
    def initialize(root = Dir.pwd)
      @root = root
      @benchmarks = "duel/**/*_duel.rb"
      @watch = %w[lib ext]
      @library = :conventional
      @build = :conventional
      @release_tags = "v*"
      @resources = []
      @metrics = []
      @workers = []
      @measures = Hash.new do |all, name|
        all[name] = {} #: Hash[Symbol, untyped]
      end
    end

    # The library: the gem the project's only .gemspec names (its name's
    # dashes are directories: my-gem is my/gem), unless set.
    def library
      given = @library
      return given unless given == :conventional

      specs = Dir[File.join(root, "*.gemspec")]
      return unless specs.size == 1

      name = File.basename(specs.first, ".gemspec")
      File.exist?(File.join(root, "lib", "#{name}.rb")) ? name : name.tr("-", "/")
    end

    # The build command: `bundle exec rake compile` for a project with
    # ext/ and a Rakefile, unless set.
    def build
      given = @build
      return given unless given == :conventional

      "bundle exec rake compile" if Dir.exist?(File.join(root, "ext")) && File.exist?(File.join(root, "Rakefile"))
    end

    # How a worker loads one version of the code, from the tree at the
    # root it's given, instead of the convention (see #load_into).
    def load_version(&block) = @loader = block

    # Loads the version at +root+: its lib/ goes first on the load path,
    # and the library is required from it. Under `bundle exec`, Bundler
    # has already loaded the candidate's gemspec, which may have required
    # files of the candidate's (its version, say): for another version
    # they're forgotten, and constants they defined are redefined quietly.
    # @api private
    def load_into(version_root)
      loader = @loader
      return loader.call(version_root) if loader

      $LOAD_PATH.unshift(File.join(version_root, "lib"))
      return unless library
      return require(library) if File.expand_path(version_root) == File.expand_path(root)

      candidate_lib = File.join(File.expand_path(root), "lib", "")
      $LOADED_FEATURES.reject! { |feature| feature.start_with?(candidate_lib) }
      QuietRedefinition.during { require library }
    end

    # Something each worker gets of its own, started by the runner before
    # the worker: the block gets a Duel::Resource (a directory of its own,
    # and help starting a server there), and returns the environment
    # variables the worker gets.
    def resource(&block) = @resources << block

    # Adds a metric to every benchmark: a Duel::Metric subclass, or
    # running totals that the block reads (see Duel::Snapshot), one by
    # name or several by their settings:
    #
    #   c.metric("sql_queries") { queries }
    #   c.metric("redis_cpu" => {kind: :ratio, unit: "µs"}, "redis_commands" => {kind: :counted}) do
    #     {"redis_cpu" => usec, "redis_commands" => calls}
    #   end
    #
    # Returns the metric: running totals' takes what explains a sample
    # (see Snapshot.details), given each stretch's readings, with the
    # context the block read with them (+[totals, context]+).
    #
    #   c.metric("sql_queries") { [queries, statements] }.details { |stretches, sample| ... }
    def metric(metric = nil, **settings, &read)
      made = case metric
      when String then Snapshot.define({metric => settings}, read)
      when Hash, nil then Snapshot.define(metric || settings, read) # (several, without braces, are keywords)
      else metric
      end
      @metrics << made
      made
    end

    # Runs the block in each worker, once its version and the benchmarks
    # have loaded and before its metrics are made: for setting up what
    # only a worker needs (subscribing to notifications, say; .duel.rb
    # itself is loaded by the runner too). It gets the worker's Stops: what
    # it gives at_stop runs when the worker ends (closing a connection it
    # opened, say).
    def worker(&block) = @workers << block

    # What each worker makes for itself, by the block (given the worker's
    # Stops, as #worker blocks are): a connection, say. Returns a PerWorker,
    # whose #value is the worker's; what the block gave at_stop runs when
    # the worker ends.
    #
    #   connection = c.per_worker { |w| Redis.new.tap { |r| w.at_stop { r.close } } }
    #   c.metric("redis_commands") { connection.value.info["total_commands_processed"] }
    def per_worker(&make)
      handle = PerWorker.new
      worker do |stops|
        handle.made(make.call(stops))
        stops.at_stop { handle.forget }
      end
      handle
    end

    # Changes a measure's settings, by its name: any metric's, a plugin's
    # or Duel's own (`c.measure("cpu", limit: 1.05)`); `skip: true` leaves
    # it out.
    def measure(name, **settings)
      Metric.check(name, settings)
      @measures[name].merge!(settings)
    end

    # Whether a measure is skipped (see #measure): for a plugin's worker
    # blocks, to set up nothing for it.
    def skip?(name) = @measures.key?(name) && @measures.fetch(name).fetch(:skip, false)

    # The files that define benchmarks, in order.
    # @api private
    def benchmark_files = Dir[File.join(root, benchmarks)]
  end

  # Silences warnings about redefined constants, while loading a version
  # over files of another's (see Config#load_into).
  # @api private
  module QuietRedefinition
    REDEFINITION = /already initialized constant|previous definition of/

    # Silences them in this thread (what's silenced, while it is: see
    # #warn) during the block.
    def self.during
      Thread.current[:duel_quiet] = REDEFINITION
      yield
    ensure
      Thread.current[:duel_quiet] = nil
    end

    def warn(message, ...)
      return if Thread.current[:duel_quiet]&.match?(message)

      super
    end
  end
  Warning.singleton_class.prepend(QuietRedefinition)
end
