# frozen_string_literal: true

# SimpleCov's strict profile: line, branch and method coverage, each held
# to 100% (COVERAGE=false to run some of the tests; mutant runs its own).
if ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby" && !defined?(Mutant)
  require "simplecov"
  SimpleCov.start("strict") do
    root File.expand_path("..", __dir__)
    skip %r{\A/?test/}
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/retained"
require "duel/testing"
# Mutant runs the tests itself (and autorun, at exit, would run them all
# again in every one of its processes).
require defined?(Mutant) ? "minitest" : "minitest/autorun"
require "minitest/strict"

# Where the tests' directories go. The process that made it removes it
# when the tests are done (under mutant, a test may be killed before its
# teardown, and minitest's hooks don't run). (Before mutant's coverage
# declarations, which define Mutant themselves.)
module TestFiles
  ROOT = Dir.mktmpdir("drt", "/tmp")
  OWNER = Process.pid
  cleanup = -> { FileUtils.rm_rf(ROOT) if Process.pid == OWNER }
  defined?(Mutant) ? at_exit(&cleanup) : Minitest.after_run(&cleanup)
end

begin
  # `cover "Duel::Retained*"` tells mutant which tests exercise which code.
  require "mutant/minitest/coverage"
rescue LoadError
  # mutant is CRuby's; elsewhere coverage declarations do nothing.
  module Minitest
    class Test
      def self.cover(_expression) = nil
    end
  end
end

class PluginTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("test", TestFiles::ROOT)
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # The metric is CRuby's: elsewhere the garbage collector can't be held
  # off, nor its live objects counted, nor their allocations traced.
  def cruby! = (skip "CRuby only: #{RUBY_ENGINE} can't count live objects or trace allocations" unless RUBY_ENGINE == "ruby")

  # Replaces +object+'s method +name+ with +body+ during the block.
  def stub(object, name, body)
    original = object.method(name)
    object.define_singleton_method(name, &body)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  # The plugin, used.
  def config = Duel::Config.new(@dir).tap { |c| c.use(:retained) }

  # A project of one benchmark, whose code remembers each item it's given
  # (made in an untimed block): all of them (+leak+), or only the last.
  def project(name, leak:)
    Duel::Testing.project(File.join(@dir, name),
      "lib/sample.rb" => <<~RUBY,
        module Sample
          @seen = []

          def self.remember(item) = #{leak ? "@seen << item.to_s" : "@seen[0] = item.to_s"}
        end
      RUBY
      "duel/remember_duel.rb" => <<~RUBY,
        require "sample"

        duel "remember" do
          item = untimed { Object.new }
          Sample.remember(item)
        end
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :retained
        end
      RUBY
  end
end
