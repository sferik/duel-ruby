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

  def test_help
    assert_equal <<~HELP, cli.send(:parser, Duel::Settings.defaults).help
      Usage: duel [options]
             duel init [options]

      Fails if this tree is slower than a baseline at any benchmark. `duel init` sets Duel up in a project.

              --base REF|DIR               Baseline: a commit (default: where HEAD left the main branch), last-release (the newest
                                           release tag), or a directory, already built
              --candidate-dir DIR          Candidate tree (default: this one)
              --filter REGEXP              Only benchmarks whose names match
              --jobs N                     Benchmarks measured at once (default: half the CPUs)
              --processes N                Worker processes per version (default: 3)
              --timeout SECONDS            Most a worker may take to load or answer (default: 60)
              --limit RATIO                Ratio above which a timing is slower (default: 1.02)
              --warm SECONDS               Warm-up per benchmark (default: 5 on JRuby and TruffleRuby, 2 with YJIT on, else 0)
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
              --clean                      Remove tmp/duel, and the baseline's git worktree, and stop
          -v, --version                    Print the version
    HELP
  end

  def test_jobs_by_default_half_the_cpus
    assert_equal [1, 4], [1, 8].map { |cpus| stub(Etc, :nprocessors, -> { cpus }) { cli.parse.jobs } }
  end

  def test_a_bad_option
    assert_equal 2, cli("--nope").run
    assert_equal "duel: invalid option: --nope\n", @err.string
  end

  def test_options
    s = cli("--base", "v1", "--candidate-dir", "c", "--filter", "push", "--jobs", "3", "--limit", "1.05",
      "--warm", "2", "--force", "--config", "x.rb", "--processes", "4", "--timeout", "9").parse

    assert_equal ["v1", nil, "c", /push/, 3, 1.05, 2.0, true, File.expand_path("x.rb"), 4, 9.0],
      [s.base, s.base_dir, s.candidate_dir, s.filter, s.jobs, s.limit, s.warm, s.force, s.config_path, s.processes, s.timeout]
  end

  # Each version's Ruby: its version file's, or a path.
  def test_ruby
    assert_equal [:version_file, "/rubies/3.4/bin/ruby", nil],
      [cli("--ruby", "version-file").parse.ruby, cli("--ruby", "/rubies/3.4/bin/ruby").parse.ruby, cli.parse.ruby]
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

  # Whether the baseline is a push's: on GitHub Actions for a push, as
  # DUEL_BASE gives it.
  def test_pushed
    push = {"GITHUB_EVENT_NAME" => "push", "DUEL_BASE" => "abc123"}

    assert cli(env: push).parse.pushed
    refute cli(env: push.merge("GITHUB_EVENT_NAME" => "pull_request")).parse.pushed, "not a push"
    refute cli(env: push.slice("GITHUB_EVENT_NAME")).parse.pushed, "no DUEL_BASE"
    refute cli("--base", "abc123", env: push.slice("GITHUB_EVENT_NAME")).parse.pushed, "--base"
    refute cli("--base", "def456", env: push).parse.pushed, "--base over DUEL_BASE"
    refute cli(env: push.slice("DUEL_BASE")).parse.pushed, "no event"
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

  def test_the_environment
    env = {"DUEL_BASE" => "v1", "DUEL_FILTER" => "run", "DUEL_FORCE" => "1"}
    s = cli(env: env).parse

    assert_equal ["v1", /run/, true], [s.base, s.filter, s.force]
    assert_equal 3, cli(env: {"DUEL_PROCESSES" => "7"}).parse.processes, "only those three"
    assert_equal "v2", cli("--base", "v2", env: env).parse.base, "options win"
    assert_nil cli(env: {"DUEL_BASE" => ""}).parse.base, "empty is unset"
  end

  def test_defaults
    s = Dir.chdir(tmpdir) { cli.parse }

    assert_equal [nil, nil, nil, //, [Etc.nprocessors / 2, 1].max, 1.02, 0.99, false, nil, 3, 60.0],
      [s.base, s.base_dir, s.candidate_dir, s.filter, s.jobs, s.limit, s.confidence, s.force, s.config_path, s.processes,
        s.timeout]
  end

  def test_finds_dot_duel_rb
    File.write(File.join(tmpdir, ".duel.rb"), "")

    assert_equal File.realpath(File.join(tmpdir, ".duel.rb")), File.realpath(Dir.chdir(tmpdir) { cli.parse.config_path })
  end

  # A run, with the runner faked: what it's given, and what its verdict
  # makes the exit status.
  def run_with(passed, *argv, dir:)
    made = []
    runner = Object.new
    runner.define_singleton_method(:run) { [:results] }
    runner.define_singleton_method(:passed?) { |results| results == [:results] && passed }
    status = stub(Duel::Runner, :new, ->(*args, **options) { (made << [*args, options]) && runner }) do
      Dir.chdir(dir) { cli(*argv, env: {"X" => "1"}).run }
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
    run_against(ref: "abc", unchanged: false, argv: ["--candidate-dir", candidate], root: File.join(tmpdir, "b").tap { |b| FileUtils.mkdir_p(b) })

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
    refute_equal File.realpath(tmpdir), tmpdir, "(reached through a symlink)"
    run_against(ref: "abc", unchanged: false, argv: ["--candidate-dir", tmpdir])

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

  def test_clean
    cleaned = []
    baseline = Object.new
    baseline.define_singleton_method(:clean) { cleaned << :clean }
    status = stub(Duel::Baseline, :new, ->(*) { baseline }) { Dir.chdir(tmpdir) { cli("--clean").run } }

    assert_equal [0, [:clean]], [status, cleaned]
    assert_equal "duel: removed tmp/duel and its baseline's worktree\n", @out.string
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

  def test_fails_when_slower_or_unable_to_compare
    _, err = capture_io { assert_raises(SystemExit) { with_status(1) { task.invoke } } }

    assert_equal "duel: slower than the baseline\n", err
    _, err = capture_io { assert_raises(SystemExit) { with_status(2) { task.invoke } } }

    assert_equal "duel: couldn't compare\n", err
  end

  def test_the_default_name
    Rake.application = Rake::Application.new
    with_status(0) { Duel::RakeTask.new }

    assert Rake::Task.task_defined?(:duel)
  end
end
