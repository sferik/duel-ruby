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
  # job's summary, in Markdown (see Summary), and tells the step's
  # outputs (GITHUB_OUTPUT) what to do about the comment on a pull
  # request (see .comment), and for a push, whether to mark it passed
  # (see Config#push_base). --markdown writes the Markdown to a file, and
  # --json the report as JSON (see JSONReport), whatever the run's
  # outcome, but not for a command line that isn't valid.
  # @api private
  class CLI
    USAGE = "Usage: duel [options]\n       duel init [options]\n\n" \
      "Fails if this tree is slower than a baseline at any benchmark. `duel init` sets Duel up in a project.\n\n"

    # Where GitHub Actions has a step add to its job's summary.
    STEP_SUMMARY = "GITHUB_STEP_SUMMARY"

    # Where GitHub Actions has a step set its outputs.
    STEP_OUTPUT = "GITHUB_OUTPUT"

    # The statuses (as the JSON report has them) that the workflow
    # comments on, by when it does (Config#comment, but :never, which
    # comments on none).
    COMMENTED = {always: %w[passed failed nothing_to_compare error], results: %w[passed failed error], failures: %w[failed error]}.freeze #: Hash[Config::comment, Array[String]]

    # A run's status (as the JSON report has it) as the comment's marker
    # has it: passed, failed (or couldn't compare), or neutral.
    MARKED = {"passed" => "passed", "failed" => "failed", "error" => "failed", "nothing_to_compare" => "neutral"}.freeze

    # The GitHub Actions events of a pull request, as GITHUB_EVENT_NAME
    # has them: a merge queue's too (see Config#fail_on).
    PULL_REQUESTS = %w[pull_request pull_request_target merge_group].freeze

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
      config = @config = settings.config_path ? Duel.load_config(settings.config_path) : Config.new
      Lock.hold(File.join(config.root, "tmp", "duel")) { compare(config, settings) }
    rescue Error => e
      @err.puts "duel: #{e}"
      unfinished(Summary::FAILED_MARK, "couldn't compare", "error", e.to_s, 2)
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

    # Whether the workflow comments on a pull request, when it comments as
    # +mode+ says (Config#comment) and the run's +status+ is the JSON
    # report's: "post" a new comment, "change", posting one only if it
    # commented on the pull request before and its last comment's status
    # (see MARKED) isn't this run's, or "none". It never edits a comment,
    # so the pull request keeps every one.
    def self.comment(mode, status)
      return "none" if mode == :never

      COMMENTED.fetch(mode).include?(status) ? "post" : "change"
    end

    # The mode --comment names (see Config#comment), or an invalid
    # argument.
    def self.comment_mode(name) = named(name, Config::COMMENTS)

    # The runs --fail-on names (see Config#fail_on), or an invalid
    # argument.
    def self.fail_on(name) = named(name, Config::FAIL_ON)

    # Which of +values+ (symbols) an option's argument names, or an
    # invalid argument.
    def self.named(name, values)
      values.find { |value| value.to_s == name } or
        raise OptionParser::InvalidArgument, "#{name} (give #{values.join(", ")})"
    end

    # The settings, from the environment and then the options.
    def parse
      settings = Settings.defaults
      settings.jobs = [Etc.nprocessors / 2, 1].max
      parser(settings).parse!(env_options + @argv)
      set = variables
      settings.pushed = pushed? && set.key?("DUEL_BASE") && settings.base == set.fetch("DUEL_BASE")
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
      if settings.base_dir.nil? && baseline.ref.nil?
        return nothing("no commit to compare against", "no commit before this push to compare against") if settings.pushed

        return nothing("no release to compare against", "no release tag (#{config.release_tags}) before HEAD to compare against")
      end
      if !settings.force && baseline.unchanged?
        @passed = marks_passed?(config, settings)
        return nothing("nothing to compare",
          "#{baseline.watched.join(", ")} unchanged since the baseline, so there's nothing to compare (--force to anyway)")
      end

      candidate = settings.candidate_dir || config.root
      baseline.build(candidate, "the candidate")
      base_root = baseline.root
      uneven(base_root, candidate)
      runner = Runner.new(config, settings, base_root, out: @out)
      results = runner.run
      passed = runner.passed?(results)
      @passed = passed && marks_passed?(config, settings)
      status = passed ? 0 : slower(config, settings)
      publish(
        passed ? "passed" : "failed",
        -> {
          Summary.new(runner, results, settings: settings, baseline: described_baseline(config, settings, baseline),
            candidate: described_candidate(config, settings)).markdown
        },
        ->(comment) {
          JSONReport.new(runner, results, settings: settings, exit: status, comment: comment,
            baseline: baseline_json(config, settings, baseline, base_root), candidate: candidate_json(config, settings)).to_h
        }
      )
      status
    end

    # The exit status of a run that was slower (or whose benchmark
    # failed): 1, or 0 on GitHub Actions outside a pull request, where
    # c.fail_on (or --fail-on) says only a pull request fails, with a
    # warning that says so.
    def slower(config, settings)
      return 1 unless pull_requests_only?(config, settings)
      return 1 unless outside_pull_request?

      @out.puts "::warning::Duel: slower, but only a pull request fails (c.fail_on), so this #{variables.fetch("GITHUB_EVENT_NAME")} passes"
      0
    end

    # Whether the workflow marks a push that passed (or had nothing to
    # compare) as the last commit Duel passed: where Config#push_base
    # says to compare a push with that commit.
    def marks_passed?(config, settings) = settings.pushed && config.push_base == :last_passed

    # Whether a regression fails only a pull request (--fail-on, or else
    # Config#fail_on).
    def pull_requests_only?(config, settings) = (settings.fail_on || config.fail_on) == :pull_requests

    # Whether this is a run on GitHub Actions for something other than a
    # pull request (PULL_REQUESTS): a push, say.
    def outside_pull_request?
      set = variables
      set.key?("GITHUB_EVENT_NAME") && !PULL_REQUESTS.include?(set.fetch("GITHUB_EVENT_NAME"))
    end

    # Whether this is a run on GitHub Actions for a push.
    def pushed?
      set = variables
      set.key?("GITHUB_EVENT_NAME") && set.fetch("GITHUB_EVENT_NAME") == "push"
    end

    # Says there's nothing to compare (+title+, in Markdown), and +why+,
    # and passes.
    def nothing(title, why)
      @out.puts "duel: #{why}"
      unfinished(Summary::NEUTRAL_MARK, title, "nothing_to_compare", why, 0)
    end

    # Reports a run that didn't compare (+mark+ and +title+ say so in
    # Markdown, and +status+ in JSON), and +why+, and returns +exit+.
    def unfinished(mark, title, status, why, exit)
      # (Parsed, so set: see #run.)
      settings = @settings #: Settings
      publish(status, -> { Summary.note(mark, title, why) }, ->(comment) { JSONReport.note(status, exit, "duel: #{why}", settings, comment) })
      exit
    end

    # What the workflow does about its comment on a pull request, or on
    # a pushed commit (see .comment), for a run whose +status+ is the
    # JSON report's: as --comment says, or else the configuration, or the
    # default where the configuration didn't load. It comments on a push
    # only where a regression in one passes (Config#fail_on), so the
    # comment says what the check doesn't.
    def commenting(status)
      # (Parsed, so set: see #run.)
      settings = @settings #: Settings
      config = @config || Config.new
      return "none" if pushed? && !pull_requests_only?(config, settings)

      CLI.comment(settings.comment || config.comment, status)
    end

    # Writes the reports of a run whose +status+ is the JSON report's
    # where they're asked for: the JSON +json+ makes, given what the
    # workflow does about its comment (see #commenting), to the file
    # --json names, and the Markdown +markdown+ makes to the file
    # --markdown names, and added to the job's summary on GitHub Actions
    # (STEP_SUMMARY). Each is only made if it's written. On GitHub
    # Actions, it also sets the step's outputs (STEP_OUTPUT) for the jobs
    # that comment: +comment+, and +status+ as the comment's marker has
    # it (MARKED), and for the job that marks a push passed, "passed"
    # (see #marks_passed?).
    def publish(status, markdown, json)
      comment = commenting(status)
      set = variables
      outputs = "comment=#{comment}\nstatus=#{MARKED.fetch(status)}\n#{"passed=true\n" if @passed}"
      File.write(set.fetch(STEP_OUTPUT), outputs, mode: "a") if set.key?(STEP_OUTPUT)
      path = @json
      write(path, "#{JSON.pretty_generate(json.call(comment))}\n") if path
      path = @markdown
      summary = (set.fetch(STEP_SUMMARY) if set.key?(STEP_SUMMARY))
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

    # The baseline, in Markdown: its directory, or its commit, bare (so
    # GitHub links it) and followed by a space, never punctuation, and
    # what chose it: the main branch, the push (on GitHub Actions, the
    # commit before it, from DUEL_BASE, or the last commit Duel passed),
    # the last release, or --base.
    def described_baseline(config, settings, baseline)
      dir = settings.base_dir
      return Summary.code(dir) if dir

      # (There's one: #compare checked.)
      ref = baseline.ref #: String
      commit = git(config.root, "rev-parse", "--short", "#{ref}^{commit}").first.chomp
      chosen = case settings.base
      when nil then "where HEAD left #{Summary.code(baseline.main_branch)}"
      when Baseline::LAST_RELEASE then "the last release, #{Summary.code(ref)}"
      else
        if settings.pushed then (ref == baseline.passed) ? "the last commit Duel passed" : "the commit before the push"
        elsif !ref.match?(/\A\h+\z/) then Summary.code(ref)
        else "from --base"
        end
      end
      "#{commit} (#{chosen})"
    end

    # The candidate, in Markdown: its directory, or its commit, bare (see
    # #described_baseline), and whether what's watched (Baseline#watched)
    # has changes not committed.
    def described_candidate(config, settings)
      dir = settings.candidate_dir || config.root
      head, found = git(dir, "rev-parse", "--short", "HEAD")
      return Summary.code(dir) unless found.success?

      _, clean = git(dir, "diff", "--quiet", "HEAD", "--", *Baseline.new(config, settings).watched)
      "#{head.chomp}#{" (with changes not committed)" unless clean.success?}"
    end

    # The baseline, for JSON: the ref that named it (the main branch,
    # where HEAD left it), its commit, and its tree (+root+), or only its
    # tree, a directory.
    def baseline_json(config, settings, baseline, root)
      described = {"ref" => nil, "commit" => nil, "root" => File.expand_path(root)}
      return described if settings.base_dir

      # (There's one: #compare checked.)
      ref = baseline.ref #: String
      named = settings.base ? ref : baseline.main_branch
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
        o.on("--comment MODE", "When the workflow comments on a pull request: always, results (passed or failed),",
          "failures, or never (default: c.comment, or failures)") { |v| settings.comment = CLI.comment_mode(v) }
        o.on("--fail-on RUNS", "Which runs a regression fails: every_run, or pull_requests (on GitHub Actions, another",
          "warns and passes) (default: c.fail_on, or every_run)") { |v| settings.fail_on = CLI.fail_on(v) }
        o.on("--clean", "Remove tmp/duel, and the baseline's git worktree, and stop") { @clean = true }
        o.on("-v", "--version", "Print the version") do
          @out.puts "duel #{VERSION}"
          throw :version
        end
      end
    end
  end
end
