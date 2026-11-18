# frozen_string_literal: true

require_relative "test_helper"

class CLITest < DuelTest
  cover "Duel::CLI*"

  def cli(*argv, env: {}) = Duel::CLI.new(argv, env: env, out: (@out = StringIO.new), err: (@err = StringIO.new))

  def test_version
    assert_equal 0, cli("--version").run
    assert_equal "duel #{Duel::VERSION}\n", @out.string
    assert_equal 0, cli("-v").run
    assert_equal "duel #{Duel::VERSION}\n", @out.string
  rescue SystemExit
    flunk "OptionParser's own --version exits"
  end

  def test_out_err_and_env_by_default
    out, = capture_io { assert_equal 0, Duel::CLI.new(["--version"]).run }

    assert_equal "duel #{Duel::VERSION}\n", out
    _, err = capture_io { assert_equal 2, Duel::CLI.new(["--nope"]).run }

    assert_equal "duel: invalid option: --nope\n", err
    ENV["DUEL_FILTER"] = "push"

    assert_equal(/push/, Duel::CLI.new([]).parse.filter)
  rescue SystemExit
    flunk "OptionParser's own --version exits"
  ensure
    ENV.delete("DUEL_FILTER")
  end

  # A filter that isn't a regular expression is a usage error, from the
  # environment too.
  def test_an_invalid_filter
    assert_equal 2, cli("--filter", "[").run
    assert_equal "duel: invalid argument: --filter [ (premature end of char-class: /[/)\n", @err.string
    assert_equal 2, cli(env: {"DUEL_FILTER" => "a("}).run
    assert_match(/\Aduel: invalid argument: --filter a\( \(end pattern with unmatched parenthesis/, @err.string)
    assert_equal(/a|b/, Duel::CLI.regexp("a|b"))
  end

  def test_leaves_its_arguments_alone
    argv = ["--force"]
    Duel::CLI.new(argv, env: {}).parse

    assert_equal ["--force"], argv
  end

  # `duel comment` is the Comment command's, given the environment.
  def test_the_comment_command
    report = FileUtils.mkdir_p(File.join(tmpdir, "report")).first
    File.write(File.join(report, "comment.env"), "pr=12\ncomment=post\nstatus=failed\n")
    bin = File.join(tmpdir, "bin")
    fake_command(File.join(bin, "gh"), "exit 1")
    path = ENV.fetch("PATH")
    ENV["PATH"] = path_with(bin)

    assert_equal 1, cli("comment", "--report", report, "--head", "abc", env: {"GITHUB_REPOSITORY" => "me/mine"}).run
    assert_equal ["", "duel comment: gh api repos/me/mine/pulls/12: \n"], [@out.string, @err.string]
    File.delete(File.join(report, "comment.env"))

    assert_equal 0, cli("comment", "--report", report, "--head", "abc").run
    assert_equal "duel comment: no comment (Duel said not to)\n", @out.string
  ensure
    ENV["PATH"] = path
  end

  def test_help
    assert_equal <<~HELP, cli.send(:parser, Duel::Settings.defaults).help
      Usage: duel [options]
             duel base [options]
             duel init [options]
             duel clean [--config PATH]
             duel comment [options]

      Fails if this tree is slower than a baseline at any benchmark. `duel base` prints the commit it would compare
      with, `duel init` sets Duel up in a project, `duel clean` removes tmp/duel and the baseline's git worktree,
      and `duel comment` is what its Perf comment workflow runs.

              --base REF|DIR               Baseline: a commit (default: where HEAD left the main branch), last-release (the newest
                                           release tag), or a directory, already built
              --candidate DIR              Candidate: a directory, already built (default: this tree)
              --filter REGEXP              Only benchmarks whose names match
              --jobs N                     Benchmarks measured at once (default: c.jobs, or one for every #{Duel::CPUS_PER_LANE} CPUs, as many as fit)
              --processes N                Worker processes per version (default: c.processes, or #{Duel::PROCESSES}, as many as fit in memory)
              --timeout SECONDS            Most a worker may take to load or answer (default: c.timeout, or #{Duel::TIMEOUT.round})
              --time-limit SECONDS         Most a run measures for, then fails what's unmeasured or looks worse (default: c.time_limit, or 7200)
              --limit RATIO                Ratio above which a timing is slower (default: c.limit, or 1.02)
              --confidence LEVEL           Confidence of every interval (default: c.confidence, or 0.99)
              --warm SECONDS               Warm-up per benchmark, in seconds (default: c.warm, or until steady, up to 60 on JRuby and TruffleRuby, 10 with YJIT or ZJIT on, else 0)
              --ruby version-file|PATH     Each version's Ruby: the one its version file names (.ruby-version, say), or a
                                           path (default: c.ruby, or this one)
              --force                      Compare even if nothing watched changed
              --config PATH                Config file (default: .duel.rb)
              --markdown PATH              Also write the report to PATH in Markdown, for a pull request comment (on GitHub
                                           Actions, it's added to the job's summary too)
              --json PATH                  Also write the report to PATH as JSON, for a program to read
              --comment MODE               When the workflow comments on a pull request: always, results (passed or failed),
                                           failures, or never (default: c.comment, or failures)
              --fail-on RUNS               Which runs a regression fails: every_run, or pull_requests (on GitHub Actions, another
                                           warns and passes) (default: c.fail_on, or every_run)
          -v, --version                    Print the version
    HELP
  end

  # Half the CPUs, or on JRuby and TruffleRuby, a quarter.
  def test_jobs_by_default_half_the_cpus
    per = {"jruby" => 4, "truffleruby" => 4}.fetch(RUBY_ENGINE, 2)

    assert_equal [1, 8 / per], [1, 8].map { |cpus| stub(Etc, :nprocessors, -> { cpus }) { cli.parse.jobs } }
  end

  # Duel may lower the jobs and processes to fit the memory available
  # (Runner#fit), but not those an option sets.
  def test_fit
    assert_equal [%i[jobs processes], %i[processes], %i[jobs], []],
      [[], ["--jobs", "2"], ["--processes", "4"], ["--jobs", "2", "--processes", "4"]].map { |args| cli(*args).parse.fit }
  end

  def test_a_bad_option
    assert_equal 2, cli("--nope").run
    assert_equal "duel: invalid option: --nope\n", @err.string
  end

  def test_options
    s = cli("--base", "v1", "--candidate", "c", "--filter", "push", "--jobs", "3", "--limit", "1.05",
      "--warm", "2", "--force", "--config", "x.rb", "--processes", "4", "--timeout", "9", "--time-limit", "600", "--confidence", "0.95").parse

    assert_equal ["v1", nil, "c", /push/, 3, 1.05, 2.0, true, File.expand_path("x.rb"), 4, 9.0, 600.0, 0.95, []],
      [s.base, s.base_dir, s.candidate_dir, s.filter, s.jobs, s.limit, s.warm, s.force, s.config_path, s.processes, s.timeout,
        s.time_limit, s.confidence, s.fit]
    assert_equal %i[jobs processes], cli.parse.fit, "as many as fit in memory, unless they're given"
  end

  # A run setting's option given what it doesn't take (as .duel.rb's
  # wouldn't: see Config::RUN_SETTINGS) is a bad option.
  def test_a_run_setting_out_of_range
    # (Each as it's parsed: a Float, or an Integer.)
    {%w[--confidence 1.5] => "1.5: give a level above 0 and below 1", %w[--limit 0.5] => "0.5: give a ratio of 1 or more",
     %w[--processes 0] => "0: give a whole number, 1 or more", %w[--time-limit 0] => "0.0: give seconds, more than 0"}.each do |argv, said|
      assert_equal 2, cli(*argv).run
      assert_equal "duel: invalid argument: #{argv.first} #{said}\n", @err.string
    end
  end

  # An argument that isn't an option is a mistake, not ignored.
  def test_a_needless_argument
    assert_equal 2, cli("--base", "v1", "v2", "v3").run
    assert_equal "duel: needless argument: v2\n", @err.string
  end

  # Each version's Ruby: its version file's (version-file, or
  # version_file), or a path.
  def test_ruby
    assert_equal [:version_file, :version_file, "/rubies/3.4/bin/ruby", "/my_rubies/version-file", nil],
      [cli("--ruby", "version-file").parse.ruby, cli("--ruby", "version_file").parse.ruby, cli("--ruby", "/rubies/3.4/bin/ruby").parse.ruby,
        cli("--ruby", "/my_rubies/version-file").parse.ruby, cli.parse.ruby]
  end

  # When the workflow comments on a pull request: a mode by its name, or
  # c.comment's (nil), and a name that isn't one fails.
  def test_comment
    assert_equal [:always, :results, :failures, :never, nil], [*%w[always results failures never].map { |mode| cli("--comment", mode).parse.comment }, cli.parse.comment]
    assert_equal 2, cli("--comment", "failure").run
    assert_equal "duel: invalid argument: --comment failure (give always, results, failures, never)\n", @err.string
  end

  # Which runs a regression fails: by name, or c.fail_on's (nil), and a
  # name that isn't one fails.
  def test_fail_on
    assert_equal [:every_run, :pull_requests, nil], [*%w[every_run pull_requests].map { |runs| cli("--fail-on", runs).parse.fail_on }, cli.parse.fail_on]
    assert_equal 2, cli("--fail-on", "pushes").run
    assert_equal "duel: invalid argument: --fail-on pushes (give every_run, pull_requests)\n", @err.string
  end

  # A file of a GitHub Actions event, +payload+ (as JSON).
  def event(payload) = File.join(tmpdir, "event.json").tap { |path| File.write(path, payload) }

  # On GitHub Actions for a push, the baseline is the commit before it,
  # as its event says (GITHUB_EVENT_PATH), and the branch pushed is the
  # push's, unless --base or DUEL_BASE names another baseline.
  def test_pushed
    push = {"GITHUB_EVENT_NAME" => "push", "GITHUB_EVENT_PATH" => event(%({"before": "abc123"})), "GITHUB_REF_NAME" => "2-x-stable"}

    assert_equal ["abc123", "2-x-stable"], cli(env: push).parse.then { |s| [s.base, s.pushed] }
    assert_equal "2-x-stable", cli(env: push.merge("DUEL_BASE" => "abc123")).parse.pushed,
      "DUEL_BASE that's the event's, as the workflows duel init wrote before give it"
    assert_equal ["def456", nil], cli("--base", "def456", env: push).parse.then { |s| [s.base, s.pushed] }, "--base"
    assert_equal ["def456", nil], cli(env: push.merge("DUEL_BASE" => "def456")).parse.then { |s| [s.base, s.pushed] }, "DUEL_BASE"
    assert_equal [nil, nil], cli("--base", tmpdir, env: push).parse.then { |s| [s.base, s.pushed] }, "a directory"
    assert_nil cli(env: push.merge("GITHUB_EVENT_NAME" => "pull_request")).parse.pushed, "not a push"
    assert_equal [nil, nil], cli(env: push.except("GITHUB_EVENT_PATH")).parse.then { |s| [s.base, s.pushed] }, "no event"
    assert_nil cli(env: push.except("GITHUB_REF_NAME")).parse.pushed, "no branch"
    %w[[] { "nothing"].each { |payload| assert_nil cli(env: push.merge("GITHUB_EVENT_PATH" => event(payload))).parse.base, payload }
  end

  # The baseline other events say: a merge queue's base, and on a
  # schedule, the last release. A pull request's is where HEAD left the
  # branch it targets.
  def test_the_baseline_an_event_says
    queued = {"GITHUB_EVENT_NAME" => "merge_group", "GITHUB_EVENT_PATH" => event(%({"merge_group": {"base_sha": "fed987"}}))}

    assert_equal ["fed987", nil], cli(env: queued.merge("GITHUB_REF_NAME" => "main")).parse.then { |s| [s.base, s.pushed] }
    assert_nil cli(env: queued.merge("GITHUB_EVENT_PATH" => event("{}"))).parse.base, "no merge_group"
    assert_equal "last-release", cli(env: {"GITHUB_EVENT_NAME" => "schedule"}).parse.base
    assert_equal "v1", cli(env: {"GITHUB_EVENT_NAME" => "schedule", "DUEL_BASE" => "v1"}).parse.base
    assert_nil cli(env: queued.merge("GITHUB_EVENT_NAME" => "pull_request")).parse.base
    assert_nil cli(env: queued.merge("GITHUB_EVENT_NAME" => "workflow_dispatch")).parse.base
  end

  # The branch a pull request targets, on GitHub Actions: on origin, for
  # a pull request (or a merge queue's run) only.
  def test_target
    pr = {"GITHUB_EVENT_NAME" => "pull_request", "GITHUB_BASE_REF" => "2-x-stable"}

    assert_equal "origin/2-x-stable", cli(env: pr).parse.target
    assert_equal "origin/2-x-stable", cli(env: pr.merge("GITHUB_EVENT_NAME" => "pull_request_target")).parse.target
    assert_nil cli(env: pr.merge("GITHUB_EVENT_NAME" => "push")).parse.target, "not a pull request"
    assert_nil cli(env: pr.merge("GITHUB_BASE_REF" => "")).parse.target, "none"
    assert_nil cli(env: pr.slice("GITHUB_EVENT_NAME")).parse.target, "unset"
    assert_nil cli(env: pr.slice("GITHUB_BASE_REF")).parse.target, "not on GitHub Actions"
  end

  # On a schedule, the commit since the last release that merged the last
  # pull request accepted with the label, as the workflow found it.
  def test_accepted
    assert_equal "abc123", cli(env: {"DUEL_ACCEPTED" => "abc123"}).parse.accepted
    assert_nil cli(env: {"DUEL_ACCEPTED" => ""}).parse.accepted, "none"
    assert_nil cli.parse.accepted, "unset"
  end

  # On GitLab CI: a push's baseline (CI_COMMIT_BEFORE_SHA) and branch
  # (CI_COMMIT_BRANCH), a schedule's, and a merge request's target
  # (CI_MERGE_REQUEST_TARGET_BRANCH_NAME).
  def test_on_gitlab
    gitlab = {"GITLAB_CI" => "true", "CI_COMMIT_BEFORE_SHA" => "abc123", "CI_COMMIT_BRANCH" => "main",
              "CI_MERGE_REQUEST_TARGET_BRANCH_NAME" => "trunk"}
    push = cli(env: gitlab.merge("CI_PIPELINE_SOURCE" => "push")).parse
    merge_request = cli(env: gitlab.merge("CI_PIPELINE_SOURCE" => "merge_request_event")).parse

    assert_equal ["abc123", "main", nil], [push.base, push.pushed, push.target]
    assert_equal [nil, nil, "origin/trunk"], [merge_request.base, merge_request.pushed, merge_request.target]
    assert_equal "last-release", cli(env: gitlab.merge("CI_PIPELINE_SOURCE" => "schedule")).parse.base
    assert_nil cli(env: gitlab.merge("CI_PIPELINE_SOURCE" => "push", "GITLAB_CI" => "")).parse.pushed, "not GitLab CI"
  end

  # A baseline that's a directory, by --base (or DUEL_BASE): the last
  # given wins, a ref or a directory.
  def test_a_base_directory
    s = cli("--base", tmpdir).parse

    assert_equal [nil, tmpdir], [s.base, s.base_dir]
    assert_equal [nil, tmpdir], cli("--base", "v1", "--base", tmpdir).parse.then { |t| [t.base, t.base_dir] }
    assert_equal ["v1", nil], cli("--base", "v1", env: {"DUEL_BASE" => tmpdir}).parse.then { |t| [t.base, t.base_dir] }
    assert_equal [nil, tmpdir], cli(env: {"DUEL_BASE" => tmpdir}).parse.then { |t| [t.base, t.base_dir] }
  end

  # Each of --base, --filter, --ruby, and the options .duel.rb can set
  # too, as DUEL_ and its name: under an option given.
  def test_the_environment
    env = {"DUEL_BASE" => "v1", "DUEL_CANDIDATE" => "new", "DUEL_FILTER" => "run", "DUEL_FORCE" => "1", "DUEL_RUBY" => "version-file", "DUEL_LIMIT" => "1.05",
           "DUEL_CONFIDENCE" => "0.995", "DUEL_JOBS" => "3", "DUEL_PROCESSES" => "7", "DUEL_TIMEOUT" => "30", "DUEL_TIME_LIMIT" => "60",
           "DUEL_WARM" => "2"}
    s = cli(env: env).parse

    assert_equal ["v1", "new", /run/, true, :version_file, 1.05, 0.995, 3, 7, 30.0, 60.0, 2.0],
      [s.base, s.candidate_dir, s.filter, s.force, s.ruby, s.limit, s.confidence, s.jobs, s.processes, s.timeout, s.time_limit, s.warm]
    assert_equal ["v2", 8], cli("--base", "v2", "--processes", "8", env: env).parse.then { |t| [t.base, t.processes] }, "options win"
    assert_nil cli(env: {"DUEL_BASE" => ""}).parse.base, "empty is unset"
  end

  # DUEL_FORCE is 1 or true, or 0 or false: anything else is a mistake,
  # not --force.
  def test_duel_force
    assert_equal [true, true, false, false], %w[1 TRUE 0 false].map { |value| cli(env: {"DUEL_FORCE" => value}).parse.force }
    error = assert_raises(OptionParser::InvalidArgument) { cli(env: {"DUEL_FORCE" => "yes"}).parse }

    assert_includes error.message, "DUEL_FORCE=yes (give 1 or true, or 0 or false)"
  end

  def test_defaults
    s = Dir.chdir(tmpdir) { cli.parse }

    assert_equal [nil, nil, nil, //, [Etc.nprocessors / Duel::CPUS_PER_LANE, 1].max, 1.02, 0.99, false, nil, Duel::TIMEOUT, 7200.0],
      [s.base, s.base_dir, s.candidate_dir, s.filter, s.jobs, s.limit, s.confidence, s.force, s.config_path, s.timeout, s.time_limit]
    assert_equal({"jruby" => 8, "truffleruby" => 8}.fetch(RUBY_ENGINE, 12), s.processes, "fewer of a JVM's")
    assert_equal({"jruby" => 300.0, "truffleruby" => 300.0}.fetch(RUBY_ENGINE, 60.0), s.timeout, "longer for a JVM to start")
  end

  def test_finds_dot_duel_rb
    File.write(File.join(tmpdir, ".duel.rb"), "")

    assert_equal File.realpath(File.join(tmpdir, ".duel.rb")), File.realpath(Dir.chdir(tmpdir) { cli.parse.config_path })
  end

  # A run, with the runner faked: what it's given, and what its verdict
  # makes the exit status.
  def run_with(passed, *argv, dir:, env: {"X" => "1"})
    made = []
    runner = Object.new
    runner.define_singleton_method(:run) { [:results] }
    runner.define_singleton_method(:passed?) { |results| results == [:results] && passed }
    status = stub(Duel::Runner, :new, ->(*args, **options) { (made << [*args, options]) && runner }) do
      Dir.chdir(dir) { cli(*argv, env: env).run }
    end
    [status, *made.first]
  end

  def test_compares_two_directories
    base = FileUtils.mkdir_p(File.join(tmpdir, "base")).first
    candidate = FileUtils.mkdir_p(File.join(tmpdir, "candidate")).first
    File.write(File.join(candidate, ".duel.rb"), 'Duel.configure { |c| c.benchmarks = "duel/*.rb" }')
    status, config, settings, root, options = run_with(true, "--base", base, "--jobs", "1", dir: candidate)

    assert_equal 0, status
    assert_equal "duel/*.rb", config.benchmarks, "its config file"
    assert_same Duel.config, config
    assert_equal [base, 1], [settings.base_dir, settings.jobs]
    assert_equal base, root
    assert_equal({out: @out}, options)
    assert_equal 1, run_with(false, "--base", base, dir: candidate).first, "slower"
  end

  # .duel.rb's run settings (c.limit, c.jobs, c.timeout...), but each
  # one's option, or variable, where it's given, and Duel's own defaults
  # where none is.
  def test_run_settings_from_the_config_file
    base = FileUtils.mkdir_p(File.join(tmpdir, "base")).first
    candidate = FileUtils.mkdir_p(File.join(tmpdir, "candidate")).first
    File.write(File.join(candidate, ".duel.rb"),
      "Duel.configure { |c| c.limit = 1.05; c.confidence = 0.995; c.processes = 6; c.timeout = 90; c.time_limit = 600; c.warm = 4 }")
    settings = run_with(true, "--base", base, dir: candidate)[2]

    assert_equal [1.05, 0.995, 6, 90.0, 600.0, 4.0, [:jobs]],
      [settings.limit, settings.confidence, settings.processes, settings.timeout, settings.time_limit, settings.warm, settings.fit],
      "c.processes: that many, not as many as fit"
    File.write(File.join(candidate, ".duel.rb"), "Duel.configure { |c| c.jobs = 2; c.limit = 1.05 }")
    settings = run_with(true, "--base", base, dir: candidate, env: {"DUEL_LIMIT" => "1.2"})[2]

    assert_equal [2, 1.2, [:processes]], [settings.jobs, settings.limit, settings.fit], "c.jobs, and DUEL_LIMIT over c.limit"
    File.write(File.join(candidate, ".duel.rb"),
      "Duel.configure { |c| c.limit = 1.05; c.confidence = 0.995; c.processes = 6; c.timeout = 90; c.time_limit = 600; c.warm = 4 }")
    settings = run_with(true, "--base", base, "--limit", "1.1", "--confidence", "0.9", "--processes", "3", "--timeout", "5",
      "--time-limit", "60", "--warm", "0", dir: candidate)[2]

    assert_equal [1.1, 0.9, 3, 5.0, 60.0, 0.0],
      [settings.limit, settings.confidence, settings.processes, settings.timeout, settings.time_limit, settings.warm], "the options' over .duel.rb's"
    File.write(File.join(candidate, ".duel.rb"), "Duel.configure { |c| c.limit = 1.05 }")
    settings = run_with(true, "--base", base, dir: candidate)[2]
    defaults = Duel::Settings.defaults

    assert_equal [1.05, defaults.confidence, defaults.timeout, defaults.time_limit, nil, %i[jobs processes]],
      [settings.limit, settings.confidence, settings.timeout, settings.time_limit, settings.warm, settings.fit], "Duel's own, where neither says"
  end

  # A run with the baseline faked too: +ref+ (nil: no release yet) and
  # whether nothing changed since it. What it built goes in @built.
  # Its root is the candidate's own (+root+ for another): its path is as
  # long.
  def run_against(ref:, unchanged:, argv: [], build: nil, root: tmpdir)
    @built = built = []
    baseline = Struct.new(:ref, :unchanged?, :root, :watched).new(ref, unchanged, root, %w[lib duel])
    baseline.define_singleton_method(:build) { |dir, what| (built << [dir, what]) && build&.call }
    stub(Duel::Baseline, :new, ->(*) { baseline }) { run_with(true, *argv, dir: tmpdir) }
  end

  # The candidate is built before every run (a build already done costs
  # little), and a run whose build fails can't compare.
  def test_builds_the_candidate
    status, = run_against(ref: "abc", unchanged: false)

    assert_equal 0, status
    assert_equal [[File.realpath(tmpdir), "the candidate"]], @built.map { |dir, what| [File.realpath(dir), what] }
    candidate = FileUtils.mkdir_p(File.join(tmpdir, "c")).first
    run_against(ref: "abc", unchanged: false, argv: ["--candidate", candidate], root: File.join(tmpdir, "b").tap { |b| FileUtils.mkdir_p(b) })

    assert_equal [[candidate, "the candidate"]], @built
    status, runner = run_against(ref: "abc", unchanged: false, build: -> { raise Duel::Error, "building the candidate failed" })

    assert_equal [2, nil], [status, runner]
    assert_equal "duel: building the candidate failed\n", @err.string
  end

  def test_nothing_to_compare_without_a_release
    status, runner = run_against(ref: nil, unchanged: false)

    assert_equal [0, nil], [status, runner]
    assert_equal "duel: no release tag (v*) before HEAD to compare against\n", @out.string
    assert_equal tmpdir, run_against(ref: nil, unchanged: false, argv: ["--base", tmpdir])[3], "a directory needs none"
  end

  def test_nothing_to_compare_when_nothing_changed
    status, runner = run_against(ref: "abc", unchanged: true)

    assert_equal [0, nil], [status, runner]
    assert_equal "duel: lib, duel unchanged since the baseline, so there's nothing to compare (--force to anyway)\n", @out.string
    assert_equal tmpdir, run_against(ref: "abc", unchanged: true, argv: ["--force"])[3]
  end

  # The two versions' paths, resolved, are as long, or it says which is
  # longer: what a version does with its own paths takes longer on a
  # longer one.
  def test_paths_of_different_lengths
    run_against(ref: "abc", unchanged: false)

    assert_empty @out.string
    # (Off Windows, where the tests' directories are reached through a
    # symlink: see TestDirs.)
    refute_equal File.realpath(tmpdir), tmpdir, "(reached through a symlink)" unless windows?
    run_against(ref: "abc", unchanged: false, argv: ["--candidate", tmpdir])

    assert_empty @out.string, "resolved, as long"
    run_against(ref: "abc", unchanged: false, root: FileUtils.mkdir_p(File.join(tmpdir, "base")).first)

    assert_equal "duel: the baseline's path is 5 characters longer than the candidate's, so it may measure a little slower\n", @out.string
    @out.truncate(0)
    @out.rewind
    run_against(ref: "abc", unchanged: false, root: File.dirname(tmpdir))

    assert_equal "duel: the baseline's path is #{File.basename(tmpdir).length + 1} characters shorter than the candidate's, " \
      "so it may measure a little faster\n", @out.string
  end

  # A run holds the project's lock (Duel::Lock) throughout, and one that
  # can't, can't compare.
  def test_holds_the_projects_lock
    held = []
    hold = ->(dir, &block) { (held << [dir, block.call]) && held.last.last }
    status, = stub(Duel::Lock, :hold, hold) { run_against(ref: "abc", unchanged: false) }

    assert_equal 0, status
    assert_equal [[File.join(Dir.chdir(tmpdir) { Dir.pwd }, "tmp", "duel"), 0]], held
    status = stub(Duel::Lock, :hold, ->(_) { raise Duel::Error, "another duel run (pid 1) is using it" }) do
      Dir.chdir(tmpdir) { cli.run }
    end

    assert_equal [2, "duel: another duel run (pid 1) is using it\n"], [status, @err.string]
  end

  # duel clean: the baseline's clean, holding the lock, for the
  # configuration of the .duel.rb here (or --config's), and nothing else.
  def test_clean
    cleaned = []
    baseline = Object.new
    baseline.define_singleton_method(:clean) { cleaned << :clean }
    File.write(File.join(tmpdir, ".duel.rb"), %(Duel.configure { |c| c.release_tags = "here-*" }\n))
    File.write(File.join(FileUtils.mkdir_p(File.join(tmpdir, "other")).first, ".duel.rb"), "")
    made = ->(config, settings) { (cleaned << [config.root, config.release_tags, settings.class]) && baseline }
    locked = ->(state, &block) { (cleaned << [:locked, state]) && block.call }
    statuses = stub(Duel::Lock, :hold, locked) do
      stub(Duel::Baseline, :new, made) { Dir.chdir(tmpdir) { [cli("clean").run, cli("clean", "--config", "other/.duel.rb").run] } }
    end
    here = Dir.chdir(tmpdir) { Dir.pwd }
    other = File.join(here, "other")

    assert_equal [0, 0], statuses
    assert_equal [[:locked, File.join(here, "tmp", "duel")], [here, "here-*", Duel::Settings], :clean,
      [:locked, File.join(other, "tmp", "duel")], [other, "v*", Duel::Settings], :clean], cleaned
    assert_equal "duel: removed tmp/duel and its baseline's worktree\n", @out.string
  end

  # Its usage (its own: OptionParser's exits), and what it doesn't take.
  def test_clean_takes_only_config
    usage = "Usage: duel clean [--config PATH]\n        --config PATH                Config file (default: .duel.rb)\n" \
      "    -h, --help                       Print this help\n"
    %w[--help -h].each do |help|
      assert_equal [0, usage], Dir.chdir(tmpdir) { [cli("clean", help).run, @out.string] }
    rescue SystemExit
      flunk "OptionParser's own #{help} exits"
    end

    refute_path_exists File.join(tmpdir, "tmp"), "nothing cleaned"
    assert_equal 2, Dir.chdir(tmpdir) { cli("clean", "--base", "v1").run }
    assert_equal "duel clean: invalid option: --base\n", @err.string
    assert_equal 2, Dir.chdir(tmpdir) { cli("clean", "x", "y").run }
    assert_equal "duel clean: needless argument: x\n", @err.string
  end

  def test_the_conventions_without_a_config_file
    _, config, = run_with(true, "--base", tmpdir, dir: tmpdir)

    assert_equal File.realpath(tmpdir), File.realpath(config.root)
    assert_equal "duel/**/*_duel.rb", config.benchmarks
  end

  def git_repo
    repo = project(File.join(tmpdir, "repo"))
    run = ->(*args) { system("git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t", *args, out: File::NULL) }
    run.call("init", "-q", "-b", "main")
    run.call("add", "-A")
    run.call("commit", "-qm", "one")
    [repo, run]
  end

  def test_no_release_yet
    repo, = git_repo

    assert_equal 0, Dir.chdir(repo) { cli("--base", "last-release").run }
    assert_equal "duel: no release tag (v*) before HEAD to compare against\n", @out.string
  end

  def test_nothing_changed
    repo, run = git_repo
    run.call("commit", "-q", "--allow-empty", "-m", "two")

    assert_equal 0, Dir.chdir(repo) { cli("--base", "HEAD^").run }
    assert_includes @out.string, "lib, ext, duel, .duel.rb unchanged since the baseline, so there's nothing to compare (--force to anyway)"
  end

  def test_errors_are_reported
    repo, = git_repo

    assert_equal 2, Dir.chdir(repo) { cli("--base", "nope", "--force").run }
    assert_match(/\Aduel: git rev-parse nope/, @err.string)
  end
end

class RakeTaskTest < DuelTest
  cover "Duel::RakeTask*"

  require "duel/rake_task"

  # Defining the task loads Rake, and not Duel: a Rakefile's other tasks
  # (rake test, say) load nothing more for it.
  # Duel loads as the task runs, in a process that hadn't loaded it.
  def test_the_task_loads_duel_as_it_runs
    # (On JRuby on Windows, its JVM: jruby.exe takes the code's quotes out.)
    said, = Duel::Spawn.open3(:capture2e, *RUBY_COMMAND, "-I", File.expand_path("../lib", __dir__), "-e",
      'require "duel/rake_task"; Duel::RakeTask.new(:perf, "--help"); Rake::Task[:perf].invoke')

    assert_includes said, "Usage: duel"
  end

  # The task loads Duel before it runs Duel's command.
  def test_the_task_loads_duel_first
    unloaded = Class.new(StandardError)
    Duel::RakeTask.new(:perf_loads)

    stub(Duel::RakeTask, :load_duel, -> { raise unloaded }) do
      assert_raises(unloaded) { Rake::Task[:perf_loads].invoke }
    end
  end

  def test_defining_the_task_loads_no_more_of_duel
    loaded = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
      'before = $LOADED_FEATURES.dup; require "duel/rake_task"; Duel::RakeTask.new; puts $LOADED_FEATURES - before'], &:read)

    assert_empty loaded.lines(chomp: true).grep(%r{/duel/(?!rake_task\.rb\z)}), "nothing of Duel's but the task"
  end

  def with_status(status)
    Duel::CLI.alias_method(:original_run, :run)
    Duel::CLI.define_method(:run) { status }
    yield
  ensure
    Duel::CLI.alias_method(:run, :original_run)
    Duel::CLI.remove_method(:original_run)
  end

  # Invokes +task+, failing if it aborts (minitest lets SystemExit
  # through, which would end the run instead).
  def invoke(task)
    capture_io { task.invoke }
  rescue SystemExit => e
    flunk "aborted (#{e.status})"
  end

  def task(*args)
    Rake::TaskManager.record_task_metadata = true # keeps descriptions
    Rake.application = Rake::Application.new
    Duel::RakeTask.new(:perf, *args)
    Rake::Task[:perf]
  end

  def test_defines_a_task_that_runs_duel
    seen = nil
    Duel::CLI.alias_method(:original_run, :run)
    Duel::CLI.define_method(:run) { (seen = @argv) && 0 }
    t = task("--base", "last-release")

    assert_nil seen, "not until it's invoked"

    assert_equal "Fail if this tree is slower than its baseline at any benchmark (duel)", t.comment
    invoke(t)

    assert_equal %w[--base last-release], seen
  ensure
    Duel::CLI.alias_method(:run, :original_run)
    Duel::CLI.remove_method(:original_run)
  end

  def test_passes_when_not_slower
    with_status(0) { invoke(task) }

    pass "not aborted"
  end

  # Slower, unable to compare, or slower but only warned (on GitLab, for
  # allow_failure: exit_codes: [3]): with duel's own status.
  def test_exits_with_duels_status
    [1, 2, 3].each do |status|
      exited = assert_raises(SystemExit) { with_status(status) { task.invoke } }

      assert_equal status, exited.status
    end
  end

  def test_the_default_name
    Rake.application = Rake::Application.new
    with_status(0) { Duel::RakeTask.new }

    assert Rake::Task.task_defined?(:duel)
  end
end
