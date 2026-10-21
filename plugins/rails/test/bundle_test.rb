# frozen_string_literal: true

require_relative "test_helper"

# Each version's own bundle, from a Resource for the version
# (Config#prepare(:version): Duel::Resource, faked: what it's asked to cache
# and run).
class BundleTest < PluginTest
  cover "Duel::Rails::Bundle*"

  # A version at +root+, on +ruby+, with +env+, logging what's cached and
  # run.
  class FakeVersion
    attr_reader :root, :ruby, :env, :log

    def initialize(root, ruby: "/rubies/3.4/bin/ruby", env: {})
      @root = root
      @ruby = ruby
      @env = env
      @log = []
    end

    def cached(key)
      @log << [:cached, key]
      yield "/cache/#{key}"
    end

    def run(*command, **options) = @log << [:run, command, options]
  end

  def lockfile(content = "GEM\n")
    gemfile = File.join(@dir, "Gemfile")
    File.write(gemfile, "source 'https://rubygems.org'\n")
    File.write("#{gemfile}.lock", content)
    gemfile
  end

  def test_a_version_without_a_lockfile_keeps_the_runners_bundle
    File.write(File.join(@dir, "Gemfile"), "")
    version = FakeVersion.new(@dir)

    assert_empty Duel::Rails::Bundle.environment(version)
    assert_empty version.log
  end

  # Installed once per lockfile and Ruby (the key names them), in the
  # version's own directory, outside the runner's bundle and on the
  # version's Ruby (its environment); its workers then run it.
  def test_a_versions_own_bundle
    gemfile = lockfile
    version = FakeVersion.new(@dir, env: {"PATH" => "/rubies/3.3/bin", "GEM_HOME" => nil})
    env = Duel::Rails::Bundle.environment(version)
    unbundled = Bundler.unbundled_env.merge("PATH" => "/rubies/3.3/bin", "GEM_HOME" => nil, "BUNDLE_GEMFILE" => gemfile)

    assert_equal [[:cached, Duel::Rails::Bundle.key("#{gemfile}.lock", "/rubies/3.4/bin/ruby")],
      [:run, [unbundled, "bundle", "install"], {log: "bundle", chdir: @dir, unsetenv_others: true}]], version.log
    assert_equal({"BUNDLE_GEMFILE" => gemfile, "BUNDLE_LOCKFILE" => "#{gemfile}.lock"}, env)
  end

  # Keyed by the lockfile's content and the Ruby's path: another of either
  # is installed again.
  def test_key
    gemfile = lockfile
    key = Duel::Rails::Bundle.key("#{gemfile}.lock", "/ruby")

    assert_equal "bundle-#{Digest::SHA256.hexdigest("GEM\n\0/ruby")[0, 16]}", key
    refute_equal key, Duel::Rails::Bundle.key("#{gemfile}.lock", "/other")
    lockfile("GEM\n  rails\n")

    refute_equal key, Duel::Rails::Bundle.key("#{gemfile}.lock", "/ruby")
  end

  def test_configure_prepares_each_version
    c = Duel::Config.new(@dir)
    Duel::Rails::Bundle.configure(c)

    assert_equal 1, c.prepares.fetch(:version).size
    assert_empty c.prepares.fetch(:version).first.call(FakeVersion.new(@dir)), "(no Gemfile.lock)"
    gemfile = lockfile

    assert_equal gemfile, c.prepares.fetch(:version).first.call(FakeVersion.new(@dir)).fetch("BUNDLE_GEMFILE")
  end

  def test_unbundled
    assert_equal Bundler.unbundled_env, Duel::Rails::Bundle.unbundled
  end
end
