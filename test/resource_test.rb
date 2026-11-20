# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

# What a resource block gets: a directory of the worker's own, processes
# started there and waited for, and stopped with it.
class ResourceTest < DuelTest
  cover "Duel::Resource*"

  hangs_after 5

  # Each process a test starts leads a process group of its own, which
  # ends with the test, with anything it started, whatever the resource
  # does (a mutation of it that stops nothing, say, or waits forever).
  # (Process.spawn's, not Resource#spawn's: a mutation could drop the
  # option, or return anything but the pid.)
  # Each runs in a directory of its own too, so what a mutation writes to
  # a relative path (a log that isn't in the resource's directory, say)
  # lands there, and one that isn't tmpdir, where a test runs a command
  # (chdir:).
  def setup
    super
    @made = []
    @dir = Dir.pwd
    Dir.chdir(FileUtils.mkdir_p(File.join(tmpdir, "cwd")).fetch(0))
    groups = @groups = []
    spawn = @spawn = Process.method(:spawn)
    Process.define_singleton_method(:spawn) do |*command, **options|
      spawn.call(*command, **options, **Duel::Spawn.group).tap { |pid| groups << pid }
    end
  end

  def teardown
    @hang_watch&.kill
    Process.define_singleton_method(:spawn, @spawn)
    @groups.each { |pid| end_group(pid) }
    # (Through Open3, on JRuby on Windows, none leads a group of the test's:
    # each resource's processes, killed with what they started.)
    @made.flat_map { |r| r.instance_variable_get(:@processes) }.each { |process| Duel::Spawn.kill_tree(process.child.pid) } if Duel::Platform::JRUBY_ON_WINDOWS
    Dir.chdir(@dir)
    super
  end

  # (Long enough for a JVM to start on a busy machine.)
  def resource(timeout: 30.0)
    Duel::Resource.new(File.join(short_tmpdir, "head-1-1"), "head-1", "/candidate", timeout: timeout,
      cache: File.join(tmpdir, "cache")).tap { |r| @made << r }
  end

  # (On JRuby on Windows, its JVM's command: see Duel::Rubies.launch.)
  def ruby(*code) = [*RUBY_COMMAND, "-e", *code]

  # A log, with LF line endings (JRuby reads CRLF as it is, on Windows).
  def logged(path) = File.read(path).gsub("\r\n", "\n")

  # What a Ruby process's log is named for ("ruby", or "jruby", say, or on
  # JRuby on Windows, its JVM's "java.exe").
  RUBY = File.basename(RUBY_COMMAND.first)

  def alive?(pid)
    Process.kill(0, pid) && true
  rescue Errno::ESRCH, Errno::EPERM # (JRuby's EPERM, on Windows, for one that ended)
    false
  end

  # Prepare blocks, in order, each given a Resource of its own (kept as
  # it's made), and what they returned together. Each Resource's env is
  # the one given, or (a version's, so_far) with what the blocks before it
  # returned too.
  def test_prepared_by_blocks
    blocks = [->(_) { {"A" => "1"} }, ->(r) { {"B" => r.env.fetch("A", "none")} }]
    [false, true].each do |so_far|
      kept = []
      env = Duel::Resource.prepare(blocks, File.join(tmpdir, "w"), "head-1", "/candidate", env: {"E" => "e"}, ruby: "/ruby", timeout: 7.0,
        cache: File.join(tmpdir, "cache"), so_far:) { |r| kept << r }

      assert_equal({"E" => "e", "A" => "1", "B" => so_far ? "1" : "none"}, env, "so_far: #{so_far}")
      assert_equal [{"E" => "e"}, so_far ? {"E" => "e", "A" => "1"} : {"E" => "e"}], kept.map(&:env)
      assert_equal [File.join(tmpdir, "w-1"), File.join(tmpdir, "w-2")], kept.map(&:dir)
      assert_equal [["head-1", "/candidate", "/ruby", 7.0, File.join(tmpdir, "cache")]] * 2,
        kept.map { |r| [r.name, r.root, r.ruby, *%i[@timeout @cache].map { |ivar| r.instance_variable_get(ivar) }] }
    end
    assert_equal({"E" => "e"}, Duel::Resource.prepare([], "w", "head-1", "/c", env: {"E" => "e"}, ruby: "/ruby", timeout: 1.0, cache: "c") { flunk })
    kept = []
    Duel::Resource.prepare(blocks, File.join(tmpdir, "w"), "head-1", "/c", env: {}, ruby: "/ruby", timeout: 1.0, cache: "c") { |r| kept << r }

    assert_equal [{}, {}], kept.map(&:env), "by default, a worker's: its version's alone"
    clash = [->(_) { {"X" => "1"} }, ->(_) { {"X" => "2"} }]
    error = assert_raises(Duel::Failed) do
      Duel::Resource.prepare(clash, File.join(tmpdir, "w"), "head-1", "/c", env: {}, ruby: "/ruby", timeout: 1.0, cache: "c") { nil }
    end

    assert_equal "head-1: two prepare blocks set X (1, 2)", error.message
  end

  def test_a_directory_of_its_own
    r = resource

    assert_equal "head-1", r.name
    assert_equal "/candidate", r.root
    assert_equal "head-1-1", File.basename(r.dir)
    assert Dir.exist?(r.dir)
    assert_equal File.join(r.dir, "redis.sock"), r.path("redis.sock")
  end

  # A port the system chose, free again, for a server to listen on.
  def test_a_free_port
    r = resource
    ports = Array.new(3) { r.port }

    assert(ports.all? { |port| port.between?(1, 65_535) })
    TCPServer.new("127.0.0.1", ports.last).close
  end

  # Its version's Ruby (the runner's, by default), and its version's
  # environment for what it runs, under a command's own.
  def test_its_versions_ruby_and_environment
    assert_equal RbConfig.ruby, resource.ruby
    r = Duel::Resource.new(File.join(short_tmpdir, "baseline"), "baseline", "/base", timeout: 30.0, cache: tmpdir, ruby: "/other/ruby",
      env: {"DUEL_TEST_A" => "version", "DUEL_TEST_B" => "version"})

    assert_equal ["/other/ruby", {"DUEL_TEST_A" => "version", "DUEL_TEST_B" => "version"}], [r.ruby, r.env]
    assert_empty resource.env
    echo = ruby("puts ENV.values_at('DUEL_TEST_A', 'DUEL_TEST_B').join(' ')")
    r.run(*echo, log: "plain")
    r.run(Class.new(Hash)["DUEL_TEST_B", "its own"], *echo, log: "own")
    r.spawn({"DUEL_TEST_B" => "spawned"}, *echo, log: "spawned")
    r.wait_until { File.size?(r.path("spawned.log")) }

    assert_equal ["version version\n", "version its own\n", "version spawned\n"], %w[plain own spawned].map { |log| logged(r.path("#{log}.log")) }
  end

  def test_spawns_a_process_logging_to_its_directory_and_stops_it
    r = resource
    pid = r.spawn(*ruby("puts :once; $stdout.flush; warn :twice; sleep"))
    r.wait_until { logged(r.path("#{RUBY}.log")).include?("twice") }

    assert_equal "once\ntwice\n", logged(r.path("#{RUBY}.log")), "out and err, added to its program's log"
    # (Through Open3, it's open while its output is copied to it.)
    assert_empty open_logs(r), "the runner's copy closed" if redirects?

    assert alive?(pid)
    r.stop

    refute alive?(pid), "ended, and waited for"
    assert_empty open_logs(r), "the runner's copy closed, once it's done"
  end

  # The runner's Files open on the log, where ObjectSpace can tell
  # (JRuby's sees only classes).
  def open_logs(resource)
    return [] unless RUBY_ENGINE == "ruby"

    ObjectSpace.each_object(File).select { |f| !f.closed? && f.path == resource.path("#{RUBY}.log") }
  end

  # Whether Process.spawn redirects its output.
  def redirects? = true

  def test_a_spawned_process_gets_no_other_file_descriptors
    skip "JRuby's spawn ignores close_others" if RUBY_ENGINE == "jruby"
    skip "Windows's spawn ignores close_others: only a handle made inheritable is passed on" if windows?

    IO.pipe do |reader, writer|
      writer.close_on_exec = false
      resource.spawn(*ruby("sleep"))
      writer.close

      assert_nil reader.read_nonblock(1, exception: false), "the pipe's only writer is closed"
    end
  end

  def test_spawn_options_and_a_shell_command
    skip "sh's command: Windows's shell is cmd" if windows?

    r = resource
    elsewhere = File.realpath(tmpdir)
    r.spawn({"GREETING" => "hi"}, "echo $GREETING from $0 in $(pwd -P)", chdir: elsewhere)
    r.wait_until { logged(r.path("echo.log")).include?("hi") }

    assert_equal "hi from sh in #{elsewhere}\n", logged(r.path("echo.log")), "named for the program, run as told"
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

    assert_equal %(""\n), logged(r.path("#{RUBY}.log"))
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

    assert_equal "head-1's resource: #{RUBY} exited before it was ready\nport in use\n", error.message
  end

  # Every process is looked at, not just the first: here the second ends.
  def test_a_second_process_that_exits_before_its_ready
    r = resource
    r.spawn(*ruby("sleep"), log: "first")
    r.spawn(*ruby("puts 'port in use'; exit 1"), log: "second")
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "head-1's resource: second exited before it was ready\nport in use\n", error.message
  ensure
    r&.stop
  end

  # One that got ready and ended since the last look (a command that
  # writes what's waited for, say) is ready: it's looked at once more.
  def test_a_process_that_ends_ready
    r = resource
    done = r.path("done")
    r.spawn(*ruby("File.write(ARGV[0], '')", done))
    sleep 0.05 until File.exist?(done)
    sleep 0.2 # (and has ended)
    looks = 0

    assert_nil r.wait_until { (looks += 1) > 1 }
    assert_equal 2, looks, "after it ended"
  end

  def test_a_process_that_isnt_ready_in_time
    r = resource(timeout: 0.2)
    r.spawn(*ruby("puts 'starting'; $stdout.flush; sleep"))
    log = r.path("#{RUBY}.log")
    # (Started, and its log written, however long a busy machine takes.)
    sleep 0.01 until File.read(log).include?("starting")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "head-1's resource: not ready within 0.2s\nstarting\n", error.message
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator waited, :>=, 0.2
    assert_operator waited, :<, 2, "not much longer"
  end

  def test_waiting_without_a_process
    r = resource(timeout: 0.1)
    error = assert_raises(Duel::Failed) { r.wait_until { false } }

    assert_equal "head-1's resource: not ready within 0.1s", error.message
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

    assert_equal "head-1's resource: #{RUBY} exited before it was ready\n#{(2..11).map { |i| "#{i}\n" }.join}", error.message
  end

  # A process that ends when it's asked to (TERM) isn't killed, and only
  # the resource's own processes are waited for.
  def test_a_process_ends_when_asked
    skip "Windows kills, with no signal to ask it to stop" if windows?

    other = ended_child
    r = resource
    ended = r.path("ended")
    ready = r.path("ready")
    # (It takes a moment to end, after saying it was asked.)
    r.spawn(*ruby("trap('TERM') { File.write(ARGV[0], ''); sleep 0.2; exit }; File.write(ARGV[1], ''); sleep", ended, ready))
    r.wait_until { File.exist?(ready) }
    signals = []
    kill = Process.method(:kill)
    stub(Process, :kill, ->(signal, pid) { (signals << signal) && kill.call(signal, pid) }) { r.stop }

    assert_equal ["TERM"], signals, "not killed"
    assert_path_exists ended, "asked, and it ended"
    _, status = Process.wait2(other)

    assert_equal 3, status.exitstatus, "another child, still there to wait for"
  end

  # Windows can send another process no signal but KILL: what it spawned
  # there is killed.
  def test_stopped_on_windows
    r = resource
    ready = r.path("ready")
    new = Duel::Spawn::Child.method(:new)
    pid = stub(Duel::Spawn::Child, :new, ->(*args, **options) { new.call(*args, **options, windows: true) }) do
      r.spawn(*ruby("File.write(ARGV[0], ''); sleep", ready))
    end
    r.wait_until { File.exist?(ready) }
    killed = []
    kill = Process.method(:kill)
    # (Its tree, with taskkill, here as this system kills one.)
    stub(Duel::Spawn, :kill_tree, ->(id, windows:) { (killed << [id, windows]) && kill.call("KILL", id) }) do
      stub(Process, :kill, ->(*args) { flunk "sent #{args.inspect}, not its tree killed" }) { r.stop }
    end

    assert_equal [[pid, true]], killed, "with what it started (JRuby's JVM, say)"
  end

  # One that's gone already, as JRuby on Windows says of a process that
  # ended (EPERM), or as elsewhere (ESRCH), is let be.
  def test_stopping_one_said_to_be_gone
    [Errno::EPERM, Errno::ESRCH].each do |error|
      r = resource
      r.spawn(*ruby("sleep"))
      kill = Process.method(:kill)
      stub(Process, :kill, ->(_, id) { kill.call("KILL", id) && raise(error) }) { r.stop }
    end
  end

  # A log of its own name, and a signal of its own to stop it (some
  # servers shut down fast on INT, slowly on TERM).
  def test_a_named_log_and_a_stop_signal
    skip "Windows kills, with no signal to ask it to stop" if windows?

    r = resource
    ended = r.path("ended")
    ready = r.path("ready")
    r.spawn(*ruby("trap('INT') { File.write(ARGV[0], ''); exit }; trap('TERM') {}; puts :up; $stdout.flush; " \
      "File.write(ARGV[1], ''); sleep", ended, ready), log: "server", stop_signal: "INT")
    r.wait_until { File.exist?(ready) }
    r.stop

    assert_equal "up\n", logged(r.path("server.log"))
    assert_path_exists ended, "asked with INT"
  end

  # A command run to its end (setting something up), logged. One that
  # fails, fails, showing its log.
  def test_running_a_command
    r = resource
    r.run(*ruby("puts :made"), log: "setup")
    elsewhere = File.realpath(tmpdir)
    r.run(*ruby("puts Dir.pwd"), log: "where", chdir: elsewhere)

    assert_equal "made\n", logged(r.path("setup.log"))
    assert_equal "#{elsewhere}\n", logged(r.path("where.log")), "run as told"
    error = assert_raises(Duel::Failed) { r.run(*ruby("puts 'no space'; exit 4")) }

    assert_equal "head-1's resource: #{RUBY} exited with 4\nno space\n", error.message
  end

  # A program given its arguments is named for its whole path's last part,
  # spaces and all (C:/Program Files/PostgreSQL/17/bin/initdb, say), and a
  # command line for its first word.
  def test_a_program_in_a_path_with_a_space
    r = resource
    program = fake_command(File.join(tmpdir, "Program Files", "bin", "tool"), %(echo "$1"))
    r.run(program, "an argument")

    assert_equal "an argument\n", logged(r.path("#{File.basename(program)}.log"))
    r.run("echo a line")

    assert_equal "a line\n", logged(r.path("echo.log")), "a command line: its first word"
  end

  # One a signal killed says which.
  def test_running_a_command_a_signal_kills
    skip "Windows kills with no signal" if windows?

    error = assert_raises(Duel::Failed) { resource.run("sh", "-c", "kill -TERM $$", log: "killed") }

    assert_equal "head-1's resource: killed was killed by SIGTERM", error.message
    # (As JRuby's Signal.signame does for one it has no name for.)
    unnamed = assert_raises(Duel::Failed) do
      stub(Signal, :signame, ->(_) { raise ArgumentError }) { resource.run("sh", "-c", "kill -TERM $$", log: "killed") }
    end

    assert_equal "head-1's resource: killed was killed by signal 15", unnamed.message
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
    threads = resources.map { |r| Thread.new { r.cached("t") { |_| (builds += 1) && sleep(0.05) } } }
    # (Every one ended before any one's error is raised: a thread that
    # outlives the test dies under mutant's abort_on_exception, in its
    # main thread, as it reports, and the mutation goes uncounted.)
    threads.each { |thread| sleep 0.01 while thread.alive? }
    threads.each(&:join)

    assert_equal 1, builds
  end

  def test_a_cached_build_that_fails_leaves_nothing
    error = assert_raises(RuntimeError) { resource.cached("t") { |dir| File.write(File.join(dir, "half"), "") && raise("no initdb") } }

    assert_equal "no initdb", error.message
    assert_empty Dir.children(File.join(tmpdir, "cache"))
    error = assert_raises(ArgumentError) { resource.cached("../t") { flunk } }

    assert_equal 'a cache key is a file name (letters, digits, - _ .), not "../t"', error.message
  end

  # Another run that built it first wins, and one that fails to put it in
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

  # Once a run's done with them, the builds it used replace the others of
  # their name: of another version, or another hash. The rest stay.
  def test_builds_replaced_by_those_used
    cache = File.join(tmpdir, "cache")
    kept = %w[mysql-0.1.1 mysql-ab12 other-0.1.2-0123456789abcdef postgresql-0.1.2-0123456789abcdef t]
    gone = %w[mysql-0.1.1-0123456789abcdef mysql-0123456789abcdef mysql-0.1.2-fedcba9876543210 bundle-fedcba9876543210]
    (kept + gone).each { |build| FileUtils.mkdir_p(File.join(cache, build, "data")) }
    FileUtils.mkdir_p(File.join(tmpdir, "elsewhere", "postgresql-0.1.1-0123456789abcdef"))
    FileUtils.mkdir_p(File.join(cache, "redis-0.1-0123456789abcdef"))
    kept << "redis-0.1-0123456789abcdef"
    Duel::Resource.new(short_tmpdir, "head-1", "/candidate", timeout: 1.0, cache: File.join(tmpdir, "elsewhere"))
      .cached("redis-0.2-1123456789abcdef") { |_| nil }
    used = %w[mysql-0.1.2-3f9c2a1b7e5d4c6a bundle-0123456789abcdef bundle-1123456789abcdef t]
    used.each { |key| resource.cached(key) { |_| nil } }
    Duel::Resource.evict(cache)

    assert_equal (kept | used).sort, Dir.children(cache).sort
    assert_path_exists File.join(tmpdir, "elsewhere", "postgresql-0.1.1-0123456789abcdef"), "another cache's"
    Duel::Resource.evict(File.join(tmpdir, "none"))

    pass "no cache, nothing to remove"
  end

  def test_the_environment_of_several
    assert_equal({"A" => "1", "B" => "2"}, Duel::Resource.environment("head-1", {"A" => "1"}, {"A" => "1", "B" => "2"}),
      "the same value twice is no clash")
    error = assert_raises(Duel::Failed) { Duel::Resource.environment("head-1", {"A" => "1", "B" => "2"}, {"B" => "3"}) }

    assert_equal "head-1: two prepare blocks set B (2, 3)", error.message
  end

  # A log of a Windows program's lines, ending with CRLF: shown with LF.
  def test_failing_with_a_log_of_crlf_lines
    r = resource
    File.binwrite(r.path("x.log"), "a\r\nb\r\n")
    error = assert_raises(Duel::Failed) { r.fail!("broke", log: r.path("x.log")) }

    assert_equal "head-1's resource: broke\na\nb\n", error.message
  end

  def test_failing_with_a_reason
    r = resource
    error = assert_raises(Duel::Failed) { r.fail!("no PostgreSQL") }

    assert_equal "head-1's resource: no PostgreSQL", error.message
    File.write(r.path("why.log"), "a\nb\n")
    error = assert_raises(Duel::Failed) { r.fail!("no PostgreSQL", log: r.path("why.log")) }

    assert_equal "head-1's resource: no PostgreSQL\na\nb\n", error.message
  end

  def test_a_process_that_ignores_term_is_killed
    other = ended_child
    r = resource
    ready = r.path("ready")
    pid = r.spawn(*ruby("trap('TERM') {}; File.write(ARGV[0], ''); sleep", ready))
    r.wait_until { File.exist?(ready) }
    with_constants(Duel::Resource, STOP_WAIT: 0.2) { r.stop }

    refute alive?(pid)
    assert_still_to_wait_for(other, "another child, still there to wait for")
  end

  def test_stopping_a_process_already_gone
    r = resource
    pid = r.spawn(*ruby("exit"))
    sleep 0.01 while alive?(pid)
    r.stop
  end
