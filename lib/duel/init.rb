# frozen_string_literal: true

require "erb"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require_relative "../duel"

module Duel
  # `duel init`: sets Duel up in a gem or an app that isn't a Rails app
  # (duel-rails's generator sets a Rails app up). It writes .duel.rb, a
  # benchmark to start from, and a GitHub Actions workflow, adds a Rake
  # task to the Rakefile, and adds StackProf to the Gemfile (for profiles
  # of regressions, on CRuby). It overwrites nothing without --force, and
  # writes nothing with --dry-run.
  # @api private
  class Init
    USAGE = "Usage: duel init [options]\n\n" \
      "Sets Duel up in this project: .duel.rb, a benchmark to start from in duel/, a GitHub Actions workflow,\n" \
      "a Rake task, and StackProf in the Gemfile.\n\n"

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

    def initialize(argv, out: $stdout, err: $stderr, root: Dir.pwd)
      @argv = argv
      @out = out
      @err = err
      @root = root
    end

    # Returns the exit status: 0 set up, 1 a Rails app (not set up), 2 a
    # bad option.
    def run
      rest = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?
      return rails if File.exist?(File.join(@root, "config", "application.rb"))

      @out.puts "duel init: a dry run, so nothing is written" if @dry_run
      files.each { |path, content| write(path, content) }
      add_rake_task
      add_stackprof
      @out.print next_steps
      0
    rescue OptionParser::ParseError => e
      @err.puts "duel init: #{e}"
      2
    end

    # The files it writes, from the project's root, to what's in them.
    def files
      workflow = Pathname(File.realpath(repository)).relative_path_from(File.realpath(@root)).join(".github", "workflows", workflow_name)
      {".duel.rb" => render("duel.rb"), benchmark_file => render("benchmark_duel.rb"), workflow.to_s => render("perf.yml")}
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--force", "Overwrite files that exist") { @force = true }
        o.on("--dry-run", "Say what it would do, and write nothing") { @dry_run = true }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Says to use duel-rails's generator instead.
    def rails
      @err.puts "duel init: this is a Rails app (config/application.rb). Add duel-rails to the Gemfile's development group, " \
        "and run `bin/rails generate duel:install` instead"
      1
    end

    # Writes +content+ to +path+, unless it exists (without --force), and
    # says what it did.
    def write(path, content)
      full = File.join(@root, path)
      exists = File.exist?(full)
      return said("skip", "#{path} (it exists: --force to overwrite)") if exists && !@force

      said(exists ? "overwrite" : "create", path)
      return if @dry_run

      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
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
      steps << "Run `bundle exec duel --force`. It compares the code with itself, and passes when the benchmarks are sound."
      steps << "Commit and push. On a pull request, the workflow compares the code with the main branch, and comments with the " \
        "report when a benchmark fails (c.comment in .duel.rb says when)."
      "\nNext:\n#{steps.each_with_index.map { |step, i| "  #{i + 1}. #{step}\n" }.join}"
    end

    def render(name) = ERB.new(File.read(File.join(TEMPLATES, "#{name}.erb")), trim_mode: "-").result(binding)

    # The project's configuration, as the conventions have it.
    def config = Config.new(@root)

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

    # The branch that marks the last commit Duel passed in a push (see
    # Baseline#passed_branch).
    def passed_branch = ["duel/passed", working_directory&.tr("/", "-")].compact.join("-")
  end
end
