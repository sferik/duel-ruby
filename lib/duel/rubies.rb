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
