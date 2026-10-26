# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "optparse"
require_relative "runner"
require_relative "baseline"
require_relative "lock"
require_relative "summary"
require_relative "json_report"
require_relative "init"

module Duel
  # The `duel` command (and `duel init`: see Init). What a run behind a
  # rake task or a CI expression can't pass as an option can be set in
  # the environment (DUEL_BASE, DUEL_FILTER, DUEL_FORCE), and options win.
  # On GitHub Actions (GITHUB_STEP_SUMMARY), it adds its report to the
  # job's summary, in Markdown (see Summary). --markdown writes that to a
  # file, and --json the report as JSON (see JSONReport), whatever the
  # run's outcome, but not for a command line that isn't valid.
  # @api private
  class CLI
    USAGE = "Usage: duel [options]\n       duel init [options]\n\n" \
      "Fails if this tree is slower than a baseline at any benchmark. `duel init` sets Duel up in a project.\n\n"

    # Where GitHub Actions has a step add to its job's summary.
    STEP_SUMMARY = "GITHUB_STEP_SUMMARY"

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

    # Runs, and returns the exit status: 0 not slower (or nothing to compare),
    # 1 slower (or a benchmark failed), 2 couldn't compare.
    def run
      return Init.new(@argv.drop(1), out: @out, err: @err).run if @argv.first == "init"

      settings = @settings = catch(:version) { parse } or return 0
      config = settings.config_path ? Duel.load_config(settings.config_path) : Config.new
      Lock.hold(File.join(config.root, "tmp", "duel")) { compare(config, settings) }
    rescue Error => e
      @err.puts "duel: #{e}"
      unfinished("couldn't compare", "error", "duel: #{e}", 2)
    rescue OptionParser::ParseError => e
      @err.puts "duel: #{e}"
      2
    end

    # +source+ as a Regexp: one that isn't is an option's invalid
    # argument (a usage error, as any is).
    def self.regexp(source)
      Regexp.new(source)
    rescue RegexpError => e
      raise OptionParser::InvalidArgument, "#{source} (#{e})"
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

    # What #run does, holding the project's lock (see Lock).
    def compare(config, settings)
      baseline = Baseline.new(config, settings)
      if @clean
        baseline.clean
        @out.puts "duel: removed tmp/duel and its baseline's worktree"
        return 0
      end
      return nothing("no release tag (#{config.release_tags}) before HEAD to compare against") if settings.base_dir.nil? && baseline.ref.nil?
      if !settings.force && baseline.unchanged?
        return nothing("#{baseline.watched.join(", ")} unchanged since the baseline, so there's nothing to compare (--force to anyway)")
      end

      candidate = settings.candidate_dir || config.root
      baseline.build(candidate, "the candidate")
      base_root = baseline.root
      uneven(base_root, candidate)
      runner = Runner.new(config, settings, base_root, out: @out)
      results = runner.run
      status = runner.passed?(results) ? 0 : 1
      publish(
        -> {
          Summary.new(runner, results, settings: settings, baseline: described_baseline(config, settings, baseline),
            candidate: described_candidate(config, settings)).markdown
        },
        -> {
          JSONReport.new(runner, results, settings: settings, exit: status, baseline: baseline_json(config, settings, baseline, base_root),
            candidate: candidate_json(config, settings)).to_h
        }
      )
      status
    end

    # Says there's nothing to compare, and why, and passes.
    def nothing(why)
      @out.puts "duel: #{why}"
      unfinished("nothing to compare", "nothing_to_compare", "duel: #{why}", 0)
    end

    # Reports a run that didn't compare (+title+ says why in Markdown,
    # and +status+ in JSON) with +message+, and returns +exit+.
    def unfinished(title, status, message, exit)
      # (Parsed, so set, where there's JSON to write: see #publish.)
      settings = @settings #: Settings
      publish(-> { Summary.note(title, message) }, -> { JSONReport.note(status, exit, message, settings) })
      exit
    end

    # Writes the reports where they're asked for: the JSON +json+ makes
    # to the file --json names, and the Markdown +markdown+ makes to the
    # file --markdown names, and added to the job's summary on GitHub
    # Actions (STEP_SUMMARY). Each is only made if it's written.
    def publish(markdown, json)
      path = @json
      write(path, "#{JSON.pretty_generate(json.call)}\n") if path
      path = @markdown
      summary = (variables.fetch(STEP_SUMMARY) if variables.key?(STEP_SUMMARY))
      return unless path || summary

      text = markdown.call
      write(path, text) if path
      File.write(summary, text, mode: "a") if summary
    end

    # Writes +text+ to +path+, in a directory made for it.
    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    # The baseline, in Markdown: its directory, or its commit, and what
    # named it.
    def described_baseline(config, settings, baseline)
      dir = settings.base_dir
      return Summary.code(dir) if dir

      # (There's one: #compare checked.)
      ref = baseline.ref #: String
      commit = Summary.code(git(config.root, "rev-parse", "--short", "#{ref}^{commit}").first.chomp)
      case settings.base
      when nil then "#{commit}, where HEAD left #{Summary.code(baseline.main_branch)}"
      when Baseline::LAST_RELEASE then "#{Summary.code(ref)} (#{commit}), the last release"
      else ref.match?(/\A\h+\z/) ? commit : "#{Summary.code(ref)} (#{commit})"
      end
    end

    # The candidate, in Markdown: its directory, or its commit, and
    # whether what's watched (Baseline#watched) has changes not committed.
    def described_candidate(config, settings)
      dir = settings.candidate_dir || config.root
      head, found = git(dir, "rev-parse", "--short", "HEAD")
      return Summary.code(dir) unless found.success?

      _, clean = git(dir, "diff", "--quiet", "HEAD", "--", *Baseline.new(config, settings).watched)
      "#{Summary.code(head.chomp)}#{", with changes not committed" unless clean.success?}"
    end

    # The baseline, for JSON: the ref that named it (the main branch,
    # where HEAD left it), its commit, and its tree (+root+), or only its
    # tree, a directory.
    def baseline_json(config, settings, baseline, root)
      described = {"ref" => nil, "commit" => nil, "root" => File.expand_path(root)}
      return described if settings.base_dir

      # (There's one: #compare checked.)
      ref = baseline.ref #: String
      named = case settings.base
      when nil then baseline.main_branch
      when Baseline::LAST_RELEASE then ref
      else settings.base
      end
      described.merge("ref" => named, "commit" => git(config.root, "rev-parse", "#{ref}^{commit}").first.chomp)
    end

    # The candidate, for JSON: its commit, and whether what's watched
    # (Baseline#watched) has changes not committed (each nil outside a
    # repository), and its tree.
    def candidate_json(config, settings)
      dir = File.expand_path(settings.candidate_dir || config.root)
      head, found = git(dir, "rev-parse", "HEAD")
      return {"commit" => nil, "uncommitted_changes" => nil, "root" => dir} unless found.success?

      _, clean = git(dir, "diff", "--quiet", "HEAD", "--", *Baseline.new(config, settings).watched)
      {"commit" => head.chomp, "uncommitted_changes" => !clean.success?, "root" => dir}
    end

    # Git's output, and its status, in +dir+.
    def git(dir, *args)
      out, _, status = Open3.capture3("git", "-C", dir, *args)
      [out, status]
    end

    # Says so if the two versions' paths differ in length (resolved): what
    # a version does with its own paths takes longer on a longer path, so
    # one may measure a little slower than the other.
    def uneven(base_root, candidate)
      longer = File.realpath(base_root).length - File.realpath(candidate).length
      return if longer.zero?

      @out.puts "duel: the baseline's path is #{Runner.count(longer.abs, "character")} #{longer.positive? ? "longer" : "shorter"} than the " \
        "candidate's, so it may measure a little #{longer.positive? ? "slower" : "faster"}"
    end

    # The DUEL_* variables set, as options (empty is as good as unset,
    # which CI expressions find handy).
    def env_options
      set = variables
      ENV_OPTIONS.flat_map { |name, option| set.key?(name) ? [option, set.fetch(name)] : [] } +
        ENV_FLAGS.filter_map { |name, flag| flag if set.key?(name) }
    end

    # The environment's variables that are set (not empty).
    def variables = @env.reject { |_, value| value.empty? }

    def parser(settings)
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--base REF|DIR", "Baseline: a commit (default: where HEAD left the main branch), last-release (the newest",
          "release tag), or a directory, already built") do |v|
          # (A directory is one, whatever else it could name, and the last given wins.)
          directory = File.directory?(v)
          settings.base = (v unless directory)
          settings.base_dir = (v if directory)
        end
        o.on("--candidate-dir DIR", "Candidate tree (default: this one)") { |v| settings.candidate_dir = v }
        o.on("--filter REGEXP", "Only benchmarks whose names match") { |v| settings.filter = CLI.regexp(v) }
        o.on("--jobs N", Integer, "Benchmarks measured at once (default: half the CPUs)") { |v| settings.jobs = v }
        o.on("--processes N", Integer, "Worker processes per version (default: 3)") { |v| settings.processes = v }
        o.on("--timeout SECONDS", Float, "Most a worker may take to load or answer (default: 60)") { |v| settings.timeout = v }
        o.on("--limit RATIO", Float, "Ratio above which a timing is slower (default: 1.02)") { |v| settings.limit = v }
        o.on("--warm SECONDS", Float, "Warm-up per benchmark (default: 5 on JRuby and TruffleRuby, 2 with YJIT on, else 0)") { |v| settings.warm = v }
        o.on("--ruby version-file|PATH", "Each version's Ruby: the one its version file names (.ruby-version, say), or a",
          "path (default: c.ruby, or this one)") { |v| settings.ruby = (v == "version-file") ? :version_file : v }
        o.on("--force", "Compare even if nothing watched changed") { settings.force = true }
        o.on("--config PATH", "Config file (default: .duel.rb)") { |v| settings.config_path = v }
        o.on("--markdown PATH", "Also write the report to PATH in Markdown, for a pull request comment (on GitHub",
          "Actions, it's added to the job's summary too)") { |v| @markdown = v }
        o.on("--json PATH", "Also write the report to PATH as JSON, for a program to read") { |v| @json = v }
        o.on("--clean", "Remove tmp/duel, and the baseline's git worktree, and stop") { @clean = true }
        o.on("-v", "--version", "Print the version") do
          @out.puts "duel #{VERSION}"
          throw :version
        end
      end
    end
  end
end
