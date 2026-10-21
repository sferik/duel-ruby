# frozen_string_literal: true

# SimpleCov's strict profile: line, branch and method coverage, each held
# to 100% (COVERAGE=false to run some of the tests; mutant runs its own).
if ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby" && !defined?(Mutant)
  require "simplecov"
  SimpleCov.start("strict") do
    root File.expand_path("..", __dir__)
    skip %r{\A/?test/}
    # (The generator's templates are ERB, evaluated: not the gem's code.)
    skip %r{/templates/}
  end
end

require "fileutils"
require "tmpdir"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
# (Rails first, as in an app: duel/rails then has its Railtie.)
require "rails"
require "duel/rails"
require "duel/testing"
# Mutant runs the tests itself (and autorun, at exit, would run them all
# again in every one of its processes).
require defined?(Mutant) ? "minitest" : "minitest/autorun"
require "minitest/strict"

# Where the tests' files go: each test's directory, and each process's
# database (each of mutant's has its own: they'd lock one another out of
# a shared one). The process that made it removes it when the tests are
# done (under mutant, a test may be killed before its teardown, and
# minitest's hooks don't run).
module TestFiles
  ROOT = Dir.mktmpdir("drt", "/tmp")
  OWNER = Process.pid
  cleanup = -> { FileUtils.rm_rf(ROOT) if Process.pid == OWNER }
  defined?(Mutant) ? at_exit(&cleanup) : Minitest.after_run(&cleanup)
end

# The tests' app (test/app), booted once as a worker boots its version,
# in the benchmark environment, from its own directory (and back).
module TestApp
  ROOT = File.expand_path("app", __dir__)

  here = Dir.pwd
  ENV["DATABASE_URL"] = "sqlite3:#{File.join(TestFiles::ROOT, "boot.sqlite3")}"
  Duel::Rails.boot(ROOT, "benchmark")
  Dir.chdir(here)

  # Connects this process to its own database, with the app's schema, the
  # first time (see TestFiles).
  def self.connect
    return if @connected == Process.pid

    @connected = Process.pid
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(TestFiles::ROOT, "test-#{Process.pid}.sqlite3"))
    Duel::Rails::Database.load_schema
  end
end

begin
  # `cover "Duel::Rails*"` tells mutant which tests exercise which code.
  require "mutant/minitest/coverage"
rescue LoadError
  # mutant is CRuby's: elsewhere coverage declarations do nothing.
  module Minitest
    class Test
      def self.cover(_expression) = nil
    end
  end
end

class PluginTest < Minitest::Test
  def setup
    TestApp.connect
    @dir = Dir.mktmpdir("test", TestFiles::ROOT)
    Post.delete_all
  end

  def teardown
    Duel.benchmarks.clear
    Rails.cache.clear
  end

  # Replaces +object+'s method +name+ with +body+ during the block.
  def stub(object, name, body)
    original = object.method(name)
    object.define_singleton_method(name, &body)
    yield
  ensure
    if original.owner == object.singleton_class
      object.define_singleton_method(name, original)
    else
      object.singleton_class.remove_method(name)
    end
  end

  # A Rack environment's response from the app, read through.
  def get(path) = Rack::MockRequest.new(Rails.application).get(path)
end
