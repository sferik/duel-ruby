# frozen_string_literal: true

require_relative "test_helper"

# A worker process as the runner sees it, with what it spawns faked: a
# process that only sleeps (or exits), and the test playing the worker
# over the control socket.
class WorkerProcessTest < DuelTest
  cover "Duel::WorkerProcess*"

  HELLO = {"benchmarks" => [{"name" => "a", "n" => 1}, {"name" => "b", "n" => 2}], "metrics" => [{"name" => "cpu"}],
           "memory" => true, "profiler" => false, "yjit" => false, "ruby" => "ruby 9.9", "extensions" => {"x.so" => "/x.so"},
           "gem_dirs" => ["/gems/"]}.freeze

  def setup
    super
    @pids = []
    @threads = []
    @workers = []
    @dir = short_tmpdir
  end

  def teardown
    # The fake workers end with their test: one left to fail later, once
    # mutant's Thread.abort_on_exception is back, would end the process.
    # (Their connection closed first: JRuby's Thread#kill doesn't stop a
    # read.)
    @workers.each { |worker| worker.instance_variable_get(:@socket).close }
    @threads.each do |thread|
      thread.kill.join
    rescue # (what it failed with, if it did)
      nil
    end
    @pids.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
    super
  end

  # A WorkerProcess whose spawn runs +command+ instead, answering what
  # the block answers each request with (nil: it closes the connection),
  # after +hello+ (nil: nothing, ever).
  def worker_process(command = %w[sleep 30], hello: HELLO, config_path: nil, timeout: 5.0, delay: 0, ruby: RbConfig.ruby, &serve)
    @spawned = []
    real = Process.method(:spawn)
    spawned = @spawned
    pids = @pids
    threads = @threads
    control = File.join(@dir, "candidate-1.sock")
    play = method(:play)
    fake = lambda do |*args, **options|
      spawned << [args, options]
      # (Its socket may be closed under it, when a test is done with it.)
      if hello
        threads << Thread.new do
          Thread.current.report_on_exception = false
          sleep(delay) && play.call(control, hello, &serve)
        end
      end
      real.call(*command, **options).tap { |pid| pids << pid }
    end
    stub(Process, :spawn, fake) do
      Duel::WorkerProcess.new("candidate-1", "/base", "/candidate", @dir, config_path: config_path, env: {"E" => "1"},
        timeout: timeout, ruby: ruby)
    end.tap { |worker| @workers << worker }
  end

  def play(control, hello, &serve)
    socket = UNIXSocket.new(control)
    socket.puts JSON.generate(hello)
    socket.each_line do |line|
      reply = serve.call(JSON.parse(line))
      break socket.close unless reply

      socket.puts JSON.generate(reply)
    end
  end

  def test_starts_a_worker_and_learns_what_it_has
    worker = worker_process

    assert_equal [[{"E" => "1"}, RbConfig.ruby, *Duel::WorkerProcess.load_path(RbConfig.ruby).flat_map { |lib| ["-I", lib] }, "-r",
      "duel/worker", "-e", "Duel::Worker.main(*ARGV)", "/base", "/candidate", File.join(@dir, "candidate-1.sock")],
      {in: File::NULL, close_others: true}], @spawned.first
    assert_equal File.expand_path("../lib", __dir__), Duel::WorkerProcess::LIB
    assert_equal "candidate-1", worker.label
    assert_equal({"a" => {"name" => "a", "n" => 1}, "b" => {"name" => "b", "n" => 2}}, worker.benchmarks)
    assert_equal [{"name" => "cpu"}], worker.metrics
    assert_equal [true, false, false], [worker.memory, worker.profiler, worker.yjit]
    assert_equal ["ruby 9.9", {"x.so" => "/x.so"}, ["/gems/"]], [worker.description, worker.extensions, worker.gem_dirs]
    refute_path_exists File.join(@dir, "candidate-1.sock"), "its socket is gone once it's connected"
  end

  # A gem's spec, as Gem.loaded_specs has it.
  Spec = Struct.new(:full_require_paths, :runtime_dependencies)
  Dependency = Struct.new(:name)

  # Duel's lib first, then every Duel gem's (Duel's, its plugins'), and,
  # on the runner's own Ruby, Duel's dependencies'.
  def test_the_load_path
    specs = {"duel" => Spec.new(["/gems/duel/lib"], [Dependency.new("fiddle"), Dependency.new("unloaded")]),
             "duel-redis" => Spec.new(["/gems/duel-redis/lib", "/gems/duel-redis/ext"], []),
             "duelist" => Spec.new(["/gems/duelist/lib"], []), "redis" => Spec.new(["/gems/redis/lib"], []),
             "fiddle" => Spec.new(["/gems/fiddle/lib"], []), "my-duel" => Spec.new(["/gems/my-duel/lib"], [])}
    other = File.join(tmpdir, "ruby").tap { |ruby| File.write(ruby, "") }

    assert_equal [Duel::WorkerProcess::LIB, "/gems/duel/lib", "/gems/duel-redis/lib", "/gems/duel-redis/ext", "/gems/fiddle/lib"],
      Duel::WorkerProcess.load_path(RbConfig.ruby, specs: specs)
    assert_equal [Duel::WorkerProcess::LIB, "/gems/duel/lib", "/gems/duel-redis/lib", "/gems/duel-redis/ext"],
      Duel::WorkerProcess.load_path(other, specs: specs), "not another Ruby's dependencies"
    assert_equal [Duel::WorkerProcess::LIB, "/gems/duel-redis/lib", "/gems/duel-redis/ext"],
      Duel::WorkerProcess.load_path(RbConfig.ruby, specs: specs.except("duel"))
    assert_equal [Duel::WorkerProcess::LIB, "/gems/duel/lib"],
      Duel::WorkerProcess.load_path(RbConfig.ruby, specs: {"duel" => Spec.new([Duel::WorkerProcess::LIB, "/gems/duel/lib"], [])})
    assert_equal [Duel::WorkerProcess::LIB], Duel::WorkerProcess.load_path(RbConfig.ruby, specs: {}), "Duel not as a gem"
    assert_equal Duel::WorkerProcess.load_path(RbConfig.ruby, specs: Gem.loaded_specs), Duel::WorkerProcess.load_path(RbConfig.ruby)
  end

  # A worker on another Ruby, and a process benchmark's runs, started as
  # it was: on its Ruby, in its version's tree, with its environment, by
  # one ProcessSample for its life, stopped with it.
  def test_a_ruby_of_its_own_and_its_processes
    ruby = File.join(tmpdir, "ruby").tap { |path| File.write(path, "") }
    worker = stub(Duel::WorkerProcess, :load_path, ->(given) { ["/lib-for-#{File.basename(given)}"] }) do
      worker_process(%w[sleep 0.2], ruby: ruby)
    end

    assert_equal [ruby, "-I", "/lib-for-ruby", "-r"], @spawned.first.first[1, 4]
    made = []
    runs = Struct.new(:log) do
      def run(command) = (log << command) && {"timed" => {}}

      def stop = log << :stop
    end.new(made)
    stub(Duel::ProcessSample, :new, ->(*args, **options) { (made << [args, options]) && runs }) do
      assert_equal({"timed" => {}}, worker.run({"command" => %w[bin/rails runner 1], "ruby" => nil}))
      worker.run({"command" => nil, "ruby" => "require 'x'"})
    end
    worker.stop

    options = {env: {"E" => "1"}, chdir: "/base", log: File.join(@dir, "candidate-1.log"), timeout: 5.0}

    assert_equal [[["candidate-1"], options], %w[bin/rails runner 1], [ruby, "-I", "/base/lib", "-e", "require 'x'"], :stop], made
  end

  def test_a_worker_that_takes_a_while_to_load
    servers = []
    listen = UNIXServer.method(:new)
    worker = stub(UNIXServer, :new, ->(path) { listen.call(path).tap { |server| servers << server } }) do
      worker_process(hello: HELLO.merge("memory" => false, "profiler" => true, "yjit" => true), delay: 0.1)
    end

    assert_equal [false, true, true], [worker.memory, worker.profiler, worker.yjit]
    assert_predicate servers.first, :closed?
  end

  def test_a_config_file
    worker_process(config_path: "/c/.duel.rb")

    assert_equal "/c/.duel.rb", @spawned.first.first.last
  end

  def test_requests_and_replies
    worker = worker_process { |request| {"got" => request} }

    assert_equal({"got" => {"op" => "setup", "name" => "a", "n" => 2}}, worker.request("setup", "a", n: 2))
    assert_equal({"got" => {"op" => "sample", "name" => "a", "n" => 3, "runs" => 1, "count" => false}}, worker.sample("a", 3))
    assert_equal({"got" => {"op" => "sample", "name" => "a", "n" => 3, "runs" => 2, "count" => true}},
      worker.sample("a", 3, runs: 2, count: true))
  end

  def test_an_error_is_raised
    worker = worker_process { {"error" => "KeyError: no", "backtrace" => ["a.rb:1", "b.rb:2"]} }
    error = assert_raises(Duel::Failed) { worker.request("setup", "x") }

    assert_equal "candidate-1: KeyError: no\n  a.rb:1\n  b.rb:2", error.message
  end

  def test_a_worker_that_exits
    worker = worker_process { nil }
    error = assert_raises(Duel::Failed) { worker.request("setup", "x") }

    assert_equal "candidate-1 worker exited", error.message
  end

  def test_a_worker_that_doesnt_answer
    worker = worker_process(timeout: 0.2) { sleep }
    error = assert_raises(Duel::Failed) { worker.request("setup", "x") }

    assert_equal "candidate-1 worker didn't answer within 0.2s (killed: a benchmark that hangs?)", error.message
    assert_raises(Errno::ECHILD, "killed, and waited for") { Process.wait(@pids.first) }
  end

  def test_a_worker_that_exits_while_loading
    error = assert_raises(Duel::Failed) { worker_process(%w[true], hello: nil) }

    assert_equal "candidate-1 worker exited while loading", error.message
    assert_empty Dir.children(@dir), "its socket is gone"
  end

  def test_a_worker_that_doesnt_load_in_time
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Duel::Failed) { worker_process(hello: nil, timeout: 0.2) }

    assert_equal "candidate-1 worker didn't load within 0.2s (killed: a benchmark that hangs?)", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_raises(Errno::ECHILD) { Process.wait(@pids.first) }
    assert_empty Dir.children(@dir)
  end

  # Stopping, with the sleeps between looks and any kill seen.
  def stop(worker, **options)
    looks = []
    kills = []
    worker.define_singleton_method(:sleep) { |seconds| (looks << seconds) && Kernel.sleep(seconds) }
    kill = Process.method(:kill)
    stub(Process, :kill, ->(*args) { (kills << args.first) && kill.call(*args) }) { worker.stop(**options) }
    [looks, kills]
  end

  def test_stop_waits_for_the_worker_to_end
    worker = worker_process(%w[sleep 0.2])
    looks, kills = stop(worker)

    assert_predicate worker.instance_variable_get(:@socket), :closed?
    assert_operator looks.size, :>, 2
    assert_equal [0.01], looks.uniq
    assert_empty kills
    assert_raises(Errno::ECHILD, "waited for") { Process.wait(@pids.first) }
  end

  def test_stop_kills_a_stuck_worker
    worker = worker_process
    @pids << Process.spawn("true") # (to be waited for after: not by stop)
    sleep 0.1
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, kills = stop(worker, wait: 0.1)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal ["KILL"], kills
    assert_raises(Errno::ECHILD) { Process.wait(@pids.first) }
    assert_nil worker.stop, "already gone"
  end

  def test_waits_ten_seconds_by_default
    assert_equal 10, Duel::WorkerProcess::STOP_WAIT
  end
end
