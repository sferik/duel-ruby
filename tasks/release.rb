# frozen_string_literal: true

require "date"
require "open3"
require "rubygems/package"
require "tmpdir"

# Releases Duel and every plugin together, in lockstep at one version
# (`rake release:all`), and prepares such a release (`rake
# release:bump[0.2.0]`). See CONTRIBUTING.md's Releasing section.
#
# A release checks everything first, and tags nothing unless every
# check passes. Then it tags HEAD for each gem (v0.2.0 for Duel,
# duel-redis-v0.2.0 for duel-redis, and so on) and pushes the tags, which
# run the push workflows (.github/workflows/push.yml and plugin-push.yml)
# that build, sign and push each gem.
module Release
  extend self

  BRANCH = "main"
  REMOTE = "origin"
  # The line of a version file that holds the version.
  VERSION_LINE = /^(\s*VERSION = ")([^"]*)(")/
  # A gemspec's dependency on a gem of this repository.
  DEPENDENCY_LINE = /^(\s*spec\.add_(?:runtime_)?dependency\s+"(duel(?:-[\w-]+)?)",\s+")([^"]*)(")/
  UNRELEASED = "Unreleased"
  # A changelog's Unreleased section, up to the next section or the links
  # at the bottom.
  UNRELEASED_SECTION = /^## \[Unreleased\][^\n]*\n.*?(?=^## |^\[[^\]\n]+\]: |\z)/m
  # A changelog's link to what's changed since the last release.
  UNRELEASED_LINK = %r{^\[Unreleased\]: (?<base>\S+)/compare/(?<from>\S+)\.\.\.HEAD$}
  # What a changelog says of a release with nothing of its own in it.
  NO_CHANGES = "No changes of its own: released in step with the other Duel gems."

  # One of the gems: Duel (at the root) or a plugin (in plugins/<dir>).
  Component = Data.define(:name, :dir) do
    def core? = dir == "."

    def tag(version) = core? ? "v#{version}" : "#{name}-v#{version}"

    def gemspec = path("#{name}.gemspec")

    def version_file = path(File.join("lib", "duel", *(core? ? [] : [name.delete_prefix("duel-")]), "version.rb"))

    def changelog = path("CHANGELOG.md")

    # +file+'s path from the root.
    def path(file) = core? ? file : File.join(dir, file)
  end

  # Duel, then its plugins, by name.
  def components(root)
    plugins = Dir[File.join(root, "plugins", "*", "*.gemspec")].map do |gemspec|
      Component.new(File.basename(gemspec, ".gemspec"), File.join("plugins", File.basename(File.dirname(gemspec))))
    end
    [Component.new("duel", "."), *plugins.sort_by(&:name)]
  end

  # The options the Rake tasks take from the environment.
  def options(env)
    {
      date: env.fetch("RELEASE_DATE") { Date.today.iso8601 },
      dry_run: flag?(env["DRY_RUN"]),
      force: flag?(env["FORCE"]) || flag?(env["CI"])
    }
  end

  def flag?(value) = !value.to_s.empty? && !%w[0 false no].include?(value.downcase)

  def version(root, component) = File.read(File.join(root, component.version_file))[VERSION_LINE, 2]

  # Every check's problems, for releasing the gems at Duel's version on
  # +date+: none, and the release can go ahead.
  def check(root, date:)
    components = components(root)
    version = version(root, components.first)
    problems = check_versions(root, components, version) +
      components.flat_map { |component| check_changelog(root, component, version, date) } +
      check_git(root, components, version) +
      Dir.mktmpdir("release") { |dir| components.flat_map { |component| check_build(root, component, components, version, dir) } }
    [version, problems]
  end

  def check_versions(root, components, version)
    components.filter_map do |component|
      found = version(root, component)
      "#{component.name} is at version #{found.inspect} (#{component.version_file}), not #{version}" unless found == version
    end
  end

  def check_changelog(root, component, version, date)
    text = File.read(File.join(root, component.changelog))
    unreleased = section(text, UNRELEASED)
    # "## [0.2.0] - 2026-10-24": " - 2026-10-24".
    heading = text[/^## \[#{Regexp.escape(version)}\](.*)$/, 1]
    where = component.changelog
    [
      ("#{where} has no [#{UNRELEASED}] section" unless unreleased),
      ("#{where} has entries under [#{UNRELEASED}]: move them under [#{version}] (rake release:bump)" unless unreleased.to_s.strip.empty?),
      ("#{where} has no section for #{version}" unless heading),
      ("#{where} dates #{version} #{heading.delete_prefix(" - ").inspect}, not #{date} (RELEASE_DATE sets the date)" if heading && heading != " - #{date}"),
      ("#{where} has no link for [#{version}]" unless text.match?(/^\[#{Regexp.escape(version)}\]: \S/))
    ].compact
  end

  # The body of a changelog's section (nil if it has none), up to the
  # next section or the links at the bottom.
  def section(text, title) = text[/^## \[#{Regexp.escape(title)}\][^\n]*\n(.*?)(?=^## |^\[[^\]\n]+\]: |\z)/m, 1]

  def check_git(root, components, version)
    status, = git(root, "status", "--porcelain")
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD").first.strip
    head = git(root, "rev-parse", "HEAD").first.strip
    local_tags, = git(root, "tag", "--list")
    remote, ok = git(root, "ls-remote", REMOTE, "refs/heads/#{BRANCH}", "refs/tags/*")
    refs = ok ? remote.lines.to_h { |line| line.split("\t").map(&:strip).reverse } : {}
    remote_main = refs["refs/heads/#{BRANCH}"]
    tags = components.map { |component| component.tag(version) }
    [
      ("couldn't reach #{REMOTE}: #{remote.lines.last.to_s.strip}" unless ok),
      ("the working tree isn't clean:\n#{status.gsub(/^/, "      ")}" unless status.empty?),
      ("HEAD is on #{branch}, not #{BRANCH}" unless branch == BRANCH),
      ("#{REMOTE} has no #{BRANCH} branch" if ok && !remote_main),
      ("HEAD (#{head[0, 7]}) isn't #{REMOTE}/#{BRANCH} (#{remote_main[0, 7]}): pull or push first" if remote_main && remote_main != head),
      *tags.select { |tag| local_tags.lines.map(&:strip).include?(tag) }.map { |tag| "the tag #{tag} exists already here" },
      *tags.select { |tag| refs.key?("refs/tags/#{tag}") }.map { |tag| "the tag #{tag} exists already on #{REMOTE}" }
    ].compact
  end

  # Builds +component+'s gem in +dir+, and checks it: what it's named and
  # numbered, that its files are all its own (tracked by Git in its
  # directory, and for Duel's, none a plugin's), and that it depends on
  # the other gems at requirements +version+ satisfies.
  def check_build(root, component, components, version, dir)
    path = File.join(dir, "#{component.name}.gem")
    output, status = Open3.capture2e("gem", "build", File.basename(component.gemspec), "--output", path, chdir: File.join(root, component.dir))
    return ["#{component.name} doesn't build: #{output.lines.last(3).join.strip}"] unless status.success?

    spec = Gem::Package.new(path).spec
    tracked, = git(root, "ls-files", "-z", "--", component.dir)
    own = tracked.split("\0").reject { |file| component.core? && file.start_with?("plugins/") }
      .map { |file| component.core? ? file : file.delete_prefix("#{component.dir}/") }
    foreign = spec.files - own
    siblings = spec.runtime_dependencies.select { |dependency| components.any? { |other| other.name == dependency.name } }
    [
      ("#{component.name} builds as #{spec.name} #{spec.version}, not #{component.name} #{version}" unless spec.name == component.name && spec.version.to_s == version),
      ("#{component.name}'s gem has files that aren't its own: #{foreign.join(", ")}" unless foreign.empty?),
      ("#{component.name} doesn't depend on duel" unless component.core? || siblings.any? { |dependency| dependency.name == "duel" }),
      *siblings.reject { |dependency| dependency.match?(dependency.name, version) }.map do |dependency|
        "#{component.name} depends on #{dependency.name} #{dependency.requirement}, which #{version} doesn't satisfy (#{component.gemspec})"
      end
    ].compact
  end

  # Checks, and unless any check fails (or it's a dry run), tags HEAD for
  # every gem and pushes the tags, once +input+ confirms (or +force+).
  # Whether the release went ahead (or would have, in a dry run).
  def release(root, date:, dry_run: false, force: false, input: $stdin, output: $stdout)
    version, problems = check(root, date:)
    unless problems.empty?
      output.puts "Can't release #{version}:", *problems.map { |problem| "  - #{problem}" }
      return false
    end

    components = components(root)
    head, = git(root, "rev-parse", "HEAD")
    head = head.strip
    tags = components.map { |component| component.tag(version) }
    output.puts "Every check passes for #{version} (#{components.size} gems, at #{head[0, 7]}, dated #{date})."
    if dry_run
      output.puts "Dry run: would tag #{head[0, 7]} #{tags.join(", ")}, and push each tag to #{REMOTE}."
      return true
    end

    unless force
      output.print "Tag #{head[0, 7]} #{tags.join(", ")} and push the tags to #{REMOTE}, releasing #{components.size} gems? [y/N] "
      unless input.gets.to_s.strip.casecmp?("y")
        output.puts "Not released."
        return false
      end
    end

    components.each { |component| git!(root, "tag", "--annotate", component.tag(version), "--message", "#{component.name} #{version}", head) }
    push(root, tags, output)
    output.puts "Released #{version}: the push workflows build, sign and push each gem."
    true
  end

  # Pushes +tags+ one at a time: GitHub runs no workflow for any tag of a
  # push of more than three (https://docs.github.com/en/actions/reference/events-that-trigger-workflows#push).
  def push(root, tags, output)
    tags.each_with_index do |tag, index|
      output.puts "Pushing #{tag}"
      _, ok = git(root, "push", REMOTE, "refs/tags/#{tag}")
      next if ok

      raise "Couldn't push #{tag}. Push the rest yourself: git push #{REMOTE} #{tags.drop(index).join(" ")}"
    end
  end

  # Sets every gem's version to +version+, moves each changelog's
  # Unreleased entries under a section for it dated +date+, links that
  # section, and loosens a gemspec's requirement of another of the gems
  # that +version+ wouldn't satisfy (to "~> 0.2", say). The files it
  # changed.
  def bump(root, version, date:)
    raise ArgumentError, "#{version.inspect} isn't a version" unless Gem::Version.correct?(version) && !version.to_s.empty?

    components = components(root)
    problems = components.filter_map do |component|
      current = version(root, component)
      "#{component.name} is at #{current} already, not below #{version}" unless Gem::Version.new(current) < Gem::Version.new(version)
    end
    raise ArgumentError, "Can't bump to #{version}:\n#{problems.map { |problem| "  - #{problem}" }.join("\n")}" unless problems.empty?

    components.flat_map do |component|
      previous = version(root, component)
      [
        rewrite(root, component.version_file) { |text| text.sub(VERSION_LINE) { "#{$1}#{version}#{$3}" } },
        rewrite(root, component.changelog) { |text| bump_changelog(text, component, previous, version, date) },
        rewrite(root, component.gemspec) { |text| loosen(text, components, version) }
      ]
    end.compact
  end

  def bump_changelog(text, component, previous, version, date)
    entries = section(text, UNRELEASED).to_s.strip
    entries = NO_CHANGES if entries.empty?
    text = text.sub(UNRELEASED_SECTION) do
      "## [#{UNRELEASED}]\n\n## [#{version}] - #{date}\n\n#{entries}\n\n"
    end
    text.sub(UNRELEASED_LINK) do
      base = $~[:base]
      "[#{UNRELEASED}]: #{base}/compare/#{component.tag(version)}...HEAD\n" \
        "[#{version}]: #{base}/compare/#{component.tag(previous)}...#{component.tag(version)}"
    end
  end

  def loosen(text, components, version)
    text.gsub(DEPENDENCY_LINE) do
      name, requirement = $2, $3
      next $& unless components.any? { |component| component.name == name } && !Gem::Requirement.new(requirement).satisfied_by?(Gem::Version.new(version))

      "#{$1}~> #{Gem::Version.new(version).segments.first(2).join(".")}#{$4}"
    end
  end

  # Writes the block's change to +path+ (under +root+), if it changes it.
  # The path, if it did.
  def rewrite(root, path)
    file = File.join(root, path)
    before = File.read(file)
    after = yield before
    return if after == before

    File.write(file, after)
    path
  end

  # [Git's output, whether it succeeded].
  def git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    [output, status.success?]
  end

  def git!(root, *args)
    output, ok = git(root, *args)
    raise "git #{args.join(" ")} failed: #{output.strip}" unless ok

    output
  end
end
