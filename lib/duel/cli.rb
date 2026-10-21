# frozen_string_literal: true

require "etc"
require "optparse"
require_relative "runner"
require_relative "baseline"

module Duel
  # The `duel` command. What a run behind a rake task or a CI expression
  # can't pass as an option can be set in the environment (DUEL_BASE,
  # DUEL_FILTER, DUEL_FORCE); options win.
  # @api private
  class CLI
    USAGE = "Usage: duel [options]\n\n" \
      "Fails if this tree is slower than a baseline at any benchmark.\n\n"

    # The variables that set options, to their values, and the one that
    # sets a flag by being set at all.
    ENV_OPTIONS = {"DUEL_BASE" => "--base", "DUEL_FILTER" => "--filter"}.freeze
    ENV_FLAGS = {"DUEL_FORCE" => "--force"}.freeze

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv
      @env = env
      @out = out
      @err = err
    end

    # Runs; returns the exit status: 0 not slower (or nothing to compare),
    # 1 slower (or a benchmark failed), 2 couldn't compare.
    def run
      settings = catch(:version) { parse } or return 0
      config = settings.config_path ? Duel.load_config(settings.config_path) : Config.new
      baseline = Baseline.new(config, settings)
      if @clean
        baseline.clean
        @out.puts "duel: removed tmp/duel and its baseline's worktree"
        return 0
      end
      if settings.base_dir.nil? && baseline.ref.nil?
        @out.puts "duel: no release tag (#{config.release_tags}) before HEAD to compare against"
        return 0
      end
      if !settings.force && baseline.unchanged?
        @out.puts "duel: #{config.watch.join(", ")} unchanged since the baseline; nothing to compare (--force to anyway)"
        return 0
      end
      baseline.build(settings.candidate_dir || config.root, "the candidate")
      runner = Runner.new(config, settings, baseline.root, out: @out)
      runner.passed?(runner.run) ? 0 : 1
    rescue Error, OptionParser::ParseError => e
      @err.puts "duel: #{e}"
      2
    end

    # The settings, from the environment and then the options.
    def parse
      settings = Settings.defaults
      settings.jobs = [Etc.nprocessors / 2, 1].max
      parser(settings).parse!(env_options + @argv)
      settings.config_path ||= (".duel.rb" if File.exist?(".duel.rb"))
      settings.config_path &&= File.expand_path(settings.config_path)
      settings
    end

    private

    # The DUEL_* variables set, as options (empty is as good as unset,
    # which CI expressions find handy).
    def env_options
      set = @env.reject { |_, value| value.empty? }
      ENV_OPTIONS.flat_map { |name, option| set.key?(name) ? [option, set.fetch(name)] : [] } +
        ENV_FLAGS.filter_map { |name, flag| flag if set.key?(name) }
    end

    def parser(settings)
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--base REF|DIR", "Baseline: a commit (default: where HEAD left the main branch; last-release: the newest",
          "release tag), or a directory, already built") do |v|
          # (A directory is one, whatever else it could name; the last given wins.)
          directory = File.directory?(v)
          settings.base = (v unless directory)
          settings.base_dir = (v if directory)
        end
        o.on("--candidate-dir DIR", "Candidate tree (default: this one)") { |v| settings.candidate_dir = v }
        o.on("--filter REGEXP", "Only benchmarks whose names match") { |v| settings.filter = Regexp.new(v) }
        o.on("--jobs N", Integer, "Benchmarks measured at once (default: half the CPUs)") { |v| settings.jobs = v }
        o.on("--processes N", Integer, "Worker processes per version (default: 3)") { |v| settings.processes = v }
        o.on("--timeout SECONDS", Float, "Most a worker may take to load or answer (default: 60)") { |v| settings.timeout = v }
        o.on("--limit RATIO", Float, "Ratio above which a timing is slower (default: 1.02)") { |v| settings.limit = v }
        o.on("--warm SECONDS", Float, "Warm-up per benchmark (default: 5 on JRuby and TruffleRuby, else 0)") { |v| settings.warm = v }
        o.on("--force", "Compare even if nothing watched changed") { settings.force = true }
        o.on("--config PATH", "Config file (default: .duel.rb)") { |v| settings.config_path = v }
        o.on("--clean", "Remove tmp/duel, and the baseline's git worktree, and stop") { @clean = true }
        o.on("-v", "--version", "Print the version") do
          @out.puts "duel #{VERSION}"
          throw :version
        end
      end
    end
  end
end
