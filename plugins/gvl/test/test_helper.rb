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
require "duel/gvl"
require "duel/testing"
# Mutant runs the tests itself (and autorun, at exit, would run them all
# again in every one of its processes).
require defined?(Mutant) ? "minitest" : "minitest/autorun"
# Assertions that take only true and false for true and false.
require "minitest/strict"

begin
  # `cover "Duel::Thing*"` tells mutant which tests exercise which code.
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
  # Whether the extension is built, loaded here and not by
  # Duel::GVL.load_extension: that's under test (and with it broken, its
  # tests mustn't be skipped).
  EXTENSION = RUBY_ENGINE == "ruby" && begin
    require "duel_gvl/duel_gvl"
    true
  rescue LoadError
    false
  end

  def setup
    skip "no GVL to wait for on #{RUBY_ENGINE}" unless RUBY_ENGINE == "ruby"
    skip "the extension isn't built (bundle exec rake compile)" unless EXTENSION
  end

  def config = Duel::Config.new(Dir.pwd).tap { |c| c.use(:gvl) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

  # Runs +threads+ threads that each run Ruby code, never releasing the
  # GVL on their own, for +seconds+ from when they start (so as long as
  # any of them runs, the others wait), and waits for them all: none is
  # left to wait (or to be counted) later.
  def busy(threads, seconds)
    Array.new(threads) do
      Thread.new do
        deadline = monotonic + (seconds * 1e9)
        nil while monotonic < deadline
      end
    end.each(&:join)
  end

  # A project of three benchmarks: "wait", whose three threads each run
  # a little Ruby code and wait in a C call (usleep) that releases the
  # GVL (so they wait for each other now and then: how much depends on
  # how busy the machine is, 5% of their CPU time to more than all of
  # it), or (+held+) holds it (several times as long as they run);
  # "fight", whose three threads only run Ruby code (each waiting for
  # the other two: some three times as long as they run, whatever the
  # machine's doing); and "one thread", whose one thread does the work
  # (waiting next to nothing, below the floor).
  def project(dir, name, held:)
    Duel::Testing.project(File.join(dir, name),
      "lib/sample.rb" => <<~RUBY,
        require "fiddle"

        module Sample
          USLEEP = Fiddle::Function.new(Fiddle::Handle::DEFAULT["usleep"], [Fiddle::TYPE_UINT], Fiddle::TYPE_INT, need_gvl: #{held})

          def self.wait(n) = Array.new(3) { Thread.new { n.times { USLEEP.call(50); 500.times {} } } }.each(&:join)
        end
      RUBY
      "duel/wait_duel.rb" => <<~RUBY,
        require "sample"

        duel("wait", only: :timing) { |n| Sample.wait(n) }
        duel("fight", only: :timing) { |n| Array.new(3) { Thread.new { n.times { 500.times {} } } }.each(&:join) }
        duel("one thread", only: :timing) { |n| Thread.new { n.times { 500.times {} } }.join }
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :gvl
        end
      RUBY
  end

  # Compares the project at +base+ with +candidate+: patiently (a busy
  # machine's workers can be slow to answer), and with a limit for CPU
  # time it settles sooner (it isn't what's tested; gvl_wait has a limit
  # of its own).
  def compare(base, candidate) = Duel::Testing.compare(base, candidate, timeout: 300.0, limit: 1.5)
end
