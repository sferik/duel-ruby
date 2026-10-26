# frozen_string_literal: true

require_relative "test_helper"
require "generators/duel/install/install_generator"
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

  # What it adds to the Gemfile for profiles of regressions.
  STACKPROF = %(gem "stackprof", platforms: :mri, group: :development\n)

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

    assert_equal %w[duel comment commit-comment passed], YAML.safe_load(workflow).fetch("jobs").keys, "YAML"
    refute_includes workflow, "working-directory"
    refute_includes workflow, "baseline-ruby", "no Ruby of the baseline's own"
    assert_includes workflow, "          ruby-version: \"#{RUBY_VERSION[/\A\d+\.\d+/]}\"\n          bundler-cache: true\n"
    refute_includes workflow, "apt-get"
    assert_equal "source \"https://rubygems.org\"\n#{STACKPROF}", read("Gemfile"), "StackProf, and no plugin for SQLite"
  end

  # The workflow writes Duel's report in Markdown, and comments on a pull
  # request with it. The job that runs the app's code only reads, and
  # keeps the report: another, which checks nothing out and runs none of
  # it, comments.
  def test_the_workflow_comments
    generate
    workflow = read(".github/workflows/perf.yml")
    duel, comment = YAML.safe_load(workflow).fetch("jobs").values_at("duel", "comment")

    assert_includes workflow, %(        run: bundle exec duel --markdown "$RUNNER_TEMP/duel.md"\n)
    assert_includes workflow, %(          marker="<!-- duel"\n)
    assert_equal({"contents" => "read", "pull-requests" => "read"}, YAML.safe_load(workflow).fetch("permissions"))
    assert_equal({"fetch-depth" => 0, "persist-credentials" => false}, duel.fetch("steps").first.fetch("with"))
    assert_equal ["Keep the report", "duel-report"], [duel.fetch("steps").last.fetch("name"), duel.fetch("steps").last.dig("with", "name")]
    assert_equal ["duel", {"pull-requests" => "write"}], comment.values_at("needs", "permissions")
    assert_equal ["Get the report", "Comment on the pull request"], comment.fetch("steps").map { |step| step.fetch("name") }
    refute_includes comment.to_s, "checkout"
  end

  # Whether it comments is Duel's to say, from .duel.rb: the Comment job
  # posts a new comment, or none, as Duel's own workflow does.
  def test_the_workflow_comments_as_duel_says
    generate
    workflow = read(".github/workflows/perf.yml")
    duel, comment = YAML.safe_load(workflow).fetch("jobs").values_at("duel", "comment")

    assert_equal({"comment" => "${{ steps.compare.outputs.comment }}", "status" => "${{ steps.compare.outputs.status }}",
                  "passed" => "${{ steps.compare.outputs.passed }}"}, duel.fetch("outputs"))
    assert_includes comment.fetch("if"), "(needs.duel.outputs.comment == 'post' || needs.duel.outputs.comment == 'change')", "as Duel says"
    assert_equal ["POST"], comment.dig("steps", 1, "run").scan(/--method (\w+)/).flatten, "a new comment, never an edit"
    assert_equal File.read(File.expand_path("../../../lib/duel/templates/perf.yml.erb", __dir__))[/^  comment:\n.*?^          marker=/m],
      workflow[/^  comment:\n.*?^          marker=/m], "Duel's own"
    assert_equal File.read(File.expand_path("../../../lib/duel/templates/perf.yml.erb", __dir__))[/^  commit-comment:\n.*?^          marker=/m],
      workflow[/^  commit-comment:\n.*?^          marker=/m], "Duel's own, on a push"
    assert_equal File.read(File.expand_path("../../../lib/duel/templates/perf.yml.erb", __dir__))[/^  passed:\n.*?^          BRANCH:/m],
      workflow[/^  passed:\n.*?^          BRANCH:/m], "Duel's own, marking a push passed"
    assert_equal "duel/passed", YAML.safe_load(workflow).dig("jobs", "passed", "steps", 0, "env", "BRANCH")
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
    assert_operator workflow.index("id: baseline-ruby"), :<, workflow.rindex("bundler-cache"), "the baseline's Ruby first"
    baseline = YAML.safe_load(workflow).dig("jobs", "duel", "steps").find { |step| step["id"] == "baseline-ruby" }

    assert_equal({"ruby-version" => "${{ steps.baseline.outputs.ruby }}", "bundler-cache" => true}, baseline.fetch("with"), "with its own bundle")
    assert_includes workflow, %(ruby_of() { git show "$1:./.ruby-version" 2>/dev/null)
    assert_includes workflow, %(          RELEASE_TAGS: "v*"\n)
    assert_includes workflow, %(ln -sfn "$PREFIX" ~/.rubies/ruby-)
    assert_equal 8, YAML.safe_load(workflow).dig("jobs", "duel", "steps").size, "YAML"
  end

  # An app in a subdirectory of its repository (a monorepo's): its
  # workflow is at the repository's root, named for the app's directory,
  # and runs there.
  def test_an_app_in_a_subdirectory
    system("git", "init", "--quiet", @dir, exception: true)
    app = File.join(@dir, "apps", "blog")
    generate(root: app)
    workflow = read(".github/workflows/perf-apps-blog.yml")

    assert_includes workflow, "      - uses: actions/checkout@v7\n        with:\n          fetch-depth: 0 ", "the whole repository"
    assert_includes workflow, "    defaults:\n      run:\n        working-directory: apps/blog\n"
    assert_includes workflow, "        with:\n          working-directory: apps/blog\n"
    assert_equal [%(          marker="<!-- duel apps/blog"), "          BRANCH: duel/passed-apps-blog"],
      workflow.lines(chomp: true).grep(/marker="|BRANCH: /).uniq, "a comment, and a branch, of its own"
    assert_equal [{"run" => {"working-directory" => "apps/blog"}}, nil],
      YAML.safe_load(workflow).fetch("jobs").values_at("duel", "comment").map { |job| job["defaults"] }, "none where nothing's checked out"
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
