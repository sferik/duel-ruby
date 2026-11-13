# frozen_string_literal: true

require "erb"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "optparse"
require "pathname"
require "tempfile"
require_relative "../duel"
require_relative "comment"

module Duel
  # `duel init`: sets Duel up in a gem or an app that isn't a Rails app
  # (duel-rails's generator sets a Rails app up). It writes .duel.rb, a
  # benchmark to start from, and GitHub Actions workflows (Duel's, and
  # one that comments on a pull request with its report, and with --badge
  # a job that keeps a badge), or with
  # --gitlab, GitLab CI jobs to include, adds a Rake
  # task to the Rakefile, and adds StackProf to the Gemfile (for profiles
  # of regressions, on CRuby). With --reusable, its workflows are short
  # ones that call Duel's reusable workflows (see Reusable), passing on
  # what .duel.rb sets. It overwrites nothing without --force, and
  # writes nothing with --dry-run, or with --check, which says how the
  # workflows differ from what it writes.
  # @api private
  class Init
    USAGE = "Usage: duel init [options]\n\n" \
      "Sets Duel up in this project: .duel.rb, a benchmark to start from in duel/, GitHub Actions workflows\n" \
      "(or GitLab CI jobs), a Rake task, and StackProf in the Gemfile.\n\n"

    TEMPLATES = File.join(__dir__, "templates")

    # What's added to a Rakefile.
    RAKE_TASK = %(require "duel/rake_task"\nDuel::RakeTask.new\n)

    # What's added to a Gemfile, for profiles of regressions: StackProf
    # runs on CRuby only, so it's left out of JRuby's and TruffleRuby's
    # bundles.
    STACKPROF = %(gem "stackprof", platforms: :mri)

    # A Gemfile's development group (or development and test's), with the
    # indentation of its first line.
    DEVELOPMENT = /^([ \t]*)group[ \t(]+(?::development(?:,[ \t]*:test)?|:test,[ \t]*:development)[ \t)]+do[ \t]*\n/

    # The color of the label it creates (see #create_label): GitHub's
    # yellow, a warning's.
    LABEL_COLOR = "FBCA04"

    # Where Duel's reusable workflows are (see Reusable), which the
    # workflows it writes with --reusable call, at this release's tag.
    REUSABLE = "sferik/duel-ruby/.github/workflows"

    def initialize(argv, out: $stdout, err: $stderr, input: $stdin, root: Dir.pwd)
      @argv = argv
      @out = out
      @err = err
      @input = input
      @root = root
    end

    # Returns the exit status: 0 set up (or with --check, its workflows
    # are what it writes), 1 a Rails app (not set up, or checked), or with
    # --check, a workflow that differs, 2 a bad option.
    def run
      rest = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?
      raise OptionParser::InvalidOption, "--reusable with --gitlab (GitLab CI has no reusable workflows)" if @reusable && @gitlab
      return rails if File.exist?(File.join(@root, "config", "application.rb"))

      return check if @check

      @out.puts "duel init: a dry run, so nothing is written" if @dry_run
      files.each { |path, content| write(path, content) }
      add_rake_task
      add_stackprof
      create_label
      @out.print next_steps
      0
    rescue OptionParser::ParseError => e
      @err.puts "duel init: #{e}"
      2
    end

    # The files it writes, from the project's root, to what's in them.
    def files
      top = Pathname(File.realpath(repository)).relative_path_from(File.realpath(@root))
      written = {".duel.rb" => render("duel.rb"), benchmark_file => render("benchmark_duel.rb")}
      return written.merge(top.join(gitlab_file).to_s => render("duel.gitlab-ci.yml")) if @gitlab

      workflows = top.join(".github", "workflows")
      # (With --reusable, ones that call Duel's.)
      perf, comment = @reusable ? %w[perf-caller.yml perf-comment-caller.yml] : %w[perf.yml perf-comment.yml]
      written.merge(workflows.join(workflow_name).to_s => render(perf),
        workflows.join(workflow_name.sub(/\.yml\z/, "-comment.yml")).to_s => render(comment))
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--force", "Overwrite files that exist") { @force = true }
        o.on("--dry-run", "Say what it would do, and write nothing") { @dry_run = true }
        o.on("--check", "Say how the workflows differ from what it writes (with the same options), and write nothing") { @check = true }
        o.on("--badge", "Write a job that keeps a badge for the README (it needs contents: write)") { @badge = true }
        o.on("--gitlab", "Write GitLab CI jobs (to include from .gitlab-ci.yml), not GitHub Actions workflows") { @gitlab = true }
        o.on("--reusable", "Write workflows that call Duel's reusable ones (at this release), not whole workflows") { @reusable = true }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Says to use duel-rails's generator instead.
    def rails
      @err.puts "duel init: this is a Rails app (config/application.rb). Add duel-rails to the Gemfile's development group, " \
        "and run `bin/rails generate duel:install#{" --check" if @check}` instead"
      1
    end

    # Says whether each workflow (or with --gitlab, the GitLab CI jobs) is
    # what it writes, or how it differs, or that it's missing: they're the
    # files a project rarely changes, but Duel's releases do. Returns 0
    # where each is, or else 1.
    def check
      written = files.except(".duel.rb", benchmark_file)
      written.count { |path, content| !same?(path, content) }.zero? ? 0 : 1
    end

    # Whether the file at +path+ is +content+, saying so, or how it
    # differs (as diff -u has it), or that it's missing. Its lines are
    # compared, whatever they end with: git can check a file out with
    # CRLF line endings, on Windows.
    def same?(path, content)
      full = File.join(@root, path)
      unless File.file?(full)
        said("missing", path)
        return false
      end

      lines = File.binread(full).gsub("\r\n", "\n")
      # (Nothing, where they're the same.)
      differences = diff(path, lines, content)
      said(differences.empty? ? "same" : "differs", path)
      @out.print differences
      differences.empty?
    end

    # Creates the label that accepts a regression (Config#accept_label) in
    # the project's GitHub repository, with gh (or with --gitlab, its
    # GitLab project, with glab), if it's missing and the answer to
    # whether to is yes: it asks only at a terminal, and not on a dry run.
    # Where it doesn't, the next steps say to.
    def create_label
      label = accept_label
      return unless label && !@dry_run && @input.tty?

      repo = (@gitlab ? gitlab_project : cli("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")&.chomp) or return
      names = (@gitlab ? gitlab_labels(repo) : github_labels(repo, label)) or return
      if names.include?(label)
        said("skip", "label #{label} (#{repo} has it)")
        return @label = true
      end

      @out.print "Create the label #{label.inspect} in #{repo} with #{@gitlab ? "glab" : "gh"}, so a #{request} can accept a regression? [y/N] "
      return unless @input.gets.to_s.strip.match?(/\Ay(?:es)?\z/i)

      described = ["--repo", repo, "--description", "Accepts a regression that Duel found"]
      created = @gitlab ? cli("glab", "label", "create", "--name", label, "--color", "##{LABEL_COLOR}", *described) :
        cli("gh", "label", "create", label, "--color", LABEL_COLOR, *described)
      return unless created

      said("create", "label #{label} (#{repo})")
      @label = true
    end

    # The names of the GitHub repository +repo+'s labels that gh finds by
    # +label+, or nil.
    def github_labels(repo, label) = cli("gh", "label", "list", "--repo", repo, "--search", label, "--limit", "100", "--json", "name",
      "--jq", ".[].name")&.lines(chomp: true)

    # The project's GitLab project, as glab has it (group/project), or nil.
    def gitlab_project
      project = cli("glab", "repo", "view", "--output", "json") or return
      parsed = JSON.parse(project)
      parsed["path_with_namespace"] if parsed.instance_of?(Hash)
    rescue JSON::ParserError
      nil
    end

    # The names of the GitLab project +repo+'s labels, every page of them,
    # or nil where glab can't list a page.
    def gitlab_labels(repo)
      names = [] #: Array[String]
      page = 1
      while (listed = cli("glab", "label", "list", "--repo", repo, "--output", "json", "--per-page", "100", "--page", page.to_s))
        labels = JSON.parse(listed)
        names.concat(labels.map { |label| label.fetch("name") })
        return names if labels.size < 100

        page += 1
      end
    rescue JSON::ParserError
      nil
    end

    # What +program+ (gh, or glab) prints, run in the project, or nil where
    # it fails (which it says) or isn't there.
    def cli(program, *args)
      out, err, status = Open3.capture3(program, *args, chdir: @root)
      return out if status.success?

      @err.puts "duel init: #{program} #{args.first(2).join(" ")}: #{err.strip}"
    rescue SystemCallError
      nil
    end

    # How +lines+ (the file at +path+'s) differ from +content+, as diff -u
    # has it.
    # mutant:disable -- the temporary file's name is never shown (diff
    # labels it), and binmode only matters on Windows (where text mode
    # would write CRLF), which mutant doesn't run on
    def diff(path, lines, content)
      Tempfile.create("duel-init") do |file|
        file.binmode
        file.write(lines)
        file.close
        Open3.capture2("diff", "-u", "-L", path, "-L", "#{path} (duel init)", file.path, "-", stdin_data: content).first
      end
    end

    # What Duel compares: a pull request, or on GitLab, a merge request.
    def request = @gitlab ? "merge request" : "pull request"

    # Writes +content+ to +path+, unless it exists (without --force), and
    # says what it did.
    def write(path, content)
      full = File.join(@root, path)
      exists = File.exist?(full)
      return said("skip", "#{path} (it exists: --force to overwrite)") if exists && !@force

      said(exists ? "overwrite" : "create", path)
      return if @dry_run

      FileUtils.mkdir_p(File.dirname(full))
      # (Its lines end with LF, as Duel's templates do, on Windows too.)
      File.binwrite(full, content)
    end

    # Adds Duel's Rake task to the Rakefile, if there is one without it.
    def add_rake_task
      rakefile = File.join(@root, "Rakefile")
      return unless File.exist?(rakefile)

      text = File.read(rakefile)
      return said("skip", "Rakefile (it has Duel's task)") if text.include?("duel/rake_task")

      said("append", "Rakefile")
      File.write(rakefile, gap(text) + RAKE_TASK, mode: "a") unless @dry_run
    end

    # Adds StackProf to the Gemfile, if there is one without it: in its
    # development group, if it has one, or else at its end.
    def add_stackprof
      gemfile = File.join(@root, "Gemfile")
      return unless File.exist?(gemfile)

      text = File.read(gemfile)
      return said("skip", "Gemfile (it has stackprof)") if text.include?("stackprof")

      @stackprof = true
      grouped = in_development_group(text)
      said(grouped ? "insert" : "append", "Gemfile (#{STACKPROF}#{", in the development group" if grouped})")
      File.write(gemfile, grouped || at_the_end(text)) unless @dry_run
    end

    # The Gemfile's +text+ with StackProf last in its development group,
    # or nil without one (or without the end of one).
    def in_development_group(text)
      group = DEVELOPMENT.match(text) or return
      indent = group[1]
      ending = /^#{indent}end\b/.match(group.post_match) or return
      "#{group.pre_match}#{group}#{ending.pre_match}#{indent}  #{STACKPROF}\n#{ending}#{ending.post_match}"
    end

    # What goes between a file's +text+ and what's added at its end: a
    # blank line, if there's anything before it.
    def gap(text) = text.empty? ? "" : "#{"\n" unless text.end_with?("\n")}\n"

    # The Gemfile's +text+ with StackProf at its end.
    def at_the_end(text) = "#{text}#{gap(text)}# For profiles of regressions (StackProf runs on CRuby only)\n#{STACKPROF}\n"

    def said(what, path) = @out.puts(format("  %-10s%s", what, path))

    # What to do next, numbered, after a blank line.
    def next_steps
      steps = [] #: Array[String]
      if !gemfile?
        steps << %(Add gem "duel" to the Gemfile's development group, and run `bundle install`.)
      elsif @stackprof
        steps << "Run `bundle install`, for StackProf (added to the Gemfile)."
      end
      steps << "Set c.library in .duel.rb to what each version's workers require." unless required
      steps << "Replace the example in #{benchmark_file} with benchmarks of your own code."
      steps << "Create the label #{accept_label.inspect} in your repository, so a #{request} can accept a regression (c.accept_label)." if
        accept_label && !@label
      steps << "Run `bundle exec duel --force`. It compares the code with itself, and passes when the benchmarks are sound."
      steps << if @gitlab
        "Include #{gitlab_file} from .gitlab-ci.yml, and add the tokens it says to, for comments. On a merge request, the job " \
          "compares the code with the branch it targets."
      else
        "Commit and push. On a pull request, the workflow compares the code with the branch it targets, and comments with the " \
          "report when a benchmark fails (c.comment in .duel.rb says when)."
      end
      "\nNext:\n#{steps.each_with_index.map { |step, i| "  #{i + 1}. #{step}\n" }.join}"
    end

    def render(name) = ERB.new(File.read(File.join(TEMPLATES, "#{name}.erb")), trim_mode: "-").result(binding)

    # Whether the templates are rendered as Duel's reusable workflows (see
    # Reusable).
    # mutant:disable -- nil (a mutation's) renders as false does
    def reusable? = false

    # Whether the workflow's jobs write to the repository: to mark a push
    # passed, comment on one, or keep the badge.
    def writes? = mark_passed? || comment_on_pushes? || badge?

    # What the workflow it writes with --reusable passes on to Duel's
    # Perf workflow, as its inputs (see Reusable): what .duel.rb sets that
    # isn't the input's default, each as YAML has it.
    def perf_inputs
      {
        "ruby-version" => ruby_version,
        "version-file" => (true if version_file),
        "working-directory" => working_directory,
        "accept-label" => accept_label,
        "release-tags" => (set_release_tags unless set_release_tags == "v*"),
        "comment-on-pushes" => (true if comment_on_pushes?),
        "mark-passed" => (true if mark_passed?),
        "badge" => (true if badge?),
        "passed-branch" => (passed_branch if working_directory),
        "badge-branch" => (badge_branch if working_directory && badge?),
        "marker" => (marker if working_directory)
      }.compact.transform_values(&:to_json)
    end

    # The glob release tags match, as .duel.rb sets it (c.release_tags),
    # or nil where it doesn't load. (The whole workflows take the
    # conventions', and say to set RELEASE_TAGS to match.)
    def set_release_tags = settings&.release_tags

    # The same, for Duel's Perf comment workflow.
    def comment_inputs
      {
        "accept-label" => accept_label,
        "perf-workflow" => ("Perf (#{working_directory})" if working_directory),
        "marker" => (marker if working_directory)
      }.compact.transform_values(&:to_json)
    end

    # The project's configuration, as the conventions have it.
    def config = Config.new(@root)

    # The project's settings, which decide the workflow's jobs: its
    # .duel.rb's, or where there's none yet or --force replaces it, those
    # of the one it writes. Nil where it doesn't load (one
    # of its plugins isn't installed, say), and then the workflow has
    # both jobs for pushes, as if .duel.rb asked for them, and says so.
    def settings = instance_variable_defined?(:@settings) ? @settings : (@settings = load_settings)

    def load_settings
      path = File.join(@root, ".duel.rb")
      return written_settings if @force || !File.exist?(path)

      Duel.load_config(path)
    rescue ScriptError, StandardError => e
      @err.puts "duel init: .duel.rb didn't load (#{e.class}: #{e}), so the workflow has both jobs for pushes, as if it asked for them"
    end

    # The settings of the .duel.rb it writes.
    def written_settings
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".duel.rb")
        File.write(path, render("duel.rb"))
        Duel.load_config(path)
      end
    end

    # The label that accepts a regression (Config#accept_label), for the
    # workflows: the Duel job's, to find what was accepted since the last
    # release, and the comment's, to run the Duel job again when it's
    # added or taken off. Nil without one, or where .duel.rb doesn't load.
    def accept_label = settings&.accept_label

    # Whether the workflow comments on a pushed commit: where a regression
    # in a push passes (c.fail_on = :pull_requests), the only time Duel
    # says to.
    def comment_on_pushes?
      found = settings
      found.nil? || found.fail_on == :pull_requests
    end

    # Whether the workflow marks a push passed: where a push is compared
    # with the last commit Duel passed (c.push_base = :last_passed).
    def mark_passed?
      found = settings
      found.nil? || found.push_base == :last_passed
    end

    # Whether the workflow keeps a badge for the README (--badge): its job
    # moves a branch, so it's the workflow's only job, without the jobs
    # for pushes, that writes to the repository.
    def badge? = @badge

    # The library the gemspec names (see Config#library), or nil.
    def library = config.library

    # The glob release tags match (Config#release_tags), for the workflow
    # to find the last release as Duel does.
    def release_tags = config.release_tags

    # The library, without a gemspec: lib/'s only Ruby file, or nil.
    def guess
      found = Dir.glob("*.rb", base: File.join(@root, "lib"))
      File.basename(found.first, ".rb") if found.size == 1
    end

    # What each version's workers require: the library, or the guess.
    def required = library || guess

    def benchmark_file = File.join("duel", "#{(required || "example").tr("/", "_")}_duel.rb")

    def gemfile? = File.exist?(File.join(@root, "Gemfile")) && File.read(File.join(@root, "Gemfile")).match?(/gem ["']duel["']/)

    def ext = Dir.exist?(File.join(@root, "ext"))

    def version_file = File.exist?(File.join(@root, ".ruby-version"))

    # The Ruby the workflow sets up: this one's (its minor version), or
    # none, where .ruby-version names it.
    def ruby_version = (RUBY_VERSION[/\A\d+\.\d+/] unless version_file)

    # The root of the project's git repository: the project's own
    # directory, outside one.
    def repository
      top, _, status = Open3.capture3("git", "-C", @root, "rev-parse", "--show-toplevel")
      status.success? ? top.chomp : @root
    end

    # The project's directory, from its repository's root ("gems/parser"),
    # or nil at the root.
    def working_directory
      path = Pathname(File.realpath(@root)).relative_path_from(File.realpath(repository)).to_s
      path unless path == "."
    end

    # perf.yml, or for a project in a subdirectory of its repository,
    # perf-<its path>.yml (perf-gems-parser.yml), so that each of a
    # monorepo's projects can have its own.
    def workflow_name = working_directory&.then { |dir| "perf-#{dir.tr("/", "-")}.yml" } || "perf.yml"

    # What marks the workflow's comment on a pull request.
    def marker = ["duel", working_directory].compact.join(" ")

    # Where the GitLab CI jobs are, from the repository's root:
    # .gitlab/duel.gitlab-ci.yml, or for a project in a subdirectory,
    # .gitlab/duel-<its path>.gitlab-ci.yml.
    def gitlab_file = File.join(".gitlab", "#{["duel", working_directory&.tr("/", "-")].compact.join("-")}.gitlab-ci.yml")

    # The GitLab CI job's name: duel, or for a project in a subdirectory,
    # duel:<its path>, so each of a monorepo's projects has its own.
    def gitlab_job = ["duel", working_directory].compact.join(":")

    # The Ruby image's tag for GitLab CI: the version .ruby-version names,
    # exactly (so it's the Ruby that c.ruby = :version_file asks for), or
    # this one's minor version.
    def gitlab_ruby
      named = File.read(File.join(@root, ".ruby-version")).split.first if version_file
      named&.delete_prefix("ruby-") || RUBY_VERSION.rpartition(".").first
    end

    # What names the branches that mark the last commit Duel passed in a
    # push, before the branch pushed's name (see Baseline#passed_branch).
    def passed_branch = ["duel/passed", working_directory&.tr("/", "-")].compact.join("-")

    # The branch that holds the workflow's badge: duel/badge, or for a
    # project in a subdirectory, duel/badge-<its path>.
    def badge_branch = ["duel/badge", working_directory&.tr("/", "-")].compact.join("-")

    # Duel's reusable workflows, which the workflows `duel init --reusable`
    # writes call: .github/workflows/duel.yml (the Perf workflow's jobs)
    # and duel-comment.yml (the Perf comment workflow's), in Duel's
    # repository. They're the templates `duel init` writes from, rendered
    # with each setting of .duel.rb they need as an input (and a job or a
    # step that would be left out run only where its input says to).
    # `rake workflows` writes them, and a test says they're what's there.
    # @api private
    class Reusable < Init
      def initialize = super([])

      # The files, from the repository's root, to what's in them.
      def files
        workflows = File.join(".github", "workflows")
        {File.join(workflows, "duel.yml") => render("perf.yml"), File.join(workflows, "duel-comment.yml") => render("perf-comment.yml")}
      end

      private

      def reusable? = true

      # Each an input's (see the templates' workflow_call).
      def accept_label = "${{ inputs.accept-label }}"

      def release_tags = "${{ inputs.release-tags }}"

      def ruby_version = "${{ inputs.ruby-version }}"

      def working_directory = "${{ inputs.working-directory }}"

      def passed_branch = "${{ inputs.passed-branch }}"

      def badge_branch = "${{ inputs.badge-branch }}"

      # Each in, run only where its input says to.
      def version_file = true

      def comment_on_pushes? = true

      def mark_passed? = true

      def badge? = true
    end
  end
end
