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
  #   points to (origin/main, say), when lib/ or ext/ changed, or what
  #   decides how they're measured (see #watch)
  # - releases are tagged v*
  #
  # .duel.rb, at the root, changes what doesn't fit:
  #
  #   Duel.configure do |c|
  #     c.benchmarks = "perf/**/*_duel.rb"
  #     c.build = "make"
  #     c.use :redis                        # a plugin: see #use
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

    # Paths, from the root, of the code whose changes a comparison is
    # about: when none of them changed since the baseline, nor what
    # decides how it's measured (the benchmarks' directory, the
    # configuration's file, and with each version on its own Ruby, the
    # version files at the root), there's nothing to compare.
    attr_accessor :watch

    # The library to require from each version, as `require` takes it,
    # or nil for none (benchmarks require what they need).
    attr_writer :library

    # A shell command that builds a checked-out tree, run in it, or nil
    # for none.
    attr_writer :build

    # The branch a comparison defaults to (nil: the one origin/HEAD names).
    attr_accessor :main_branch

    # The glob release tags match (for `--base last-release`).
    attr_accessor :release_tags

    # The Ruby each version runs on (`duel --ruby` overrides it). It's nil
    # for the runner's own, or :version_file for the one the version's own
    # version file names (.ruby-version, .tool-versions or mise.toml, in
    # its tree or above), installed with rbenv, chruby, mise or asdf (see
    # Rubies). It can also be a path to a Ruby for both, or a block given
    # the version's tree, returning the path to its Ruby.
    #
    #   c.ruby = :version_file
    #   c.ruby = ->(root) { File.join(Dir.home, ".rubies", File.read(File.join(root, ".ruby-version")).strip, "bin", "ruby") }
    attr_accessor :ruby

    # When the workflow that `duel init` writes comments on a pull request
    # with the report (`duel --comment` overrides it):
    #
    # - :always, on every run
    # - :results, when a run passed or failed, but not with nothing
    #   compared
    # - :failures (the default), only when a run failed or couldn't
    #   compare
    # - :never
    #
    # It never edits a comment: each is a new one, so the pull request
    # keeps them all. Once it has commented, a run that it wouldn't
    # comment on still does, but :never's, when its status differs from
    # the last comment's, so the last comment is never stale: after a
    # failure, the first run that passes says so. Duel tells the workflow
    # which to do (see CLI.comment).
    #
    #   c.comment = :results
    attr_reader :comment

    # The values #comment takes.
    COMMENTS = %i[always results failures never].freeze #: Array[comment]

    def comment=(mode)
      raise Error, "c.comment = #{mode.inspect}: give #{COMMENTS.map(&:inspect).join(", ")}" unless COMMENTS.include?(mode)

      @comment = mode
    end

    # The metrics #metric added, in order (classes: a Duel::Metric
    # subclass, or running totals' Snapshot), for a plugin's tests to
    # look at (their .measures and .settings).
    attr_reader :metrics

    # What #prepare (by scope), #in_worker, the hooks (#setup, say: by
    # name) and #measure were given.
    # @api private
    attr_reader :prepares, :in_workers, :hooks, :measures

    # A configuration of the conventions, for the project at +root+ (a
    # plugin's tests make one to use it in).
    def initialize(root = Dir.pwd)
      @root = root
      @benchmarks = "duel/**/*_duel.rb"
      @watch = %w[lib ext]
      @library = :conventional
      @build = :conventional
      @release_tags = "v*"
      @comment = :failures
      @prepares = SCOPES.to_h { |scope| [scope, []] }
      @metrics = []
      @in_workers = []
      @hooks = HOOKS.to_h { |hook| [hook, []] }
      @used = {}
      @measures = Hash.new do |all, name|
        all[name] = {} #: Hash[Symbol, untyped]
      end
    end

    # What #prepare prepares: each version, or each worker.
    # @api private
    SCOPES = %i[version worker].freeze

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
    #
    #   c.load { |root| require File.join(root, "config", "boot") }
    #
    # (It hides Kernel#load from the configuration's own methods, which
    # never call it: a file is loaded by Duel.load_config.)
    def load(&block) = @loader = block

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

    # Uses a plugin, by its name: requires it (duel/+name+, the plugin's
    # gem's file: duel-redis's duel/redis, say), gives files of
    # benchmarks its DSL methods, if it has any, and configures Duel for
    # it, with +options+ (see Duel.plugin). Returns what that returned
    # (the plugin's own connection to its server, say).
    #
    #   c.use :redis
    #   c.use :rails, database: :postgresql
    #
    # A plugin is configured once, the first time it's used: using it
    # again (as a plugin that needs another uses it) returns what that
    # did. Options given again must be the first's, and others fail, as
    # they would be ignored.
    def use(name, **options)
      used = @used[name]
      return used.again(name, options) if used

      begin
        require "duel/#{name}"
      rescue LoadError => e
        raise unless e.path == "duel/#{name}"

        raise Error, "c.use #{name.inspect}: no duel/#{name} to require: add the duel-#{name} gem to the Gemfile"
      end
      plugin = Duel.plugins.fetch(name) { raise Error, "c.use #{name.inspect}: duel/#{name} registers no plugin #{name.inspect} (Duel.plugin)" }
      DSL.add(plugin::DSL) if plugin.const_defined?(:DSL, false)
      used = @used[name] = Used.new(options)
      used.value = plugin.configure(self, **options)
    end

    # The plugins used (see #use), by name, in the order they were first
    # used.
    def plugins = @used.keys

    # A plugin as #use configured it: with +options+, returning +value+.
    # @api private
    class Used
      attr_reader :options

      attr_accessor :value

      def initialize(options)
        @options = options
      end

      # What using it again returns: #value, unless +given+ (options)
      # has any but the first's, which fails.
      def again(name, given)
        ignored = given.reject { |option, value| @options.key?(option) && @options.fetch(option) == value }
        return @value if ignored.empty?

        raise Error, "c.use #{name.inspect}: used already, without #{ignored.map { |option, value| "#{option}: #{value.inspect}" }.join(", ")}: " \
          "give a plugin's options the first time it's used"
      end
    end

    # Prepares each version, or each worker (+scope+: :version or
    # :worker), by the block, given a Duel::Resource for it: a directory
    # of its own, and help running commands and starting servers there,
    # stopped when it's done with. The block returns the environment
    # variables it gets: a worker's, under its version's.
    #
    # A version's (named "baseline" or "candidate", its #root the
    # version's tree and its #ruby the Ruby it runs on) is prepared once
    # for a run, in the runner, before any of its workers start:
    # installing its bundle, say. Its environment is its workers' (and
    # its process benchmarks').
    #
    #   c.prepare(:version) do |v|
    #     v.cached("bundle-#{Digest::SHA256.file(File.join(v.root, "Gemfile.lock"))}") { |_| v.run("bundle", "install", chdir: v.root) }
    #     {"BUNDLE_GEMFILE" => File.join(v.root, "Gemfile")}
    #   end
    #
    # A worker's (named "baseline-1", say) is prepared by the runner as
    # the worker starts: a server of its own, say.
    #
    #   c.prepare(:worker) do |w|
    #     socket = w.path("redis.sock")
    #     w.spawn("redis-server", "--port", "0", "--unixsocket", socket)
    #     w.wait_until { File.socket?(socket) }
    #     {"REDIS_URL" => "unix://#{socket}"}
    #   end
    def prepare(scope, &block)
      blocks = @prepares.fetch(scope) { raise ArgumentError, "prepare(:version) or prepare(:worker), not prepare(#{scope.inspect})" }
      raise ArgumentError, "prepare(#{scope.inspect}): give a block" unless block

      blocks << block
    end

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
    # have loaded and before its metrics are made: for what only a worker
    # does (loading its data, say: .duel.rb itself is loaded by the runner
    # too). It gets the worker's Stops: what it gives at_stop runs when
    # the worker ends. Returns an InWorker, whose #value is what the block
    # returned, in that worker: a connection, say.
    #
    #   redis = c.in_worker { |w| Redis.new.tap { |r| w.at_stop { r.close } } }
    #   c.metric("redis_commands") { redis.value.info["total_commands_processed"] }
    def in_worker(&block)
      made = InWorker.new
      @in_workers << lambda do |worker|
        made.made(block.call(worker))
        worker.at_stop { made.forget }
      end
      made
    end

    # The hooks (see Duel::HOOKS), for every benchmark, run in each worker
    # before its file's and its own: setup once before a benchmark's
    # samples, and teardown after them (last first), and before_sample
    # before every sample (the warm-up's too), not measured, each given
    # the benchmark (see Sample#benchmark) if it takes it.
    # around_iteration runs around each iteration, given it to run, and
    # after_iterations after each sample's iterations (inside each
    # iteration, with around_iteration), measured with them: to do the
    # work they left to be done later (jobs they queued, say), which is
    # theirs. Unlike a file's, they run where they were written (not in
    # the benchmark's context: they're a plugin's, say).
    def setup(&block) = add_hook(:setup, block)

    def teardown(&block) = add_hook(:teardown, block)

    def before_sample(&block) = add_hook(:before_sample, block)

    def around_iteration(&block) = add_hook(:around_iteration, block)

    def after_iterations(&block) = add_hook(:after_iterations, block)

    # Changes a measure's settings, by its name: any metric's, a plugin's
    # or Duel's own (`c.measure("cpu", limit: 1.05)`). `skip: true` leaves
    # it out.
    def measure(name, **settings)
      Metric.check(name, settings)
      @measures[name].merge!(settings)
    end

    # Whether a measure is skipped (see #measure): for a plugin's metric,
    # to set up nothing for it.
    def skip?(name) = @measures.key?(name) && @measures.fetch(name).fetch(:skip, false)

    # The files that define benchmarks, in order.
    # @api private
    def benchmark_files = Dir[File.join(root, benchmarks)]

    private

    def add_hook(name, block) = @hooks.fetch(name) << Duel.hook(name, block)
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
