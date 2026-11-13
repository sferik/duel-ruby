# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "yaml"

# `duel init`, in a project of the test's own.
class InitTest < DuelTest
  cover "Duel::Init*"

  def root = @root ||= FileUtils.mkdir_p(File.join(tmpdir, "my_gem")).first

  def init(*argv, at: root, input: StringIO.new) = Duel::Init.new(argv, out: (@out = StringIO.new), err: (@err = StringIO.new), input: input, root: at)

  def read(path) = File.read(File.join(root, path))

  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), content)
  end

  # A gem: its gemspec names the library.
  def gem
    write("my_gem.gemspec", %(Gem::Specification.new { |s| s.name = "my_gem" }\n))
    write("lib/my_gem.rb")
    write("Gemfile", %(source "https://rubygems.org"\ngemspec\ngem "duel"\n))
  end

  # A .duel.rb that asks for the workflow's jobs for pushes: a comment on
  # a pushed commit (c.fail_on = :pull_requests), and the last commit Duel
  # passed marked (c.push_base = :last_passed).
  PUSH_SETTINGS = "Duel.configure do |c|\n  c.fail_on = :pull_requests\n  c.push_base = :last_passed\nend\n"

  def push_settings(at: root) = File.write(File.join(at, ".duel.rb"), PUSH_SETTINGS)

  def ruby_version = RUBY_VERSION[/\A\d+\.\d+/]

  # How .duel.rb ends: when the workflow comments, which runs a regression
  # fails, the label that accepts one (set), and what a push is compared
  # with, the defaults shown.
  ENDING = "\n  # When the workflow comments on a pull request with the report: :always,\n" \
    "  # :results (passed or failed), :failures (failed, or couldn't compare),\n  # or :never.\n  # c.comment = :failures\n" \
    "\n  # Which runs a regression fails: :every_run, or :pull_requests, for a\n" \
    "  # project where people push to main directly (on GitHub Actions, another\n" \
    "  # run warns and passes, and a pushed commit gets the comment instead,\n" \
    "  # from a workflow job written only where this is set: see docs/ci.md).\n  # c.fail_on = :every_run\n" \
    "\n  # A label that accepts a regression in a pull request, for a change\n  # that's slower on purpose (nil for none).\n  c.accept_label = \"duel: accept\"\n" \
    "\n  # What the workflow compares a push with: :before (the commit before it),\n" \
    "  # or :last_passed (the last commit Duel passed, which a branch,\n" \
    "  # duel/passed/main, marks), so small slowdowns add up until they fail.\n" \
    "  # (A workflow job moves the branch, written only where this is set: see\n  # docs/ci.md.)\n  # c.push_base = :before\nend\n"

  def test_a_gem
    gem
    write("config/settings.yml")

    assert_equal 0, init.run
    assert_equal <<~OUT, @out.string
        create    .duel.rb
        create    duel/my_gem_duel.rb
        create    .github/workflows/perf.yml
        create    .github/workflows/perf-comment.yml
        append    Gemfile (gem "stackprof", platforms: :mri)

      Next:
        1. Run `bundle install`, for StackProf (added to the Gemfile).
        2. Replace the example in duel/my_gem_duel.rb with benchmarks of your own code.
        3. Create the label "duel: accept" in your repository, so a pull request can accept a regression (c.accept_label).
        4. Run `bundle exec duel --force`. It compares the code with itself, and passes when the benchmarks are sound.
        5. Commit and push. On a pull request, the workflow compares the code with the branch it targets, and comments with the report when a benchmark fails (c.comment in .duel.rb says when).
    OUT
    assert_empty @err.string
    assert_includes read(".duel.rb"), <<~RUBY
      Duel.configure do |c|
        # The library each version's workers require (from the gemspec, unless
        # this says otherwise).
        # c.library = "my_gem"
    RUBY
    assert read(".duel.rb").end_with?(%(  # c.library = "my_gem"\n#{ENDING}))
    assert_equal "duel: accept", Duel.load_config(File.join(root, ".duel.rb")).accept_label
    assert_includes read("duel/my_gem_duel.rb"), "fails if the candidate is slower at any of them. Each version's workers\n" \
      "# load my_gem and every duel/**/*_duel.rb file. See\n"
    assert_includes read("duel/my_gem_duel.rb"), %(\nduel "example: join words" do\n)
    workflow = read(".github/workflows/perf.yml")

    assert_includes workflow, "        with:\n          ruby-version: \"#{ruby_version}\"\n          bundler-cache: true\n"
    refute_includes workflow, "baseline-ruby"
    refute_includes workflow, "working-directory"
    refute_includes workflow, "marker="
    assert_includes read(".github/workflows/perf-comment.yml"), %(--marker 'duel'\n), "the comment workflow's"
    jobs = YAML.safe_load(workflow).fetch("jobs")
    steps = ->(job) { jobs.dig(job, "steps").map { |step| step["name"]&.split&.first || step.fetch("uses")[%r{/([\w-]+)@}, 1] } }

    assert_equal %w[duel], jobs.keys, "none for pushes, which the defaults don't comment on or mark passed, and no badge without --badge"
    assert_equal %w[checkout Find setup-ruby Compare Say Keep], steps.call("duel")
  end

  # The jobs for pushes, where .duel.rb asks for them: a comment on a
  # pushed commit, and the last commit Duel passed marked.
  def test_the_jobs_for_pushes
    gem
    push_settings
    init.run
    workflow = read(".github/workflows/perf.yml")
    jobs = YAML.safe_load(workflow).fetch("jobs")

    assert_equal %w[duel commit-comment passed], jobs.keys
    assert_equal [%w[Get Comment], %w[Move]], %w[commit-comment passed].map { |job| jobs.dig(job, "steps").map { |step| step.fetch("name").split.first } }
    assert_equal 1, workflow.scan(%(marker="<!-- duel"\n)).size, "the Comment on the commit job's"
    assert_includes read(".github/workflows/perf-comment.yml"), %(--marker 'duel'\n), "the comment workflow's"
  end

  # Each job for pushes, alone, where .duel.rb asks for only it.
  def test_one_job_for_pushes
    gem
    write(".duel.rb", "Duel.configure { |c| c.fail_on = :pull_requests }\n")
    init.run

    assert_equal %w[duel commit-comment], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys
    write(".duel.rb", "Duel.configure { |c| c.push_base = :last_passed }\n")
    init("--force").run

    assert_equal %w[duel], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys,
      "--force writes .duel.rb anew, with the defaults"
    write(".duel.rb", "Duel.configure { |c| c.push_base = :last_passed }\n")
    FileUtils.rm(File.join(root, ".github/workflows/perf.yml"))
    init.run

    assert_equal %w[duel passed], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys
  end

  # A .duel.rb that doesn't load (one of its plugins isn't installed, say)
  # leaves the workflow every job, and says so.
  def test_a_config_that_doesnt_load
    gem
    write(".duel.rb", %(Duel.configure { |c| c.use :not_a_plugin }\n))
    init.run

    assert_equal %w[duel commit-comment passed], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys, "no badge, which isn't .duel.rb's to say"
    assert_equal "duel init: .duel.rb didn't load (Duel::Error: c.use :not_a_plugin: no duel/not_a_plugin to require: add the " \
      "duel-not_a_plugin gem to the Gemfile), so the workflow has both jobs for pushes, as if it asked for them\n", @err.string
  end

  # The job that runs the branch's code (its benchmarks too) only reads,
  # and keeps the report, with what Duel said about commenting on a pull
  # request, for the Perf comment workflow.
  def test_the_workflows_permissions
    gem
    init.run
    workflow = YAML.safe_load(read(".github/workflows/perf.yml"))
    duel = workflow.dig("jobs", "duel")
    said = duel.fetch("steps").find { |step| step["name"] == "Say whether to comment" }

    assert_equal({"contents" => "read", "pull-requests" => "read"}, workflow.fetch("permissions"))
    refute duel.key?("permissions")
    assert_equal({"fetch-depth" => 0, "persist-credentials" => false}, duel.fetch("steps").first.fetch("with"))
    assert_equal({"name" => "duel-report", "path" => "${{ runner.temp }}/duel/", "if-no-files-found" => "ignore", "retention-days" => 1},
      duel.fetch("steps").last.fetch("with"))
    assert_equal({"comment" => "${{ steps.compare.outputs.comment }}", "status" => "${{ steps.compare.outputs.status }}",
                  "passed" => "${{ steps.compare.outputs.passed }}"}, duel.fetch("outputs"))
    assert_equal "compare", duel.fetch("steps").find { |step| step["name"] == "Compare" }.fetch("id")
    assert_equal "bundle exec duel --markdown \"$RUNNER_TEMP/duel/duel.md\"", duel.fetch("steps").find { |step| step["name"] == "Compare" }.fetch("run")
    assert_equal ["${{ !cancelled() && github.event_name == 'pull_request' }}", {"PR" => "${{ github.event.pull_request.number }}",
                                                                                 "COMMENT" => "${{ steps.compare.outputs.comment }}", "STATUS" => "${{ steps.compare.outputs.status }}"}], said.values_at("if", "env")
    env = {"PR" => "12", "COMMENT" => "post", "STATUS" => "failed", "RUNNER_TEMP" => tmpdir}

    assert system(env, "bash", "-ec", said.fetch("run"))
    assert_equal "pr=12\ncomment=post\nstatus=failed\n", File.read(File.join(tmpdir, "duel", "comment.env"))
  end

  # A pull request's newer push cancels its run, and every other run runs
  # to the end, in a group of its own.
  def test_concurrency
    gem
    init.run

    assert_equal({"group" => "${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id }}",
                  "cancel-in-progress" => "${{ github.event_name == 'pull_request' }}"},
      YAML.safe_load(read(".github/workflows/perf.yml")).fetch("concurrency"))
  end

  # The Perf comment workflow comments on a pull request (a fork's too)
  # once Perf has run, with a token that can write, so it runs none of
  # the pull request's code: only `duel comment`, from RubyGems, which
  # decides what to post (see CommentTest).
  def test_the_comment_workflow
    gem
    init.run
    workflow = YAML.safe_load(read(".github/workflows/perf-comment.yml"))
    comment = workflow.dig("jobs", "comment")
    get, ruby, post = comment.fetch("steps")

    assert_equal [{"workflows" => ["Perf"], "types" => ["completed"]}, {}], [workflow.dig(true, "workflow_run"), workflow.fetch("permissions")]
    assert_equal "${{ github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion != 'cancelled' }}",
      comment.fetch("if")
    assert_equal({"actions" => "read", "pull-requests" => "write"}, comment.fetch("permissions"))
    assert_equal({"name" => "duel-report", "path" => "${{ runner.temp }}/report", "run-id" => "${{ github.event.workflow_run.id }}",
                  "github-token" => "${{ github.token }}"}, get.fetch("with"))
    assert_equal ["ruby/setup-ruby@v1", {"ruby-version" => "ruby"}], ruby.values_at("uses", "with")
    assert_equal ["steps.report.outcome == 'success'"] * 2, [ruby, post].map { |step| step.fetch("if") }
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "HEAD_SHA" => "${{ github.event.workflow_run.head_sha }}"}, post.fetch("env"))
    assert_equal "gem install duel --version '~> 0.1.8' --no-document\n" \
      "duel comment --report \"$RUNNER_TEMP/report\" --head \"$HEAD_SHA\" --marker 'duel'\n", post.fetch("run")
    refute_includes comment.to_s, "checkout"
    refute_includes comment.to_s, "bundle"
  end

  # A marker with a quote in it is quoted for the shell.
  def test_the_comment_workflows_marker_quoted
    gem
    init.run
    init = self.init

    init.define_singleton_method(:marker) { "duel it's" }
    text = init.send(:render, "perf-comment.yml")

    assert_equal "duel it's", IO.popen(["bash", "-c", "printf %s #{text[/--marker (.*)$/, 1]}"], &:read)
  end

  # Duel gets the labels of a pull request, or of the one that merged a
  # push, for c.accept_label, and nothing's accepted without them.
  def test_the_pull_requests_labels
    gem
    init.run
    steps = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps")
    labels = steps.find { |step| step["id"] == "labels" }

    assert_equal "${{ steps.labels.outputs.labels }}", steps.find { |step| step["name"] == "Compare" }.dig("env", "DUEL_LABELS")
    assert_equal ["github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.event_name == 'push' || " \
                  "github.event_name == 'schedule'", true],
      labels.values_at("if", "continue-on-error")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "PR" => "${{ github.event.pull_request.number }}",
                  "QUEUED" => "${{ github.event.merge_group.head_ref }}", "ACCEPT_LABEL" => "duel: accept", "RELEASE_TAGS" => "v*"},
      labels.fetch("env"))
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/issues/$PR/labels" --jq '[.[].name]')
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '[.[0].labels[]?.name]')
  end

  # On a schedule, the labels step finds the last commit since the last
  # release that merged a pull request with the label, with gh stubbed to
  # list the commits that merged one (+merged+), in a repository where
  # v1 is the release, and +accepted+ and HEAD came after it: the commit,
  # for the Compare step, or nothing.
  def accepted_since_the_release(merged)
    @root = FileUtils.mkdir_p(File.join(tmpdir, "my_gem", "run#{@runs = (@runs || 0) + 1}")).first
    gem
    init.run
    step = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps").find { |s| s["id"] == "labels" }
    git = ->(*args) { IO.popen(["git", "-C", root, *args], &:read).chomp }
    git.call("init", "-q", "-b", "main")
    commit = ->(message) { git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message) }
    commit.call("one")
    git.call("tag", "v1")
    commit.call("accepted")
    accepted = git.call("rev-parse", "HEAD")
    commit.call("three")
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    File.write(File.join(bin, "gh"), %(#!/bin/bash\necho "$*" > #{tmpdir}/gh-args\nprintf '%s\\n' #{merged.call(accepted).join(" ")}\n))
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    output = File.join(tmpdir, "output")
    File.write(output, "")
    env = step.fetch("env").merge("PATH" => "#{bin}:#{ENV.fetch("PATH")}", "GITHUB_EVENT_NAME" => "schedule", "GITHUB_OUTPUT" => output,
      "GITHUB_REPOSITORY" => "me/my_gem")

    assert system(env, "bash", "-ec", step.fetch("run"), chdir: root)
    [File.read(output), accepted, File.read(File.join(tmpdir, "gh-args"))]
  end

  def test_what_was_accepted_since_the_last_release
    found, accepted, args = accepted_since_the_release(->(commit) { ["0" * 40, commit] })

    assert_equal "accepted=#{accepted}\n", found
    assert_match(/\Apr list --repo me\/my_gem --state merged --label duel: accept --search merged:>=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ /, args)
    assert_equal "accepted=\n", accepted_since_the_release(->(_) { ["0" * 40] }).first, "none merged since the release"
    assert_equal "accepted=\n", accepted_since_the_release(->(_) { [] }).first, "none at all"
  end

  # Without a label that accepts a regression, the workflows look for
  # none: no schedule's accepted change, and no second run for the label.
  def test_no_label_that_accepts_a_regression
    gem
    write(".duel.rb", "Duel.configure { |c| c.accept_label = nil }\n")
    init.run
    perf = read(".github/workflows/perf.yml")
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))

    refute_includes perf, "outputs.accepted"
    refute_includes perf, "ACCEPT_LABEL"
    assert_equal %w[workflow_run], comment.fetch(true).keys
    assert_equal %w[comment], comment.fetch("jobs").keys
  end

  # Whether the comment workflow runs the Duel job again, and how, when
  # the label is +action+ (labeled or unlabeled) on a pull request whose
  # head's Perf run (7, or none with +run+ nil) ended as +conclusion+:
  # the gh run rerun it asks for, or nil.
  def again(action, conclusion, run: "7")
    gem
    init.run
    job = YAML.safe_load(read(".github/workflows/perf-comment.yml")).dig("jobs", "again")
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    File.write(File.join(bin, "gh"), <<~SH)
      #!/bin/bash
      case "$1 $2" in
        "run list") echo "$*" > #{tmpdir}/list; echo "#{run}" ;;
        "run watch") ;;
        "run view") echo "#{conclusion}" ;;
        "run rerun") echo "$*" > #{tmpdir}/rerun ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    step = job.dig("steps", 0)
    env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "HEAD_SHA" => "abc", "ACTION" => action}

    assert system(env, "bash", "-ec", step.fetch("run"))
    rerun = File.join(tmpdir, "rerun")
    File.read(rerun).chomp.tap { File.delete(rerun) } if File.exist?(rerun)
  end

  # Adding the label runs the Duel job again where it failed, and taking
  # it off does where it passed (maybe only for the label), as the job
  # reads the labels as it runs. The comment workflow does it, as it runs
  # none of the pull request's code: a pull request's own workflow can't
  # run one again from a fork.
  def test_running_duel_again_for_the_label
    gem
    init.run
    workflow = YAML.safe_load(read(".github/workflows/perf-comment.yml"))
    job = workflow.dig("jobs", "again")

    assert_equal({"types" => %w[labeled unlabeled]}, workflow.dig(true, "pull_request_target"))
    assert_equal "github.event_name == 'pull_request_target' && github.event.label.name == 'duel: accept'", job.fetch("if")
    assert_equal({"actions" => "write"}, job.fetch("permissions"))
    refute(job.fetch("steps").any? { |step| step.key?("uses") }, "it checks nothing out")
    assert_equal "run rerun 7 --failed", again("labeled", "failure")
    assert_includes File.read(File.join(tmpdir, "list")), %(--workflow Perf --event pull_request --commit abc --limit 1)
    assert_nil again("labeled", "success")
    assert_equal "run rerun 7", again("unlabeled", "success")
    assert_nil again("unlabeled", "failure")
    assert_nil again("labeled", "failure", run: ""), "no run yet"
  end

  # A label with a quote in it is quoted in each workflow.
  def test_a_label_with_a_quote
    gem
    write(".duel.rb", %(Duel.configure { |c| c.accept_label = "it's fine" }\n))
    init.run
    labels = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps").find { |step| step["id"] == "labels" }

    assert_equal "it's fine", labels.dig("env", "ACCEPT_LABEL")
    assert_includes YAML.safe_load(read(".github/workflows/perf-comment.yml")).dig("jobs", "again", "if"), "== 'it''s fine'"
  end

  # A merge queue's run is compared with its base, as a pull request
  # (whose labels are the last one's queued).
  def test_a_merge_queue
    gem
    write(".ruby-version", "3.4.1\n")
    init.run
    workflow = YAML.safe_load(read(".github/workflows/perf.yml"))
    steps = workflow.dig("jobs", "duel", "steps")
    labels = steps.find { |step| step["id"] == "labels" }.fetch("run")

    assert workflow.fetch(true).key?("merge_group"), "on: a merge queue's too"
    assert_includes steps.find { |step| step["name"] == "Compare" }.dig("env", "DUEL_BASE"),
      "github.event_name == 'merge_group' && github.event.merge_group.base_sha"
    assert_includes steps.find { |step| step["id"] == "baseline" }.fetch("run"), "merge_group) base=$QUEUE_BASE ;;\n"
    assert_equal "${{ github.event.merge_group.base_sha }}", steps.find { |step| step["id"] == "baseline" }.dig("env", "QUEUE_BASE")
    script = "QUEUED=refs/heads/gh-readonly-queue/main/pr-123-0123abcd\n#{labels[/if \[ -n "\$QUEUED" \].*?\nfi\n/m]}echo $PR"

    assert_equal "123\n", IO.popen(["bash", "-c", script], &:read), "the pull request, from the queue's branch"
  end

  # A push that Duel says passed (only where c.push_base compares a push
  # with the last commit Duel passed) is marked passed, by a job of its
  # own that moves the branch (or makes it), and runs none of the code.
  def test_marking_a_push_passed
    gem
    push_settings
    init.run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    passed = jobs.fetch("passed")
    step = passed.dig("steps", 0)

    assert_equal "${{ steps.compare.outputs.passed }}", jobs.dig("duel", "outputs", "passed")
    assert_equal ["duel", {"contents" => "write"}, "Mark the commit passed"], passed.values_at("needs", "permissions", "name")
    assert_equal({"group" => "${{ github.workflow }}-passed-${{ github.ref_name }}", "cancel-in-progress" => false}, passed.fetch("concurrency"),
      "one at a time for each branch")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed == 'true' }}", passed.fetch("if")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "BRANCH" => "duel/passed/${{ github.ref_name }}"}, step.fetch("env"))
    assert_equal "bundle exec duel --markdown \"$RUNNER_TEMP/duel/duel.md\"", jobs.dig("duel", "steps").find { |s| s["name"] == "Compare" }.fetch("run"),
      "Duel says when there's no commit before a push"
    assert_equal 1, passed.fetch("steps").size
  end

  # What the step that marks a push passed asks gh, with gh stubbed: for
  # a push (abc) whose fast-forward GitHub refuses (+refused+), where the
  # branch is +at+ (nil, missing), and compared with the push +compared+
  # (or not, where gh fails with +compare_error+). A branch named +blocker+
  # keeps it from making the branch. Where +made+, something else made the
  # branch first, there (+ahead+ of the push, or not), so making it fails.
  def passed_run(refused: false, at: nil, compared: nil, compare_error: nil, blocker: nil, made: nil, ahead: false, success: true)
    gem
    push_settings
    init.run
    run = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "passed", "steps", 0, "run")
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    log = File.join(tmpdir, "log").tap { |path| File.write(path, "") }
    FileUtils.rm_f(File.join(tmpdir, "made"))
    File.write(File.join(bin, "gh"), <<~SH)
      #!/bin/bash
      echo "gh $*" >> #{log}
      case "$*" in
        *"force=true"*) ;;
        *"--method PATCH"*) if [ -f "$MADE_IT" ]; then [ -z "$AHEAD" ]; else [ -z "$REFUSED" ]; fi ;;
        *"--method POST"*) if [ -n "$MADE" ]; then touch "$MADE_IT" && exit 1; fi; [ -z "$BLOCKER" ] ;;
        *"/git/ref/heads/"*"--jq"*) if [ -f "$MADE_IT" ]; then echo "$MADE"; elif [ -n "$AT" ]; then echo "$AT"; else exit 1; fi ;;
        *"/git/ref/heads/"*) [ "${2##*/git/ref/heads/}" = "$BLOCKER" ] ;;
        *"/compare/"*) [ -z "$COMPARE_ERROR" ] || { echo "$COMPARE_ERROR" >&2; exit 1; }; echo "$COMPARED" ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "GITHUB_REPOSITORY" => "me/my_gem", "GITHUB_SHA" => "abc", "BRANCH" => "duel/passed/main",
           "REFUSED" => (refused ? "1" : nil), "AT" => at, "COMPARED" => compared, "COMPARE_ERROR" => compare_error,
           "BLOCKER" => blocker, "MADE" => made, "AHEAD" => (ahead ? "1" : nil), "MADE_IT" => File.join(tmpdir, "made")}

    assert_equal success, system(env, "bash", "-ec", run, out: (@said = File.join(tmpdir, "said")))
    File.readlines(log, chomp: true).map { |call| call.delete_prefix("gh api ").sub("repos/me/my_gem/", "") }
  end

  def test_marking_a_push_passed_moves_the_branch_forward
    assert_equal ["--method PATCH git/refs/heads/duel/passed/main -f sha=abc"], passed_run, "no force"
  end

  def test_marking_a_push_passed_makes_the_branch
    assert_equal ["--method PATCH git/refs/heads/duel/passed/main -f sha=abc", "git/ref/heads/duel/passed/main --jq .object.sha",
      "--method POST git/refs -f ref=refs/heads/duel/passed/main -f sha=abc"], passed_run(refused: true)
  end

  # A run that finishes after a newer push's (or this push's, run again)
  # leaves the branch where that one moved it, never back.
  def test_marking_a_push_passed_after_a_newer_one
    %w[ahead identical].each do |compared|
      calls = passed_run(refused: true, at: "def", compared: compared)

      assert_equal "compare/abc...def --jq .status", calls.last, compared
      assert_empty calls.grep(/force|POST/), compared
    end
  end

  # Where history was rewritten (a force push), it's moved anyway.
  def test_marking_a_push_passed_after_a_rewrite
    %w[diverged behind].each do |compared|
      assert_equal "--method PATCH git/refs/heads/duel/passed/main -f sha=abc -F force=true",
        passed_run(refused: true, at: "def", compared: compared).last, compared
    end
  end

  # Where history was replaced, GitHub can't compare the commits (they
  # have no history in common), and it's moved anyway.
  def test_marking_a_push_passed_after_history_was_replaced
    assert_equal "--method PATCH git/refs/heads/duel/passed/main -f sha=abc -F force=true",
      passed_run(refused: true, at: "def", compare_error: "gh: No common ancestor between abc and def. (HTTP 404)").last
  end

  # A branch whose name is a folder of the branch's keeps it from being
  # made (Git can't have both), and the error names that branch.
  def test_marking_a_push_passed_where_a_branch_blocks_it
    %w[duel duel/passed].each do |blocker|
      calls = passed_run(refused: true, blocker: blocker, success: false)

      assert_equal ["git/ref/heads/duel/passed", "git/ref/heads/duel"], calls.last(2), blocker
      assert_equal "::error::The branch #{blocker} keeps Duel from making duel/passed/main, as Git can't have both. " \
        "Delete it (git push origin --delete #{blocker}), or rename it.\n", File.read(@said), blocker
    end
  end

  # Where making the branch fails as something else made it first (a
  # push of it, say), it moves it forward from there, or leaves it where
  # that's ahead of the push.
  def test_marking_a_push_passed_where_something_else_made_the_branch
    make = ["--method PATCH git/refs/heads/duel/passed/main -f sha=abc", "git/ref/heads/duel/passed/main --jq .object.sha",
      "--method POST git/refs -f ref=refs/heads/duel/passed/main -f sha=abc"]

    assert_equal [*make, make.first], passed_run(refused: true, made: "old"), "forward from there"
    calls = passed_run(refused: true, made: "def", ahead: true, compared: "ahead")

    assert_equal [*make, *make.first(2), "compare/abc...def --jq .status"], calls, "left ahead"
    assert_empty File.read(@said)
  end

  def test_marking_a_push_passed_without_a_comparison
    assert_equal "compare/abc...def --jq .status", passed_run(refused: true, at: "def", compared: "", success: false).last
  end

  # Where gh fails to compare them otherwise, the error says why.
  def test_marking_a_push_passed_where_the_comparison_fails
    assert_equal "compare/abc...def --jq .status",
      passed_run(refused: true, at: "def", compare_error: "gh: Server Error (HTTP 500)", success: false).last
    assert_equal "::error::Couldn't compare duel/passed/main with this push: gh: Server Error (HTTP 500)\n", File.read(@said)
  end

  # With --badge, a push to the default branch that Duel compared updates
  # the badge, by a job of its own that writes it to a branch, and runs none of the
  # code: red where Duel failed the push or found a regression, and grey
  # where the Duel job failed before Duel said.
  def test_the_badge
    gem
    init("--badge").run
    badge = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "badge")
    step = badge.dig("steps", 0)

    assert_equal ["duel", {"contents" => "write"}, "Update the badge"], badge.values_at("needs", "permissions", "name")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && github.ref_name == github.event.repository.default_branch && " \
      "(needs.duel.result == 'failure' || needs.duel.outputs.status == 'passed' || needs.duel.outputs.status == 'failed') }}", badge.fetch("if")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "BRANCH" => "duel/badge", "RESULT" => "${{ needs.duel.result }}",
                  "STATUS" => "${{ needs.duel.outputs.status }}"},
      step.fetch("env"))
    refute badge.key?("defaults"), "nothing checked out"
    assert_equal 1, badge.fetch("steps").size
    assert_equal({"group" => "${{ github.workflow }}-badge", "cancel-in-progress" => false}, badge.fetch("concurrency"),
      "one at a time, so an older push's run can't write over a newer one's")
  end

  # The badge's script, with gh stubbed, and a curl that fails: [what it
  # ran (gh's calls, and curl's, if any), the tree it made, or nil] for a
  # run with +env+.
  def badge_run(env)
    gem
    init("--badge").run
    run = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "badge", "steps", 0, "run")
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    log = File.join(tmpdir, "log").tap { |path| File.write(path, "") }
    tree = File.join(tmpdir, "tree.json")
    File.write(File.join(bin, "gh"), <<~SH)
      #!/bin/bash
      echo "gh $*" >> #{log}
      case "$*" in
        *"/commits/duel/badge --jq .commit.message") [ -n "$LAST" ] && echo "$LAST" || { echo '{"message":"Not Found"}'; exit 1; } ;;
        *"/compare/"*) echo "$COMPARED" ;;
        *"git/trees"*) cat > #{tree}; echo tree1 ;;
        *"git/commits"*) echo commit1 ;;
        *"--method PATCH"*) [ -z "$NO_BRANCH" ] ;;
      esac
    SH
    File.write(File.join(bin, "curl"), %(#!/bin/bash\necho "curl $*" >> #{log}\nexit 1\n))
    FileUtils.chmod(0o755, Dir[File.join(bin, "*")])
    env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "RUNNER_TEMP" => tmpdir, "GITHUB_REPOSITORY" => "me/my_gem", "GITHUB_REF_NAME" => "main",
           "GITHUB_SHA" => "abc", "BRANCH" => "duel/badge", "LAST" => nil, "COMPARED" => nil,
           "NO_BRANCH" => nil}.merge(env)

    assert system(env, "bash", "-ec", run)
    calls = File.exist?(log) ? File.readlines(log, chomp: true) : []
    [calls, (JSON.parse(File.read(tree)) if File.exist?(tree))]
  end

  # Each version of the badge's image, as the job writes it.
  def image(name) = {"tree" => [{"path" => "badge.svg", "mode" => "100644", "type" => "blob",
                                 "content" => File.read(File.expand_path("../assets/#{name}.svg", __dir__))}]}

  def test_a_green_badge
    calls, tree = badge_run("RESULT" => "success", "STATUS" => "passed")

    assert_equal image("badge"), tree, "written as it is in assets/"
    assert_empty calls.grep(/\Acurl /), "fetched from nowhere"
    assert_includes calls, %(gh api --method POST repos/me/my_gem/git/commits -f message=Duel's badge, for abc -f tree=tree1 --jq .sha)
    assert_equal ["gh api --method PATCH repos/me/my_gem/git/refs/heads/duel/badge -f sha=commit1 -F force=true"], calls.grep(/refs/),
      "the branch moved"
  end

  def test_a_red_badge_for_a_regression
    calls, tree = badge_run("RESULT" => "success", "STATUS" => "failed", "NO_BRANCH" => "1")

    assert_equal image("badge-regressed"), tree, "red, though the job passed (c.fail_on)"
    assert_equal "gh api --method POST repos/me/my_gem/git/refs -f ref=refs/heads/duel/badge -f sha=commit1", calls.last, "the branch made"
  end

  # A job that failed before Duel said whether the push passed (its
  # runner lost, say) measured nothing.
  def test_a_grey_badge_for_a_failed_job
    _, tree = badge_run("RESULT" => "failure", "STATUS" => "")

    assert_equal image("badge-not-measured"), tree
  end

  # A step that failed after Duel passed the push leaves the badge green.
  def test_a_green_badge_for_a_job_that_failed_after_duel_passed
    _, tree = badge_run("RESULT" => "failure", "STATUS" => "passed")

    assert_equal image("badge"), tree
  end

  # A newer push's badge replaces an older push's (or the same push's,
  # run again), whatever it says.
  def test_a_badge_for_a_newer_push
    calls, tree = badge_run("RESULT" => "success", "STATUS" => "passed", "LAST" => "Duel's badge, for 0123abcd", "COMPARED" => "behind")

    assert_equal image("badge"), tree
    assert_includes calls, "gh api repos/me/my_gem/compare/abc...0123abcd --jq .status", "the badge's push, from its commit"
    assert_includes calls, "gh api --method PATCH repos/me/my_gem/git/refs/heads/duel/badge -f sha=commit1 -F force=true"
  end

  # A run that finishes after a newer push's leaves that push's badge.
  def test_a_badge_for_an_older_push
    calls, tree = badge_run("RESULT" => "failure", "STATUS" => "", "LAST" => "Duel's badge, for 0123abcd", "COMPARED" => "ahead")

    assert_nil tree, "the newer push's run has the say"
    assert_equal ["gh api repos/me/my_gem/commits/duel/badge --jq .commit.message", "gh api repos/me/my_gem/compare/abc...0123abcd --jq .status"],
      calls
  end

  # The red badge is the green one, wider for its words.
  def test_the_red_badge
    green, red = %w[badge badge-regressed].map { |name| File.read(File.expand_path("../assets/#{name}.svg", __dir__)) }

    assert_equal green.sub('width="133"', 'width="142"').gsub("perf guarded", "perf regressed").sub("#34D058", "#EA4A5A")
      .sub("#28A745", "#D73A49").sub("M0 0h76.939C78.629 0 80 1.343 80 3v14c0 1.657-1.37 3-3.061 3H0V0z",
        "M0 0h85.939C87.629 0 89 1.343 89 3v14c0 1.657-1.37 3-3.061 3H0V0z"), red
  end

  # The grey badge is the green one, wider for its words too.
  def test_the_grey_badge
    green, grey = %w[badge badge-not-measured].map { |name| File.read(File.expand_path("../assets/#{name}.svg", __dir__)) }

    assert_equal green.sub('width="133"', 'width="138"').gsub("perf guarded", "not measured").sub("#34D058", "#959DA5")
      .sub("#28A745", "#6A737D").sub("M0 0h76.939C78.629 0 80 1.343 80 3v14c0 1.657-1.37 3-3.061 3H0V0z",
        "M0 0h81.939C83.629 0 85 1.343 85 3v14c0 1.657-1.37 3-3.061 3H0V0z"), grey
  end

  # On a push, a job of its own comments on the commit, as Duel says
  # (only where a regression in a push passes: see Config#fail_on), with
  # the permission that takes, and running none of the code either.
  def test_the_comment_on_a_pushed_commit
    gem
    push_settings
    init.run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    duel, comment = jobs.values_at("duel", "commit-comment")

    assert_includes duel.fetch("steps").last.fetch("if"), "github.event_name == 'push'", "the report kept for a push too"
    assert_equal ["duel", {"contents" => "write"}, "Comment on the commit"], comment.values_at("needs", "permissions", "name")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && (needs.duel.outputs.comment == 'post' || " \
      "needs.duel.outputs.comment == 'change') }}", comment.fetch("if")
    assert_equal({"COMMENT" => "${{ needs.duel.outputs.comment }}", "STATUS" => "${{ needs.duel.outputs.status }}"},
      comment.dig("steps", 1, "env").slice("COMMENT", "STATUS"))
    run = comment.dig("steps", 1, "run")

    assert_equal ["POST"], run.scan(/--method (\w+)/).flatten, "a new comment, never an edit"
    assert_includes run, %("repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/comments")
    assert_includes run, %("repos/$GITHUB_REPOSITORY/comments"), "the last on any commit"
    assert_equal [true, {"name" => "duel-report", "path" => "${{ runner.temp }}/report"}], comment.fetch("steps").first.values_at("continue-on-error", "with")
    refute_includes comment.to_s, "checkout"
    refute_includes comment.to_s, "bundle"
  end

  # A gem whose name has a dash: its library's in a directory.
  def test_a_dashed_gem
    write("my-gem.gemspec", %(Gem::Specification.new { |s| s.name = "my-gem" }\n))
    write("lib/my/gem.rb")
    init.run

    assert_includes @out.string, "  create    duel/my_gem_duel.rb\n"
    assert_includes read(".duel.rb"), %(  # c.library = "my/gem"\n)
    refute_includes @out.string, "c.library"
  end

  # The workflow's Ruby: this one's minor version.
  def test_the_workflows_ruby
    assert_equal ["10.12", "3.4"], ["10.12.3", "3.4.11"].map { |version| with_constants(Object, RUBY_VERSION: version) { init.send(:ruby_version) } }
  end

  # The example defines a benchmark, as workers load it.
  def test_the_example
    gem
    init.run
    path = File.join(root, "duel", "my_gem_duel.rb")
    DSL.instance_eval(File.read(path), path)

    assert_equal ["example: join words"], Duel.benchmarks.keys
  end

  # A gem with a C extension is built with rake compile, and one with a
  # .ruby-version runs each version on its own Ruby, whose workflow sets
  # up the baseline's too.
  def test_a_gem_with_an_extension_and_a_ruby_version
    gem
    write("ext/my_gem/extconf.rb")
    write(".ruby-version", "3.4.1\n")
    init.run

    assert_includes read(".duel.rb"), %(  # c.library = "my_gem"\n\n  # Builds each version's C extension, so that each is measured with its\n) +
      %(  # own build.\n  c.build = "bundle exec rake compile"\n\n  # Each version runs on the Ruby that its own .ruby-version names, so a\n) +
      "  # branch that upgrades Ruby is compared on each version's Ruby.\n  c.ruby = :version_file\n#{ENDING}"
    workflow = read(".github/workflows/perf.yml")

    assert_includes workflow, "        with:\n          bundler-cache: true\n"
    assert_includes workflow, %(ruby_of() { git show "$1:./.ruby-version" 2>/dev/null)
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true}, baseline.fetch("with"), "with its own bundle")
    assert_includes workflow, %(          RELEASE_TAGS: "v*"\n), "the last release as Duel finds it"
    assert_equal 9, YAML.safe_load(workflow).dig("jobs", "duel", "steps").size
    workflow.scan(/^        run: \|\n((?:          .*\n)+)/).flatten.each { |script| refute_includes script, "${{", "only in env" }
  end

  # The guide's steps that set up the baseline's Ruby, in docs/ci.md, are
  # the workflow's.
  def test_the_guides_steps_for_the_baseline_ruby
    write(".ruby-version", "3.4.1\n")
    steps = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n      # \(Before the step that sets up the candidate's Ruby\.\)\n(.*?)^```$/m, 1]

    assert_includes init.files.fetch(".github/workflows/perf.yml"), "      # (And whatever else your tests need set up: packages, services.)\n#{steps}      - uses: ruby/setup-ruby@v1\n"
  end

  # Without a gemspec: lib/'s only file is the library, or there's none
  # to guess, and it says to set one.
  def test_an_app
    write("lib/my_app.rb")
    init.run

    assert_includes read(".duel.rb"), %(  # The library each version's workers require, from its lib/.\n  c.library = "my_app"\n#{ENDING})
    assert_includes @out.string, "  create    duel/my_app_duel.rb\n"
    assert_includes read("duel/my_app_duel.rb"), "# load my_app and every duel/**/*_duel.rb file. See\n"
    write("lib/other.rb")
    init("--force").run

    assert_includes read(".duel.rb"), %(  #   c.load { |root| require File.join(root, "config", "boot") }\n  # c.library = "my_library"\n#{ENDING})
    assert_includes @out.string, "  create    duel/example_duel.rb\n"
    assert_includes read("duel/example_duel.rb"), "# load every duel/**/*_duel.rb file. See\n"
    assert_includes @out.string, "\n  2. Set c.library in .duel.rb to what each version's workers require.\n  3. Replace the example in duel/example_duel.rb"
  end

  # Without Duel in the Gemfile (or a Gemfile), it says to add it.
  def test_duel_to_add
    write("lib/my_app.rb")
    init.run

    assert_includes @out.string, %(\nNext:\n  1. Add gem "duel" to the Gemfile's development group, and run `bundle install`.\n  2. Replace)
    write("Gemfile", %(gem "duel-redis"\n))
    init.run

    assert_includes @out.string, %(  1. Add gem "duel")
    write("Gemfile", %(gem 'duel', group: :development\ngem "stackprof"\n))
    init.run

    assert_includes @out.string, "\n  1. Replace"
  end

  # Files that exist are left, unless --force.
  def test_existing_files
    gem
    write(".duel.rb", "mine")
    init.run

    assert_equal "mine", read(".duel.rb")
    assert_includes @out.string, "  skip      .duel.rb (it exists: --force to overwrite)\n  create    duel/my_gem_duel.rb\n"
    init("--force").run

    assert_includes read(".duel.rb"), "Duel.configure"
    assert_includes @out.string, "  overwrite .duel.rb\n  overwrite duel/my_gem_duel.rb\n  overwrite .github/workflows/perf.yml\n"
  end

  def test_a_dry_run
    gem
    write(".duel.rb", "mine")

    assert_equal 0, init("--dry-run").run
    assert_equal "duel init: a dry run, so nothing is written\n  skip      .duel.rb (it exists: --force to overwrite)\n" \
      "  create    duel/my_gem_duel.rb\n", @out.string.lines.first(3).join
    assert_equal ["my_gem.gemspec", "lib", "Gemfile", ".duel.rb"].sort, Dir.children(root).sort
    init("--dry-run", "--force").run

    assert_includes @out.string, "  overwrite .duel.rb\n"
    assert_equal "mine", read(".duel.rb")
  end

  # Duel's Rake task, added to a Rakefile (once), after a blank line.
  def test_the_rakefile
    gem
    write("Rakefile", "task :default")
    init.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    assert_includes @out.string, "  create    .github/workflows/perf-comment.yml\n  append    Rakefile\n  append    Gemfile"
    init.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    assert_includes @out.string, "  skip      Rakefile (it has Duel's task)\n"
    write("Rakefile", "task :default\n")
    init.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    write("Rakefile")
    init.run

    assert_equal %(require "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    write("Rakefile", "x\n")
    init("--dry-run").run

    assert_equal "x\n", read("Rakefile")
    assert_includes @out.string, "  append    Rakefile\n"
  end

  # StackProf, for profiles of regressions, added to the Gemfile (on
  # CRuby's platforms only): last in its development group, if it has
  # one, or else at its end, after a blank line. A Gemfile with
  # stackprof is left alone, even with --force.
  def test_stackprof
    gem

    assert_equal 0, init.run
    assert_equal %(source "https://rubygems.org"\ngemspec\ngem "duel"\n\n# For profiles of regressions (StackProf runs on CRuby only)\n) +
      %(gem "stackprof", platforms: :mri\n), read("Gemfile")
    init("--force").run

    assert_includes @out.string, "  skip      Gemfile (it has stackprof)\n\nNext:\n  1. Replace"
    assert_equal 1, read("Gemfile").scan("stackprof").size
    group = "group :development do\n  gem \"duel\"\n  if true\n  end\nend\n"
    {"" => "", "gem \"rake\"" => "gem \"rake\"\n", "group :test do\nend" => "group :test do\nend\n",
     "group :development do\n  gem \"duel\"\n" => "group :development do\n  gem \"duel\"\n"}.each do |gemfile, before|
      write("Gemfile", gemfile)
      init.run

      assert_includes @out.string, "  append    Gemfile (gem \"stackprof\", platforms: :mri)\n"
      assert_equal "#{before}#{"\n" unless before.empty?}# For profiles of regressions (StackProf runs on CRuby only)\n" \
        "gem \"stackprof\", platforms: :mri\n", read("Gemfile"), gemfile
    end
    ["group :development do", "group :development, :test do", "group :test, :development do", "group(:development, :test) do",
      "  group :development do"].each do |opening|
      indent = opening[/\A */]
      write("Gemfile", "#{indent}platforms :ruby do\n#{indent}end\n\n#{opening}\n#{indent}  gem \"duel\"\n#{indent}end\n#{indent}gem \"x\"\n")
      init.run

      assert_includes @out.string, "  insert    Gemfile (gem \"stackprof\", platforms: :mri, in the development group)\n"
      assert_equal "#{indent}platforms :ruby do\n#{indent}end\n\n#{opening}\n#{indent}  gem \"duel\"\n#{indent}  gem \"stackprof\", platforms: :mri\n#{indent}end\n" \
        "#{indent}gem \"x\"\n", read("Gemfile"), opening
    end
    write("Gemfile", group)
    init.run

    assert_equal "group :development do\n  gem \"duel\"\n  if true\n  end\n  gem \"stackprof\", platforms: :mri\nend\n",
      read("Gemfile"), "at its own end"
  end

  def test_stackprof_in_a_dry_run
    gem
    init("--dry-run").run

    assert_includes @out.string, "  append    Gemfile (gem \"stackprof\", platforms: :mri)\n\nNext:\n  1. Run `bundle install`"
    write("Gemfile", "group :development do\nend\n")
    init("--dry-run").run

    assert_includes @out.string, "  insert    Gemfile (gem \"stackprof\", platforms: :mri, in the development group)\n"
    assert_equal "group :development do\nend\n", read("Gemfile")
  end

  # Without a Gemfile, there's none to add StackProf to.
  def test_stackprof_without_a_gemfile
    write("lib/my_app.rb")
    init.run

    refute_includes @out.string, "stackprof"
    refute_path_exists File.join(root, "Gemfile")
  end

  # A Rails app is set up by duel-rails's generator.
  def test_a_rails_app
    write("config/application.rb")

    assert_equal 1, init.run
    assert_equal "duel init: this is a Rails app (config/application.rb). Add duel-rails to the Gemfile's development group, " \
      "and run `bin/rails generate duel:install` instead\n", @err.string
    assert_empty @out.string
    assert_equal %w[config], Dir.children(root)
    assert_equal 1, init("--check").run
    assert_includes @err.string, "and run `bin/rails generate duel:install --check` instead\n", "its own --check"
  end

  # In a subdirectory, the baseline's bundle is installed there too.
  def test_a_project_in_a_subdirectory_with_a_ruby_version
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    File.write(File.join(project, ".ruby-version"), "3.4.1\n")
    init(at: project).run
    workflow = File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"working-directory" => "gems/parser", "ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true},
      baseline.fetch("with"))
    assert_equal "origin/duel/passed-gems-parser/${{ github.ref_name }}", YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline" }.dig("env", "PASSED")
  end

  # A project in a subdirectory of its repository: the workflow is at the
  # repository's root, named for the project's directory, and runs there.
  def test_a_project_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    push_settings(at: project)
    init("--badge", at: project).run

    assert_includes @out.string, "  create    ../../.github/workflows/perf-gems-parser.yml\n"
    workflow = File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))

    assert_includes workflow, "    defaults:\n      run:\n        working-directory: gems/parser\n    steps:\n"
    assert_includes workflow, "        with:\n          working-directory: gems/parser\n          ruby-version:"
    assert_includes workflow, %(marker="<!-- duel gems/parser"\n)
    comments = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser-comment.yml"))

    assert_equal ["Perf (gems/parser)", ["Perf (gems/parser)"]], [YAML.safe_load(workflow).fetch("name"), comments.dig(true, "workflow_run", "workflows")],
      "a workflow of its own, and its comments"
    assert_includes comments.dig("jobs", "comment", "steps", 2, "run"), %(--marker 'duel gems/parser'\n)
    assert_equal "duel/passed-gems-parser/${{ github.ref_name }}", YAML.safe_load(workflow).dig("jobs", "passed", "steps", 0, "env", "BRANCH"), "a branch of its own"
    assert_equal "duel/badge-gems-parser", YAML.safe_load(workflow).dig("jobs", "badge", "steps", 0, "env", "BRANCH"), "a badge of its own"
    assert_includes workflow, "https://raw.githubusercontent.com/OWNER/REPO/duel/badge-gems-parser/badge.svg"
    assert_path_exists File.join(project, ".duel.rb")
    assert_equal({"run" => {"working-directory" => "gems/parser"}}, YAML.safe_load(workflow).dig("jobs", "duel", "defaults"))
    refute YAML.safe_load(workflow).dig("jobs", "commit-comment").key?("defaults"), "nothing checked out there"
    init(at: tmpdir).run

    assert_includes @out.string, "  create    .github/workflows/perf.yml\n", "at the root"
  end

  # The workflow is the guide's, in docs/ci.md (with this Ruby).
  def test_the_guides_workflow
    workflow = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n# \.github\/workflows\/perf\.yml\n(.*?)^```$/m, 1]

    assert_equal workflow.sub(%("3.4" # (or none, with a .ruby-version)), %("#{ruby_version}")), init.files.fetch(".github/workflows/perf.yml")
  end

  # And the jobs for pushes, as it writes them where .duel.rb asks for
  # them.
  def test_the_guides_jobs_for_pushes
    gem
    push_settings
    workflow = init.files.fetch(".github/workflows/perf.yml")
    guide = File.read(File.expand_path("../docs/ci.md", __dir__))
    {"c.fail_on = :pull_requests" => ["  # The report, as a new comment on a pushed commit", "  # With c.push_base = :last_passed"],
     "c.push_base = :last_passed" => ["  # With c.push_base = :last_passed", nil]}.each do |setting, (from, to)|
      job = guide[/^```yaml\n# \.github\/workflows\/perf\.yml, in jobs: \(with #{Regexp.escape(setting)}\)\n(.*?)^```$/m, 1]

      assert_equal workflow[workflow.index(from)...(workflow.index(to) if to)].rstrip, job.rstrip, setting
    end
  end

  # And the badge's job, as it writes it with --badge.
  def test_the_guides_badge_job
    init = init("--badge")
    init.send(:parser).parse(["--badge"])
    workflow = init.files.fetch(".github/workflows/perf.yml")
    job = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n# \.github\/workflows\/perf\.yml, in jobs: \(with duel init --badge\)\n(.*?)^```$/m, 1]

    assert_equal workflow[workflow.index("  # Duel's badge")..].rstrip, job.rstrip
  end

  # And the GitLab CI jobs.
  def test_the_guides_gitlab_jobs
    jobs = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n# \.gitlab\/duel\.gitlab-ci\.yml\n(.*?)^```$/m, 1]
    init = init("--gitlab")
    init.send(:parser).parse(["--gitlab"])

    assert_equal jobs.sub("ruby:3.4", "ruby:#{ruby_version}"), init.files.fetch(".gitlab/duel.gitlab-ci.yml")
  end

  # And the one that comments on a pull request.
  def test_the_guides_comment_workflow
    workflow = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n# \.github\/workflows\/perf-comment\.yml\n(.*?)^```$/m, 1]

    assert_equal workflow, init.files.fetch(".github/workflows/perf-comment.yml")
  end

  # With --gitlab, GitLab CI jobs to include, not GitHub Actions
  # workflows: the Duel job, on its Ruby's image, which lets a regression
  # outside a merge request fail as a warning, and writes its outputs as
  # variables, and the jobs after it, which run none of the code.
  def test_gitlab
    gem
    write(".ruby-version", "ruby-3.4.1\n")

    assert_equal 0, init("--gitlab").run
    assert_includes @out.string, "  create    .gitlab/duel.gitlab-ci.yml\n"
    assert_includes @out.string, "Include .gitlab/duel.gitlab-ci.yml from .gitlab-ci.yml, and add the tokens it says to"
    refute_path_exists File.join(root, ".github")
    jobs = YAML.safe_load(read(".gitlab/duel.gitlab-ci.yml"))
    duel = jobs.fetch("duel")

    assert_equal %w[duel duel:comment duel:commit-comment duel:passed], jobs.keys
    assert_equal ["ruby:3.4.1", {"exit_codes" => [3]}, ["bundle exec duel --markdown duel.md"]], duel.values_at("image", "allow_failure", "script")
    assert_equal({"GIT_DEPTH" => 0, "DUEL_OUTPUT" => "duel.env"}, duel.fetch("variables"))
    assert_equal({"when" => "always", "paths" => ["duel.md"], "reports" => {"dotenv" => "duel.env"}, "expire_in" => "1 day"}, duel.fetch("artifacts"))
    assert_equal [{"DUEL_BASE" => "$CI_COMMIT_BEFORE_SHA"}, {"DUEL_BASE" => "last-release"}, {"DUEL_FORCE" => "1"}],
      duel.fetch("rules").filter_map { |rule| rule["variables"] }
    %w[duel:comment duel:commit-comment duel:passed].each do |name|
      assert_equal [["duel"], {"GIT_STRATEGY" => "none"}], jobs.fetch(name).values_at("needs", "variables"), name
    end
    assert_includes jobs.dig("duel:comment", "rules", 0, "if"), "$DUEL_COMMENT_TOKEN"
    assert_equal ["ruby:slim", ["gem install duel --version '~> 0.1.8' --no-document",
      %(duel comment --gitlab --report . --head "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-$CI_COMMIT_SHA}" --marker 'duel')]],
      jobs.fetch("duel:comment").values_at("image", "script"), "Duel's own code, from RubyGems"
    assert_includes jobs.dig("duel:passed", "rules", 0, "if"), "$DUEL_TOKEN"
    assert_equal "duel/passed", jobs.dig("duel:passed", "resource_group"), "one at a time"
  end

  # What GitLab's job that marks a push passed asks its API, with curl
  # stubbed: for a push (abc) where the branch is +at+ (nil, missing),
  # whose merge base with the push is +base+.
  # A branch named +blocker+ keeps it from making the branch.
  def gitlab_passed_run(at: nil, base: nil, blocker: nil, success: true)
    gem
    init("--gitlab").run
    script = YAML.safe_load(read(".gitlab/duel.gitlab-ci.yml")).dig("duel:passed", "script", 1)
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    log = File.join(tmpdir, "log").tap { |path| File.write(path, "") }
    File.write(File.join(bin, "curl"), <<~SH)
      #!/bin/sh
      url=$(for arg; do last=$arg; done; echo "$last")
      method=GET
      case "$*" in *"-X DELETE"*) method=DELETE ;; *"--data-urlencode"*) method=POST ;; esac
      echo "$method ${url#https://gitlab/api/v4/projects/7/}" >> #{log}
      case "$method $url" in
        "GET "*/merge_base*) echo "{\\"id\\":\\"$BASE\\"}" ;;
        "GET "*/branches/duel%2Fpassed%2Fmain) [ -n "$AT" ] && echo "{\\"commit\\":{\\"id\\":\\"$AT\\"}}" || exit 22 ;;
        "GET "*/branches/*) [ "${url##*/branches/}" = "$BLOCKER" ] || exit 22 ;;
        "POST "*) [ -z "$BLOCKER" ] || exit 22 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(bin, "curl"))
    env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "DUEL_PASSED" => "true", "CI_API_V4_URL" => "https://gitlab/api/v4", "CI_PROJECT_ID" => "7",
           "DUEL_TOKEN" => "t", "CI_COMMIT_BRANCH" => "main", "CI_COMMIT_SHA" => "abc", "AT" => at, "BASE" => base, "BLOCKER" => blocker}

    assert_equal success, system(env, "sh", "-ec", "set -o pipefail\n#{script}", out: (@said = File.join(tmpdir, "said")))
    File.readlines(log, chomp: true)
  end

  def test_gitlab_marking_a_push_passed
    moved = ["DELETE repository/branches/duel%2Fpassed%2Fmain", "POST repository/branches"]

    assert_equal ["GET repository/branches/duel%2Fpassed%2Fmain", *moved], gitlab_passed_run, "made"
    assert_equal moved, gitlab_passed_run(at: "old", base: "old").last(2), "moved forward"
    assert_equal moved, gitlab_passed_run(at: "def", base: "123").last(2), "moved anyway, after a rewrite"
    assert_equal "GET repository/merge_base?refs%5B%5D=abc&refs%5B%5D=def", gitlab_passed_run(at: "def", base: "abc").last,
      "left where a newer push's job moved it"
    assert_equal "GET repository/merge_base?refs%5B%5D=abc&refs%5B%5D=def", gitlab_passed_run(at: "def", base: "", success: false).last,
      "no comparison"
  end

  def test_gitlab_marking_a_push_passed_where_a_branch_blocks_it
    calls = gitlab_passed_run(blocker: "duel", success: false)

    assert_equal ["GET repository/branches/duel%2Fpassed", "GET repository/branches/duel"], calls.last(2)
    assert_equal "The branch duel keeps Duel from making duel/passed/main, as Git can't have both. " \
      "Delete it (git push origin --delete duel), or rename it.\n", File.read(@said)
  end

  # For a project in a subdirectory, its own jobs, file, and branch, and
  # without a .ruby-version, this Ruby's minor version.
  def test_gitlab_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    init("--gitlab", at: project).run
    text = File.read(File.join(tmpdir, ".gitlab", "duel-gems-parser.gitlab-ci.yml"))
    jobs = YAML.safe_load(text)

    assert_equal ["duel:gems/parser", "duel:gems/parser:comment", "duel:gems/parser:commit-comment", "duel:gems/parser:passed"], jobs.keys
    assert_equal ["ruby:#{ruby_version}", "cd gems/parser"], [jobs.dig("duel:gems/parser", "image"), jobs.dig("duel:gems/parser", "before_script", 0)]
    assert_equal ["gems/parser/duel.md", "gems/parser/duel.env"], jobs.dig("duel:gems/parser", "artifacts").values_at("paths", "reports").map { |v| v.is_a?(Array) ? v.first : v.fetch("dotenv") }
    assert_includes text, %(marker="<!-- duel gems/parser"\n)
    assert_includes text, %(--report gems/parser --head "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-$CI_COMMIT_SHA}" --marker 'duel gems/parser'\n)
    assert_includes text, %(branch="duel/passed-gems-parser/$CI_COMMIT_BRANCH"\n)
    assert_equal "duel/gems/parser/passed", jobs.dig("duel:gems/parser:passed", "resource_group"), "its own, with no colon, which GitLab doesn't take"
  end

  # --check says whether each workflow is what it writes, or how it
  # differs, or that it's missing, and writes nothing.
  def test_check
    gem
    init.run
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort

    assert_equal 0, init("--check").run
    assert_equal "  same      .github/workflows/perf.yml\n  same      .github/workflows/perf-comment.yml\n", @out.string
    assert_equal read(".github/workflows/perf.yml"), File.binread(File.join(root, ".github/workflows/perf.yml")), "written with LF, as it is"
    crlf = File.join(root, ".github/workflows/perf-comment.yml")
    File.binwrite(crlf, File.binread(crlf).gsub("\n", "\r\n"))

    assert_equal 0, init("--check").run, "with CRLF line endings, as git can check it out on Windows"
    File.write(File.join(root, ".github/workflows/perf.yml"), read(".github/workflows/perf.yml").sub("name: Perf\n", "name: Mine\n"))

    assert_equal 1, init("--check").run, "one that differs"
    File.delete(File.join(root, ".github/workflows/perf-comment.yml"))

    assert_equal 1, init("--check").run
    assert_equal <<~OUT, @out.string
        differs   .github/workflows/perf.yml
      --- .github/workflows/perf.yml
      +++ .github/workflows/perf.yml (duel init)
      @@ -1,4 +1,4 @@
      -name: Mine
      +name: Perf
       
       on:
         pull_request:
        missing   .github/workflows/perf-comment.yml
    OUT
    assert_equal before - [".github/workflows/perf-comment.yml"], Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort, "nothing written"
    assert_equal 1, init("--check", "--badge").run, "with other options, other workflows"
    assert_equal 1, init("--check", "--gitlab").run
    assert_equal "  missing   .gitlab/duel.gitlab-ci.yml\n", @out.string
  end

  # A terminal, answering +answer+.
  def terminal(answer = "")
    StringIO.new(answer).tap { |io| io.define_singleton_method(:tty?) { true } }
  end

  # Runs `duel init` (with +argv+), its input +input+, with gh and glab
  # faked: they answer as +answers+ say (by the program and its first two
  # arguments), and nil to anything else. Returns the calls it made.
  def labeled(*argv, input: terminal, answers: {})
    gem
    calls = []
    command = init(*argv, input: input)
    command.define_singleton_method(:cli) do |*args|
      calls << args
      answers[args.first(3)]
    end
    command.run
    calls
  end

  REPO = {%w[gh repo view] => "me/my_gem\n"}.freeze

  LISTED = %w[gh label list --repo me/my_gem --search duel:\ accept --limit 100 --json name --jq .[].name].freeze

  # At a terminal, with a GitHub repository that hasn't the label that
  # accepts a regression, it asks whether to create it, with gh.
  def test_creating_the_label
    calls = labeled(input: terminal("y\n"), answers: REPO.merge(%w[gh label list] => "duel\nduel: accepted\n", %w[gh label create] => ""))

    assert_equal [%w[gh repo view --json nameWithOwner --jq .nameWithOwner], LISTED,
      ["gh", "label", "create", "duel: accept", "--color", "FBCA04", "--repo", "me/my_gem", "--description", "Accepts a regression that Duel found"]], calls
    assert_includes @out.string, %(Create the label "duel: accept" in me/my_gem with gh, so a pull request can accept a regression? [y/N]   create    label duel: accept (me/my_gem)\n)
    refute_includes @out.string, "Create the label \"duel: accept\" in your repository"
    %W[yes\n Y\n YES #{" y\n"}].each do |answer|
      assert_equal 3, labeled("--force", input: terminal(answer), answers: REPO.merge(%w[gh label list] => "", %w[gh label create] => "")).size, answer
    end
  end

  # Where it doesn't create the label, the next steps say to.
  def test_not_creating_the_label
    step = %(Create the label "duel: accept" in your repository, so a pull request can accept a regression (c.accept_label).\n)
    [["n\n", "no"], ["", "no answer"], ["yes, sure\n", "not a yes"]].each do |answer, why|
      assert_equal 2, labeled("--force", input: terminal(answer), answers: REPO.merge(%w[gh label list] => "")).size, why
      assert_includes @out.string, step, why
    end
    assert_equal 3, labeled("--force", input: terminal("y\n"), answers: REPO.merge(%w[gh label list] => "")).size
    assert_includes @out.string, step, "gh didn't"
    refute_includes @out.string, "  create    label"
    assert_equal [LISTED], labeled("--force", answers: REPO).drop(1), "it couldn't list them"
    assert_includes @out.string, step
    assert_equal 1, labeled("--force").size, "not a GitHub repository, say"
    refute_includes @out.string, "[y/N]"
    assert_includes @out.string, step
  end

  # With the label already, it says so.
  def test_a_label_that_exists
    assert_equal 2, labeled(answers: REPO.merge(%w[gh label list] => "bug\nduel: accept\n")).size
    assert_includes @out.string, "  skip      label duel: accept (me/my_gem has it)\n"
    refute_includes @out.string, "[y/N]"
    refute_includes @out.string, "Create the label"
  end

  # It asks only at a terminal, for GitHub, not on a dry run, and only
  # with a label.
  def test_when_it_asks_about_the_label
    assert_empty labeled(input: StringIO.new("y\n"), answers: REPO)
    assert_includes @out.string, "Create the label \"duel: accept\" in your repository"
    assert_empty labeled("--force", "--dry-run", answers: REPO)
    write(".duel.rb", "Duel.configure { |c| c.accept_label = nil }\n")

    assert_empty labeled(answers: REPO)
    refute_includes @out.string, "Create the label"
  end

  # gh (or glab), run in the project: what it prints, or nil where it
  # fails (which it says) or isn't there.
  def test_cli
    bin = File.join(tmpdir, "bin")
    fake_command(File.join(bin, "gh"), %([ "$2" = fail ] && { echo ' no ' >&2; exit 1; }\necho "$*"; pwd -W 2>/dev/null || pwd -P))
    command = init
    original = ENV.fetch("PATH")
    ENV["PATH"] = path_with(bin, original)

    assert_equal "a b\n#{File.realpath(root)}\n", command.send(:cli, "gh", "a", "b")
    assert_nil command.send(:cli, "gh", "a", "fail", "c")
    assert_equal "duel init: gh a fail: no\n", @err.string
    ENV["PATH"] = File.join(tmpdir, "nothing")

    assert_nil command.send(:cli, "gh", "a")
  ensure
    ENV["PATH"] = original
  end

  GITLAB_REPO = {%w[glab repo view] => %({"path_with_namespace": "me/my_gem", "id": 7})}.freeze

  # A page of GitLab labels, named +names+.
  def gitlab_labels(*names) = JSON.generate(names.map { |name| {"name" => name, "color" => "#fff"} })

  # On GitLab, it asks the same, with glab, of every page of the labels.
  def test_creating_a_gitlab_label
    pages = [gitlab_labels(*Array.new(100) { |i| "label #{i}" }), gitlab_labels("bug", "duel: accept")]
    answers = GITLAB_REPO.merge(%w[glab label list] => gitlab_labels("bug"), %w[glab label create] => "")
    calls = labeled("--gitlab", input: terminal("y\n"), answers: answers)

    assert_equal [%w[glab repo view --output json],
      %w[glab label list --repo me/my_gem --output json --per-page 100 --page 1],
      ["glab", "label", "create", "--name", "duel: accept", "--color", "#FBCA04", "--repo", "me/my_gem", "--description",
        "Accepts a regression that Duel found"]], calls
    assert_includes @out.string, %(Create the label "duel: accept" in me/my_gem with glab, so a merge request can accept a regression? [y/N] )
    assert_includes @out.string, "  create    label duel: accept (me/my_gem)\n"
    command = init("--force", "--gitlab", input: terminal("y\n"))
    listed = []
    command.define_singleton_method(:cli) do |*args|
      next %({"path_with_namespace": "me/my_gem"}) if args.first(3) == %w[glab repo view]

      listed << args
      pages[Integer(args.last) - 1] if args.first(3) == %w[glab label list]
    end

    assert_equal 0, command.run
    assert_equal [%w[1 2], []], [listed.map(&:last), listed.reject { |args| args[2] == "list" }],
      "past the first page, a hundred labels long, to the last, which has it"
    assert_includes @out.string, "  skip      label duel: accept (me/my_gem has it)\n"
  end

  # On GitLab, a label that's there already, on any page, isn't made again.
  def test_a_gitlab_label_that_exists
    calls = labeled("--gitlab", answers: GITLAB_REPO.merge(%w[glab label list] => gitlab_labels("bug", "duel: accept")))

    assert_equal 2, calls.size
    assert_includes @out.string, "  skip      label duel: accept (me/my_gem has it)\n"
  end

  # Where glab can't say the project, or its labels, it asks nothing, and
  # the next steps say to make the label.
  def test_no_gitlab_label
    step = %(Create the label "duel: accept" in your repository, so a merge request can accept a regression (c.accept_label).\n)
    ["", "{", "[]", %({"id": 7}), nil].each do |project|
      assert_equal 1, labeled("--force", "--gitlab", answers: {%w[glab repo view] => project}).size
      assert_includes @out.string, step
    end
    ["{", nil].each do |labels|
      assert_equal 2, labeled("--force", "--gitlab", answers: GITLAB_REPO.merge(%w[glab label list] => labels)).size
      refute_includes @out.string, "[y/N]"
    end
  end

  def test_help
    assert_equal 0, init("--help").run
    assert_empty @err.string
    assert_equal <<~HELP, @out.string
      Usage: duel init [options]

      Sets Duel up in this project: .duel.rb, a benchmark to start from in duel/, GitHub Actions workflows
      (or GitLab CI jobs), a Rake task, and StackProf in the Gemfile.

              --force                      Overwrite files that exist
              --dry-run                    Say what it would do, and write nothing
              --check                      Say how the workflows differ from what it writes (with the same options), and write nothing
              --badge                      Write a job that keeps a badge for the README (it needs contents: write)
              --gitlab                     Write GitLab CI jobs (to include from .gitlab-ci.yml), not GitHub Actions workflows
              --reusable                   Write workflows that call Duel's reusable ones (at this release), not whole workflows
          -h, --help                       Print this help
    HELP
    assert_equal 0, init("-h").run
    assert_includes @out.string, "Usage: duel init"
    assert_empty Dir.children(root), "nothing written"
  rescue SystemExit
    flunk "OptionParser's own --help exits"
  end

  def test_bad_arguments
    assert_equal 2, init("--nope").run
    assert_equal "duel init: invalid option: --nope\n", @err.string
    assert_equal 2, init("here", "there").run
    assert_equal "duel init: needless argument: here\n", @err.string
    assert_empty Dir.children(root)
  end

  # In the working directory, by default, and to $stdout and $stderr.
  def test_defaults
    gem
    out, = capture_io { Dir.chdir(root) { Duel::Init.new([]).run } }

    assert_includes out, "  create    .duel.rb\n"
    _, err = capture_io { Duel::Init.new(["--nope"]).run }

    assert_equal "duel init: invalid option: --nope\n", err
  end

  # Duel's reusable workflows, in its repository, are what the templates
  # render with each setting an input (see Init::Reusable): `rake
  # workflows` writes them.
  def test_the_reusable_workflows
    files = Duel::Init::Reusable.new.files

    assert_equal [".github/workflows/duel.yml", ".github/workflows/duel-comment.yml"], files.keys
    files.each { |path, content| assert_equal content, File.read(File.expand_path(File.join("..", path), __dir__)), "#{path}: run `rake workflows`" }
    perf, comment = files.values.map { |content| YAML.safe_load(content) }

    assert_equal "Duel", perf.fetch("name")
    assert_equal %w[ruby-version version-file working-directory setup accept-label release-tags comment-on-pushes mark-passed badge passed-branch badge-branch marker],
      perf.dig(true, "workflow_call", "inputs").keys
    refute perf.key?("concurrency"), "the caller's: one of its own would wait for the caller's run"
    assert_equal %w[duel commit-comment passed badge], perf.fetch("jobs").keys, "every job"
    assert_equal %w[inputs.comment-on-pushes inputs.mark-passed inputs.badge], perf.fetch("jobs").values.drop(1).map { |job| job.fetch("if")[/inputs\.[a-z-]+/] },
      "each that's left out unless .duel.rb asks for it, run where its input says to"
    steps = perf.dig("jobs", "duel", "steps")

    assert_equal "inputs.version-file", steps.find { |step| step["name"] == "Find the baseline's Ruby" }.fetch("if")
    assert_equal({"name" => "Set up", "if" => "inputs.setup != ''", "env" => {"SETUP" => "${{ inputs.setup }}"}, "run" => %(eval "$SETUP")}, steps.fetch(2))
    assert_equal "${{ inputs.accept-label }}", steps.fetch(1).dig("env", "ACCEPT_LABEL")
    assert_equal %w[accept-label perf-workflow marker], comment.dig(true, "workflow_call", "inputs").keys
    assert_includes comment.dig("jobs", "comment", "steps", 2, "run"), %(--marker "$MARKER"\n)
    assert_includes comment.dig("jobs", "again", "if"), "github.event.label.name == inputs.accept-label"
  end

  # With --reusable, workflows that call Duel's (at this release), with
  # what .duel.rb sets that isn't an input's default, and the
  # permissions their jobs need.
  def test_reusable
    gem

    assert_equal 0, init("--reusable").run
    perf = YAML.safe_load(read(".github/workflows/perf.yml"))
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))
    job = perf.dig("jobs", "duel")

    assert_equal "sferik/duel-ruby/.github/workflows/duel.yml@v#{Duel::VERSION}", job.fetch("uses")
    assert_equal({"contents" => "read", "pull-requests" => "read"}, job.fetch("permissions"), "nothing it writes")
    assert_equal({"ruby-version" => ruby_version, "accept-label" => "duel: accept"}, job.fetch("with"))
    assert_equal %w[pull_request merge_group push schedule workflow_dispatch], perf.fetch(true).keys
    assert perf.key?("concurrency")
    assert_equal "sferik/duel-ruby/.github/workflows/duel-comment.yml@v#{Duel::VERSION}", comment.dig("jobs", "comment", "uses")
    assert_equal({"actions" => "write", "pull-requests" => "write"}, comment.dig("jobs", "comment", "permissions"), "to run the Duel job again")
    assert_equal({"accept-label" => "duel: accept"}, comment.dig("jobs", "comment", "with"))
    assert_equal %w[workflow_run pull_request_target], comment.fetch(true).keys
  end

  # What .duel.rb asks for is passed on: the jobs for pushes (which write,
  # as the badge's does), no label, other release tags, and the Ruby
  # .ruby-version names.
  def test_reusable_settings
    gem
    write(".ruby-version", "4.0.1\n")
    write(".duel.rb", "Duel.configure do |c|\n  c.fail_on = :pull_requests\n  c.push_base = :last_passed\n  c.accept_label = nil\n" \
      "  c.release_tags = \"my_gem-v*\"\nend\n")
    init("--reusable", "--badge").run
    job = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel")
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))

    assert_equal({"version-file" => true, "release-tags" => "my_gem-v*", "comment-on-pushes" => true, "mark-passed" => true, "badge" => true},
      job.fetch("with"))
    assert_equal "write", job.dig("permissions", "contents")
    assert_equal({"actions" => "read", "pull-requests" => "write"}, comment.dig("jobs", "comment", "permissions"))
    refute comment.fetch("jobs").fetch("comment").key?("with"), "nothing to pass on"
    assert_equal %w[workflow_run], comment.fetch(true).keys, "no label to run it again for"
    %w[mark-passed comment-on-pushes].each do |input|
      write(".duel.rb", (input == "mark-passed") ? "Duel.configure { |c| c.push_base = :last_passed }\n" : "Duel.configure { |c| c.fail_on = :pull_requests }\n")
      FileUtils.rm_rf(File.join(root, ".github"))
      init("--reusable").run
      written = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel")

      assert_equal [true, "write"], [written.dig("with", input), written.dig("permissions", "contents")], input
    end
  end

  # Where .duel.rb doesn't load, the workflow has both jobs for pushes (as
  # the whole workflow does), and passes on no label or release tags.
  def test_reusable_with_a_config_that_doesnt_load
    gem
    write(".duel.rb", "raise 'not here'\n")
    init("--reusable").run

    assert_equal({"ruby-version" => ruby_version, "comment-on-pushes" => true, "mark-passed" => true},
      YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "with"))
  end

  # A project in a subdirectory: its directory, its branches, its marker,
  # and its Perf workflow's name.
  def test_reusable_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    init("--reusable", "--badge", at: project).run
    perf = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))
    comment = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser-comment.yml"))

    assert_equal({"ruby-version" => ruby_version, "working-directory" => "gems/parser", "accept-label" => "duel: accept", "badge" => true,
                  "passed-branch" => "duel/passed-gems-parser", "badge-branch" => "duel/badge-gems-parser", "marker" => "duel gems/parser"},
      perf.dig("jobs", "duel", "with"))
    assert_equal({"accept-label" => "duel: accept", "perf-workflow" => "Perf (gems/parser)", "marker" => "duel gems/parser"}, comment.dig("jobs", "comment", "with"))
    assert_equal ["Perf (gems/parser)", ["Perf (gems/parser)"]], [perf.fetch("name"), comment.dig(true, "workflow_run", "workflows")]
  end

  # --check with --reusable compares the workflows that call Duel's, and
  # --reusable is GitHub Actions': GitLab CI has no reusable workflows.
  def test_reusable_checked
    gem
    init("--reusable").run

    assert_equal 0, init("--check", "--reusable").run
    assert_equal 1, init("--check").run, "not the whole workflows"
    assert_equal 2, init("--reusable", "--gitlab").run
    assert_equal "duel init: invalid option: --reusable with --gitlab (GitLab CI has no reusable workflows)\n", @err.string
  end
end
