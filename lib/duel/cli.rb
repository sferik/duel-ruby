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
require_relative "comment"
require_relative "mark_passed"
require_relative "badge"
require_relative "spawn"

module Duel
  # The `duel` command (and `duel init`, `duel comment`,
  # `duel mark-passed` and `duel badge`: see Init, Comment, MarkPassed
  # and Badge). What a run behind a rake task or a CI expression can't pass
  # as an option can be set in the environment (DUEL_BASE, DUEL_FILTER,
  # DUEL_FORCE...: see ENV_OPTIONS), and options win. On CI, the baseline
  # is what the run's event says (see #event_base), unless one of them
  # names one.
  # On GitHub Actions (GITHUB_STEP_SUMMARY), it adds its report to the
  # job's summary, in Markdown (see Summary), and tells the step's
  # outputs (GITHUB_OUTPUT) what to do about the comment on a pull
  # request (see .comment), and for a push, the branch that marks it
  # passed, where it's to be (see Config#push_base). --markdown writes the Markdown to a file, and
  # --json the report as JSON (see JSONReport), whatever the run's
  # outcome, but not for a command line that isn't valid.
  # @api private
  class CLI
    USAGE = "Usage: duel [options]\n       duel base [options]\n       duel init [options]\n       duel clean [--config PATH]\n" \
      "       duel comment [options]\n       duel mark-passed BRANCH\n       duel badge BRANCH [options]\n\n" \
      "Fails if this tree is slower than a baseline at any benchmark. `duel base` prints the commit it would compare\n" \
      "with, `duel init` sets Duel up in a project, `duel clean` removes tmp/duel and the baseline's git worktree,\n" \
      "and `duel comment`, `duel mark-passed` and `duel badge` are what the workflows it writes run.\n\n"

    # Where GitHub Actions has a step add to its job's summary.
    STEP_SUMMARY = "GITHUB_STEP_SUMMARY"

    # Where GitHub Actions has a step set its outputs.
    STEP_OUTPUT = "GITHUB_OUTPUT"

    # Where else to write them, as variables (DUEL_COMMENT, DUEL_STATUS,
    # DUEL_PASSED): on GitLab CI, a dotenv report, for the jobs after.
    OUTPUT = "DUEL_OUTPUT"

    # The statuses (as the JSON report has them) that the workflow
    # comments on, by when it does (Config#comment, but :never, which
    # comments on none).
    COMMENTED = {always: %w[passed failed nothing_to_compare error], results: %w[passed failed error], failures: %w[failed error]}.freeze #: Hash[Config::comment, Array[String]]

    # A run's status (as the JSON report has it) as the comment's marker
    # has it: passed, failed (or couldn't compare), or neutral.
    MARKED = {"passed" => "passed", "failed" => "failed", "error" => "failed", "nothing_to_compare" => "neutral"}.freeze

    # The GitHub Actions events of a pull request, as GITHUB_EVENT_NAME
    # has them: a merge queue's too (see Config#fail_on). (A GitLab merge
    # request's is pull_request: see #event.)
    PULL_REQUESTS = %w[pull_request pull_request_target merge_group].freeze

    # The exit status of a run that was slower outside a merge request on
    # GitLab CI, where only a merge request fails (Config#fail_on): the
    # job that `duel init --gitlab` writes lets it fail, as a warning.
    WARNED = 3

    # The variables that set options, to their values: DUEL_ and the
    # option's name (DUEL_LIMIT=1.05 is --limit 1.05, DUEL_TIME_LIMIT
    # --time-limit), for --base, --candidate, --filter, --ruby, and each
    # option .duel.rb can set too (Config::RUN_SETTINGS). An option given
    # beats its variable, which beats .duel.rb.
    ENV_OPTIONS = [:base, :candidate, :filter, :ruby, *Config::RUN_SETTINGS.keys].to_h { |name| ["DUEL_#{name.upcase}", "--#{name.to_s.tr("_", "-")}"] }.freeze

    # What DUEL_FORCE's values say: to compare whatever changed
    # (--force), or not.
    FORCE = {"1" => true, "true" => true, "0" => false, "false" => false}.freeze

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv
      @env = env
      @out = out
      @err = err
    end

    # Runs, and returns the exit status: 0 not slower (or nothing to compare),
    # 1 slower (or a benchmark failed), 2 couldn't compare, 3 slower but
    # warned (see WARNED).
    def run
      return Init.new(@argv.drop(1), out: @out, err: @err).run if @argv.first == "init"
      return Comment.new(@argv.drop(1), env: @env, out: @out, err: @err).run if @argv.first == "comment"
      return MarkPassed.new(@argv.drop(1), env: @env, out: @out, err: @err).run if @argv.first == "mark-passed"
      return Badge.new(@argv.drop(1), env: @env, out: @out, err: @err).run if @argv.first == "badge"
      return clean(@argv.drop(1)) if @argv.first == "clean"
      return show_base(@argv.drop(1)) if @argv.first == "base"

      settings = @settings = catch(:version) { parse } or return 0
      config = @config = settings.config_path ? Duel.load_config(settings.config_path) : Config.new
      # (.duel.rb's, but where an option says: c.limit, unless --limit.)
      config.run_settings.each { |name, value| set(settings, name, value) unless @given.include?(name) }
      Lock.hold(config.state) { compare(config, settings) }
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

    # The settings, from the environment and then the options.
    def parse
      @given = [] # (the RUN_SETTINGS options given: see Config)
      settings = Settings.defaults
      settings.jobs = [Etc.nprocessors / CPUS_PER_LANE, 1].max
      settings.fit = %i[jobs processes]
      rest = parser(settings).parse(env_options + @argv)
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?

      # (A base given that's the event's is the event's too: the workflows
      # duel init wrote before give DUEL_BASE as the event says.)
      settings.base = event_base unless settings.base || settings.base_dir
      settings.pushed = variable("GITHUB_REF_NAME", "CI_COMMIT_BRANCH") if pushed? && from_event?(settings)
      target = variable("GITHUB_BASE_REF", "CI_MERGE_REQUEST_TARGET_BRANCH_NAME")
      settings.target = "origin/#{target}" if target && pull_request?
      settings.accepted = variable("DUEL_ACCEPTED")
      # (Where Duel finds what a label accepted since the last release, on
      # a schedule: see Baseline#merged_accepted.)
      settings.repository = variable("GITHUB_REPOSITORY") if event == "schedule" && !gitlab?
      settings.config_path ||= (".duel.rb" if File.exist?(".duel.rb"))
      settings.config_path &&= File.expand_path(settings.config_path)
      settings
    end

    private

    # `duel base`: prints the commit a run given +argv+ (a run's options:
    # --base, say) compares with, or nothing, where it has none (no release
    # yet, say, or a directory): for what needs it before the run, as the
    # workflow's step that installs the baseline's Ruby does.
    def show_base(argv)
      @argv = argv
      settings = @settings = catch(:version) { parse } or return 0
      config = settings.config_path ? Duel.load_config(settings.config_path) : Config.new
      ref = Baseline.new(config, settings).ref unless settings.base_dir
      commit, found = git(config.root, "rev-parse", "#{ref}^{commit}") if ref
      raise Error, "#{ref} isn't a commit here" if found && !found.success?

      @out.puts commit
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "duel base: #{e}"
      2
    end

    # `duel clean`: removes what Duel keeps (tmp/duel), and the baseline's
    # git worktree (see Baseline#clean), holding the project's lock, for
    # the configuration at --config, or .duel.rb.
    def clean(argv)
      path = nil
      parser = OptionParser.new("Usage: duel clean [--config PATH]") do |o|
        o.on("--config PATH", "Config file (default: .duel.rb)") { |v| path = v }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          return 0
        end
      end
      rest = parser.parse(argv)
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?

      path ||= (".duel.rb" if File.exist?(".duel.rb"))
      config = path ? Duel.load_config(path) : Config.new
      Lock.hold(config.state) { Baseline.new(config, Settings.defaults).clean }
      @out.puts "duel: removed tmp/duel and its baseline's worktree"
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "duel clean: #{e}"
      2
    end

    # What #run does, holding the project's lock (see Lock).
    def compare(config, settings)
      baseline = Baseline.new(config, settings)
      if settings.base_dir.nil? && baseline.ref.nil?
        return nothing("no commit to compare against", "no commit before this push to compare against") if settings.pushed

        return nothing("no release to compare against", "no release tag (#{Config.globs(config.release_tags).join(", ")}) before HEAD to compare against")
      end
      if !settings.force && baseline.unchanged?
        @passed = (baseline.passed_branch if marks_passed?(config, settings))
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
      status = passed ? 0 : slower(config)
      @passed = (baseline.passed_branch if (passed || accepted?(config)) && marks_passed?(config, settings))
      publish(
        passed ? "passed" : "failed",
        -> {
          Summary.new(runner, results, settings: settings, baseline: described_baseline(config, settings, baseline),
            candidate: described_candidate(config, settings, baseline), note: @note, accepted: @accepted).markdown
        },
        -> {
          JSONReport.new(runner, results, settings: settings, passed: passed, exit: status, passed_anyway: @passed_anyway,
            baseline: baseline_json(config, settings, baseline, base_root), candidate: candidate_json(config, settings, baseline)).to_h
        }
      )
      status
    end

    # The exit status of a run that was slower (or whose benchmark
    # failed): 1, or 0 where the pull request's label accepts it
    # (Config#accept_label), or on GitHub Actions outside a pull request,
    # where c.fail_on says only a pull request fails, with
    # a warning that says so, and a note in the report.
    def slower(config)
      if accepted?(config)
        # (Set: see #accepted?.)
        label = config.accept_label #: String
        @accepted = true
        @passed_anyway = "accept_label"
        return passing("accepted with the #{label} label", "Accepted with the #{Summary.code(label)} label.")
      end
      return 1 unless pull_requests_only?(config) && outside_pull_request?

      # (Outside a pull request on CI, so there's one: see #event.)
      run = event #: String
      @passed_anyway = "fail_on"
      passing("only a pull request fails (c.fail_on), so this #{run} passes",
        "Only a pull request fails (#{Summary.code("c.fail_on")}), so this #{run} passes.", gitlab? ? WARNED : 0)
    end

    # Passes a run that was slower (or on GitLab CI, warns: +exit+), as
    # +why+ says, in a warning (on GitHub Actions, an annotation), and as
    # +note+ says in the report.
    def passing(why, note, exit = 0)
      @out.puts "#{gitlab? ? "duel: " : "::warning::Duel: "}slower, but #{why}"
      @note = note
      exit
    end

    # Whether the pull request's labels have the one that accepts a
    # regression (Config#accept_label).
    def accepted?(config)
      label = config.accept_label
      !label.nil? && labels.include?(label)
    end

    # The pull request's labels: DUEL_LABELS (a JSON array of their names)
    # on GitHub Actions, or a GitLab merge request's
    # (CI_MERGE_REQUEST_LABELS, by commas), or none, where neither is
    # set, or DUEL_LABELS isn't a JSON array.
    def labels
      json = variable("DUEL_LABELS")
      return variable("CI_MERGE_REQUEST_LABELS").to_s.split(",") unless json

      names = JSON.parse(json)
      names.instance_of?(Array) ? names : []
    rescue JSON::ParserError
      []
    end

    # Whether the workflow marks a push that passed (or had nothing to
    # compare) as the last commit Duel passed: where Config#push_base
    # says to compare a push with that commit.
    def marks_passed?(config, settings) = !settings.pushed.nil? && config.push_base == :last_passed

    # Whether a regression fails only a pull request (Config#fail_on).
    def pull_requests_only?(config) = config.fail_on == :pull_requests

    # What a run on CI is for, as GitHub Actions names it
    # (GITHUB_EVENT_NAME): push, pull_request, schedule, say. On GitLab
    # CI, its pipeline's source (CI_PIPELINE_SOURCE), as GitHub would
    # name it: a merge request's is pull_request. Outside CI, nil.
    def event
      github = variable("GITHUB_EVENT_NAME")
      return github if github
      return unless gitlab?

      source = variable("CI_PIPELINE_SOURCE")
      (source == "merge_request_event") ? "pull_request" : source
    end

    # Whether this is a run on GitLab CI.
    def gitlab? = !variable("GITLAB_CI").nil?

    # Whether this is a run on CI for something other than a pull request
    # (PULL_REQUESTS): a push, say.
    def outside_pull_request?
      run = event
      !run.nil? && !PULL_REQUESTS.include?(run)
    end

    # Whether this is a run on CI for a pull request (or a merge queue:
    # see PULL_REQUESTS).
    def pull_request? = PULL_REQUESTS.include?(event)

    # Whether +settings+' baseline is the one the run's event says (see
    # #event_base): the event's, or a base given that's the event's (as
    # the workflows duel init wrote before give DUEL_BASE).
    def from_event?(settings)
      found = event_base
      !found.nil? && settings.base == found
    end

    # The baseline a run on CI is for, as its event says, where neither
    # --base nor DUEL_BASE names one: for a push, the commit before it
    # (on GitHub Actions, the event's before, and on GitLab CI,
    # CI_COMMIT_BEFORE_SHA), for a merge queue, its base, and on a
    # schedule, the last release (Baseline::LAST_RELEASE). Nil for the
    # rest: a pull request, whose baseline is where HEAD left the branch
    # it targets, as outside CI.
    def event_base
      case event
      when "push" then gitlab? ? variable("CI_COMMIT_BEFORE_SHA") : event_payload["before"]
      when "merge_group" then event_payload.dig("merge_group", "base_sha")
      when "schedule" then Baseline::LAST_RELEASE
      end
    end

    # Whether this is a run on CI for a push.
    def pushed? = event == "push"

    # The first of the variables +names+ that's set, or nil.
    def variable(*names) = names.map { |name| @env[name] }.find { |value| value && !value.empty? }

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
      publish(status, -> { Summary.note(mark, title, why) }, -> { JSONReport.note(status, exit, "duel: #{why}", settings) })
      exit
    end

    # What the workflow does about its comment on a pull request, or on
    # a pushed commit (see .comment), for a run whose +status+ is the
    # JSON report's: as the configuration says (Config#comment), or the
    # default where it didn't load. It comments on a push
    # only where a regression in one passes (Config#fail_on), so the
    # comment says what the check doesn't. A regression the label
    # accepts (Config#accept_label) is commented on as a run that passed
    # would be: whoever added the label knows, so by default it posts
    # only where the last comment's status isn't its own.
    def commenting(status)
      config = @config || Config.new
      return "none" if pushed? && !pull_requests_only?(config)

      CLI.comment(config.comment, @accepted ? "passed" : status)
    end

    # Writes the reports of a run whose +status+ is the JSON report's
    # where they're asked for: the JSON +json+ makes to the file --json
    # names, and the Markdown +markdown+ makes to the file --markdown
    # names, and added to the job's summary on GitHub Actions
    # (STEP_SUMMARY). Each is only made if it's written. On GitHub
    # Actions, it also sets the step's outputs (STEP_OUTPUT) for the jobs
    # that comment: +comment+, and +status+ as the comment's marker has
    # it (MARKED), and for the job that marks a push passed, "passed",
    # the branch that marks it (see #marks_passed?). Where DUEL_OUTPUT
    # names a file (OUTPUT), it writes them there too, as variables.
    def publish(status, markdown, json)
      comment = commenting(status)
      outputs = "comment=#{comment}\nstatus=#{MARKED.fetch(status)}\n#{"passed=#{@passed}\n" if @passed}"
      step_output = variable(STEP_OUTPUT)
      File.write(step_output, outputs, mode: "a") if step_output
      output = variable(OUTPUT)
      File.write(output, outputs.gsub(/^\w+=/) { |name| "DUEL_#{name.upcase}" }, mode: "a") if output
      path = @json
      write(path, "#{JSON.pretty_generate(json.call)}\n") if path
      path = @markdown
      summary = variable(STEP_SUMMARY)
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
    # what chose it: the main branch, the push (the commit before it, or
    # the last commit Duel passed), the merge queue (its base), the last
    # release, or --base.
    def described_baseline(config, settings, baseline)
      dir = settings.base_dir
      return Summary.code(dir) if dir

      # (There's one: #compare checked.)
      ref = baseline.ref #: String
      commit = git(config.root, "rev-parse", "--short", "#{ref}^{commit}").first.chomp
      chosen = case settings.base
      when nil then "where HEAD left #{Summary.code(baseline.main_branch)}"
      when Baseline::LAST_RELEASE then last_release(config, baseline)
      else
        if ref == baseline.passed then "the last commit Duel passed"
        # (The event's: a push's, or a merge queue's, as a schedule's is the last release.)
        elsif from_event?(settings) then pushed? ? "the commit before the push" : "the merge queue's base"
        elsif !ref.match?(/\A\h+\z/) then Summary.code(ref)
        else "from --base"
        end
      end
      "#{commit} (#{chosen})"
    end

    # What chose a baseline of the last release: the release, or a change
    # since it that was accepted with the label (Settings#accepted).
    def last_release(config, baseline)
      release = baseline.release #: String
      return "the last release, #{Summary.code(release)}" if baseline.ref == release

      label = config.accept_label #: String
      "the last change accepted with the #{Summary.code(label)} label, since the last release, #{Summary.code(release)}"
    end

    # The candidate, in Markdown: its directory, or its commit, bare (see
    # #described_baseline), and whether what's watched (Baseline#watched)
    # has changes not committed.
    def described_candidate(config, settings, baseline)
      dir = settings.candidate_dir || config.root
      head, found = git(dir, "rev-parse", "--short", "HEAD")
      return Summary.code(dir) unless found.success?

      return "#{head.chomp} (with changes not committed)" if uncommitted?(dir, baseline)

      merged(dir) || head.chomp
    end

    # On GitHub Actions, a pull request's run checks out the commit that
    # merges it with the branch it targets, which isn't in the pull
    # request, so its head is named instead, as merged (or nil, where HEAD
    # is no such commit). So does a merge request's merged results
    # pipeline, on GitLab CI.
    def merged(dir)
      pull = (gitlab? ? merge_request : pull_request) or return
      sha, branch = pull.dig("head", "sha"), pull.dig("base", "ref")
      return unless branch.instance_of?(String) && git(dir, "rev-parse", "HEAD^2").first.chomp == sha

      "#{git(dir, "rev-parse", "--short", sha).first.chomp} (merged with #{Summary.code(branch)})"
    end

    # A GitLab merge request's merged results pipeline's head and the
    # branch it targets, as #pull_request has a pull request's (each nil
    # in a merge request's other pipelines, whose HEAD is its head).
    def merge_request = {"head" => {"sha" => variable("CI_MERGE_REQUEST_SOURCE_BRANCH_SHA")},
                         "base" => {"ref" => variable("CI_MERGE_REQUEST_TARGET_BRANCH_NAME")}}

    # The pull request a pull_request event's run is for, as GitHub
    # Actions describes it (see #event_payload), or nil.
    def pull_request
      pull = event_payload["pull_request"] if event == "pull_request"
      pull if pull.instance_of?(Hash)
    end

    # The event a run on GitHub Actions is for, as its file
    # (GITHUB_EVENT_PATH) describes it, or nothing ({}), where there's
    # none, or it isn't a JSON object.
    def event_payload
      path = variable("GITHUB_EVENT_PATH")
      payload = JSON.parse(File.read(path)) if path && File.file?(path)
      payload.instance_of?(Hash) ? payload : {}
    rescue JSON::ParserError
      {}
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
    def candidate_json(config, settings, baseline)
      dir = File.expand_path(settings.candidate_dir || config.root)
      head, found = git(dir, "rev-parse", "HEAD")
      return {"commit" => nil, "uncommitted_changes" => nil, "root" => dir} unless found.success?

      {"commit" => head.chomp, "uncommitted_changes" => uncommitted?(dir, baseline), "root" => dir}
    end

    # Whether what +baseline+ watches (Baseline#watched) has changes not
    # committed in +dir+, a repository.
    def uncommitted?(dir, baseline)
      _, clean = git(dir, "diff", "--quiet", "HEAD", "--", *baseline.watched)
      !clean.success?
    end

    # Git's output, and its status, in +dir+.
    def git(dir, *args)
      out, _, status = Spawn.open3(:capture3, "git", "-C", dir, *args)
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
      force = variable("DUEL_FORCE")
      if force && !FORCE.key?(force.downcase)
        raise OptionParser::InvalidArgument, "DUEL_FORCE=#{force} (give 1 or true, or 0 or false)"
      end

      ENV_OPTIONS.flat_map { |name, option| set.key?(name) ? [option, set.fetch(name)] : [] } + (FORCE[force.to_s.downcase] ? ["--force"] : [])
    end

    # The environment's variables that are set (not empty).
    def variables = @env.reject { |_, value| value.empty? }

    # Sets +settings+' +name+d setting (one of Config::RUN_SETTINGS) to
    # +value+, an option's, over .duel.rb's: one it doesn't take is an
    # invalid option.
    def given(settings, name, value)
      problem = Config.problem(name, value)
      # (OptionParser says which option.)
      raise OptionParser::InvalidArgument, "#{value}: give #{problem}" if problem

      set(settings, name, value)
      @given << name
    end

    # Sets +settings+' +name+d setting to +value+: a number of processes,
    # that many, not as many as fit in memory.
    def set(settings, name, value)
      settings[name] = value
      settings.fit -= [name]
    end

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
        o.on("--candidate DIR", "Candidate: a directory, already built (default: this tree)") { |v| settings.candidate_dir = v }
        o.on("--filter REGEXP", "Only benchmarks whose names match") { |v| settings.filter = CLI.regexp(v) }
        o.on("--jobs N", Integer, "Benchmarks measured at once (default: c.jobs, or one for every #{CPUS_PER_LANE} CPUs, as many as fit)") do |v|
          given(settings, :jobs, v)
        end
        o.on("--processes N", Integer, "Worker processes per version (default: c.processes, or #{PROCESSES}, as many as fit in memory)") do |v|
          given(settings, :processes, v)
        end
        o.on("--timeout SECONDS", Float, "Most a worker may take to load or answer (default: c.timeout, or #{TIMEOUT.round})") do |v|
          given(settings, :timeout, v)
        end
        o.on("--time-limit SECONDS", Float, "Most a run measures for, then fails what's unmeasured or looks worse (default: c.time_limit, or 7200)") do |v|
          given(settings, :time_limit, v)
        end
        o.on("--limit RATIO", Float, "Ratio above which a timing is slower (default: c.limit, or 1.02)") { |v| given(settings, :limit, v) }
        o.on("--confidence LEVEL", Float, "Confidence of every interval (default: c.confidence, or 0.99)") { |v| given(settings, :confidence, v) }
        o.on("--warm SECONDS", Float, "Warm-up per benchmark, in seconds (default: c.warm, or until steady, up to 60 on JRuby and TruffleRuby, 10 with YJIT or ZJIT on, else 0)") do |v|
          given(settings, :warm, v)
        end
        o.on("--ruby version-file|PATH", "Each version's Ruby: the one its version file names (.ruby-version, say), or a",
          "path (default: c.ruby, or this one)") { |v| settings.ruby = (v.tr("_", "-") == "version-file") ? :version_file : v }
        o.on("--force", "Compare even if nothing watched changed") { settings.force = true }
        o.on("--config PATH", "Config file (default: .duel.rb)") { |v| settings.config_path = v }
        o.on("--markdown PATH", "Also write the report to PATH in Markdown, for a pull request comment (on GitHub",
          "Actions, it's added to the job's summary too)") { |v| @markdown = v }
        o.on("--json PATH", "Also write the report to PATH as JSON, for a program to read") { |v| @json = v }
        o.on("-v", "--version", "Print the version") do
          @out.puts "duel #{VERSION}"
          throw :version
        end
      end
    end
  end
end
