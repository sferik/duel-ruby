# frozen_string_literal: true

require_relative "test_helper"

# The report in Markdown (see Duel::Summary): written to --markdown's
# file, and added to GitHub Actions' job summary (GITHUB_STEP_SUMMARY),
# whatever the run's outcome. And as JSON (see Duel::JSONReport), to
# --json's file.
class CLISummaryTest < DuelTest
  cover "Duel::CLI*"

  def cli(*argv, env: {}) = Duel::CLI.new(argv, env: env, out: (@out = StringIO.new), err: (@err = StringIO.new))

  def markdown = File.join(tmpdir, "out", "duel.md")

  def json = File.join(tmpdir, "json", "duel.json")

  # The JSON report written.
  def written = JSON.parse(File.read(json))

  # A run against a directory, with the runner (+passed+ or not), the
  # Summary and the JSONReport faked: the Summary's arguments go in
  # @summarized, and the JSONReport's in @reported.
  def run_faked(*argv, passed: true, env: {})
    runner = Object.new
    runner.define_singleton_method(:run) { [:results] }
    runner.define_singleton_method(:passed?) { |_| passed }
    @summarized = summarized = []
    made = Object.new
    made.define_singleton_method(:markdown) { "MARKDOWN\n" }
    summary = ->(*args, **options) { (summarized << [*args, options]) && made }
    @reported = reported = []
    report = Object.new
    report.define_singleton_method(:to_h) { {"status" => "passed", "seconds" => 1.5} }
    json_report = ->(*args, **options) { (reported << [*args, options]) && report }
    base = FileUtils.mkdir_p(File.join(tmpdir, "base")).first
    stub(Duel::Runner, :new, ->(*) { runner }) do
      stub(Duel::Summary, :new, summary) do
        stub(Duel::JSONReport, :new, json_report) { Dir.chdir(tmpdir) { cli("--base", base, *argv, env: env).run } }
      end
    end
  end

  def test_json_to_a_file
    assert_equal 1, run_faked("--json", json, passed: false)
    assert_equal "{\n  \"status\": \"passed\",\n  \"seconds\": 1.5\n}\n", File.read(json), "in a directory made for it"
    assert_empty @summarized, "no Markdown made"
    runner, results, options = @reported.first

    assert_equal [:results], results
    assert_equal %i[passed? run], runner.singleton_methods.sort
    assert_equal [1, File.join(tmpdir, "base")], [options.fetch(:exit), options.fetch(:settings).base_dir]
    base = {"ref" => nil, "commit" => nil, "root" => File.join(tmpdir, "base")}

    assert_equal [base, {"commit" => nil, "uncommitted_changes" => nil, "root" => Dir.chdir(tmpdir) { Dir.pwd }}],
      options.values_at(:baseline, :candidate)
    assert_equal 0, run_faked("--json", "json/duel.json", "--markdown", markdown)
    assert_equal [0, "passed", "MARKDOWN\n"], [@reported.first.last.fetch(:exit), written.fetch("status"), File.read(markdown)],
      "relative to where it ran, and with Markdown too"
  end

  def test_markdown_to_a_file
    assert_equal 1, run_faked("--markdown", markdown, passed: false)
    assert_equal "MARKDOWN\n", File.read(markdown), "in a directory made for it"
    runner, results, options = @summarized.first

    assert_equal [:results], results
    assert_equal %i[passed? run], runner.singleton_methods.sort
    assert_equal File.join(tmpdir, "base"), options.fetch(:settings).base_dir
    assert_equal ["`#{File.join(tmpdir, "base")}`", "`#{Dir.chdir(tmpdir) { Dir.pwd }}`"], options.values_at(:baseline, :candidate),
      "directories, as code"
    assert_equal 0, run_faked("--markdown", markdown)
    assert_equal "MARKDOWN\n", File.read(markdown), "replaced"
  end

  def test_relative_to_where_it_ran
    run_faked("--markdown", "out/duel.md")

    assert_equal "MARKDOWN\n", File.read(markdown)
  end

  # On GitHub Actions, added to the job's summary (an empty variable is
  # unset).
  def test_the_job_summary
    summary = File.join(tmpdir, "summary.md")
    File.write(summary, "before\n")
    run_faked(env: {"GITHUB_STEP_SUMMARY" => summary})

    assert_equal "before\nMARKDOWN\n", File.read(summary)
    refute_path_exists markdown
    run_faked("--markdown", markdown, env: {"GITHUB_STEP_SUMMARY" => summary})

    assert_equal ["before\nMARKDOWN\nMARKDOWN\n", "MARKDOWN\n"], [File.read(summary), File.read(markdown)]
    run_faked(env: {"GITHUB_STEP_SUMMARY" => ""})

    assert_empty @summarized, "not made for nowhere"
  end

  def test_none_asked_for
    run_faked

    assert_empty @summarized
    assert_empty @reported
  end

  def git_repo
    repo = FileUtils.mkdir_p(File.join(tmpdir, "repo")).first
    FileUtils.mkdir_p(File.join(repo, "lib"))
    File.write(File.join(repo, "lib", "a.rb"), "")
    FileUtils.mkdir_p(File.join(repo, "duel"))
    File.write(File.join(repo, "duel", "a_duel.rb"), "")
    @git = ->(*args) { system("git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t", *args, out: File::NULL) }
    @git.call("init", "-q", "-b", "main")
    @git.call("add", "-A")
    @git.call("commit", "-qm", "one")
    repo
  end

  def short(repo, ref = "HEAD") = IO.popen(["git", "-C", repo, "rev-parse", "--short", ref], &:read).chomp

  # A run that has nothing to compare says so, in Markdown too: no
  # release, or nothing changed.
  def test_nothing_to_compare
    repo = git_repo
    status = Dir.chdir(repo) { cli("--base", "last-release", "--markdown", markdown, "--json", json).run }

    assert_equal 0, status
    assert_equal "### ⬜ Duel: no release to compare against\n\nno release tag (v\\*) before HEAD to compare against\n", File.read(markdown)
    assert_equal ["nothing_to_compare", "duel: no release tag (v*) before HEAD to compare against"], written.values_at("status", "message")
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    Dir.chdir(repo) { cli("--base", "HEAD^", "--markdown", markdown).run }

    assert_equal "### ⬜ Duel: nothing to compare\n\nlib, ext, duel, .duel.rb unchanged since the baseline, so there's nothing to compare " \
      "(--force to anyway)\n", File.read(markdown)
    Dir.chdir(repo) { cli("--base", "HEAD^", "--json", json, "--limit", "1.05").run }

    assert_equal ["nothing_to_compare", 0, "duel: lib, ext, duel, .duel.rb unchanged since the baseline, so there's nothing to compare (--force to anyway)",
      []], written.values_at("status", "exit", "message", "benchmarks")
    assert_in_delta 1.05, written.dig("settings", "limit")
  end

  # A run that can't compare says why, in Markdown too, but not an option
  # it doesn't know.
  def test_couldnt_compare
    repo = git_repo

    assert_equal 2, Dir.chdir(repo) { cli("--base", "nope", "--force", "--markdown", markdown).run }
    assert_match(/\A### 🔻 Duel: couldn't compare\n\ngit rev-parse nope\^\{commit\} failed: fatal: .*\n\n<details>\n<summary>The whole message<\/summary>\n\n```text\ngit rev-parse nope/,
      File.read(markdown))
    summary = File.join(tmpdir, "summary.md")

    assert_equal 2, cli("--nope", env: {"GITHUB_STEP_SUMMARY" => summary}).run
    refute_path_exists summary
    assert_equal 2, Dir.chdir(repo) { cli("--base", "nope", "--force", "--json", json).run }
    assert_equal ["error", 2], written.values_at("status", "exit")
    assert_match(/\Aduel: git rev-parse nope/, written.fetch("message"))
    FileUtils.rm_f(json)

    assert_equal 2, cli("--json", json, "--nope").run
    assert_equal 2, cli("--json", json, "--jobs", "x").run
    refute_path_exists json, "not for a command line that isn't valid"
  end

  # Whether the workflow comments, by when it does and the run's status:
  # a new comment, one only if the last it posted had another status, or
  # none.
  def test_whether_to_comment
    statuses = %w[passed failed nothing_to_compare error]
    decided = Duel::Config::COMMENTS.to_h { |mode| [mode, statuses.map { |status| Duel::CLI.comment(mode, status) }] }

    assert_equal({always: %w[post post post post], results: %w[post post change post], failures: %w[change post change post],
                  never: %w[none none none none]}, decided)
    assert_equal({"passed" => "passed", "failed" => "failed", "error" => "failed", "nothing_to_compare" => "neutral"}, Duel::CLI::MARKED)
    assert_predicate Duel::CLI::COMMENTED, :frozen?
    assert_predicate Duel::CLI::MARKED, :frozen?
  end

  # On GitHub Actions, the step's outputs say whether the workflow
  # comments, and the run's status, as --comment says, or c.comment, and
  # the JSON report says whether too.
  def test_the_step_outputs
    output = File.join(tmpdir, "output")
    File.write(output, "before=1\n")
    run_faked("--json", json, env: {"GITHUB_OUTPUT" => output})

    assert_equal "before=1\ncomment=change\nstatus=passed\n", File.read(output), "added to"
    assert_equal "change", @reported.first.last.fetch(:comment)
    File.write(output, "")
    run_faked("--comment", "always", env: {"GITHUB_OUTPUT" => output})
    run_faked(passed: false, env: {"GITHUB_OUTPUT" => output})

    assert_equal "comment=post\nstatus=passed\ncomment=post\nstatus=failed\n", File.read(output)
    File.write(File.join(tmpdir, ".duel.rb"), "Duel.configure { |c| c.comment = :never }\n")
    File.write(output, "")
    run_faked(passed: false, env: {"GITHUB_OUTPUT" => output})
    run_faked("--comment", "results", passed: false, env: {"GITHUB_OUTPUT" => output})

    assert_equal "comment=none\nstatus=failed\ncomment=post\nstatus=failed\n", File.read(output), "--comment over c.comment"
    run_faked(env: {"GITHUB_OUTPUT" => ""})

    assert_equal "comment=none\nstatus=failed\ncomment=post\nstatus=failed\n", File.read(output), "nowhere: not on GitHub Actions"
  end

  # Where only a pull request fails (c.fail_on, or --fail-on), a
  # regression on GitHub Actions outside one passes, with a warning, and
  # a push's commit gets the comment that c.comment says. Elsewhere, and
  # by default, it fails, and a push gets no comment.
  def test_failing_only_on_a_pull_request
    output = File.join(tmpdir, "output")
    outcome = lambda do |*argv, event: "push", passed: false|
      File.write(output, "")
      env = {"GITHUB_OUTPUT" => output, "GITHUB_EVENT_NAME" => event}
      [run_faked(*argv, "--json", json, passed: passed, env: env), File.read(output), @reported.first.last.fetch(:exit), @out.string.lines.grep(/warning/).join]
    end
    warning = "::warning::Duel: slower, but only a pull request fails (c.fail_on), so this push passes\n"

    assert_equal [1, "comment=none\nstatus=failed\n", 1, ""], outcome.call, "by default"
    assert_equal [0, "comment=post\nstatus=failed\n", 0, warning], outcome.call("--fail-on", "pull_requests")
    assert_equal [0, "comment=change\nstatus=passed\n", 0, ""], outcome.call("--fail-on", "pull_requests", passed: true)
    assert_equal [1, "comment=post\nstatus=failed\n", 1, ""], outcome.call("--fail-on", "pull_requests", event: "pull_request")
    assert_equal [1, "comment=post\nstatus=failed\n", 1, ""], outcome.call("--fail-on", "pull_requests", event: "pull_request_target")
    assert_equal [1, "comment=post\nstatus=failed\n", 1, ""], outcome.call("--fail-on", "pull_requests", event: "merge_group")
    assert_equal [0, "comment=post\nstatus=failed\n", 0, warning.sub("push", "schedule")],
      outcome.call("--fail-on", "pull_requests", event: "schedule")
    assert_equal [1, "comment=post\nstatus=failed\n", 1, ""], outcome.call("--fail-on", "pull_requests", event: ""),
      "not on GitHub Actions"
    outcome.call("--fail-on", "pull_requests", "--markdown", markdown)

    assert_equal "Only a pull request fails (`c.fail_on`), so this push passes.", @summarized.first.last.fetch(:note)
    File.write(File.join(tmpdir, ".duel.rb"), "Duel.configure { |c| c.fail_on = :pull_requests }\n")

    assert_equal [0, "comment=post\nstatus=failed\n", 0, warning], outcome.call, "c.fail_on"
    assert_equal [1, "comment=none\nstatus=failed\n", 1, ""], outcome.call("--fail-on", "every_run"), "--fail-on over c.fail_on"
    assert_equal({"PULL_REQUESTS" => %w[pull_request pull_request_target merge_group], "frozen" => true},
      {"PULL_REQUESTS" => Duel::CLI::PULL_REQUESTS, "frozen" => Duel::CLI::PULL_REQUESTS.frozen?})
  end

  # A pull request labeled as c.accept_label says (DUEL_LABELS) passes a
  # regression, with a warning, and a note in the report. Without the
  # setting, or the label, it fails.
  def test_accepting_a_regression_with_a_label
    outcome = lambda do |labels, env: {}|
      run_faked("--markdown", markdown, passed: false, env: {"DUEL_LABELS" => labels, "GITHUB_EVENT_NAME" => "pull_request"}.merge(env))
      [@summarized.first.last.fetch(:note), @out.string.lines.grep(/warning/).join]
    end
    accepted = ["Accepted with the `duel: accept` label.", "::warning::Duel: slower, but accepted with the duel: accept label\n"]

    assert_equal 1, run_faked("--markdown", markdown, passed: false, env: {"DUEL_LABELS" => %(["duel: accept"])}), "without c.accept_label"
    assert_nil @summarized.first.last.fetch(:note)
    assert_equal 1, run_faked(passed: false, env: {"DUEL_LABELS" => "[null]"}), "no label isn't one"
    File.write(File.join(tmpdir, ".duel.rb"), %(Duel.configure { |c| c.accept_label = "duel: accept" }\n))

    assert_equal 0, run_faked(passed: false, env: {"DUEL_LABELS" => %(["bug", "duel: accept"])})
    assert_equal accepted, outcome.call(%(["bug", "duel: accept"]))
    assert_equal accepted, outcome.call(%(["duel: accept"]), env: {"GITHUB_EVENT_NAME" => "push"}), "a push, by its pull request's"
    assert_equal 1, run_faked(passed: false, env: {"DUEL_LABELS" => %(["bug"])}), "not the label"
    assert_equal [nil, ""], outcome.call(%(["bug"]))
    assert_equal 1, run_faked(passed: false, env: {"DUEL_LABELS" => %("duel: accept")}), "not an array"
    assert_equal 1, run_faked(passed: false, env: {"DUEL_LABELS" => "[duel: accept"}), "not JSON"
    assert_equal 1, run_faked(passed: false), "no labels"
    assert_equal 0, run_faked("--markdown", markdown, env: {"DUEL_LABELS" => %(["duel: accept"])}), "passed anyway"
    assert_nil @summarized.first.last.fetch(:note)
  end

  # A push that couldn't compare fails either way, and its commit gets a
  # comment only where a regression in a push passes.
  def test_a_push_that_couldnt_compare
    repo = git_repo
    output = File.join(tmpdir, "output")
    env = {"GITHUB_OUTPUT" => output, "GITHUB_EVENT_NAME" => "push"}

    assert_equal 2, Dir.chdir(repo) { cli("--base", "nope", "--force", env: env).run }
    assert_equal "comment=none\nstatus=failed\n", File.read(output)
    File.write(output, "")

    assert_equal 2, Dir.chdir(repo) { cli("--base", "nope", "--force", "--fail-on", "pull_requests", env: env).run }
    assert_equal "comment=post\nstatus=failed\n", File.read(output)
  end

  # Nothing to compare is neutral, and couldn't compare failed, as
  # c.comment says, or by default where .duel.rb didn't load.
  def test_the_step_outputs_without_a_comparison
    repo = git_repo
    output = File.join(tmpdir, "output")
    env = {"GITHUB_OUTPUT" => output}
    Dir.chdir(repo) { cli("--base", "last-release", "--json", json, env: env).run }

    assert_equal ["comment=change\nstatus=neutral\n", "change"], [File.read(output), written.fetch("comment")]
    File.write(File.join(repo, ".duel.rb"), "Duel.configure { |c| c.comment = :results }\n")
    File.write(output, "")
    Dir.chdir(repo) { cli("--base", "nope", "--force", "--json", json, env: env).run }

    assert_equal ["comment=post\nstatus=failed\n", "post"], [File.read(output), written.fetch("comment")]
    File.write(output, "")
    Dir.chdir(repo) { cli("--base", "last-release", "--comment", "always", env: env).run }

    assert_equal "comment=post\nstatus=neutral\n", File.read(output)
    File.write(File.join(repo, ".duel.rb"), "Duel.configure { |c| c.comment = :sometimes }\n")
    File.write(output, "")

    assert_equal 2, Dir.chdir(repo) { cli("--base", "last-release", env: env).run }
    assert_equal "duel: c.comment = :sometimes: give :always, :results, :failures, :never\n", @err.string
    assert_equal "comment=post\nstatus=failed\n", File.read(output), "failed, on failures"
  end

  # The baseline: a directory, or its commit, and what named it.
  def test_the_baseline_described
    repo = git_repo
    first = short(repo)
    @git.call("tag", "v1")
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    config = Duel::Config.new(repo)
    config.main_branch = "main"
    described = lambda do |base, base_dir: nil|
      s = settings(base: base, base_dir: base_dir)
      cli.send(:described_baseline, config, s, Duel::Baseline.new(config, s))
    end

    assert_equal "`#{tmpdir}`", described.call(nil, base_dir: tmpdir)
    assert_equal "#{short(repo)} (where HEAD left `main`)", described.call(nil), "bare, so GitHub links it"
    assert_equal "#{first} (the last release, `v1`)", described.call("last-release")
    assert_equal "#{first} (`HEAD^`)", described.call("HEAD^")
    sha = IO.popen(["git", "-C", repo, "rev-parse", "HEAD^"], &:read).chomp

    assert_equal "#{first} (from --base)", described.call(sha), "a commit, by its hash"
    assert_equal "#{first} (from --base)", described.call(sha[0, 9]), "or part of it"
  end

  # On GitHub Actions, a push's baseline (DUEL_BASE) is the commit before
  # it, or where c.push_base says, the last commit Duel passed.
  def test_the_baseline_of_a_push
    repo = git_repo
    first = short(repo)
    sha = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    config = Duel::Config.new(repo)
    described = lambda do |env, *argv|
      s = Dir.chdir(repo) { cli(*argv, env: env).parse }
      cli(env: env).send(:described_baseline, config, s, Duel::Baseline.new(config, s))
    end
    push = {"GITHUB_EVENT_NAME" => "push", "DUEL_BASE" => sha, "GITHUB_REF_NAME" => "main"}

    assert_equal "#{first} (the commit before the push)", described.call(push)
    assert_equal "#{first} (from --base)", described.call(push.merge("GITHUB_EVENT_NAME" => "pull_request")), "not a push"
    assert_equal "#{first} (from --base)", described.call(push.slice("GITHUB_EVENT_NAME"), "--base", sha), "no DUEL_BASE"
    assert_equal "#{first} (from --base)", described.call(push.slice("DUEL_BASE")), "no event"
    assert_equal "#{first} (from --base)", described.call(push.merge("DUEL_BASE" => "HEAD"), "--base", sha), "--base, not DUEL_BASE"
    assert_equal "#{first} (`HEAD^`)", described.call(push.slice("GITHUB_EVENT_NAME"), "--base", "HEAD^"), "a ref, named"
    @git.call("update-ref", "refs/remotes/origin/duel/passed/main", sha)

    assert_equal "#{first} (the commit before the push)", described.call(push), "by default, not the last passed"
    config.push_base = :last_passed

    assert_equal "#{first} (the last commit Duel passed)", described.call(push.merge("DUEL_BASE" => short(repo, "HEAD")))
  end

  # On GitHub Actions, a merge queue's baseline (DUEL_BASE) is its base.
  def test_the_baseline_of_a_merge_queue
    repo = git_repo
    first = short(repo)
    sha = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    config = Duel::Config.new(repo)
    described = lambda do |env, *argv|
      s = Dir.chdir(repo) { cli(*argv, env: env).parse }
      cli(env: env).send(:described_baseline, config, s, Duel::Baseline.new(config, s))
    end
    queue = {"GITHUB_EVENT_NAME" => "merge_group", "DUEL_BASE" => sha}

    assert_equal "#{first} (the merge queue's base)", described.call(queue)
    assert_equal "#{first} (from --base)", described.call(queue.merge("GITHUB_EVENT_NAME" => "pull_request")), "not a merge queue"
    assert_equal "#{first} (from --base)", described.call(queue.slice("GITHUB_EVENT_NAME"), "--base", sha), "no DUEL_BASE"
    assert_equal "#{first} (from --base)", described.call(queue, "--base", sha[0, 9]), "--base, not DUEL_BASE"
  end

  # A push whose commit before it isn't here (a branch's first push, or
  # one that rewrote history) has nothing to compare, and isn't marked
  # passed.
  def test_a_push_with_no_commit_before_it
    repo = git_repo
    output = File.join(tmpdir, "output")
    File.write(File.join(repo, ".duel.rb"), "Duel.configure { |c| c.push_base = :last_passed }\n")
    env = {"GITHUB_OUTPUT" => output, "GITHUB_EVENT_NAME" => "push", "DUEL_BASE" => "0" * 40, "GITHUB_REF_NAME" => "main"}

    assert_equal 0, Dir.chdir(repo) { cli("--markdown", markdown, env: env).run }
    assert_equal "duel: no commit before this push to compare against\n", @out.string
    assert_includes File.read(markdown), "no commit to compare against"
    assert_equal "comment=none\nstatus=neutral\n", File.read(output)
  end

  # Where c.push_base says to compare a push with the last commit Duel
  # passed, a push that passed, or had nothing to compare, is marked
  # passed (the step output "passed"). Nothing else is.
  def test_marking_a_push_passed
    repo = git_repo
    sha = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp
    output = File.join(tmpdir, "output")
    outputs = lambda do |*argv, passed: true, env: {}|
      File.write(output, "")
      runner = Object.new
      runner.define_singleton_method(:run) { [] }
      runner.define_singleton_method(:passed?) { |_| passed }
      stub(Duel::Runner, :new, ->(*) { runner }) do
        Dir.chdir(repo) { cli(*argv, env: {"GITHUB_OUTPUT" => output, "GITHUB_EVENT_NAME" => "push", "DUEL_BASE" => sha, "GITHUB_REF_NAME" => "main"}.merge(env)).run }
      end
      File.read(output)
    end

    assert_equal "comment=none\nstatus=neutral\n", outputs.call, "by default"
    File.write(File.join(repo, ".duel.rb"), "Duel.configure { |c| c.push_base = :last_passed }\n")
    @git.call("add", "-A")
    @git.call("commit", "-qm", "two")

    assert_equal "comment=none\nstatus=passed\npassed=true\n", outputs.call
    assert_equal "comment=none\nstatus=failed\n", outputs.call(passed: false)
    File.write(File.join(repo, ".duel.rb"), %(Duel.configure { |c| c.push_base = :last_passed\n c.accept_label = "ok" }\n))
    @git.call("commit", "-qam", "three")

    assert_equal "comment=none\nstatus=failed\npassed=true\n", outputs.call(passed: false, env: {"DUEL_LABELS" => %(["ok"])}),
      "accepted: marked passed"
    assert_equal "comment=none\nstatus=neutral\npassed=true\n", outputs.call(env: {"DUEL_BASE" => short(repo, "HEAD")}),
      "nothing to compare"
    assert_equal "comment=change\nstatus=passed\n", outputs.call(env: {"GITHUB_EVENT_NAME" => "pull_request"}), "not a push"
  end

  # The baseline, for JSON: a directory, or the ref that named it and its
  # commit.
  def test_the_baseline_for_json
    repo = git_repo
    first = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp
    @git.call("tag", "v1")
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    config = Duel::Config.new(repo)
    config.main_branch = "main"
    described = lambda do |base, base_dir: nil|
      s = settings(base: base, base_dir: base_dir)
      cli.send(:baseline_json, config, s, Duel::Baseline.new(config, s), "base/../root")
    end
    root = File.expand_path("root")
    head = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp

    assert_equal({"ref" => nil, "commit" => nil, "root" => root}, described.call(nil, base_dir: tmpdir))
    assert_equal({"ref" => "main", "commit" => head, "root" => root}, described.call(nil))
    assert_equal({"ref" => "v1", "commit" => first, "root" => root}, described.call("last-release"))
    assert_equal({"ref" => "HEAD^", "commit" => first, "root" => root}, described.call("HEAD^"))
    @git.call("update-ref", "refs/remotes/origin/duel/passed/main", first)
    config.push_base = :last_passed
    s = settings(base: head, pushed: "main")

    assert_equal({"ref" => "origin/duel/passed/main", "commit" => first, "root" => root},
      cli.send(:baseline_json, config, s, Duel::Baseline.new(config, s), "base/../root"), "the last commit Duel passed")
  end

  # The candidate, for JSON: its commit, whether what's watched changed
  # since, and its tree.
  def test_the_candidate_for_json
    repo = git_repo
    config = Duel::Config.new(repo)
    described = ->(**overrides) { cli.send(:candidate_json, config, settings(**overrides)) }

    File.write(File.join(repo, "notes.txt"), "x")
    @git.call("add", "notes.txt")
    @git.call("commit", "-qm", "notes")
    head = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).chomp

    assert_equal({"commit" => head, "uncommitted_changes" => false, "root" => repo}, described.call)
    File.write(File.join(repo, "notes.txt"), "y")

    assert_equal({"commit" => head, "uncommitted_changes" => false, "root" => repo}, described.call, "only what's watched")
    File.write(File.join(repo, "duel", "a_duel.rb"), "x")

    assert_equal({"commit" => head, "uncommitted_changes" => true, "root" => repo}, described.call, "the benchmarks too")
    @git.call("checkout", "-q", "--", "duel")
    File.write(File.join(repo, "lib", "a.rb"), "x")
    @git.call("add", "-A")

    assert_equal({"commit" => head, "uncommitted_changes" => true, "root" => repo}, described.call, "staged too")
    other = FileUtils.mkdir_p(File.join(tmpdir, "other")).first

    assert_equal({"commit" => nil, "uncommitted_changes" => nil, "root" => File.join(Dir.chdir(tmpdir) { Dir.pwd }, "other")},
      Dir.chdir(other) { described.call(candidate_dir: ".") }, "resolved")
  end

  # The candidate: its commit, and whether what's watched changed since,
  # or its directory, outside a repository.
  def test_the_candidate_described
    repo = git_repo
    config = Duel::Config.new(repo)
    described = ->(**overrides) { cli.send(:described_candidate, config, settings(**overrides)) }

    assert_equal short(repo), described.call, "bare, so GitHub links it"
    File.write(File.join(repo, "notes.txt"), "x")
    @git.call("add", "notes.txt")
    @git.call("commit", "-qm", "notes")
    File.write(File.join(repo, "notes.txt"), "y")

    assert_equal short(repo), described.call, "only what's watched"
    File.write(File.join(repo, "duel", "a_duel.rb"), "x")

    assert_equal "#{short(repo)} (with changes not committed)", described.call, "the benchmarks too"
    @git.call("checkout", "-q", "--", "duel")
    File.write(File.join(repo, "lib", "a.rb"), "x")
    @git.call("add", "-A")

    assert_equal "#{short(repo)} (with changes not committed)", described.call, "staged too"
    other = FileUtils.mkdir_p(File.join(tmpdir, "other")).first

    assert_equal "`#{other}`", described.call(candidate_dir: other)
  end

  # A comparison with a commit: the Summary's given both described.
  def test_a_comparison_with_a_commit
    repo = git_repo
    first = short(repo)
    @git.call("commit", "-q", "--allow-empty", "-m", "two")
    runner = Object.new
    runner.define_singleton_method(:run) { [] }
    runner.define_singleton_method(:passed?) { |_| true }
    made = Object.new
    made.define_singleton_method(:markdown) { "MARKDOWN\n" }
    made.define_singleton_method(:to_h) { {} }
    summarized = []
    reported = []
    status = stub(Duel::Runner, :new, ->(*) { runner }) do
      stub(Duel::Summary, :new, ->(*, **options) { (summarized << options) && made }) do
        stub(Duel::JSONReport, :new, ->(*, **options) { (reported << options) && made }) do
          Dir.chdir(repo) { cli("--base", "HEAD^", "--force", "--markdown", markdown, "--json", json).run }
        end
      end
    end

    assert_equal 0, status
    assert_equal ["#{first} (`HEAD^`)", short(repo)], summarized.first.values_at(:baseline, :candidate)
    sha = ->(ref) { IO.popen(["git", "-C", repo, "rev-parse", ref], &:read).chomp }

    assert_equal [{"ref" => "HEAD^", "commit" => sha.call("HEAD^")}, sha.call("HEAD")],
      [reported.first.fetch(:baseline).slice("ref", "commit"), reported.first.fetch(:candidate).fetch("commit")]
  ensure
    Dir.chdir(repo) { Duel::Baseline.new(Duel::Config.new(repo), settings).clean } if repo
  end

  def test_init
    made = []
    init = Object.new
    init.define_singleton_method(:run) { 7 }
    status = stub(Duel::Init, :new, ->(*args, **options) { (made << [*args, options]) && init }) { cli("init", "--force").run }

    assert_equal [7, [["--force"], {out: @out, err: @err}]], [status, made.first]
  end
end
