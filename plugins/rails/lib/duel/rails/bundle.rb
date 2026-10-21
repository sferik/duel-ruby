# frozen_string_literal: true

require "bundler"
require "digest"

module Duel
  module Rails
    # Each version runs its own bundle: its Gemfile and its Gemfile.lock,
    # installed once for the run (Config#prepare(:version)) on the version's
    # Ruby, and kept installed for later runs (Resource#cached), so a
    # change that upgrades a gem (Rails itself, say) is compared too.
    #
    # (Duel puts its own gems, and its plugins', this one too, ahead of
    # the version's bundle in each worker: a version from before the app
    # added Duel still has them, and both versions are measured with the
    # same.)
    module Bundle
      # Gives each version its own bundle (see .environment).
      def self.configure(config) = config.prepare(:version) { |v| environment(v) }

      # The environment for the bundle of the version (a Resource for it),
      # installed first, on its Ruby: nothing for a version without a
      # Gemfile.lock.
      def self.environment(version)
        gemfile = File.join(version.root, "Gemfile")
        lockfile = "#{gemfile}.lock"
        return {} unless File.exist?(lockfile)

        version.cached(key(lockfile, version.ruby)) do
          version.run(unbundled.merge(version.env, "BUNDLE_GEMFILE" => gemfile), "bundle", "install", log: "bundle",
            chdir: version.root, unsetenv_others: true)
        end
        {"BUNDLE_GEMFILE" => gemfile, "BUNDLE_LOCKFILE" => lockfile}
      end

      # What a bundle installed is kept as: its lockfile's, for the Ruby
      # (its path) it's installed for, which has gems of its own.
      def self.key(lockfile, ruby) = "bundle-#{Digest::SHA256.hexdigest("#{File.read(lockfile)}\0#{ruby}")[0, 16]}"

      # The runner's environment without Bundler's part (the bundle it
      # runs in is the candidate's), for installing another.
      def self.unbundled = Bundler.unbundled_env
    end
  end
end
