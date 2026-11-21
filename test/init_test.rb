# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "yaml"
require "shellwords"

# `duel init`, in a project of the test's own.
class InitTest < DuelTest
  cover "Duel::Init*"

  # The actions the workflows use, each at a commit (a tag can be moved).
  SETUP_RUBY = "ruby/setup-ruby@f9c4492e86def3e644ab32a0ef185eda5b0c20d0"
  DOWNLOAD_ARTIFACT = "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333"

  # Every action the workflows Duel writes use (and the reusable ones,
  # made from the same templates) is at a commit, with its release
  # beside it: a tag can be moved, and the jobs that use them hold
  # write permissions. (Duel's own reusable workflows are at the tag of
  # the release that writes them.)
  def test_every_action_at_a_commit
    templates = Dir[File.expand_path("../lib/duel/templates/*.erb", __dir__)] +
      Dir[File.expand_path("../plugins/rails/lib/generators/duel/install/templates/*.tt", __dir__)]
    # (With LF line endings, as Init#render reads them: JRuby on Windows
    # reads a CRLF checkout's as they are.)
    uses = templates.flat_map { |template| File.read(template).gsub("\r\n", "\n").scan(/uses: (.*)$/).flatten }.reject { |use| use.start_with?("<%= REUSABLE %>") }

    refute_empty uses
    assert_empty uses.grep_v(%r{\A[\w.-]+/[\w.-]+@\h{40} # v\d+\.\d+\.\d+\z})
  end

  def root = @root ||= FileUtils.mkdir_p(File.join(tmpdir, "my_gem")).first

  def init(*argv, at: root, input: StringIO.new) = Duel::Init.new(argv, out: (@out = StringIO.new), err: (@err = StringIO.new), input: input, root: at)

  # `duel init --standalone`, which writes the whole workflows, its
  # options parsed (for its #files).
  def whole(*argv, **options) = init("--standalone", *argv, **options).tap { |command| command.send(:parser).parse(["--standalone", *argv]) }

  def read(path) = File.read(File.join(root, path))

  # A file of Duel's repository, with LF line endings: as Git may check it
  # out with CRLF on Windows, which JRuby reads as it is.
  def repo_file(path) = File.read(File.expand_path(File.join("..", path), __dir__)).gsub("\r\n", "\n")

  # Runs +script+ with +shell+ (and -e, and for bash, -o pipefail, as
  # GitHub runs a step whose shell is bash, as every step of Duel's
  # reusable workflow's Duel job is), in +env+, as a file of its own
  # (JRuby on Windows passes an argument's quotes on as they are, not
  # escaped), in +chdir+ and its output to +out+, as the script itself
  # says (JRuby's system on Windows ignores chdir: and out:).
  # (Through Duel::Spawn.open3: JRuby's system on Windows may not give it
  # +env+. What it says is kept in @shell, for a failure, and shown.)
  def shell(env, script, shell: "bash", chdir: nil, out: nil)
    file = File.join(tmpdir, "script-#{@scripts = (@scripts || 0) + 1}.sh")
    File.binwrite(file, [*("cd #{Shellwords.escape(chdir)}" if chdir), *("exec > #{Shellwords.escape(out)}" if out), script].join("\n"))
    said, status = Duel::Spawn.open3(:capture2e, env, shell, "-e", *(%w[-o pipefail] if shell == "bash"), file)
    @shell = said
    print said unless out
    status.success?
  end

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
  # fails, the label that accepts one, and what a push is compared with,
  # the defaults shown.
  ENDING = "\n  # When the workflow comments on a pull request with the report: :always,\n" \
    "  # :results (passed or failed), :failures (failed, or couldn't compare),\n  # or :never.\n  # c.comment = :failures\n" \
    "\n  # Which runs a regression fails: :every_run, or :pull_requests, for a\n" \
    "  # project where people push to main directly (on GitHub Actions, another\n" \
    "  # run warns and passes, and a pushed commit gets the comment instead,\n" \
    "  # from a workflow job that runs where this is set: see docs/ci.md).\n  # c.fail_on = :every_run\n" \
    "\n  # A label that accepts a regression in a pull request, for a change\n  # that's slower on purpose (nil for none).\n  # c.accept_label = \"duel: accept\"\n" \
    "\n  # What the workflow compares a push with: :before (the commit before it),\n" \
    "  # or :last_passed (the last commit Duel passed, which a branch,\n" \
    "  # duel/passed/main, marks), so small slowdowns add up until they fail.\n" \
    "  # (A workflow job moves the branch where this is set: see docs/ci.md.)\n  # c.push_base = :before\nend\n"

  def test_a_gem
    gem
    write("config/settings.yml")

    assert_equal 0, whole.run
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
    assert_includes read(".github/workflows/perf-comment.yml"), %(--marker 'duel'\n), "the comment workflow's"
    jobs = YAML.safe_load(workflow).fetch("jobs")
    steps = ->(job) { jobs.dig(job, "steps").map { |step| step["name"]&.split&.first || step.fetch("uses")[%r{/([\w-]+)@}, 1] } }

    assert_equal %w[duel commit-comment passed], jobs.keys, "the jobs for pushes, which run where Duel says, and no badge without --badge"
    assert_equal %w[checkout Find setup-ruby Compare Say Keep], steps.call("duel")
  end

  # The jobs for pushes, where .duel.rb asks for them: a comment on a
  # pushed commit, and the last commit Duel passed marked.
  # Templates checked out with CRLF (as Git may on Windows), and read
  # without CRuby's text mode (as JRuby reads them there), write files of
  # LF line endings all the same.
  def test_templates_checked_out_with_crlf
    gem
    read = File.method(:read)
    crlf = ->(path, *args, **options) { read.call(path, *args, **options).then { |text| path.end_with?(".erb") ? text.gsub(/\r?\n/, "\r\n") : text } }

    assert_equal 0, stub(File, :read, crlf) { whole.run }
    assert_includes read(".github/workflows/perf.yml"), "name: Perf\n\non:\n"
    refute_includes read(".github/workflows/perf.yml") + read(".duel.rb"), "\r"
  end

  def test_the_jobs_for_pushes
    gem
    push_settings
    whole.run
    workflow = read(".github/workflows/perf.yml")
    jobs = YAML.safe_load(workflow).fetch("jobs")

    assert_equal %w[duel commit-comment passed], jobs.keys
    assert_equal [[DOWNLOAD_ARTIFACT, SETUP_RUBY, "Comment"], [SETUP_RUBY, "Move"]],
      %w[commit-comment passed].map { |job| jobs.dig(job, "steps").map { |step| step["uses"] || step.fetch("name").split.first } }
    assert_equal 1, workflow.scan(%(--commit "$GITHUB_SHA" --marker 'duel'\n)).size, "the Comment on the commit job's"
    assert_includes read(".github/workflows/perf-comment.yml"), %(--marker 'duel'\n), "the comment workflow's"
  end

  # The jobs for pushes, whatever .duel.rb says: they run where Duel's
  # outputs say to (see CLI#publish), as .duel.rb says.
  def test_the_jobs_for_pushes_whatever_duel_rb_says
    gem
    ["", "Duel.configure { |c| c.fail_on = :pull_requests }\n", "Duel.configure { |c| c.push_base = :last_passed }\n"].each do |config|
      write(".duel.rb", config)
      FileUtils.rm_rf(File.join(root, ".github"))
      whole.run
      jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")

      assert_equal %w[duel commit-comment passed], jobs.keys, config
      assert_equal "${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed != '' }}", jobs.dig("passed", "if")
      assert_equal "${{ needs.duel.outputs.passed }}", jobs.dig("passed", "steps", 1, "env", "BRANCH"), "the branch Duel names"
    end
  end

  # The label the comment workflow runs the Duel job again for: .duel.rb's,
  # or with --force, which writes .duel.rb anew, Duel's own.
  def test_the_label_of_duel_rb_or_duels_own
    gem
    write(".duel.rb", %(Duel.configure { |c| c.accept_label = "perf: accept" }\n))
    whole.run

    assert_includes read(".github/workflows/perf-comment.yml"), "github.event.label.name == 'perf: accept'"
    write(".duel.rb", %(Duel.configure { |c| c.accept_label = "perf: accept" }\n))
    whole("--force").run

    assert_includes read(".github/workflows/perf-comment.yml"), "github.event.label.name == 'duel: accept'"
  end

  # A .duel.rb that doesn't load (one of its plugins isn't installed, say)
  # leaves the workflows Duel's defaults, and says so.
  def test_a_config_that_doesnt_load
    gem
    write(".duel.rb", %(Duel.configure { |c| c.use :not_a_plugin }\n))
    whole.run

    assert_includes read(".github/workflows/perf-comment.yml"), "github.event.label.name == 'duel: accept'", "Duel's label"
    assert_equal "duel init: .duel.rb didn't load (Duel::Error: c.use :not_a_plugin: no duel/not_a_plugin to require: add the " \
      "duel-not_a_plugin gem to the Gemfile), so the workflows take Duel's defaults\n", @err.string
  end

  # The job that runs the branch's code (its benchmarks too) only reads,
  # and keeps the report, with what Duel said about commenting on a pull
  # request, for the Perf comment workflow.
  def test_the_workflows_permissions
    gem
    whole.run
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

    assert shell(env, said.fetch("run"))
    assert_equal "pr=12\ncomment=post\nstatus=failed\n", File.read(File.join(tmpdir, "duel", "comment.env"))
  end

  # A pull request's newer push cancels its run, and every other run runs
  # to the end, in a group of its own.
  def test_concurrency
    gem
    whole.run

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
    whole.run
    workflow = YAML.safe_load(read(".github/workflows/perf-comment.yml"))
    comment = workflow.dig("jobs", "comment")
    get, ruby, post = comment.fetch("steps")

    assert_equal [{"workflows" => ["Perf"], "types" => ["completed"]}, {}], [workflow.dig(true, "workflow_run"), workflow.fetch("permissions")]
    assert_equal "${{ github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion != 'cancelled' }}",
      comment.fetch("if")
    assert_equal({"actions" => "read", "pull-requests" => "write"}, comment.fetch("permissions"))
    assert_equal({"name" => "duel-report", "path" => "${{ runner.temp }}/report", "run-id" => "${{ github.event.workflow_run.id }}",
                  "github-token" => "${{ github.token }}"}, get.fetch("with"))
    assert_equal [SETUP_RUBY, {"ruby-version" => "ruby"}], ruby.values_at("uses", "with")
    assert_equal ["steps.report.outcome == 'success'"] * 2, [ruby, post].map { |step| step.fetch("if") }
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "HEAD_SHA" => "${{ github.event.workflow_run.head_sha }}"}, post.fetch("env"))
    assert_equal "gem install duel --version '#{Duel::VERSION}' --no-document\n" \
      "duel comment --report \"$RUNNER_TEMP/report\" --head \"$HEAD_SHA\" --marker 'duel'\n", post.fetch("run")
    refute_includes comment.to_s, "checkout"
    refute_includes comment.to_s, "bundle"
  end

  # A marker with a quote in it is quoted for the shell.
  def test_the_comment_workflows_marker_quoted
    gem
    whole.run
    init = self.init

    init.define_singleton_method(:marker) { "duel it's" }
    text = init.send(:render, "perf-comment.yml")

    assert_equal "duel it's", IO.popen(["bash", "-c", "printf %s #{text[/--marker (.*)$/, 1]}"], &:read)
  end

  # Duel gets the labels of a pull request, or of the one that merged a
  # push, for c.accept_label, and nothing's accepted without them.
  def test_the_pull_requests_labels
    gem
    whole.run
    steps = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps")
    labels = steps.find { |step| step["id"] == "labels" }

    assert_equal "${{ steps.labels.outputs.labels }}", steps.find { |step| step["name"] == "Compare" }.dig("env", "DUEL_LABELS")
    assert_equal ["github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.event_name == 'push'", true],
      labels.values_at("if", "continue-on-error")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "PR" => "${{ github.event.pull_request.number }}",
                  "QUEUED" => "${{ github.event.merge_group.head_ref }}"}, labels.fetch("env"), "nothing of .duel.rb's")
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/issues/$PR/labels" --jq '[.[].name]')
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '[.[0].labels[]?.name]')
  end

  # On a schedule, Duel finds what a label accepted since the last
  # release itself, with gh (see Baseline#merged_accepted): the steps that
  # run it get the token then, and only then.
  def test_what_was_accepted_since_the_last_release
    gem
    write(".ruby-version", "3.4.1\n")
    whole.run
    steps = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps")

    %w[baseline compare].each do |id|
      assert_equal "${{ github.event_name == 'schedule' && github.token || '' }}", steps.find { |step| step["id"] == id }.dig("env", "GH_TOKEN"), id
    end
    refute_includes read(".github/workflows/perf.yml"), "outputs.accepted", "no step of its own"
  end

  # Without a label that accepts a regression, the workflows look for
  # none: no schedule's accepted change, and no second run for the label.
  def test_no_label_that_accepts_a_regression
    gem
    write(".duel.rb", "Duel.configure { |c| c.accept_label = nil }\n")
    whole.run
    perf = read(".github/workflows/perf.yml")
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))

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
    whole.run
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
    env = {"PATH" => [bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR), "HEAD_SHA" => "abc", "ACTION" => action}

    assert shell(env, step.fetch("run"))
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
    whole.run
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
    whole.run

    assert_includes YAML.safe_load(read(".github/workflows/perf-comment.yml")).dig("jobs", "again", "if"), "== 'it''s fine'"
  end

  # A merge queue's run is compared with its base, as a pull request
  # (whose labels are the last one's queued).
  def test_a_merge_queue
    gem
    write(".ruby-version", "3.4.1\n")
    whole.run
    workflow = YAML.safe_load(read(".github/workflows/perf.yml"))
    steps = workflow.dig("jobs", "duel", "steps")
    labels = steps.find { |step| step["id"] == "labels" }.fetch("run")

    assert workflow.fetch(true).key?("merge_group"), "on: a merge queue's too"
    assert_nil steps.find { |step| step["name"] == "Compare" }.dig("env", "DUEL_BASE"), "Duel finds the queue's base, from the event"
    assert_includes steps.find { |step| step["id"] == "baseline" }.fetch("run"), "base=$(bundle exec duel base)\n", "and the baseline's Ruby's"
    script = "QUEUED=refs/heads/gh-readonly-queue/main/pr-123-0123abcd\n#{labels[/if \[ -n "\$QUEUED" \].*?\nfi\n/m]}echo $PR"

    assert_equal "123\n", IO.popen(["bash", "-c", script], &:read), "the pull request, from the queue's branch"
  end

  # A push that Duel says passed (only where c.push_base compares a push
  # with the last commit Duel passed) is marked passed, by a job of its
  # own that moves the branch (or makes it), and runs none of the code.
  def test_marking_a_push_passed
    gem
    push_settings
    whole.run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    passed = jobs.fetch("passed")
    ruby, step = passed.fetch("steps")

    assert_equal "${{ steps.compare.outputs.passed }}", jobs.dig("duel", "outputs", "passed")
    assert_equal ["duel", {"contents" => "write"}, "Mark the commit passed"], passed.values_at("needs", "permissions", "name")
    assert_equal({"group" => "${{ github.workflow }}-passed-${{ github.ref_name }}", "cancel-in-progress" => false}, passed.fetch("concurrency"),
      "one at a time for each branch")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed != '' }}", passed.fetch("if")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "BRANCH" => "${{ needs.duel.outputs.passed }}"}, step.fetch("env"), "the branch Duel names")
    assert_equal "bundle exec duel --markdown \"$RUNNER_TEMP/duel/duel.md\"", jobs.dig("duel", "steps").find { |s| s["name"] == "Compare" }.fetch("run"),
      "Duel says when there's no commit before a push"
    assert_equal [SETUP_RUBY, {"ruby-version" => "ruby"}], ruby.values_at("uses", "with")
    assert_equal "gem install duel --version '#{Duel::VERSION}' --no-document\nduel mark-passed \"$BRANCH\"\n", step.fetch("run"), "Duel's own code, from RubyGems"
    refute_includes passed.to_s, "checkout"
  end

  # With --badge, a push to the default branch that Duel compared updates
  # the badge, by a job of its own that writes it to a branch, and runs none of the
  # code: red where Duel failed the push or found a regression, and grey
  # where the Duel job failed before Duel said.
  # The branch the workflow guards: .duel.rb's c.main_branch, origin's
  # HEAD (the repository's default, in a clone), or the main or master
  # branch there is, as the push trigger and the passed branch's example
  # name it.
  def test_the_branch_it_guards
    git = ->(*args) { system("git", "-C", root, *args, out: File::NULL, err: File::NULL, exception: true) }
    git.call("init", "-q", "-b", "master")
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a commit")
    branches = -> { YAML.safe_load(read(".github/workflows/perf.yml")).dig(true, "push", "branches") }
    init("--badge").run

    assert_equal %w[master], branches.call, "the branch there is"
    assert_includes read(".duel.rb"), "  # project where people push to master directly (on GitHub Actions, another\n"
    assert_includes read(".duel.rb"), "  # duel/passed/master, marks), so small slowdowns add up until they fail.\n", "its .duel.rb's too"
    git.call("branch", "main")
    init("--force").run

    assert_equal %w[main], branches.call, "main, of both"
    git.call("branch", "-D", "main")

    assert_includes Duel::Init::Reusable.new([], root:).files.fetch(".github/workflows/duel-push.yml"),
      "(for main, git push origin main:duel/passed/main)", "Duel's own, whatever the project's"
    git.call("update-ref", "refs/remotes/origin/trunk", "HEAD")
    git.call("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    init("--force").run

    assert_equal %w[trunk], branches.call, "origin's default"
    whole("--force", "--badge").run

    assert_equal %w[trunk], branches.call, "the whole workflow's too"
    assert_includes read(".github/workflows/perf.yml"), "  # (for trunk, git push origin trunk:duel/passed/trunk).\n"
    write(".duel.rb", %(Duel.configure { |c| c.main_branch = "origin/stable" }\n))
    init("--check").run

    assert_includes @out.string, "-    branches: [trunk] # (and any other branch to guard, a stable one, say)\n+    branches: [stable] #", "what .duel.rb names"
  end

  def test_the_badge
    gem
    whole("--badge").run
    badge = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "badge")
    ruby, step = badge.fetch("steps")

    assert_equal ["duel", {"contents" => "write"}, "Update the badge"], badge.values_at("needs", "permissions", "name")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && github.ref_name == github.event.repository.default_branch && " \
      "(needs.duel.result == 'failure' || needs.duel.outputs.status == 'passed' || needs.duel.outputs.status == 'failed') }}", badge.fetch("if")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "RESULT" => "${{ needs.duel.result }}", "STATUS" => "${{ needs.duel.outputs.status }}"},
      step.fetch("env"))
    assert_equal [SETUP_RUBY, "gem install duel --version '#{Duel::VERSION}' --no-document\nduel badge duel/badge --status \"$STATUS\" --result \"$RESULT\"\n"], [ruby.fetch("uses"), step.fetch("run")],
      "Duel's own code, from RubyGems"
    refute badge.key?("defaults"), "nothing checked out"
    assert_equal({"group" => "${{ github.workflow }}-badge", "cancel-in-progress" => false}, badge.fetch("concurrency"),
      "one at a time, so an older push's run can't write over a newer one's")
    assert_includes read(".github/workflows/perf.yml"),
      "  #   [![Duel](https://raw.githubusercontent.com/OWNER/REPO/duel/badge/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/perf.yml)\n",
      "the README's Markdown, linked to the workflow's runs"
  end

  # The red badge is the green one, wider for its words.
  def test_the_red_badge
    green, red = %w[badge badge-regressed].map { |name| repo_file("assets/#{name}.svg") }

    assert_equal green.sub('width="133"', 'width="142"').gsub("perf guarded", "perf regressed").sub("#34D058", "#EA4A5A")
      .sub("#28A745", "#D73A49").sub("M0 0h76.939C78.629 0 80 1.343 80 3v14c0 1.657-1.37 3-3.061 3H0V0z",
        "M0 0h85.939C87.629 0 89 1.343 89 3v14c0 1.657-1.37 3-3.061 3H0V0z"), red
  end

  # The grey badge is the green one, wider for its words too.
  def test_the_grey_badge
    green, grey = %w[badge badge-not-measured].map { |name| repo_file("assets/#{name}.svg") }

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
    whole.run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    duel, comment = jobs.values_at("duel", "commit-comment")

    assert_includes duel.fetch("steps").last.fetch("if"), "github.event_name == 'push'", "the report kept for a push too"
    assert_equal ["duel", {"contents" => "write"}, "Comment on the commit"], comment.values_at("needs", "permissions", "name")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && (needs.duel.outputs.comment == 'post' || " \
      "needs.duel.outputs.comment == 'change') }}", comment.fetch("if")
    get, ruby, post = comment.fetch("steps")

    assert_equal({"GH_TOKEN" => "${{ github.token }}", "DUEL_COMMENT" => "${{ needs.duel.outputs.comment }}", "DUEL_STATUS" => "${{ needs.duel.outputs.status }}"},
      post.fetch("env"))
    assert_equal [SETUP_RUBY, ["steps.report.outcome == 'success'"] * 2], [ruby.fetch("uses"), [ruby, post].map { |step| step.fetch("if") }]
    assert_equal "gem install duel --version '#{Duel::VERSION}' --no-document\nduel comment --report \"$RUNNER_TEMP/report\" --commit \"$GITHUB_SHA\" --marker 'duel'\n", post.fetch("run"),
      "Duel's own code, from RubyGems"
    assert_equal [true, {"name" => "duel-report", "path" => "${{ runner.temp }}/report"}], get.values_at("continue-on-error", "with")
    refute_includes comment.to_s, "checkout"
    refute_includes comment.to_s, "bundle"
  end

  # A gem whose name has a dash: its library's in a directory.
  def test_a_dashed_gem
    write("my-gem.gemspec", %(Gem::Specification.new { |s| s.name = "my-gem" }\n))
    write("lib/my/gem.rb")
    whole.run

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
    whole.run
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
    whole.run

    assert_includes read(".duel.rb"), %(  # c.library = "my_gem"\n\n  # Builds each version's C extension, so that each is measured with its\n) +
      %(  # own build: with this, by default, for a project with ext/ and a\n  # Rakefile.\n  # c.build = "bundle exec rake compile"\n\n) +
      %(  # Each version runs on the Ruby that its own .ruby-version names, so a\n) +
      "  # branch that upgrades Ruby is compared on each version's Ruby.\n  c.ruby = :version_file\n#{ENDING}"
    workflow = read(".github/workflows/perf.yml")

    assert_includes workflow, "        with:\n          bundler-cache: true\n"
    assert_includes workflow, %(ruby_of() { git show "$1:./.ruby-version" 2>/dev/null)
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true}, baseline.fetch("with"), "with its own bundle")
    assert_equal 9, YAML.safe_load(workflow).dig("jobs", "duel", "steps").size
    workflow.scan(/^        run: \|\n((?:          .*\n)+)/).flatten.each { |script| refute_includes script, "${{", "only in env" }
  end

  # The step that finds the baseline's Ruby, run (with pipefail, as the
  # reusable workflow's bash runs it), with the baseline that duel base
  # says (here, a stand-in's): none where the baseline names the same as
  # HEAD, or names none (where git show fails), or there's no baseline,
  # and the baseline's where it names another.
  def test_finding_the_baseline_ruby
    gem
    write(".ruby-version", "3.4.1\n")
    whole.run
    step = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps").find { |s| s["id"] == "baseline" }
    git = ->(*args) { IO.popen(["git", "-C", root, *args], &:read).chomp }
    commit = lambda do |*unadded|
      git.call("add", "-A")
      unadded.each { |path| git.call("reset", "-q", path) }
      git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a commit")
      git.call("rev-parse", "HEAD")
    end
    git.call("init", "-q", "-b", "main")
    none = commit.call(".ruby-version")
    write(".ruby-version", "3.3.6\n")
    older = commit.call
    write(".ruby-version", "3.4.1\n")
    same = commit.call
    output = File.join(tmpdir, "output")
    bin = File.join(tmpdir, "bin")
    fake_command(File.join(bin, "bundle"), %([ "$*" = "exec duel base" ] && echo "$BASE"))
    found = lambda do |base|
      File.write(output, "")
      env = step.fetch("env").merge("BASE" => base, "GITHUB_OUTPUT" => output, "PATH" => path_with(bin))

      assert shell(env, step.fetch("run"), chdir: root)
      File.read(output)
    end

    assert_equal ["ruby=\n", "ruby=3.3.6\n", "ruby=\n", "ruby=\n"], [none, older, same, ""].map(&found)
  end

  # The guide's steps that set up the baseline's Ruby, in docs/ci.md, are
  # the workflow's.
  def test_the_guides_steps_for_the_baseline_ruby
    write(".ruby-version", "3.4.1\n")
    steps = repo_file("docs/ci.md")[/^```yaml\n      # \(After the step that sets up the candidate's Ruby, id: ruby\.\)\n(.*?)^```$/m, 1]

    assert_includes whole.files.fetch(".github/workflows/perf.yml"),
      "      - uses: #{SETUP_RUBY} # v1.342.0\n        id: ruby\n        with:\n          bundler-cache: true\n#{steps}      # Against the branch it targets"
  end

  # Without a gemspec: lib/'s only file is the library, or there's none
  # to guess, and it says to set one.
  def test_an_app
    write("lib/my_app.rb")
    whole.run

    assert_includes read(".duel.rb"), %(  # The library each version's workers require, from its lib/.\n  c.library = "my_app"\n#{ENDING})
    assert_includes @out.string, "  create    duel/my_app_duel.rb\n"
    assert_includes read("duel/my_app_duel.rb"), "# load my_app and every duel/**/*_duel.rb file. See\n"
    write("lib/other.rb")
    whole("--force").run

    assert_includes read(".duel.rb"), %(  #   c.library = ->(root) { require File.join(root, "config", "boot") }\n  # c.library = "my_library"\n#{ENDING})
    assert_includes @out.string, "  create    duel/example_duel.rb\n"
    assert_includes read("duel/example_duel.rb"), "# load every duel/**/*_duel.rb file. See\n"
    assert_includes @out.string, "\n  2. Set c.library in .duel.rb to what each version's workers require.\n  3. Replace the example in duel/example_duel.rb"
  end

  # Without Duel in the Gemfile (or a Gemfile), it says to add it.
  def test_duel_to_add
    write("lib/my_app.rb")
    whole.run

    assert_includes @out.string, %(\nNext:\n  1. Add gem "duel" to the Gemfile's development group, and run `bundle install`.\n  2. Replace)
    write("Gemfile", %(gem "duel-redis"\n))
    whole.run

    assert_includes @out.string, %(  1. Add gem "duel")
    write("Gemfile", %(gem 'duel', group: :development\ngem "stackprof"\n))
    whole.run

    assert_includes @out.string, "\n  1. Replace"
  end

  # Files that exist are left, unless --force.
  def test_existing_files
    gem
    write(".duel.rb", "mine")
    whole.run

    assert_equal "mine", read(".duel.rb")
    assert_includes @out.string, "  skip      .duel.rb (it exists: --force to overwrite)\n  create    duel/my_gem_duel.rb\n"
    whole("--force").run

    assert_includes read(".duel.rb"), "Duel.configure"
    assert_includes @out.string, "  overwrite .duel.rb\n  overwrite duel/my_gem_duel.rb\n  overwrite .github/workflows/perf.yml\n"
  end

  def test_a_dry_run
    gem
    write(".duel.rb", "mine")

    assert_equal 0, whole("--dry-run").run
    assert_equal "duel init: a dry run, so nothing is written\n  skip      .duel.rb (it exists: --force to overwrite)\n" \
      "  create    duel/my_gem_duel.rb\n", @out.string.lines.first(3).join
    assert_equal ["my_gem.gemspec", "lib", "Gemfile", ".duel.rb"].sort, Dir.children(root).sort
    whole("--dry-run", "--force").run

    assert_includes @out.string, "  overwrite .duel.rb\n"
    assert_equal "mine", read(".duel.rb")
  end

  # Duel's Rake task, added to a Rakefile (once), after a blank line.
  def test_the_rakefile
    gem
    write("Rakefile", "task :default")
    whole.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    assert_includes @out.string, "  create    .github/workflows/perf-comment.yml\n  append    Rakefile\n  append    Gemfile"
    whole.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    assert_includes @out.string, "  skip      Rakefile (it has Duel's task)\n"
    write("Rakefile", "task :default\n")
    whole.run

    assert_equal %(task :default\n\nrequire "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    write("Rakefile")
    whole.run

    assert_equal %(require "duel/rake_task"\nDuel::RakeTask.new\n), read("Rakefile")
    write("Rakefile", "x\n")
    whole("--dry-run").run

    assert_equal "x\n", read("Rakefile")
    assert_includes @out.string, "  append    Rakefile\n"
  end

  # StackProf, for profiles of regressions, added to the Gemfile (on
  # CRuby's platforms only): last in its development group, if it has
  # one, or else at its end, after a blank line. A Gemfile with
  # stackprof is left alone, even with --force.
  def test_stackprof
    gem

    assert_equal 0, whole.run
    assert_equal %(source "https://rubygems.org"\ngemspec\ngem "duel"\n\n# For profiles of regressions (StackProf runs on CRuby only)\n) +
      %(gem "stackprof", platforms: :mri\n), read("Gemfile")
    whole("--force").run

    assert_includes @out.string, "  skip      Gemfile (it has stackprof)\n\nNext:\n  1. Replace"
    assert_equal 1, read("Gemfile").scan("stackprof").size
    group = "group :development do\n  gem \"duel\"\n  if true\n  end\nend\n"
    {"" => "", "gem \"rake\"" => "gem \"rake\"\n", "group :test do\nend" => "group :test do\nend\n",
     "group :development do\n  gem \"duel\"\n" => "group :development do\n  gem \"duel\"\n"}.each do |gemfile, before|
      write("Gemfile", gemfile)
      whole.run

      assert_includes @out.string, "  append    Gemfile (gem \"stackprof\", platforms: :mri)\n"
      assert_equal "#{before}#{"\n" unless before.empty?}# For profiles of regressions (StackProf runs on CRuby only)\n" \
        "gem \"stackprof\", platforms: :mri\n", read("Gemfile"), gemfile
    end
    ["group :development do", "group :development, :test do", "group :test, :development do", "group(:development, :test) do",
      "  group :development do"].each do |opening|
      indent = opening[/\A */]
      write("Gemfile", "#{indent}platforms :ruby do\n#{indent}end\n\n#{opening}\n#{indent}  gem \"duel\"\n#{indent}end\n#{indent}gem \"x\"\n")
      whole.run

      assert_includes @out.string, "  insert    Gemfile (gem \"stackprof\", platforms: :mri, in the development group)\n"
      assert_equal "#{indent}platforms :ruby do\n#{indent}end\n\n#{opening}\n#{indent}  gem \"duel\"\n#{indent}  gem \"stackprof\", platforms: :mri\n#{indent}end\n" \
        "#{indent}gem \"x\"\n", read("Gemfile"), opening
    end
    write("Gemfile", group)
    whole.run

    assert_equal "group :development do\n  gem \"duel\"\n  if true\n  end\n  gem \"stackprof\", platforms: :mri\nend\n",
      read("Gemfile"), "at its own end"
  end

  def test_stackprof_in_a_dry_run
    gem
    whole("--dry-run").run

    assert_includes @out.string, "  append    Gemfile (gem \"stackprof\", platforms: :mri)\n\nNext:\n  1. Run `bundle install`"
    write("Gemfile", "group :development do\nend\n")
    whole("--dry-run").run

    assert_includes @out.string, "  insert    Gemfile (gem \"stackprof\", platforms: :mri, in the development group)\n"
    assert_equal "group :development do\nend\n", read("Gemfile")
  end

  # Without a Gemfile, there's none to add StackProf to.
  def test_stackprof_without_a_gemfile
    write("lib/my_app.rb")
    whole.run

    refute_includes @out.string, "stackprof"
    refute_path_exists File.join(root, "Gemfile")
  end

  # A Rails app is set up by duel-rails's generator.
  def test_a_rails_app
    write("config/application.rb")

    assert_equal 1, whole.run
    assert_equal "duel init: this is a Rails app (config/application.rb). Add duel-rails to the Gemfile's development group, " \
      "and run `bin/rails generate duel:install` instead\n", @err.string
    assert_empty @out.string
    assert_equal %w[config], Dir.children(root)
    assert_equal 1, whole("--check").run
    assert_includes @err.string, "and run `bin/rails generate duel:install --check` instead\n", "its own --check"
  end

  # In a subdirectory, the baseline's bundle is installed there too.
  def test_a_project_in_a_subdirectory_with_a_ruby_version
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    File.write(File.join(project, ".ruby-version"), "3.4.1\n")
    whole(at: project).run
    workflow = File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"working-directory" => "gems/parser", "ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true},
      baseline.fetch("with"))
  end

  # A project in a subdirectory of its repository: the workflow is at the
  # repository's root, named for the project's directory, and runs there.
  def test_a_project_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    push_settings(at: project)
    whole("--badge", at: project).run

    assert_includes @out.string, "  create    ../../.github/workflows/perf-gems-parser.yml\n"
    workflow = File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))

    assert_includes workflow, "    defaults:\n      run:\n        working-directory: gems/parser\n    steps:\n"
    assert_includes workflow, "        with:\n          working-directory: gems/parser\n          ruby-version:"
    assert_includes workflow, %(--commit "$GITHUB_SHA" --marker 'duel gems/parser'\n)
    comments = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser-comment.yml"))

    assert_equal ["Perf (gems/parser)", ["Perf (gems/parser)"]], [YAML.safe_load(workflow).fetch("name"), comments.dig(true, "workflow_run", "workflows")],
      "a workflow of its own, and its comments"
    assert_includes comments.dig("jobs", "comment", "steps", 2, "run"), %(--marker 'duel gems/parser'\n)
    assert_includes YAML.safe_load(workflow).dig("jobs", "badge", "steps", 1, "run"), "duel badge duel/badge-gems-parser ", "a badge of its own"
    assert_includes workflow, "[![Duel](https://raw.githubusercontent.com/OWNER/REPO/duel/badge-gems-parser/badge.svg)]" \
      "(https://github.com/OWNER/REPO/actions/workflows/perf-gems-parser.yml)", "linked to its own workflow's runs"
    assert_path_exists File.join(project, ".duel.rb")
    assert_equal({"run" => {"working-directory" => "gems/parser"}}, YAML.safe_load(workflow).dig("jobs", "duel", "defaults"))
    refute YAML.safe_load(workflow).dig("jobs", "commit-comment").key?("defaults"), "nothing checked out there"
    whole(at: tmpdir).run

    assert_includes @out.string, "  create    .github/workflows/perf.yml\n", "at the root"
  end

  # The workflow is the guide's, in docs/ci.md (with this Ruby).
  def test_the_guides_workflow
    workflow = repo_file("docs/ci.md")[/^```yaml\n# \.github\/workflows\/perf\.yml\n(.*?)^```$/m, 1]

    assert_equal workflow.sub(%("3.4" # (or none, with a .ruby-version)), %("#{ruby_version}")), whole.files.fetch(".github/workflows/perf.yml")
  end

  # And the badge's job, as it writes it with --badge.
  def test_the_guides_badge_job
    workflow = whole("--badge").files.fetch(".github/workflows/perf.yml")
    job = repo_file("docs/ci.md")[/^```yaml\n# \.github\/workflows\/perf\.yml, in jobs: \(with duel init --badge\)\n(.*?)^```$/m, 1]

    assert_equal workflow[workflow.index("  # Duel's badge")..].rstrip, job.rstrip
  end

  # And the GitLab CI jobs.
  def test_the_guides_gitlab_jobs
    jobs = repo_file("docs/ci.md")[/^```yaml\n# \.gitlab\/duel\.gitlab-ci\.yml\n(.*?)^```$/m, 1]
    init = init("--gitlab")
    init.send(:parser).parse(["--gitlab"])

    assert_equal jobs.sub("ruby:3.4", "ruby:#{ruby_version}"), init.files.fetch(".gitlab/duel.gitlab-ci.yml")
  end

  # And the one that comments on a pull request.
  def test_the_guides_comment_workflow
    workflow = repo_file("docs/ci.md")[/^```yaml\n# \.github\/workflows\/perf-comment\.yml\n(.*?)^```$/m, 1]

    assert_equal workflow, whole.files.fetch(".github/workflows/perf-comment.yml")
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
    assert_equal [{"DUEL_FORCE" => "1"}], duel.fetch("rules").filter_map { |rule| rule["variables"] }, "Duel finds the baseline, from the pipeline"
    %w[duel:comment duel:commit-comment duel:passed].each do |name|
      assert_equal [["duel"], {"GIT_STRATEGY" => "none"}], jobs.fetch(name).values_at("needs", "variables"), name
    end
    assert_includes jobs.dig("duel:comment", "rules", 0, "if"), "$DUEL_COMMENT_TOKEN"
    gem = "gem install duel --version '#{Duel::VERSION}' --no-document"

    assert_equal ["ruby:slim", [gem, %(duel comment --report . --head "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-$CI_COMMIT_SHA}" --marker 'duel')]],
      jobs.fetch("duel:comment").values_at("image", "script"), "Duel's own code, from RubyGems"
    assert_includes jobs.dig("duel:passed", "rules", 0, "if"), "$DUEL_TOKEN"
    assert_equal "duel/passed", jobs.dig("duel:passed", "resource_group"), "one at a time"
  end

  # The GitLab CI jobs for a push run Duel's own code, from RubyGems,
  # signed in with DUEL_TOKEN: none of the push's.
  def test_gitlabs_jobs_for_a_push
    gem
    init("--gitlab").run
    jobs = YAML.safe_load(read(".gitlab/duel.gitlab-ci.yml"))
    gem = "gem install duel --version '#{Duel::VERSION}' --no-document"

    assert_equal ["ruby:slim", [gem, %(duel comment --report . --commit "$CI_COMMIT_SHA" --marker 'duel')]],
      jobs.fetch("duel:commit-comment").values_at("image", "script")
    assert_equal ["ruby:slim", ['[ -n "$DUEL_PASSED" ] || exit 0', gem, %(duel mark-passed "$DUEL_PASSED")]], jobs.fetch("duel:passed").values_at("image", "script")
    assert_includes jobs.dig("duel:commit-comment", "rules", 0, "if"), "$DUEL_TOKEN"
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
    assert_includes text, %(--report gems/parser --commit "$CI_COMMIT_SHA" --marker 'duel gems/parser'\n)
    assert_includes text, %(--report gems/parser --head "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-$CI_COMMIT_SHA}" --marker 'duel gems/parser'\n)
    assert_includes text, %(duel mark-passed "$DUEL_PASSED"\n), "the branch Duel names"
    assert_equal "duel/gems/parser/passed", jobs.dig("duel:gems/parser:passed", "resource_group"), "its own, with no colon, which GitLab doesn't take"
  end

  # --check says whether each workflow is what it writes, or how it
  # differs, or that it's missing, and writes nothing.
  def test_check
    gem
    whole.run
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort

    assert_equal 0, whole("--check").run
    assert_equal "  same      .github/workflows/perf.yml\n  same      .github/workflows/perf-comment.yml\n", @out.string
    assert_equal read(".github/workflows/perf.yml"), File.binread(File.join(root, ".github/workflows/perf.yml")), "written with LF, as it is"
    crlf = File.join(root, ".github/workflows/perf-comment.yml")
    File.binwrite(crlf, File.binread(crlf).gsub("\n", "\r\n"))

    assert_equal 0, whole("--check").run, "with CRLF line endings, as git can check it out on Windows"
    File.write(File.join(root, ".github/workflows/perf.yml"), read(".github/workflows/perf.yml").sub("name: Perf\n", "name: Mine\n"))

    assert_equal 1, whole("--check").run, "one that differs"
    File.delete(File.join(root, ".github/workflows/perf-comment.yml"))

    assert_equal 1, whole("--check").run
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
    assert_equal 1, whole("--check", "--badge").run, "with other options, other workflows"
    assert_equal 1, whole("--check", "--gitlab").run
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
    command = whole(*argv, input: input)
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
    command = whole("--force", "--gitlab", input: terminal("y\n"))
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

  # A page of fewer than a hundred labels is the last: it asks for no more.
  def test_the_last_page_of_gitlab_labels
    command = init("--gitlab")
    names = Array.new(99) { |i| "label #{i}" }
    page = gitlab_labels(*names)
    listed = []
    command.define_singleton_method(:cli) do |*args|
      listed << args.last
      page
    end

    assert_equal 99, command.send(:gitlab_labels, "me/my_gem").size
    assert_equal %w[1], listed
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
              --standalone                 Write whole workflows, not ones that call Duel's reusable ones (at this release)
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

  # The reusable workflow's Duel job runs its steps in bash on every
  # runner (on Windows, Git's, not PowerShell), and where the caller sets
  # up what needs Ruby first (setup-after-ruby: on Windows, the devkit's
  # compiler), it does that once Ruby is set up, and installs the bundle
  # after it, not as setup-ruby would, before.
  def test_the_reusable_workflow_on_windows
    perf = YAML.safe_load(Duel::Init::Reusable.new([]).files.fetch(".github/workflows/duel.yml"))
    steps = perf.dig("jobs", "duel", "steps")

    assert_equal({"run" => {"shell" => "bash", "working-directory" => "${{ inputs.working-directory }}"}}, perf.dig("jobs", "duel", "defaults"))
    rubies = steps.select { |step| step["uses"]&.start_with?("ruby/setup-ruby") }

    assert_equal ["${{ inputs.setup-after-ruby == '' }}"] * 2, rubies.map { |step| step.dig("with", "bundler-cache") }
    after, bundle = steps.drop(steps.index(rubies.first) + 1).first(2)

    assert_equal({"name" => "Set up, once Ruby is", "if" => "inputs.setup-after-ruby != ''", "env" => {"SETUP" => "${{ inputs.setup-after-ruby }}"},
                  "run" => %(eval "$SETUP")}, after)
    assert_equal ["Install the bundle", "inputs.setup-after-ruby != ''"], bundle.values_at("name", "if")
    assert_includes perf.dig(true, "workflow_call", "inputs", "runs-on", "description"), "Linux, macOS or Windows"
  end

  # Duel's reusable workflows, in its repository, are what the templates
  # render with each setting an input (see Init::Reusable): `rake
  # workflows` writes them.
  def test_the_reusable_workflows
    files = Duel::Init::Reusable.new([]).files

    assert_equal %w[.github/workflows/duel.yml .github/workflows/duel-comment.yml .github/workflows/duel-push.yml], files.keys
    files.each { |path, content| assert_equal content, repo_file(path), "#{path}: run `rake workflows`" }
    perf, comment, push = files.values.map { |content| YAML.safe_load(content) }

    assert_equal ["Duel", "Duel push"], [perf, push].map { |workflow| workflow.fetch("name") }
    inputs = %w[ruby-version version-file jit runs-on timeout-minutes working-directory gemfile submodules setup setup-after-ruby report]

    assert_equal inputs, perf.dig(true, "workflow_call", "inputs").keys
    refute perf.key?("concurrency"), "the caller's: one of its own would wait for the caller's run"
    assert_equal %w[duel], perf.fetch("jobs").keys, "the Duel job alone: the push workflow's write"
    steps = perf.dig("jobs", "duel", "steps")

    assert_equal "inputs.version-file", steps.find { |step| step["name"] == "Find the baseline's Ruby" }.fetch("if")
    assert_equal({"name" => "Set up", "if" => "inputs.setup != ''", "env" => {"SETUP" => "${{ inputs.setup }}"}, "run" => %(eval "$SETUP")}, steps.fetch(2))
    gemfile = {"name" => "Use the caller's Gemfile", "if" => "inputs.gemfile != ''", "env" => {"GEMFILE" => "${{ inputs.gemfile }}"},
               "run" => %(echo "BUNDLE_GEMFILE=$(pwd -W 2> /dev/null || pwd)/$GEMFILE" >> "$GITHUB_ENV")}
    jit = {"name" => "Turn on the JIT", "if" => "inputs.jit != 'none'", "env" => {"JIT" => "${{ inputs.jit }}"}}

    assert_equal [gemfile, jit], [steps[3], steps[4].except("run")]
    assert_operator steps.index { |step| step["uses"]&.start_with?("ruby/setup-ruby") }, :>, 4
    assert_equal %w[accept-label perf-workflow marker], comment.dig(true, "workflow_call", "inputs").keys
    assert_includes comment.dig("jobs", "comment", "steps", 2, "run"), %(--marker "$MARKER"\n)
    assert_includes comment.dig("jobs", "again", "if"), "github.event.label.name == inputs.accept-label"
  end

  # Duel's push workflow has the whole Perf workflow's jobs for a push,
  # each run where what the Duel job said (its inputs) says to, and the
  # badge's where its input says to, none of them needing a job of their
  # own workflow's.
  def test_the_reusable_push_workflow
    content = Duel::Init::Reusable.new([]).files.fetch(".github/workflows/duel-push.yml")
    push = YAML.safe_load(content)
    jobs = push.fetch("jobs")

    assert_equal %w[comment status passed result working-directory report badge], push.dig(true, "workflow_call", "inputs").keys
    assert push.dig(true, "workflow_call", "inputs", "result", "required"), "how the Duel job ended, for the badge"
    assert_equal %w[commit-comment passed badge], jobs.keys
    assert_equal [false, false, "inputs.badge"], jobs.values.map { |job| job.fetch("if")[/inputs\.badge/] || job.key?("needs") }
    assert_equal ["inputs.comment", "inputs.passed", "inputs.result"], jobs.values.map { |job| job.fetch("if")[/inputs\.(comment|passed|result)/] },
      "what the Duel job said, from the push workflow's inputs"
    refute_includes content, "needs.duel", "none of the Duel job's own"
    assert_includes content, "/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/perf.yml)\n", "the badge linked to the Perf workflow's runs"
  end

  # The JIT the caller says (jit:, one of them, as Ruby runs one at
  # most), for every worker of both versions, run: YJIT or ZJIT, and
  # anything else fails.
  def test_the_reusable_workflows_jit
    workflow = YAML.safe_load(Duel::Init::Reusable.new([]).files.fetch(".github/workflows/duel.yml"))
    step = workflow.dig("jobs", "duel", "steps").find { |s| s["name"] == "Turn on the JIT" }
    env = File.join(tmpdir, "env")
    turned = lambda do |jit|
      File.write(env, "")
      [shell({"JIT" => jit, "GITHUB_ENV" => env}, step.fetch("run")), File.read(env)]
    end

    assert_equal({"type" => "string", "default" => "none"}, workflow.dig(true, "workflow_call", "inputs", "jit").except("description"))
    assert_equal [true, "RUBY_YJIT_ENABLE=1\n"], turned.call("yjit")
    assert_equal [true, "RUBY_ZJIT_ENABLE=1\n"], turned.call("zjit")
    assert_equal [false, ""], turned.call("both")
    assert_includes @shell, "::error::jit: both: give none, yjit or zjit"
  end

  # The reusable Perf workflow's Duel job, which runs the branch's code,
  # only reads, and asks for nothing more: the jobs that write
  # (contents: write) are the push workflow's, which the caller grants
  # that to alone.
  def test_the_reusable_workflows_permissions
    files = Duel::Init::Reusable.new([]).files
    perf, push = files.values_at(".github/workflows/duel.yml", ".github/workflows/duel-push.yml").map { |content| YAML.safe_load(content) }

    assert_equal({"contents" => "read", "pull-requests" => "read"}, perf.fetch("permissions"))
    refute perf.dig("jobs", "duel").key?("permissions"), "the Duel job's, as the workflow's"
    assert_equal({}, push.fetch("permissions"))
    assert_equal [{"contents" => "write"}] * 3, push.fetch("jobs").values.map { |job| job.fetch("permissions") }
  end

  # The reusable Perf workflow's Duel job runs where the caller says (on
  # a runner, within a limit, with submodules), names its check and its
  # report for a call that's one of several, and says what Duel said, for
  # the caller's own jobs. The Perf comment workflow comments with every
  # call's report.
  def test_the_reusable_workflows_calls
    perf, comment, push = Duel::Init::Reusable.new([]).files.values.map { |content| YAML.safe_load(content) }
    job = perf.dig("jobs", "duel")
    named = "duel-report${{ inputs.report != '' && format('-{0}', inputs.report) || '' }}"

    assert_equal ["Duel${{ inputs.report != '' && format(' ({0})', inputs.report) || '' }}", "${{ inputs.runs-on }}", "${{ inputs.timeout-minutes }}"],
      job.values_at("name", "runs-on", "timeout-minutes")
    assert_equal [["string", "ubuntu-latest"], ["number", 60], ["string", "false"]],
      perf.dig(true, "workflow_call", "inputs").values_at("runs-on", "timeout-minutes", "submodules").map { |input| input.values_at("type", "default") }
    assert_equal "${{ inputs.submodules }}", job.dig("steps", 0, "with", "submodules")
    assert_equal [named, named], [job.fetch("steps").find { |step| step["name"] == "Keep the report" }.dig("with", "name"),
      push.dig("jobs", "commit-comment", "steps", 0, "with", "name")]
    assert_equal(%w[comment status passed].to_h { |name| [name, "${{ jobs.duel.outputs.#{name} }}"] },
      perf.dig(true, "workflow_call", "outputs").transform_values { |output| output.fetch("value") })
    assert_equal({"pattern" => "duel-report*"}, comment.dig("jobs", "comment", "steps", 0, "with").slice("pattern", "name"))
  end

  # By default, workflows that call Duel's (at this release), with
  # what .duel.rb sets that isn't an input's default, and the
  # permissions their jobs need: reading for the Duel job, which runs the
  # branch's code, and contents: write for the push workflow's alone,
  # which runs only for a push, with what the Duel job said.
  def test_reusable
    gem

    assert_equal 0, init.run
    perf = YAML.safe_load(read(".github/workflows/perf.yml"))
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))
    job = perf.dig("jobs", "duel")

    push = perf.dig("jobs", "push")

    assert_equal %w[duel push], perf.fetch("jobs").keys
    assert_equal "sferik/duel-ruby/.github/workflows/duel.yml@v#{Duel::VERSION}", job.fetch("uses")
    assert_equal({"contents" => "read", "pull-requests" => "read"}, job.fetch("permissions"), "no write for a pull request's run")
    assert_equal({"ruby-version" => ruby_version}, job.fetch("with"), "nothing of .duel.rb's: Duel reads it")
    assert_equal ["sferik/duel-ruby/.github/workflows/duel-push.yml@v#{Duel::VERSION}", "duel", "${{ !cancelled() && github.event_name == 'push' }}",
      {"contents" => "write"}], push.values_at("uses", "needs", "if", "permissions")
    assert_equal(%w[comment status passed].to_h { |name| [name, "${{ needs.duel.outputs.#{name} }}"] }.merge("result" => "${{ needs.duel.result }}"),
      push.fetch("with"), "what the Duel job said, and how it ended")
    assert_equal %w[pull_request merge_group push schedule workflow_dispatch], perf.fetch(true).keys
    assert perf.key?("concurrency")
    assert_equal "sferik/duel-ruby/.github/workflows/duel-comment.yml@v#{Duel::VERSION}", comment.dig("jobs", "comment", "uses")
    assert_equal({"actions" => "write", "pull-requests" => "write"}, comment.dig("jobs", "comment", "permissions"), "to run the Duel job again")
    assert_equal({"accept-label" => "duel: accept"}, comment.dig("jobs", "comment", "with"))
    assert_equal %w[workflow_run pull_request_target], comment.fetch(true).keys
  end

  # What the workflow needs to know before Duel runs is passed on: the
  # Ruby .ruby-version names, and the badge, which writes. Nothing of
  # .duel.rb's, which Duel reads, but the label, for the comment
  # workflow, which runs none of the code.
  def test_reusable_settings
    gem
    write(".ruby-version", "4.0.1\n")
    write(".duel.rb", "Duel.configure do |c|\n  c.fail_on = :pull_requests\n  c.push_base = :last_passed\n  c.accept_label = nil\n" \
      "  c.release_tags = \"my_gem-v*\"\nend\n")
    init("--badge").run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    comment = YAML.safe_load(read(".github/workflows/perf-comment.yml"))

    assert_equal({"version-file" => true}, jobs.dig("duel", "with"))
    assert_equal [true, "write"], [jobs.dig("push", "with", "badge"), jobs.dig("push", "permissions", "contents")], "the badge, the push workflow's"
    assert_equal({"actions" => "read", "pull-requests" => "write"}, comment.dig("jobs", "comment", "permissions"))
    refute comment.fetch("jobs").fetch("comment").key?("with"), "nothing to pass on"
    assert_equal %w[workflow_run], comment.fetch(true).keys, "no label to run it again for"
  end

  # Where .duel.rb doesn't load, the workflows take Duel's defaults: its
  # label.
  def test_reusable_with_a_config_that_doesnt_load
    gem
    write(".duel.rb", "raise 'not here'\n")
    init.run

    assert_equal({"ruby-version" => ruby_version}, YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "with"))
    assert_equal({"accept-label" => "duel: accept"}, YAML.safe_load(read(".github/workflows/perf-comment.yml")).dig("jobs", "comment", "with"))
  end

  # The reusable workflow's badge branch and marker, from its
  # working-directory: duel/badge and duel at the root, and for a project
  # in a subdirectory, its path's, as Init names them.
  def test_the_reusable_workflows_names
    jobs = YAML.safe_load(Duel::Init::Reusable.new([]).files.fetch(".github/workflows/duel-push.yml")).fetch("jobs")
    named = jobs.dig("badge", "steps", 1, "run")[/^branch=duel\/badge\n.*?\n/m]
    out = File.join(tmpdir, "out")
    branch = ->(directory) { shell({"DIRECTORY" => directory}, "#{named}echo \"$branch\"", out: out) && File.read(out).chomp }

    assert_equal %w[duel/badge duel/badge-gems-parser], %w[. gems/parser].map(&branch)
    assert_equal "${{ inputs.working-directory == '.' && 'duel' || format('duel {0}', inputs.working-directory) }}",
      jobs.dig("commit-comment", "steps", 2, "env", "MARKER")
  end

  # A project in a subdirectory: its directory, from which the reusable
  # workflow works out its branches and its marker, and its Perf
  # workflow's name.
  def test_reusable_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    init("--badge", at: project).run
    perf = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))
    comment = YAML.safe_load_file(File.join(tmpdir, ".github", "workflows", "perf-gems-parser-comment.yml"))

    assert_equal({"ruby-version" => ruby_version, "working-directory" => "gems/parser"}, perf.dig("jobs", "duel", "with"))
    assert_equal({"working-directory" => "gems/parser", "badge" => true}, perf.dig("jobs", "push", "with").slice("working-directory", "badge"))
    assert_includes File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml")),
      %(      result: ${{ needs.duel.result }}\n      working-directory: "gems/parser"\n      badge: true\n), "as YAML strings: a directory named yes, say, isn't true"
    assert_equal({"accept-label" => "duel: accept", "perf-workflow" => "Perf (gems/parser)", "marker" => "duel gems/parser"}, comment.dig("jobs", "comment", "with"))
    assert_equal ["Perf (gems/parser)", ["Perf (gems/parser)"]], [perf.fetch("name"), comment.dig(true, "workflow_run", "workflows")]
  end

  # --check compares the workflows that call Duel's, and with
  # --standalone, the whole ones. GitLab CI has no reusable workflows, so
  # with --gitlab, it's the whole jobs either way.
  def test_reusable_checked
    gem
    init.run

    assert_equal [0, 1], [init("--check").run, init("--check", "--standalone").run], "not the whole workflows"
    init("--gitlab").run

    assert_equal [0, 0], [init("--check", "--gitlab").run, init("--check", "--gitlab", "--standalone").run]
  end
end
