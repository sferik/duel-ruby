# frozen_string_literal: true

require_relative "test_helper"
require_relative "../tasks/release"

# `rake release:all` and `rake release:bump` (tasks/release.rb), in a
# repository of the test's own: Duel and two plugins (duel-redis, and
# duel-rails, which depends on it too), with an origin of their own.
class ReleaseTaskTest < DuelTest
  DATE = "2026-10-24"
  TAGS = %w[v0.1.0 duel-rails-v0.1.0 duel-redis-v0.1.0].freeze

  def setup
    super
    @origin = File.join(tmpdir, "origin.git")
    @root = File.join(tmpdir, "work")
    sh("git", "init", "--quiet", "--bare", "--initial-branch=main", @origin, chdir: tmpdir)
    write_gem("duel", ".")
    write_gem("duel-redis", "plugins/redis")
    write_gem("duel-rails", "plugins/rails", depends: {"duel" => "~> 0.1", "duel-redis" => "~> 0.1"})
    write(".gitignore", "lib/stray.rb\n")
    git("init", "--quiet", "--initial-branch=main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    git("config", "commit.gpgSign", "false")
    git("config", "tag.gpgSign", "false")
    git("remote", "add", "origin", @origin)
    commit("The first release")
    git("push", "--quiet", "origin", "main")
  end

  def sh(*command, chdir: @root)
    output, status = Open3.capture2e(*command, chdir:)

    assert_predicate status, :success?, "#{command.join(" ")}: #{output}"
    output
  end

  def git(*args) = sh("git", *args)

  def commit(message)
    git("add", "--all")
    git("commit", "--quiet", "--message", message)
  end

  def path(file) = File.join(@root, file)

  def read(file) = File.read(path(file))

  def write(file, content)
    FileUtils.mkdir_p(File.dirname(path(file)))
    File.write(path(file), content)
  end

  def write_gem(name, dir, depends: (name == "duel") ? {} : {"duel" => "~> 0.1"})
    version_file = File.join("lib", "duel", *((name == "duel") ? [] : [name.delete_prefix("duel-")]), "version.rb")
    write(File.join(dir, version_file), %(module Duel\n  VERSION = "0.1.0"\nend\n))
    write(File.join(dir, "#{name}.gemspec"), gemspec(name, version_file, depends))
    write(File.join(dir, "CHANGELOG.md"), changelog((name == "duel") ? "v" : "#{name}-v"))
  end

  def gemspec(name, version_file, depends, files: %w[lib/**/*.rb CHANGELOG.md])
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "#{name}"
        spec.version = File.read(File.join(__dir__, "#{version_file}"))[/VERSION = "(.*)"/, 1]
        spec.summary = "#{name}"
        spec.authors = ["Test"]
        spec.license = "MIT"
        spec.homepage = "https://example.com"
        spec.required_ruby_version = ">= 3.4"
        spec.files = Dir[#{files.map(&:inspect).join(", ")}]
      #{depends.map { |dependency, requirement| %(  spec.add_dependency "#{dependency}", "#{requirement}") }.join("\n")}
      end
    RUBY
  end

  def changelog(prefix, unreleased: "")
    <<~MARKDOWN
      # Changelog

      ## [Unreleased]
      #{unreleased}
      ## [0.1.0] - #{DATE}

      - The first release.

      [Unreleased]: https://github.com/sferik/duel-ruby/compare/#{prefix}0.1.0...HEAD
      [0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/#{prefix}0.1.0
    MARKDOWN
  end

  def check = Release.check(@root, date: DATE).last

  def release(answer = nil, **options)
    @out = StringIO.new
    Release.release(@root, date: DATE, input: StringIO.new(answer.to_s), output: @out, **options)
  end

  def tags(remote: false) = git(*(remote ? %w[ls-remote --tags --refs origin] : %w[tag --list])).scan(/(?:v|duel-\S+-v)0\.1\.0$/).sort

  def test_options
    assert_equal({date: Date.today.iso8601, dry_run: false, force: false}, Release.options({}))
    assert_equal({date: "2027-01-02", dry_run: true, force: true},
      Release.options("RELEASE_DATE" => "2027-01-02", "DRY_RUN" => "1", "FORCE" => "0", "CI" => "true"))
    assert_equal({date: Date.today.iso8601, dry_run: false, force: true}, Release.options("DRY_RUN" => "no", "FORCE" => "yes", "CI" => "FALSE"))
  end

  def test_components
    assert_equal [%w[duel .], %w[duel-rails plugins/rails], %w[duel-redis plugins/redis]], Release.components(@root).map(&:to_h).map(&:values)
    duel, rails = Release.components(@root)

    assert_equal ["v0.2.0", "lib/duel/version.rb", "duel.gemspec"], [duel.tag("0.2.0"), duel.version_file, duel.gemspec]
    assert_equal ["duel-rails-v0.2.0", "plugins/rails/lib/duel/rails/version.rb", "plugins/rails/CHANGELOG.md"],
      [rails.tag("0.2.0"), rails.version_file, rails.changelog]
  end

  def test_a_dry_run_checks_everything_and_tags_nothing
    assert release(dry_run: true)
    assert_match(/Every check passes for 0.1.0 \(3 gems, at \h{7}, dated #{DATE}\)/o, @out.string)
    assert_match(/Dry run: would tag \h{7} v0.1.0, duel-rails-v0.1.0, duel-redis-v0.1.0, and push each tag to origin/, @out.string)
    assert_empty tags
    assert_empty tags(remote: true)
  end

  def test_a_release_tags_head_and_pushes_every_tag
    assert release(force: true)
    assert_equal TAGS.sort, tags
    assert_equal TAGS.sort, tags(remote: true)
    assert_equal "tag\nduel-redis 0.1.0\n", git("for-each-ref", "--format=%(objecttype)%0a%(contents:subject)", "refs/tags/duel-redis-v0.1.0")
    assert_equal git("rev-parse", "HEAD"), git("rev-parse", "duel-rails-v0.1.0^{commit}")
    assert_includes @out.string, "Pushing duel-redis-v0.1.0\n"
    assert_includes @out.string, "Released 0.1.0"
    # Once released, it can't be again.
    refute release(force: true)
    assert_includes @out.string, "the tag duel-redis-v0.1.0 exists already here"
  end

  def test_a_release_waits_for_a_yes
    refute release("n\n")
    assert_includes @out.string, "push the tags to origin, releasing 3 gems? [y/N] Not released."
    refute release
    assert_empty tags
    assert release("Y\n")
    assert_equal TAGS.sort, tags(remote: true)
  end

  def test_a_failed_push_names_the_tags_left
    File.write(File.join(@origin, "hooks", "pre-receive"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(@origin, "hooks", "pre-receive"))
    error = assert_raises(RuntimeError) { release(force: true) }
    assert_equal "Couldn't push v0.1.0. Push the rest yourself: git push origin v0.1.0 duel-rails-v0.1.0 duel-redis-v0.1.0", error.message
  end

  def test_a_tag_that_fails
    git("tag", "duel-redis-v0.1.0")
    error = assert_raises(RuntimeError) { Release.git!(@root, "tag", "duel-redis-v0.1.0") }
    assert_match(/\Agit tag duel-redis-v0.1.0 failed: fatal: tag 'duel-redis-v0.1.0' already exists\z/, error.message)
  end

  def test_versions_changelogs_and_gems_that_dont_agree
    write("plugins/redis/lib/duel/redis/version.rb", %(module Duel\n  VERSION = "0.1.1"\nend\n))
    write("plugins/rails/duel-rails.gemspec", gemspec("duel-rails", "lib/duel/rails/version.rb", {"duel" => "~> 0.0.1"}))
    write("duel.gemspec", gemspec("duel", "lib/duel/version.rb", {}, files: %w[lib/**/*.rb plugins/redis/CHANGELOG.md]))
    write("lib/stray.rb", "")
    write("CHANGELOG.md", changelog("v", unreleased: "\n- Something new.\n").sub("[0.1.0]: ", "[0.0.9]: "))
    write("plugins/rails/CHANGELOG.md", changelog("duel-rails-v").sub(DATE, "2026-10-23").sub("## [Unreleased]\n", ""))
    write("plugins/redis/CHANGELOG.md", changelog("duel-redis-v").sub(" - #{DATE}", "").sub("[0.1.0]: ", "[0.0.9]: "))
    commit("Disagree")
    git("push", "--quiet", "origin", "main")

    assert_equal [
      %(duel-redis is at version "0.1.1" (plugins/redis/lib/duel/redis/version.rb), not 0.1.0),
      "CHANGELOG.md has entries under [Unreleased]: move them under [0.1.0] (rake release:bump)",
      "CHANGELOG.md has no link for [0.1.0]",
      "plugins/rails/CHANGELOG.md has no [Unreleased] section",
      %(plugins/rails/CHANGELOG.md dates 0.1.0 "2026-10-23", not #{DATE} (RELEASE_DATE sets the date)),
      %(plugins/redis/CHANGELOG.md dates 0.1.0 "", not #{DATE} (RELEASE_DATE sets the date)),
      "plugins/redis/CHANGELOG.md has no link for [0.1.0]",
      "duel's gem has files that aren't its own: lib/stray.rb, plugins/redis/CHANGELOG.md",
      "duel-rails depends on duel ~> 0.0.1, which 0.1.0 doesn't satisfy (plugins/rails/duel-rails.gemspec)",
      "duel-redis builds as duel-redis 0.1.1, not duel-redis 0.1.0"
    ], check
  end

  def test_a_changelog_without_a_section_for_the_version
    write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n")
    commit("No section")
    git("push", "--quiet", "origin", "main")

    assert_equal ["CHANGELOG.md has no section for 0.1.0", "CHANGELOG.md has no link for [0.1.0]"], check
  end

  def test_gems_that_dont_build_or_depend_on_duel
    write("plugins/redis/duel-redis.gemspec", "raise 'broken'\n")
    write("plugins/rails/duel-rails.gemspec", gemspec("duel-rails", "lib/duel/rails/version.rb", {"duel-redis" => ">= 0"}))
    commit("Break")
    git("push", "--quiet", "origin", "main")
    problems = check

    assert_equal 2, problems.size
    assert_equal "duel-rails doesn't depend on duel", problems.first
    assert_match(/\Aduel-redis doesn't build: .*broken/m, problems.last)
  end

  def test_a_tree_thats_dirty_on_another_branch_and_not_pushed
    git("checkout", "--quiet", "-b", "topic")
    write("lib/duel.rb", "")
    commit("Unpushed")
    write("lib/duel/new.rb", "")
    git("tag", "v0.1.0")
    git("push", "--quiet", "origin", "HEAD:refs/tags/duel-redis-v0.1.0")
    problems = check

    assert_equal [
      "the working tree isn't clean:\n      ?? lib/duel/new.rb\n",
      "HEAD is on topic, not main",
      "the tag v0.1.0 exists already here",
      "the tag duel-redis-v0.1.0 exists already on origin"
    ], problems.values_at(0, 1, 3, 4)
    assert_match(/\AHEAD \(\h{7}\) isn't origin\/main \(\h{7}\): pull or push first\z/, problems[2])
    assert_equal "duel's gem has files that aren't its own: lib/duel/new.rb", problems.last
  end

  def test_an_origin_thats_unreachable_or_has_no_main
    git("remote", "set-url", "origin", File.join(tmpdir, "nowhere.git"))

    git("checkout", "--quiet", "-b", "topic")
    problems = check

    assert_equal 2, problems.size
    assert_match(/\Acouldn't reach origin: \S/, problems.first)
    assert_equal "HEAD is on topic, not main", problems.last
    git("checkout", "--quiet", "main")
    sh("git", "init", "--quiet", "--bare", File.join(tmpdir, "empty.git"), chdir: tmpdir)
    git("remote", "set-url", "origin", File.join(tmpdir, "empty.git"))

    assert_equal ["origin has no main branch"], check
  end

  def test_bump
    write("plugins/redis/CHANGELOG.md", changelog("duel-redis-v", unreleased: "\n### Fixed\n\n- A fix.\n"))
    changed = Release.bump(@root, "0.2.0", date: "2026-11-01")

    assert_equal %w[lib/duel/version.rb CHANGELOG.md plugins/rails/lib/duel/rails/version.rb plugins/rails/CHANGELOG.md
      plugins/redis/lib/duel/redis/version.rb plugins/redis/CHANGELOG.md], changed
    assert_equal %(module Duel\n  VERSION = "0.2.0"\nend\n), read("plugins/rails/lib/duel/rails/version.rb")
    assert_equal <<~MARKDOWN, read("plugins/redis/CHANGELOG.md")
      # Changelog

      ## [Unreleased]

      ## [0.2.0] - 2026-11-01

      ### Fixed

      - A fix.

      ## [0.1.0] - #{DATE}

      - The first release.

      [Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.2.0...HEAD
      [0.2.0]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.0...duel-redis-v0.2.0
      [0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-redis-v0.1.0
    MARKDOWN
    assert_includes read("CHANGELOG.md"), "## [0.2.0] - 2026-11-01\n\n#{Release::NO_CHANGES}\n\n## [0.1.0]"
    commit("Release 0.2.0")
    git("push", "--quiet", "origin", "main")

    assert_empty Release.check(@root, date: "2026-11-01").last
  end

  def test_bump_to_a_major_version_loosens_the_requirements
    write("plugins/rails/CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n- New.\n")
    Release.bump(@root, "1.0.0", date: DATE)

    assert_includes read("plugins/rails/duel-rails.gemspec"), %(spec.add_dependency "duel", "~> 1.0"\n  spec.add_dependency "duel-redis", "~> 1.0"\n)
    assert_includes read("plugins/redis/duel-redis.gemspec"), %(spec.add_dependency "duel", "~> 1.0"\n)
    # (Without links to update, it dates the entries all the same.)
    assert_equal "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - #{DATE}\n\n- New.\n\n", read("plugins/rails/CHANGELOG.md")
  end

  def test_bump_refuses_what_isnt_a_new_version
    assert_equal %("" isn't a version), assert_raises(ArgumentError) { Release.bump(@root, "", date: DATE) }.message
    assert_equal %("next" isn't a version), assert_raises(ArgumentError) { Release.bump(@root, "next", date: DATE) }.message
    write("plugins/redis/lib/duel/redis/version.rb", %(module Duel\n  VERSION = "0.2.0"\nend\n))
    error = assert_raises(ArgumentError) { Release.bump(@root, "0.2.0", date: DATE) }

    assert_equal "Can't bump to 0.2.0:\n  - duel-redis is at 0.2.0 already, not below 0.2.0", error.message
    assert_equal %(module Duel\n  VERSION = "0.1.0"\nend\n), read("lib/duel/version.rb")
  end
end
