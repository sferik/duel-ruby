# frozen_string_literal: true

require_relative "test_helper"
require "generators/duel/install/install_generator"
require "duel/version" # (for the templates' Duel::VERSION)
require "yaml"

# `rails generate duel:install`, in a directory of the test's own, for the
# tests' app (its routes, and its database: SQLite).
class GeneratorTest < PluginTest
  cover "Duel::Generators::InstallGenerator*"

  def generate(*args, gemfile: "source \"https://rubygems.org\"\n", root: @dir)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "Gemfile"), gemfile)
    Duel::Generators::InstallGenerator.start([*args, "--quiet", "--force"], destination_root: root)
  end

  def read(path) = File.read(File.join(@dir, path))

  def generator(root = @dir) = Duel::Generators::InstallGenerator.new([], {}, destination_root: root)

  # Duel's own template +name+, as `duel init` writes it: without what's
  # only Duel's reusable workflow's (an input in a condition, a line for
  # one).
  def own(name)
    File.read(File.expand_path("../../../lib/duel/templates/#{name}.erb", __dir__))
      .gsub(/<%= "[^"]*" if reusable\? %>/, "").gsub(/^<% if reusable\? -%>\n(?:(?!.*<%).*\n)*?<% end -%>\n/, "")
  end

  # What Duel's own template +name+ renders, as `duel init` writes it, with
  # +values+.
  def render_own(name, **values)
    template = File.read(File.expand_path("../../../lib/duel/templates/#{name}.erb", __dir__))
    init = Struct.new(*values.keys) { def reusable? = false }.new(*values.values)
    ERB.new(template, trim_mode: "-").result(init.instance_eval { binding })
  end

  # The workflow, written again where .duel.rb is +config+: by default, one
  # that asks for the jobs for pushes (a comment on a pushed commit, and
  # the last commit Duel passed marked), and with +badge+, the badge's job.
  def regenerate(root = @dir, config: "Duel.configure do |c|\n  c.fail_on = :pull_requests\n  c.push_base = :last_passed\nend\n", quiet: true, badge: false)
    File.write(File.join(root, ".duel.rb"), config)
    Duel::Generators::InstallGenerator.new([], {force: true, quiet: quiet, badge: badge}, destination_root: root).create_workflow
  end

  # How .duel.rb ends: when the workflow comments, which runs a regression
  # fails, the label that accepts one, and what a push is compared
  # with, the defaults shown.
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

  # What it adds to the Gemfile for profiles of regressions.
  STACKPROF = %(gem "stackprof", platforms: :mri, group: :development\n)

  # Runs it with --check: its exit status (nil where it didn't exit), and
  # what it said.
  def checked(*args)
    status = nil
    out, = capture_io do
      Duel::Generators::InstallGenerator.start(["--check", *args], destination_root: @dir)
    rescue SystemExit => e
      status = e.status
    end
    [status, out]
  end

  # --check says whether each workflow is what it writes, or how it
  # differs, or that it's missing, as `duel init --check` does, and
  # writes nothing. Where one isn't, it exits with 1.
  def test_check
    generate
    files = -> { Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).sort.to_h { |f| [f, File.file?(File.join(@dir, f)) && File.read(File.join(@dir, f))] } }
    before = files.call
    status, out = checked

    assert_nil status
    assert_equal [%w[identical .github/workflows/perf.yml], %w[identical .github/workflows/perf-comment.yml]], out.lines.map(&:split)
    assert_equal before, files.call, "nothing written"
    File.write(File.join(@dir, ".github/workflows/perf.yml"), read(".github/workflows/perf.yml").sub("name: Perf\n", "name: Mine\n"))

    assert_equal 1, checked.first, "one that differs"
    File.delete(File.join(@dir, ".github/workflows/perf-comment.yml"))
    before = files.call
    status, out = checked

    assert_equal 1, status
    assert_equal <<~OUT, out.gsub(/^ +/, "")
      differs  .github/workflows/perf.yml
      --- .github/workflows/perf.yml
      +++ .github/workflows/perf.yml (duel:install)
      @@ -1,4 +1,4 @@
      -name: Mine
      +name: Perf

      on:
      pull_request:
      missing  .github/workflows/perf-comment.yml
    OUT
    assert_equal before, files.call, "nothing written: not .duel.rb, the Gemfile, or the workflows"
    assert_equal 1, checked("--badge").first, "with other options, other workflows"
    generate

    File.delete(File.join(@dir, ".github/workflows/perf-comment.yml"))

    assert_equal 1, checked.first, "one that's missing"
  end

  # --check writes nothing even where nothing's set up: no .duel.rb, and
  # nothing added to the Gemfile, the plugin for its database's server
  # or StackProf. Without it, it says nothing of the workflows but what it
  # wrote.
  def test_check_writes_nothing
    File.write(File.join(@dir, "Gemfile"), "source \"https://rubygems.org\"\n")

    assert_equal 1, checked("--database", "postgresql").first
    assert_equal ["Gemfile"], Dir.children(@dir)
    assert_equal "source \"https://rubygems.org\"\n", read("Gemfile")
    out, = capture_io { Duel::Generators::InstallGenerator.start(["--force"], destination_root: @dir) }

    assert_equal 1, out.lines.grep(/perf-comment\.yml/).size, out
  end

  def test_the_files_it_makes
    generate

    assert_equal [false, false], ["c.ruby", "require"].map { |text| read(".duel.rb").include?(text) },
      "the runner's Ruby, without a .ruby-version, and no require: c.use requires the plugin"
    assert read(".duel.rb").end_with?("Duel.configure do |c|\n  # To load test/fixtures, or db/seeds.rb, into each worker's database:\n" \
      "  # fixtures: :all, or seeds: true.\n  c.use :rails, database: :sqlite\n#{ENDING}")
    assert_equal File.read(File.expand_path("../lib/generators/duel/install/templates/benchmark.rb.tt", __dir__)),
      read("config/environments/benchmark.rb")
    assert_equal <<~RUBY.lines.last(8).join, read("duel/requests_duel.rb").lines.last(8).join
      #   duel_request "posts: create", "POST /posts", params: {post: {title: "Hi"}}

      duel_request "posts: index", "GET /posts"

      duel_request "posts: cached", "GET /cached"

      duel_request "posts: plain", "GET /plain"

      duel_request "posts: boom", "GET /boom"
    RUBY
    workflow = read(".github/workflows/perf.yml")

    assert_equal %w[duel commit-comment passed], YAML.safe_load(workflow).fetch("jobs").keys,
      "the jobs for pushes, which run where Duel says, and no badge without --badge"
    refute_includes workflow, "working-directory"
    refute_includes workflow, "baseline-ruby", "no Ruby of the baseline's own"
    assert_includes workflow, "          ruby-version: \"#{RUBY_VERSION[/\A\d+\.\d+/]}\"\n          bundler-cache: true\n"
    refute_includes workflow, "apt-get"
    assert_equal "source \"https://rubygems.org\"\n#{STACKPROF}", read("Gemfile"), "StackProf, and no plugin for SQLite"
  end

  # The workflow writes Duel's report in Markdown, and another, Duel's
  # own, comments on a pull request with it. The job that runs the app's
  # code only reads, and keeps the report.
  def test_the_workflow_comments
    generate
    workflow = read(".github/workflows/perf.yml")
    duel = YAML.safe_load(workflow).dig("jobs", "duel")

    assert_includes workflow, %(        run: bundle exec duel --markdown "$RUNNER_TEMP/duel/duel.md"\n)
    assert_equal({"contents" => "read", "pull-requests" => "read"}, YAML.safe_load(workflow).fetch("permissions"))
    assert_equal({"fetch-depth" => 0, "persist-credentials" => false}, duel.fetch("steps").first.fetch("with"))
    assert_equal ["Keep the report", "duel-report"], [duel.fetch("steps").last.fetch("name"), duel.fetch("steps").last.dig("with", "name")]
    assert_equal render_own("perf-comment.yml", working_directory: nil, marker: "duel", accept_label: "duel: accept"),
      read(".github/workflows/perf-comment.yml"), "Duel's own"
  end

  # Whether it comments is Duel's to say, from .duel.rb: the Comment on
  # the commit job posts a new comment, or none, as Duel's own workflow
  # does.
  def test_the_workflow_comments_as_duel_says
    generate
    regenerate(badge: true)
    workflow = read(".github/workflows/perf.yml")
    duel = YAML.safe_load(workflow).dig("jobs", "duel")

    assert_equal({"comment" => "${{ steps.compare.outputs.comment }}", "status" => "${{ steps.compare.outputs.status }}",
                  "passed" => "${{ steps.compare.outputs.passed }}"}, duel.fetch("outputs"))
    assert_equal own("perf.yml")[/^concurrency:\n.*?^\n/m],
      workflow[/^concurrency:\n.*?^\n/m], "Duel's own"
    assert_equal own("perf.yml")[/^      - name: Say whether to comment\n.*?^      - name: Keep/m],
      workflow[/^      - name: Say whether to comment\n.*?^      - name: Keep/m], "Duel's own"
    %w[commit-comment passed badge].each do |job|
      assert_equal own("perf-push-jobs.yml")[/^  #{job}:\n.*?^        run: \|\n/m], workflow[/^  #{job}:\n.*?^        run: \|\n/m], "Duel's own job, #{job}"
    end
    jobs = YAML.safe_load(workflow).fetch("jobs")
    gem = "gem install duel --version '#{Duel::VERSION}' --no-document\n"

    assert_equal ["#{gem}duel comment --report \"$RUNNER_TEMP/report\" --commit \"$GITHUB_SHA\" --marker 'duel'\n", "#{gem}duel mark-passed \"$BRANCH\"\n",
      "#{gem}duel badge duel/badge --status \"$STATUS\" --result \"$RESULT\"\n"], %w[commit-comment passed badge].map { |job| jobs.dig(job, "steps").last.fetch("run") }
    # (Its whole workflow's, without the reusable one's.)
    badge = own("perf-push-jobs.yml")[/^  # Duel's badge.*\z/m].gsub(/<% if reusable\? -%>\n.*?<% else -%>\n(.*?)<% end -%>\n/m, '\\1')
      .gsub(/<% if reusable\? -%>\n.*?<% end -%>\n/m, "")

    badge = badge.gsub("<%= badge_branch %>", "duel/badge").gsub("<%= workflow_name %>", "perf.yml").gsub(%(<%= reusable? ? '"$branch"' : badge_branch %>), "duel/badge")
      .gsub("<%= Duel::VERSION %>", Duel::VERSION)

    assert_equal badge.delete_suffix("<% end -%>\n"), workflow[/^  # Duel's badge.*\z/m], "Duel's own, updating the badge"
  end

  # With --badge, the workflow keeps a badge for the README, by a job
  # that's last.
  def test_the_badge
    generate("--badge")

    assert_equal %w[duel commit-comment passed badge], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys
    assert_includes read(".github/workflows/perf.yml"), "/duel/badge/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/perf.yml)\n",
      "the README's Markdown, linked to the workflow's runs"
  end

  # A benchmark of the app's boot, in a process of its own.
  def test_the_boot_benchmark
    generate

    assert_includes read("duel/boot_duel.rb"), %(\nduel_process "boot: the app", "bin/rails", "runner", "1"\n)
  end

  # With fixtures, they're loaded into each worker's database. With a
  # .ruby-version, each version runs on its own's Ruby, and the
  # workflow's Ruby is the app's.
  def test_fixtures_and_a_ruby_version
    FileUtils.mkdir_p(File.join(@dir, "test", "fixtures", "admin"))
    File.write(File.join(@dir, "test", "fixtures", "admin", "users.yml"), "")
    File.write(File.join(@dir, ".ruby-version"), "3.4\n")
    generate

    assert_includes read(".duel.rb"), "  c.ruby = :version_file\n  c.use :rails, database: :sqlite, fixtures: :all\n#{ENDING}"
    workflow = read(".github/workflows/perf.yml")

    assert_includes workflow, "        with:\n          bundler-cache: true\n"
    assert_operator workflow.index("id: ruby\n"), :<, workflow.index("id: baseline-ruby"), "the app's Ruby first, for duel base"
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true}, baseline.fetch("with"), "with its own bundle")
    assert_includes workflow, %(ruby_of() { git show "$1:./.ruby-version" 2>/dev/null)
    assert_includes workflow, %(ln -sfn "$PREFIX" ~/.rubies/ruby-)
    assert_equal 9, YAML.safe_load(workflow).dig("jobs", "duel", "steps").size, "YAML"
  end

  # An app in a subdirectory of its repository (a monorepo's): its
  # workflow is at the repository's root, named for the app's directory,
  # and runs there.
  # A .duel.rb that doesn't load leaves the workflows Duel's defaults.
  def test_a_config_that_doesnt_load
    generate
    out, = capture_io { regenerate(config: "Duel.configure { |c| c.use :not_a_plugin }\n", quiet: false) }

    assert_equal %w[duel commit-comment passed], YAML.safe_load(read(".github/workflows/perf.yml")).fetch("jobs").keys
    said = ".duel.rb didn't load (Duel::Error: c.use :not_a_plugin: no duel/not_a_plugin to require: add the duel-not_a_plugin gem " \
      "to the Gemfile), so the workflows take Duel's defaults"

    assert_equal 1, out.scan(/warning  #{Regexp.escape(said)}$/).size, "said once, as .duel.rb is loaded once"
  end

  # The branch the workflow guards, as `duel init` finds it: origin's
  # HEAD, or else main, or master, whichever is there, or main (with no
  # git, say).
  def test_the_branch_it_guards
    git = ->(*args) { system("git", "-C", @dir, *args, out: File::NULL, err: File::NULL, exception: true) }
    git.call("init", "-q", "-b", "master")
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a commit")
    generate
    workflow = read(".github/workflows/perf.yml")

    assert_equal %w[master], YAML.safe_load(workflow).dig(true, "push", "branches"), "the branch there is"
    assert_includes workflow, "  # (for master, git push origin master:duel/passed/master).\n"
    assert_includes read(".duel.rb"), "  # duel/passed/master, marks), so small slowdowns add up until they fail.\n", "its .duel.rb's too"
    git.call("branch", "main")

    assert_equal "main", generator.send(:default_branch), "main, of both"
    git.call("update-ref", "refs/remotes/origin/trunk", "HEAD")
    git.call("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")

    assert_equal "trunk", generator.send(:default_branch), "origin's default"
    assert_equal "main", stub(Open3, :capture3, ->(*) { raise Errno::ENOENT }) { generator.send(:default_branch) }, "no git"
  end

  def test_an_app_in_a_subdirectory
    system("git", "init", "--quiet", @dir, exception: true)
    app = File.join(@dir, "apps", "blog")
    generate(root: app)
    regenerate(app, badge: true)
    workflow = read(".github/workflows/perf-apps-blog.yml")

    assert_includes workflow, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          fetch-depth: 0 ", "the whole repository"
    assert_includes workflow, "    defaults:\n      run:\n        working-directory: apps/blog\n"
    assert_includes workflow, "        with:\n          working-directory: apps/blog\n"
    assert_equal [%(          duel comment --report "$RUNNER_TEMP/report" --commit "$GITHUB_SHA" --marker 'duel apps/blog'),
      "  #   [![Duel](https://raw.githubusercontent.com/OWNER/REPO/duel/badge-apps-blog/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/perf-apps-blog.yml)",
      %(          duel badge duel/badge-apps-blog --status "$STATUS" --result "$RESULT"),
      %(          duel comment --report "$RUNNER_TEMP/report" --head "$HEAD_SHA" --marker 'duel apps/blog')],
      (workflow + read(".github/workflows/perf-apps-blog-comment.yml")).lines(chomp: true).grep(/--marker |duel badge |badge\.svg\)/),
      "comments, and a badge, of its own, linked to its own workflow's runs"
    assert_equal [{"run" => {"working-directory" => "apps/blog"}}, nil],
      YAML.safe_load(workflow).fetch("jobs").values_at("duel", "commit-comment").map { |job| job["defaults"] }, "none where nothing's checked out"
    assert_path_exists File.join(app, ".duel.rb")
    refute_path_exists File.join(app, ".github")
    assert_equal [File.realpath(@dir), "apps/blog"], [File.realpath(generator(app).send(:repository)), generator(app).send(:working_directory)]
    assert_nil generator(@dir).send(:working_directory), "at the root"
    File.symlink(app, File.join(@dir, "blog"))

    assert_equal "apps/blog", generator(File.join(@dir, "blog")).send(:working_directory), "through a symlink: where it is"
  end

  # Outside a repository, or without git: the app's own directory.
  def test_the_repository_outside_one
    assert_equal @dir, generator.send(:repository)
    found = stub(Open3, :capture3, ->(*) { raise Errno::ENOENT }) { generator.send(:repository) }

    assert_equal @dir, found
    FileUtils.mkdir(File.join(@dir, "app"))
    File.symlink(File.join(@dir, "app"), File.join(@dir, "link"))

    assert_nil generator(File.join(@dir, "link")).send(:working_directory), "through a symlink too"
  end

  # Each worker's database's server comes from its plugin (added to the
  # Gemfile, once), and the workflow installs the server.
  def test_a_database_server
    generate("--database=postgresql")

    assert_includes read(".duel.rb"), "c.use :rails, database: :postgresql"
    assert_includes read("Gemfile"), %(gem "duel-postgresql", group: :development\n)
    assert_includes read(".github/workflows/perf.yml"), "      - run: sudo apt-get install -y postgresql libpq-dev\n"
    %w[mysql2 trilogy].each do |database|
      generate("--database=#{database}", gemfile: %(gem "duel-mysql"\n))

      assert_includes read(".duel.rb"), "c.use :rails, database: :#{database}"
      assert_equal %(gem "duel-mysql"\n#{STACKPROF}), read("Gemfile"), "there already"
      assert_includes read(".github/workflows/perf.yml"), "      - run: sudo apt-get install -y mysql-server\n"
      assert_includes read(".github/workflows/perf.yml"), "sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld"
    end
  end

  # StackProf, for profiles of regressions (on CRuby's platforms only),
  # unless the Gemfile has it.
  def test_stackprof
    generate(gemfile: %(group :development do\n  gem "stackprof"\nend\n))

    assert_equal %(group :development do\n  gem "stackprof"\nend\n), read("Gemfile")
    generate("--database=postgresql", gemfile: "")

    assert_equal %(\ngem "duel-postgresql", group: :development\n#{STACKPROF}), read("Gemfile")
  end

  # The app's own database, by its adapter: one Duel can't give each
  # worker (or none, without Active Record) is nil.
  def test_the_apps_database
    generator = self.generator
    adapters = {"sqlite3" => "sqlite", "postgresql" => "postgresql", "postgis" => "postgresql", "mysql2" => "mysql2",
                "trilogy" => "trilogy", "oracle_enhanced" => nil, nil => nil}

    adapters.each do |adapter, database|
      assert_equal [database], [stub(generator, :adapter, -> { adapter }) { generator.send(:database) }], adapter.inspect
    end
    assert_equal "sqlite3", generator.send(:adapter)
    generate(gemfile: "")

    refute_includes read("Gemfile"), "duel-"
  end

  # The primary database's adapter, of the app's environment's.
  def test_the_adapter
    generator = self.generator
    config = ->(name, adapter) { ActiveRecord::DatabaseConfigurations::HashConfig.new("benchmark", name, {adapter: adapter}) }
    configs = [config.call("queue", "sqlite3"), config.call("primary", "postgresql"), config.call("cache", "mysql2")]
    found = stub(ActiveRecord::Base.configurations, :configs_for, ->(env_name:) { (env_name == Rails.env) ? configs : [] }) do
      generator.send(:adapter)
    end

    assert_equal "postgresql", found
    assert_equal "trilogy", stub(ActiveRecord::Base.configurations, :configs_for, ->(**) { [config.call("other", "trilogy")] }) { generator.send(:adapter) }
    assert_nil stub(ActiveRecord::Base.configurations, :configs_for, ->(**) { [] }) { generator.send(:adapter) }
    saved = Object.send(:remove_const, :ActiveRecord)

    assert_nil generator.send(:adapter), "without Active Record"
  ensure
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # Routes a GET without parameters reaches, of the app's own controllers:
  # the first ROUTES, each path once, and each action once (the root, to
  # posts#index too, would be a second benchmark of the same name).
  def test_routes
    route = Struct.new(:verb, :path, :requirements)
    spec = ->(path) { Struct.new(:spec).new(path) }
    routes = [
      route.new("GET", spec.call("/posts(.:format)"), {controller: "posts", action: "index"}),
      route.new("POST", spec.call("/drafts(.:format)"), {controller: "drafts", action: "create"}),
      route.new("GET", spec.call("/posts/:id(.:format)"), {controller: "posts", action: "show"}),
      route.new("GET", spec.call("/files/*path"), {controller: "files", action: "show"}),
      route.new("GET", spec.call("/up"), {controller: "rails/health", action: "show"}),
      route.new("GET", spec.call("/rails/active_storage/x"), {controller: "active_storage/blobs", action: "show"}),
      route.new("GET", spec.call("/feed"), {}),
      route.new("GET", spec.call("/posts(.:format)"), {controller: "posts", action: "list"}),
      route.new("GET", spec.call("/"), {controller: "posts", action: "index"})
    ] + Array.new(12) { |i| route.new("GET", spec.call("/p#{i}"), {controller: "pages", action: "p#{i}"}) }
    generator = self.generator
    found = stub(Rails.application.routes, :routes, -> { routes }) { generator.send(:routes) }

    assert_equal [["posts: index", "GET /posts"], *Array.new(9) { |i| ["pages: p#{i}", "GET /p#{i}"] }], found
    assert_equal 10, Duel::Generators::InstallGenerator::ROUTES
  end
end