end

# The same, its processes started through Open3, as where Process.spawn
# redirects nothing (JRuby on Windows: see Duel::Spawn). (Every one of
# ResourceTest's tests again, as it's meant to.)
class ResourceThroughOpen3Test < ResourceTest
  def resource(timeout: 30.0)
    Duel::Resource.new(File.join(short_tmpdir, "head-1-1"), "head-1", "/candidate", timeout: timeout,
      cache: File.join(tmpdir, "cache"), starter: Duel::Spawn::ThroughOpen3).tap { |r| @made << r }
  end

  def redirects? = false

  # Its processes are started by the starter it's given, and waited for
  # by the thread their Child has (Open3's, which ends once the output is
  # in the log), not detached.
  def test_waited_for_by_the_thread_it_was_given
    r = resource
    child = Duel::Spawn::Child.new(42, Thread.new { :ended })
    stub(Duel::Spawn::ThroughOpen3, :logged, ->(*, **) { child }) do
      stub(Process, :detach, ->(*) { flunk "detached" }) { assert_equal 42, r.spawn(*ruby("1")) }
    end

    assert_same child, r.instance_variable_get(:@processes).fetch(0).child
    assert_equal :ended, child.waiter.value
    r.instance_variable_get(:@processes).clear
  end

  def test_through_open3
    popen2e = Open3.method(:popen2e)
    called = []
    stub(Open3, :popen2e, ->(*args, **options) { (called << args.drop(1)) && popen2e.call(*args, **options) }) { resource.run(*ruby("1")) }

    assert_equal [ruby("1")], called
  end
end
