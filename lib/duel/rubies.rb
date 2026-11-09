# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "../duel"

module Duel
  # The Ruby each version runs on (Config#ruby): by default the runner's.
  # With :version_file, it's the one the version's own version file names
  # (.ruby-version, .tool-versions or mise.toml, in its tree or above it):
  # the runner's own, if it's that one, or else the one installed with
  # whichever of rbenv, chruby, mise and asdf has it. Or it's a path, or
  # what a block makes of the version's tree.
  # @api private
  module Rubies
    # The files that name a Ruby, in the order they're looked at in each
    # directory.
    VERSION_FILES = %w[.ruby-version .tool-versions mise.toml .mise.toml].freeze

    # Where chruby finds Rubies.
    CHRUBY = ["/opt/rubies", File.join(Dir.home, ".rubies")].freeze

    # Where each manager has a version of Ruby installed (its prefix), or
    # nil: rbenv's and asdf's by exact name (without "ruby-"), chruby's as
    # chruby matches it, and mise's as mise does (3.4: the newest 3.4).
    MANAGERS = {
      "rbenv" => ->(version) { Rubies.command("rbenv", "prefix", version.delete_prefix("ruby-")) },
      "chruby" => ->(version) { Rubies.chruby(version) },
      "mise" => ->(version) { Rubies.command("mise", "where", "ruby@#{version.delete_prefix("ruby-")}") },
      "asdf" => ->(version) { Rubies.command("asdf", "where", "ruby", version.delete_prefix("ruby-")) }
    }.freeze

    # A Ruby's own variables, set by a manager (chruby's gems, say) for the
    # Ruby it chose: wrong for any other.
    VARIABLES = %w[GEM_HOME GEM_PATH GEM_ROOT RUBY_ROOT RUBY_ENGINE RUBY_VERSION RUBY_PATCHLEVEL RBENV_VERSION
      MISE_RUBY_VERSION ASDF_RUBY_VERSION].freeze

    # The JVM's options for a JRuby worker. Each JVM's JIT compiles the
    # same code a little differently, as its compiling in the background
    # races its running, so one worker can be some 10% faster or slower
    # than another for its whole life. -Xbatch compiles in the
    # foreground, so what's compiled is less a matter of timing, and the
    # serial collector runs no threads of its own beside the code:
    # together they make JRuby's intervals over workers some half as
    # wide.
    JRUBY_WORKER = %w[-J-Xbatch -J-XX:+UseSerialGC].freeze

    # A JVM option that chooses its garbage collector: the JVM won't start
    # with two, so where JRUBY_OPTS chooses one, the serial one isn't
    # added.
    GARBAGE_COLLECTOR = /\A-J-XX:\+Use\w+GC\z/

    class << self
      # The Ruby (its executable) that +choice+ gives the version +name+d
      # ("baseline") at +root+: one that isn't there fails.
      def find(choice, root, name)
        ruby = case choice
        when nil then RbConfig.ruby
        when :version_file then from_version_file(root, name)
        when String then choice
        else choice.call(root)
        end
        raise Error, "the #{name}'s Ruby (#{ruby}) isn't there" unless File.file?(ruby) && File.executable?(ruby)

        ruby
      end

      # The engine of +ruby+ (RUBY_ENGINE): the runner's, or what +ruby+
      # says, without the runner's gems (or "ruby", where it can't say).
      def engine(ruby)
        return RUBY_ENGINE if runner?(ruby)

        out = IO.popen(environment(ruby).merge("RUBYOPT" => nil), [ruby, "--disable-gems", "-e", "print RUBY_ENGINE"], err: File::NULL, &:read)
        status = $? #: Process::Status
        status.success? ? out : "ruby"
      rescue SystemCallError
        "ruby"
      end

      # What a worker on +engine+ starts with: +env+, and on JRuby, the
      # JVM's options in JRUBY_WORKER (+env+'s JRUBY_OPTS, or else
      # +inherited+, the runner's, before them).
      def worker_environment(env, engine, inherited = ENV["JRUBY_OPTS"])
        return env unless engine == "jruby"

        options = env.fetch("JRUBY_OPTS") { inherited }.to_s.split
        collector = options.any? { |option| option.match?(GARBAGE_COLLECTOR) }
        added = JRUBY_WORKER.reject { |option| options.include?(option) || (collector && option.match?(GARBAGE_COLLECTOR)) }
        env.merge("JRUBY_OPTS" => (options + added).join(" "))
      end

      # Whether +ruby+ is the runner's own.
      def runner?(ruby) = File.realpath(ruby) == File.realpath(RbConfig.ruby)

      # What a version's processes on +ruby+ get in their environment:
      # nothing on the runner's Ruby. On another, its directory first on
      # +path+ (for what they start by name, `bundle` say), and none of the
      # runner's Ruby's VARIABLES.
      def environment(ruby, path: ENV["PATH"])
        return {} if runner?(ruby)

        VARIABLES.to_h { |variable| [variable, nil] }.merge("PATH" => [File.dirname(ruby), path].compact.join(File::PATH_SEPARATOR))
      end

      # The nearest version file, from +root+ up, that names a Ruby, and the
      # version it names: [file, version], or nil.
      def requested(root)
        dir = File.expand_path(root)
        loop do
          VERSION_FILES.each do |name|
            file = File.join(dir, name)
            version = (read(file) if File.file?(file))
            return [file, version] if version
          end
          return if dir == (dir = File.dirname(dir))
        end
      end

      # The version of Ruby a version file names, or nil (a .tool-versions
      # of other tools, say).
      def read(file)
        text = File.read(file)
        case File.basename(file)
        when ".ruby-version" then text.split.first
        when ".tool-versions" then text[/^ruby[ \t]+(\S+)/, 1]
        else
          # (mise.toml's [tools], up to the next table: ruby = "3.4",
          # ruby = ["3.4"], or ruby = { version = "3.4" }.)
          tools = text.partition(/^\[tools\]/).last.split(/^\[/).first
          tools&.[](/^[ \t]*"?ruby"?[ \t]*=[ \t]*[\[{]?[ \t]*(?:version[ \t]*=[ \t]*)?"([^"]+)"/, 1)
        end
      end

      # Where chruby has +version+: the Ruby of that name, or else the last
      # (by name) whose name has it in it.
      def chruby(version)
        dirs = CHRUBY.flat_map { |rubies| Dir.glob(File.join(rubies, "*")) }
        dirs.find { |dir| File.basename(dir) == version } || dirs.reverse.find { |dir| File.basename(dir).include?(version) }
      end

      # Whether +version+, as a version file names it, is the runner's own
      # Ruby (by its +engine+ and its +engine_version+), as the managers
      # match one: with or without "ruby-" for CRuby (a bare version is
      # CRuby's), with its engine's name for another ("jruby-10.1.2.0",
      # "truffleruby+graalvm-24.1.0"), and exactly or by its first parts
      # ("3.4" for 3.4.11, as mise and chruby take it).
      def runner_asked?(version, engine: RUBY_ENGINE, engine_version: RUBY_ENGINE_VERSION)
        match = /\A(?:([a-z]+)(?:\+[^-]+)?-)?(\d[\w.]*)\z/.match(version)
        return false unless match

        name, number = match.captures
        (name || "ruby") == engine && (engine_version == number || engine_version.start_with?("#{number}."))
      end

      # What a command prints, or nil if it fails (or isn't there).
      def command(*command)
        out, _, status = Open3.capture3(*command)
        out.strip if status.success?
      rescue SystemCallError
        nil
      end

      private

      # The Ruby the nearest version file names (see #requested): the
      # runner's, if it's that one (see #runner_asked?) or there's no
      # version file, or else the first manager's that has it.
      def from_version_file(root, name)
        requested = requested(root)
        return RbConfig.ruby unless requested

        file, version = requested
        # (The runner's own, if it's the one asked for: installed where no
        # manager looks, by CI's setup step, say.)
        return RbConfig.ruby if runner_asked?(version)

        MANAGERS.each_value do |manager|
          prefix = manager.call(version)
          # (JRuby's may have no bin/ruby.)
          ruby = prefix && %w[ruby jruby].map { |program| File.join(prefix, "bin", program) }.find { |path| File.executable?(path) }
          return ruby if ruby
        end
        raise Error, "the #{name}'s #{file} asks for Ruby #{version}, which isn't installed with rbenv, chruby, mise or " \
          "asdf: install it, or set c.ruby in .duel.rb"
      end
    end
  end
end
