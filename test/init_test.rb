# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# `duel init`, in a project of the test's own.
class InitTest < DuelTest
  cover "Duel::Init*"

  def root = @root ||= FileUtils.mkdir_p(File.join(tmpdir, "my_gem")).first

  def init(*argv, at: root) = Duel::Init.new(argv, out: (@out = StringIO.new), err: (@err = StringIO.new), root: at)

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

  def ruby_version = RUBY_VERSION[/\A\d+\.\d+/]

  # How .duel.rb ends: when the workflow comments, which runs a regression
  # fails, the label that accepts one, and what a push is compared with,
  # the defaults shown.
  ENDING = "\n  # When the workflow comments on a pull request with the report: :always,\n" \
    "  # :results (passed or failed), :failures (failed, or couldn't compare),\n  # or :never.\n  # c.comment = :failures\n" \
    "\n  # Which runs a regression fails: :every_run, or :pull_requests, for a\n" \
    "  # project where people push to main directly (on GitHub Actions, another\n" \
    "  # run warns and passes, and a pushed commit gets the comment instead).\n  # c.fail_on = :every_run\n" \
    "\n  # A label that accepts a regression in a pull request (nil for none).\n  # c.accept_label = \"duel: accept\"\n" \
    "\n  # What the workflow compares a push with: :before (the commit before it),\n" \
    "  # or :last_passed (the last commit Duel passed, which the branch\n" \
    "  # duel/passed marks), so small slowdowns add up until they fail a push.\n  # c.push_base = :before\nend\n"

  def test_a_gem
    gem
    write("config/settings.yml")

    assert_equal 0, init.run
    assert_equal <<~OUT, @out.string
        create    .duel.rb
        create    duel/my_gem_duel.rb
        create    .github/workflows/perf.yml
        append    Gemfile (gem "stackprof", platforms: :mri)

      Next:
        1. Run `bundle install`, for StackProf (added to the Gemfile).
        2. Replace the example in duel/my_gem_duel.rb with benchmarks of your own code.
        3. Run `bundle exec duel --force`. It compares the code with itself, and passes when the benchmarks are sound.
        4. Commit and push. On a pull request, the workflow compares the code with the main branch, and comments with the report when a benchmark fails (c.comment in .duel.rb says when).
    OUT
    assert_empty @err.string
    assert_includes read(".duel.rb"), <<~RUBY
      Duel.configure do |c|
        # The library each version's workers require (from the gemspec, unless
        # this says otherwise).
        # c.library = "my_gem"
    RUBY
    assert read(".duel.rb").end_with?(%(  # c.library = "my_gem"\n#{ENDING}))
    assert_includes read("duel/my_gem_duel.rb"), "fails if the candidate is slower at any of them. Each version's workers\n" \
      "# load my_gem and every duel/**/*_duel.rb file. See\n"
    assert_includes read("duel/my_gem_duel.rb"), %(\nduel "example: join words" do\n)
    workflow = read(".github/workflows/perf.yml")

    assert_includes workflow, "        with:\n          ruby-version: \"#{ruby_version}\"\n          bundler-cache: true\n"
    refute_includes workflow, "baseline-ruby"
    refute_includes workflow, "working-directory"
    assert_includes workflow, %(marker="<!-- duel"\n)
    jobs = YAML.safe_load(workflow).fetch("jobs")
    steps = ->(job) { jobs.dig(job, "steps").map { |step| step["name"]&.split&.first || step.fetch("uses")[%r{/([\w-]+)@}, 1] } }

    assert_equal %w[checkout setup-ruby Find Compare Keep], steps.call("duel")
    assert_equal %w[Get Comment], steps.call("comment")
    assert_equal %w[Get Comment], steps.call("commit-comment")
    assert_equal %w[Move], steps.call("passed")
  end

  # The job that runs the branch's code (its benchmarks too) only reads,
  # and keeps the report. Another, which checks nothing out and runs none
  # of it, comments with it, on a pull request from the repository.
  def test_the_workflows_permissions
    gem
    init.run
    workflow = YAML.safe_load(read(".github/workflows/perf.yml"))
    duel, comment = workflow.fetch("jobs").values_at("duel", "comment")

    assert_equal({"contents" => "read", "pull-requests" => "read"}, workflow.fetch("permissions"))
    refute duel.key?("permissions")
    assert_equal({"fetch-depth" => 0, "persist-credentials" => false}, duel.fetch("steps").first.fetch("with"))
    assert_equal({"name" => "duel-report", "path" => "${{ runner.temp }}/duel.md", "if-no-files-found" => "ignore", "retention-days" => 1},
      duel.fetch("steps").last.fetch("with"))
    assert_equal ["duel", {"pull-requests" => "write"}], comment.values_at("needs", "permissions")
    assert_includes comment.fetch("if"), "github.event.pull_request.head.repo.full_name == github.repository"
    assert_includes comment.fetch("if"), "(needs.duel.outputs.comment == 'post' || needs.duel.outputs.comment == 'change')", "as Duel says"
    assert_equal({"comment" => "${{ steps.compare.outputs.comment }}", "status" => "${{ steps.compare.outputs.status }}",
                  "passed" => "${{ steps.compare.outputs.passed }}"}, duel.fetch("outputs"))
    assert_equal "compare", duel.fetch("steps").find { |step| step["name"] == "Compare" }.fetch("id")
    assert_equal({"COMMENT" => "${{ needs.duel.outputs.comment }}", "STATUS" => "${{ needs.duel.outputs.status }}"},
      comment.dig("steps", 1, "env").slice("COMMENT", "STATUS"))
    assert_equal ["POST"], comment.dig("steps", 1, "run").scan(/--method (\w+)/).flatten, "a new comment, never an edit"
    assert_equal [true, "duel-report"], [comment.dig("steps", 0, "continue-on-error"), comment.dig("steps", 0, "with", "name")]
    refute_includes comment.to_s, "checkout"
    refute_includes comment.to_s, "bundle"
  end

  # Duel gets the labels of a pull request, or of the one that merged a
  # push, for c.accept_label, and nothing's accepted without them.
  def test_the_pull_requests_labels
    gem
    init.run
    steps = YAML.safe_load(read(".github/workflows/perf.yml")).dig("jobs", "duel", "steps")
    labels = steps.find { |step| step["id"] == "labels" }

    assert_equal "${{ steps.labels.outputs.labels }}", steps.find { |step| step["name"] == "Compare" }.dig("env", "DUEL_LABELS")
    assert_equal ["github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.event_name == 'push'", true],
      labels.values_at("if", "continue-on-error")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "PR" => "${{ github.event.pull_request.number }}",
                  "QUEUED" => "${{ github.event.merge_group.head_ref }}"}, labels.fetch("env"))
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/issues/$PR/labels" --jq '[.[].name]')
    assert_includes labels.fetch("run"), %(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '[.[0].labels[]?.name]')
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
    init.run
    jobs = YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs")
    passed = jobs.fetch("passed")
    step = passed.dig("steps", 0)

    assert_equal "${{ steps.compare.outputs.passed }}", jobs.dig("duel", "outputs", "passed")
    assert_equal ["duel", {"contents" => "write"}, "Mark the commit passed"], passed.values_at("needs", "permissions", "name")
    assert_equal "${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed == 'true' }}", passed.fetch("if")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "BRANCH" => "duel/passed"}, step.fetch("env"))
    assert_equal %(gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" -f sha="$GITHUB_SHA" -F force=true > /dev/null 2>&1 ||\n) +
      %(  gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$GITHUB_SHA" > /dev/null\n), step.fetch("run")
    assert_equal "bundle exec duel --markdown \"$RUNNER_TEMP/duel.md\"", jobs.dig("duel", "steps").find { |s| s["name"] == "Compare" }.fetch("run"),
      "Duel says when there's no commit before a push"
    assert_equal 1, passed.fetch("steps").size
  end

  # On a push, a job of its own comments on the commit, as Duel says
  # (only where a regression in a push passes: see Config#fail_on), with
  # the permission that takes, and running none of the code either.
  def test_the_comment_on_a_pushed_commit
    gem
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
    assert_equal comment.fetch("steps").first, jobs.dig("comment", "steps").first
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
    assert_equal 8, YAML.safe_load(workflow).dig("jobs", "duel", "steps").size
    workflow.scan(/^        run: \|\n((?:          .*\n)+)/).flatten.each { |script| refute_includes script, "${{", "only in env" }
  end

  # The guide's steps that set up the baseline's Ruby, in docs/ci.md, are
  # the workflow's.
  def test_the_guides_steps_for_the_baseline_ruby
    write(".ruby-version", "3.4.1\n")
    steps = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n      # \(Before the step that sets up the candidate's Ruby\.\)\n(.*?)^```$/m, 1]

    assert_includes init.files.fetch(".github/workflows/perf.yml"), "    steps:\n      - uses: actions/checkout@v7\n" \
      "        with:\n          fetch-depth: 0 # the baseline comes from history, tags included\n          persist-credentials: false\n" \
      "      # (And whatever else your tests need set up: packages, services.)\n#{steps}      - uses: ruby/setup-ruby@v1\n"
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
    assert_includes @out.string, "  create    .github/workflows/perf.yml\n  append    Rakefile\n  append    Gemfile"
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
    assert_equal "origin/duel/passed-gems-parser", YAML.safe_load(workflow).dig("jobs", "duel", "steps", 1, "env", "PASSED")
  end

  # A project in a subdirectory of its repository: the workflow is at the
  # repository's root, named for the project's directory, and runs there.
  def test_a_project_in_a_subdirectory
    system("git", "init", "--quiet", tmpdir, exception: true)
    project = File.join(tmpdir, "gems", "parser")
    FileUtils.mkdir_p(File.join(project, "lib"))
    File.write(File.join(project, "lib", "parser.rb"), "")
    init(at: project).run

    assert_includes @out.string, "  create    ../../.github/workflows/perf-gems-parser.yml\n"
    workflow = File.read(File.join(tmpdir, ".github", "workflows", "perf-gems-parser.yml"))

    assert_includes workflow, "    defaults:\n      run:\n        working-directory: gems/parser\n    steps:\n"
    assert_includes workflow, "        with:\n          working-directory: gems/parser\n          ruby-version:"
    assert_includes workflow, %(marker="<!-- duel gems/parser"\n)
    assert_equal "duel/passed-gems-parser", YAML.safe_load(workflow).dig("jobs", "passed", "steps", 0, "env", "BRANCH"), "a branch of its own"
    assert_path_exists File.join(project, ".duel.rb")
    assert_equal({"run" => {"working-directory" => "gems/parser"}}, YAML.safe_load(workflow).dig("jobs", "duel", "defaults"))
    refute YAML.safe_load(workflow).dig("jobs", "comment").key?("defaults"), "nothing checked out there"
    init(at: tmpdir).run

    assert_includes @out.string, "  create    .github/workflows/perf.yml\n", "at the root"
  end

  # The workflow is the guide's, in docs/ci.md (with this Ruby).
  def test_the_guides_workflow
    workflow = File.read(File.expand_path("../docs/ci.md", __dir__))[/^```yaml\n# \.github\/workflows\/perf\.yml\n(.*?)^```$/m, 1]

    assert_equal workflow.sub(%("3.4" # (or none, with a .ruby-version)), %("#{ruby_version}")), init.files.fetch(".github/workflows/perf.yml")
  end

  def test_help
    assert_equal 0, init("--help").run
    assert_empty @err.string
    assert_equal <<~HELP, @out.string
      Usage: duel init [options]

      Sets Duel up in this project: .duel.rb, a benchmark to start from in duel/, a GitHub Actions workflow,
      a Rake task, and StackProf in the Gemfile.

              --force                      Overwrite files that exist
              --dry-run                    Say what it would do, and write nothing
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
end
