# frozen_string_literal: true

require_relative "test_helper"

# What a resource block gets: a directory of the worker's own, processes
# started there and waited for, and stopped with it.
class ResourceTest < DuelTest
  cover "Duel::Resource*"

  def setup
    super
    @resources = []
  end

  def teardown
    @resources.each(&:stop)
    super
  end

  # (Long enough for a JVM to start on a busy machine.)
  def resource(timeout: 30.0)
    Duel::Resource.new(File.join(short_tmpdir, "candidate-1-1"), "candidate-1", "/candidate", timeout: timeout,
      cache: File.join(tmpdir, "cache")).tap { |r| @resources << r }
  end

  def ruby(*code) = [RbConfig.ruby, "-e", *code]

  # What a Ruby process's log is named for ("ruby", or "jruby", say).
  RUBY = File.basename(RbConfig.ruby)

  def alive?(pid)
    Process.kill(0, pid) && true
  rescue Errno::ESRCH
    false
  end

  def test_a_directory_of_its_own
    r = resource

    assert_equal "candidate-1", r.name
    assert_equal "/candidate", r.root
    assert_equal "candidate-1-1", File.basename(r.dir)
    assert Dir.exist?(r.dir)
    assert_equal File.join(r.dir, "redis.sock"), r.path("redis.sock")
  end

  def test_spawns_a_process_logging_to_its_directory_and_stops_it
    r = resource
    pid = r.spawn(*ruby("puts :once; $stdout.flush; warn :twice; sleep"))
    r.wait_until { File.read(r.path("#{RUBY}.log")).include?("twice") }

    assert_equal "once\ntwice\n", File.read(r.path("#{RUBY}.log")), "out and err, added to its program's log"
    if RUBY_ENGINE == "ruby" # (JRuby's ObjectSpace sees only classes)
      assert_empty ObjectSpace.each_object(File).select { |f| !f.closed? && f.path == r.path("#{RUBY}.log") }, "the runner's copy closed"
    end

    assert alive?(pid)
    r.stop

    refute alive?(pid), "ended, and waited for"
  end

  def test_a_spawned_process_gets_no_other_file_descriptors
    skip "JRuby's spawn ignores close_others" if RUBY_ENGINE == "jruby"

    IO.pipe do |reader, writer|
      writer.close_on_exec = false
      resource.spawn(*ruby("sleep"))
      writer.close

      assert_nil reader.read_nonblock(1, exception: false), "the pipe's only writer is closed"
    end
  end

  def test_spawn_options_and_a_shell_command
    r = resource
    elsewhere = File.realpath(tmpdir)
    r.spawn({"GREETING" => "hi"}, "echo $GREETING from $0 in $(pwd -P)", chdir: elsewhere)
    r.wait_until { File.read(r.path("echo.log")).include?("hi") }

    assert_equal "hi from sh in #{elsewhere}\n", File.read(r.path("echo.log")), "named for the program, run as told"
  end

  # Its input is nothing, not the runner's.
  def test_a_spawned_process_reads_nothing
    reader, writer = IO.pipe
    writer.write("the runner's input")
    writer.close
    stdin = $stdin.dup
    $stdin.reopen(reader)
    r = resource
    r.spawn(*ruby("p $stdin.read"))
    r.wait_until { File.size?(r.path("#{RUBY}.log")) }

    assert_equal %(""\n), File.read(r.path("#{RUBY}.log"))
  ensure
    $stdin.reopen(stdin) if stdin
  end

  def test_waits_until_ready
    r = resource
    ready = r.path("ready")
    r.spawn(*ruby("sleep 0.2; File.write(ARGV[0], '')", ready))
    looks = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r.wait_until { (looks += 1) && File.exist?(ready) }
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator looks, :>, 1
    assert_operator looks, :<=, (waited / Duel::Resource::POLL) + 2, "a look every POLL seconds"
  end

  def test_a_process_that_exits_before_its_ready
    r = resource
    r.spawn(*ruby("puts 'port in use'; exit 1"))
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "candidate-1's resource: #{RUBY} exited before it was ready\nport in use\n", error.message
  end

  def test_a_process_that_isnt_ready_in_time
    r = resource(timeout: 0.2)
    r.spawn(*ruby("puts 'starting'; $stdout.flush; sleep"))
    log = r.path("#{RUBY}.log")
    # (Started, and its log written, however long a busy machine takes.)
    sleep 0.01 until File.read(log).include?("starting")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "candidate-1's resource: not ready within 0.2s\nstarting\n", error.message
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator waited, :>=, 0.2
    assert_operator waited, :<, 2, "not much longer"
  end

  def test_waiting_without_a_process
    r = resource(timeout: 0.1)
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "candidate-1's resource: not ready within 0.1s", error.message
    r.wait_until { true }
  end

  def test_at_stop_runs_first_last_first
    r = resource
    pid = r.spawn(*ruby("sleep"))
    order = []
    r.at_stop { order << [:first, alive?(pid)] }
    r.at_stop { order << [:second, alive?(pid)] }
    r.stop

    assert_equal [[:second, true], [:first, true]], order, "before its processes end"
  end

  def test_a_failure_shows_the_end_of_the_log
    r = resource
    r.spawn(*ruby("12.times { |i| puts i }; exit 1"))
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "candidate-1's resource: #{RUBY} exited before it was ready\n#{(2..11).map { |i| "#{i}\n" }.join}", error.message
  end

  # A process that ends when it's asked to (TERM) isn't killed; and only
  # the resource's own processes are waited for.
  def test_a_process_ends_when_asked
    other = ended_child
    r = resource
    ended = r.path("ended")
    ready = r.path("ready")
    r.spawn(*ruby("trap('TERM') { sleep 0.2; File.write(ARGV[0], ''); exit }; File.write(ARGV[1], ''); sleep", ended, ready))
    r.wait_until { File.exist?(ready) }
    signals = []
    kill = Process.method(:kill)
    stub(Process, :kill, ->(signal, pid) { (signals << signal) && kill.call(signal, pid) }) { r.stop }

    assert_path_exists ended, "not killed"
    assert_equal ["TERM"], signals
    _, status = Process.wait2(other)

    assert_equal 3, status.exitstatus, "another child, still there to wait for"
  end

  # A log of its own name, and a signal of its own to stop it (some
  # servers shut down fast on INT, slowly on TERM).
  def test_a_named_log_and_a_stop_signal
    r = resource
    ended = r.path("ended")
    ready = r.path("ready")
    r.spawn(*ruby("trap('INT') { File.write(ARGV[0], ''); exit }; trap('TERM') {}; puts :up; $stdout.flush; " \
      "File.write(ARGV[1], ''); sleep", ended, ready), log: "server", stop_signal: "INT")
    r.wait_until { File.exist?(ready) }
    r.stop

    assert_equal "up\n", File.read(r.path("server.log"))
    assert_path_exists ended, "asked with INT"
  end

  # A command run to its end (setting something up), logged; one that
  # fails, fails, showing its log.
  def test_running_a_command
    r = resource
    r.run(*ruby("puts :made"), log: "setup")
    elsewhere = File.realpath(tmpdir)
    r.run(*ruby("puts Dir.pwd"), log: "where", chdir: elsewhere)

    assert_equal "made\n", File.read(r.path("setup.log"))
    assert_equal "#{elsewhere}\n", File.read(r.path("where.log")), "run as told"
    error = assert_raises(Duel::Failed) { r.run(*ruby("puts 'no space'; exit 4")) }

    assert_equal "candidate-1's resource: #{RUBY} exited with 4\nno space\n", error.message
    error = assert_raises(Duel::Failed) { r.run("sh", "-c", "kill -TERM $$", log: "killed") }

    assert_equal "candidate-1's resource: killed was killed by SIGTERM", error.message
  end

  # Built once, for every worker (and later runs): the first to ask
  # builds it, in a directory of its own, renamed into place.
  def test_cached
    builds = 0
    dirs = Array.new(2) do
      resource.cached("template-1.0") do |dir|
        builds += 1
        File.write(File.join(dir, "made"), dir)
      end
    end

    assert_equal 1, builds
    assert_equal [File.join(tmpdir, "cache", "template-1.0")] * 2, dirs
    assert_match(/template-1\.0\.\d+\.building\z/, File.read(File.join(dirs.first, "made")), "built aside")
    assert_equal ["template-1.0"], Dir.children(File.join(tmpdir, "cache"))
  end

  # A build this process left half done (it crashed, say) is built again.
  def test_a_cached_build_left_half_done
    FileUtils.mkdir_p(File.join(tmpdir, "cache", "t.#{Process.pid}.building", "stale"))
    built = resource.cached("t") { |dir| File.write(File.join(dir, "fresh"), "") }

    assert_equal ["fresh"], Dir.children(built)
  end

  # Workers start at once: their resources build it once between them.
  def test_cached_by_workers_at_once
    builds = 0
    resources = Array.new(3) { resource }
    resources.map { |r| Thread.new { r.cached("t") { |_| (builds += 1) && sleep(0.05) } } }.each(&:join)

    assert_equal 1, builds
  end

  def test_a_cached_build_that_fails_leaves_nothing
    error = assert_raises(RuntimeError) { resource.cached("t") { |dir| File.write(File.join(dir, "half"), "") && raise("no initdb") } }

    assert_equal "no initdb", error.message
    assert_empty Dir.children(File.join(tmpdir, "cache"))
    error = assert_raises(ArgumentError) { resource.cached("../t") { flunk } }

    assert_equal 'a cache key is a file name (letters, digits, - _ .), not "../t"', error.message
  end

  # Another run that built it first wins; one that fails to put it in
  # place for another reason fails.
  def test_a_cached_build_another_run_finished_first
    cache = File.join(tmpdir, "cache")
    built = resource.cached("t") { |_| FileUtils.mkdir_p(File.join(cache, "t", "theirs")) }

    assert_equal ["theirs"], Dir.children(built)
    assert_equal ["t"], Dir.children(cache)
    error = stub(File, :rename, ->(*) { raise Errno::EACCES }) { assert_raises(Errno::EACCES) { resource.cached("u") { |_| nil } } }

    assert_kind_of SystemCallError, error
    assert_equal ["t"], Dir.children(cache), "nothing left behind"
  end

  def test_the_environment_of_several
    assert_equal({"A" => "1", "B" => "2"}, Duel::Resource.environment("candidate-1", {"A" => "1"}, {"A" => "1", "B" => "2"}),
      "the same value twice is no clash")
    error = assert_raises(Duel::Failed) { Duel::Resource.environment("candidate-1", {"A" => "1", "B" => "2"}, {"B" => "3"}) }

    assert_equal "candidate-1: two resources set B (2, 3)", error.message
  end

  def test_failing_with_a_reason
    r = resource
    error = assert_raises(Duel::Failed) { r.failed("no PostgreSQL") }

    assert_equal "candidate-1's resource: no PostgreSQL", error.message
    File.write(r.path("why.log"), "a\nb\n")
    error = assert_raises(Duel::Failed) { r.failed("no PostgreSQL", log: r.path("why.log")) }

    assert_equal "candidate-1's resource: no PostgreSQL\na\nb\n", error.message
  end

  def test_a_process_that_ignores_term_is_killed
    other = ended_child
    r = resource
    ready = r.path("ready")
    pid = r.spawn(*ruby("trap('TERM') {}; File.write(ARGV[0], ''); sleep", ready))
    r.wait_until { File.exist?(ready) }
    with_constants(Duel::Resource, STOP_WAIT: 0.2) { r.stop }

    refute alive?(pid)
    assert_equal 3, Process.wait2(other).last.exitstatus, "another child, still there to wait for"
  end

  # A child of the test's that has ended, and not been waited for.
  def ended_child
    other = Process.spawn(*ruby("exit 3"))
    sleep 0.01 until `ps -o stat= -p #{other}`.start_with?("Z")
    other
  end

  def test_stopping_a_process_already_gone
    r = resource
    pid = r.spawn(*ruby("exit"))
    Process.wait(pid)
    r.stop
  end
end
