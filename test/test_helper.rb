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

require "fileutils"
require "tmpdir"

# Every directory a run of the tests makes (the workers they start too) is
# under one root of its own, tmp/test/<pid>, reached by a path short enough
# for Unix sockets, /tmp/duel-test-<pid>, which is TMPDIR. A run that was
# interrupted (mutant's, say) leaves its root: the next run removes it.
module TestDirs
  ROOTS = File.expand_path("../tmp/test", __dir__)

  def self.short(pid) = "/tmp/duel-test-#{pid}"

  def self.alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM # (someone else's)
    true
  end

  # Removes the roots of runs that are over.
  def self.clear
    Dir.glob(File.join(ROOTS, "*")).each do |root|
      pid = Integer(File.basename(root), exception: false)
      next if pid && alive?(pid)

      FileUtils.rm_rf(root)
      FileUtils.rm_f(short(pid)) if pid
    end
  end

  # Makes this run's root, and points TMPDIR at it.
  def self.open
    clear
    root = File.join(ROOTS, Process.pid.to_s)
    FileUtils.mkdir_p(root)
    FileUtils.rm_f(short(Process.pid))
    File.symlink(root, short(Process.pid))
    ENV["TMPDIR"] = short(Process.pid)
    run = Process.pid
    at_exit do
      next unless Process.pid == run # (not in a process forked from it)

      FileUtils.rm_rf(root)
      FileUtils.rm_f(short(run))
    end
  end
end
TestDirs.open

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel"
require "duel/cli"
require "duel/worker"
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

# A list that threads add to at once (a lane's workers start at once:
# JRuby's Array isn't safe for that).
class SharedList < Array
  LOCK = Mutex.new

  def <<(item) = LOCK.synchronize { super }
end

class DuelTest < Minitest::Test
  def setup
    @saved_config = Duel.instance_variable_get(:@config)
    @saved_benchmarks = Duel.benchmarks.dup
    @saved_setups = [Duel.setups, Duel.teardowns].map { |all| all.to_h { |file, blocks| [file, blocks.dup] } }
    [Duel.benchmarks, Duel.setups, Duel.teardowns].each(&:clear)
    # A thread's error is raised where it's joined, as Duel expects (mutant
    # would have it raised at once, in the main thread, wherever that is).
    @saved_abort = Thread.abort_on_exception
    Thread.abort_on_exception = false
  end

  def teardown
    Thread.abort_on_exception = @saved_abort
    Duel.config = @saved_config
    Duel.benchmarks.replace(@saved_benchmarks)
    [Duel.setups, Duel.teardowns].zip(@saved_setups) { |all, saved| all.clear.merge!(saved) } # (keeping their defaults)
  end

  # The DSL, as files of benchmarks have it (a block's file is where it's
  # written: the test's).
  DSL = Object.new.extend(Duel::DSL)

  def duel(...) = DSL.duel(...)

  # A directory with a short path (for Unix sockets), removed after the run.
  def short_tmpdir = Dir.mktmpdir("dw").tap { |dir| Minitest.after_run { FileUtils.rm_rf(dir) } }

  # A directory for the test, removed after it.
  def tmpdir
    @tmpdir ||= Dir.mktmpdir("duel-test").tap { |dir| Minitest.after_run { FileUtils.rm_rf(dir) } }
  end

  # Runs the block in a directory of the test's own, so whatever a
  # mutation of the code writes in the working directory lands there.
  def elsewhere(&) = Dir.chdir(tmpdir, &)

  # Replaces +object+'s method +name+ with +body+ during the block (in
  # which self is +object+).
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

  # Sets constants of +mod+ during the block (those it had, as they were
  # after).
  def with_constants(mod, constants)
    saved = constants.keys.select { |name| mod.const_defined?(name, false) }.to_h { |name| [name, mod.send(:remove_const, name)] }
    constants.each { |name, value| mod.const_set(name, value) }
    yield
  ensure
    constants.each_key { |name| mod.send(:remove_const, name) if mod.const_defined?(name, false) }
    saved&.each { |name, value| mod.const_set(name, value) }
  end

  # Writes a small project into +dir+: lib/sample.rb, whose Sample.work
  # takes +work+ steps and allocates +allocations+ objects, and (unless
  # +benchmarks+ is nil) duel/sample_duel.rb defining +benchmarks+. (Each
  # step depends on the last, and the result is kept, so a JIT can't
  # skip the steps: TruffleRuby's would drop a plain count.)
  def project(dir, work: 3000, allocations: 0, benchmarks: DEFAULT_BENCHMARKS, extra: "")
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "sample.rb"), <<~RUBY)
      module Sample
        def self.work
          x = 0
          #{work}.times { |i| x = ((x * 31) + i) & 0xffff }
          #{allocations}.times { Object.new }
          @last = x
        end
        #{extra}
      end
    RUBY
    if benchmarks
      FileUtils.mkdir_p(File.join(dir, "duel"))
      File.write(File.join(dir, "duel", "sample_duel.rb"), benchmarks)
    end
    dir
  end

  # Whether this machine counts instructions (see Duel::Metrics::Instructions).
  INSTRUCTIONS = Duel::Metrics::Instructions.available?

  # The timed metrics a benchmark of +cpu+ gets here, as reported.
  def timed_metrics(cpu: :thread)
    counter = Duel::Metrics::Instructions.counter
    instructions = INSTRUCTIONS && (cpu == :thread || counter.scope == "process")
    instructions ? %w[instructions cpu] : %w[cpu]
  end

  DEFAULT_BENCHMARKS = <<~RUBY
    require "sample"

    duel("work") { Sample.work }
  RUBY

  def settings(**overrides)
    Duel::Settings.defaults.tap do |s|
      s.jobs = 1
      s.warm = 0.0
      overrides.each { |key, value| s[key] = value }
    end
  end
end
