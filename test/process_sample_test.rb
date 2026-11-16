# frozen_string_literal: true

require_relative "test_helper"

# A process benchmark's runs: each a fresh process, run by a Ruby process
# of its own, kept for the worker's life, that measures what its children
# took.
class ProcessSampleTest < DuelTest
  cover "Duel::ProcessSample*"
  hangs_after 10

  # (What it spawns is noted: the Ruby process of its own. And it runs
  # in a directory of its own, where what a mutation writes where it
  # shouldn't lands.)
  def setup
    super
    @log = File.join(tmpdir, "head-1.log")
    @spawned = []
    @waited = []
    @samples = []
    @pwd = Dir.pwd
    Dir.chdir(FileUtils.mkdir_p(File.join(tmpdir, "cwd")).fetch(0))
  end

  def teardown
    @samples.each(&:stop)
    Dir.chdir(@pwd)
    super
  end

  # Runs the block with what's spawned (or on JRuby on Windows, started
  # through Open3), and waited for, noted.
  def noting(&)
    spawned = @spawned
    waited = @waited
    spawn = Process.method(:spawn)
    wait = Process.method(:wait)
    opened = %i[popen2 popen2e].to_h { |name| [name, Open3.method(name)] }
    # (Open3's, where it starts them: not taskkill, run through it too.)
    open3 = lambda do |name|
      lambda do |*args, **options, &block|
        opened.fetch(name).call(*args, **options, &block).tap do |*, waiter|
          spawned << [waiter.pid, args, options] if Duel::Platform::JRUBY_ON_WINDOWS && args.first != "taskkill"
        end
      end
    end
    stub(Process, :spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |pid| spawned << [pid, args, options] } }) do
      stub(Open3, :popen2, open3.call(:popen2)) do
        stub(Open3, :popen2e, open3.call(:popen2e)) do
          stub(Process, :wait, ->(*args) { (waited << args) && wait.call(*args) }, &)
        end
      end
    end
  end

  # Whether JRuby runs a program it can't find through the shell: but on
  # Windows, where Duel finds it first.
  def jruby_shell? = RUBY_ENGINE == "jruby" && !Duel::Platform::JRUBY_ON_WINDOWS

  # Its log, with LF line endings (JRuby reads CRLF as it is, on Windows).
  def logged = File.read(@log).gsub("\r\n", "\n")

  # (A test of how a process is spawned: where it's started through
  # Open3, see the _through_open3 tests.)
  def skip_unless_spawned
    skip "started through Open3 here: see the _through_open3 tests" unless Duel::Spawn::REDIRECTS
  end

  # A ProcessSample, stopped after the test.
  # (Long enough for two JVMs, JRuby's, to start one after the other on a
  # busy machine: its Ruby process's, and a run's.)
  def sampler(env: {}, chdir: tmpdir, timeout: (RUBY_ENGINE == "jruby") ? 60.0 : 30.0, **options)
    Duel::ProcessSample.new("head-1", env: env, chdir: chdir, log: @log, timeout: timeout, **options).tap { |sample| @samples << sample }
  end

  def run_once(*command, **options) = noting { sampler(**options).run(command) }

  # (On JRuby on Windows, its JVM's command: see Duel::Rubies.launch.)
  def ruby(code) = [*RUBY_COMMAND, "-e", code]

  # Whether +pid+ is running, or ended but not yet waited for.
  def alive?(pid)
    Process.kill(0, pid) && true
  rescue Errno::ESRCH, Errno::EPERM # (JRuby's EPERM, on Windows, for one that ended)
    false
  end

  # Its Ruby process, out of the runner's bundle (its RUBYOPT and RUBYLIB
  # unset), with Duel's load path, given nothing else: started with the
  # first run, kept for the rest, and waited for once it's stopped.
  def test_the_ruby_process_of_its_own
    skip_unless_spawned
    other = ended_child
    runs = sampler
    pipes = []
    sent = []
    pipe = IO.method(:pipe)
    # (What's written to each pipe's end, noted.)
    pipes_noting = lambda do
      pipe.call.tap do |ends|
        pipes << ends
        ends.last.define_singleton_method(:puts) { |*lines| (sent << lines) && super(*lines) }
      end
    end
    stub(IO, :pipe, pipes_noting) { noting { 2.times { runs.run(["true"]) } } }

    assert_equal 1, @spawned.size, "one for every run"
    pid, args, options = @spawned.first
    env, ruby, *rest = args

    assert_equal [{"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby], [env, ruby]
    assert_equal [*Duel::WorkerProcess.load_path(RbConfig.ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/process_sample", "-e",
      "Duel::ProcessSample.main"], rest, "no argument (JRuby's spawn on Windows splits one at its spaces)"
    assert_equal({"env" => ENV.to_h, "chdir" => tmpdir, "log" => @log}, JSON.parse(sent.first.first), "its input's first line, first")
    assert_equal [%w[true]] * 2, sent.drop(1).map { |(line)| JSON.parse(line) }, "then each run's"
    (input, requests), (replies, output) = pipes

    assert_equal [input, output, true], options.values_at(:in, :out, :close_others), "a pipe each way"
    assert_equal Duel::Spawn.group, options.slice(:pgroup, :new_pgroup), "in a group of its own"
    assert_equal [true, false, false, true], [input, requests, replies, output].map(&:closed?), "its ends, not this process's"
    assert alive?(pid)
    noting { runs.stop }

    refute alive?(pid), "ended, and waited for"
    assert_equal [true, true], [requests, replies].map(&:closed?)
    assert_still_to_wait_for(other, "and only it")
    stub(Duel::Spawn, :kill_tree, ->(*) { flunk "stopped once" }) { noting { runs.stop(wait: 0) } }
    noting { runs.run(["true"]) }

    assert_equal 2, @spawned.size, "and started again"
  end

  # Its CPU time (the more it works, the more), and its peak memory where
  # that can be told.
  def test_measures_a_process
    runs = sampler
    light = noting { runs.run(ruby("1")) }
    # (Work for a while of CPU time, not a number of steps: a JVM's start
    # takes seconds of it, and varies by more than a few steps take.)
    busy = (RUBY_ENGINE == "ruby") ? 0.2 : 3
    heavy = noting do
      runs.run(ruby("cpu = -> { t = Process.times; t.utime + t.stime }; start = cpu.call; nil while cpu.call - start < #{busy}; " \
        "s = 'a' * 50_000_000"))
    end
    again = noting { runs.run(ruby("1")) }

    assert_equal %w[timed counted heap peak], heavy.keys
    assert_equal [{}, 0], heavy.values_at("counted", "heap")
    assert_operator heavy.fetch("timed").fetch("cpu"), :>, light.fetch("timed").fetch("cpu")
    assert_operator again.fetch("timed").fetch("cpu"), :<, heavy.fetch("timed").fetch("cpu"), "each run's own"
    # (On Windows, by a handle on it, JRuby's too.)
    if Duel::Native::FIDDLE || windows?
      assert_operator heavy.fetch("peak"), :>, 50_000_000
      assert_operator light.fetch("peak"), :<, heavy.fetch("peak")
      assert_operator again.fetch("peak"), :<, heavy.fetch("peak"), "each run's own"
    else
      assert_nil heavy.fetch("peak")
    end
  end

  # Each run's output in its log, that run's alone.
  def test_each_run_logged
    runs = sampler
    noting { %w[one two].each { |word| runs.run(["echo #{word}"]) } }

    assert_equal "two\n", logged
  end

  # Where it's told, with what it's given in its environment (over this
  # process's own, less what's unset), its output in its log.
  def test_where_and_with_what
    ENV["DUEL_TEST_KEPT"] = "kept"
    ENV["DUEL_TEST_UNSET"] = "set"
    run_once(*ruby("$stdout.sync = true; puts [*ENV.values_at('DUEL_TEST_GIVEN', 'DUEL_TEST_KEPT'), ENV.fetch('DUEL_TEST_UNSET', 'unset'), 'in', " \
      "File.realpath(Dir.pwd)].join(' '); warn 'err'"), env: {"DUEL_TEST_GIVEN" => "given", "DUEL_TEST_UNSET" => nil})

    assert_equal "given kept unset in #{File.realpath(tmpdir)}\nerr\n", logged
  ensure
    ENV.delete("DUEL_TEST_KEPT")
    ENV.delete("DUEL_TEST_UNSET")
  end

  # Measured out of the runner's bundle: what its Ruby needs, it loads
  # itself (the process gets the runner's environment, all the same).
  def test_out_of_the_runners_bundle
    ENV["RUBYOPT"] = "-rduel-no-such-library"
    # (Not Ruby's, which RUBYOPT would stop: the shell's.)
    run_once(windows? ? "echo %RUBYOPT%" : "echo $RUBYOPT")

    assert_equal "-rduel-no-such-library\n", logged
  ensure
    ENV.delete("RUBYOPT")
  end

  # A process that fails is an error, with the end of its output. The
  # Ruby process of its own runs the next all the same.
  def test_a_process_that_fails
    runs = sampler
    error = assert_raises(Duel::Failed) { noting { runs.run(ruby("12.times { |i| puts i }; exit 3")) } }

    assert_equal "head-1: #{ruby("12.times { |i| puts i }; exit 3").join(" ")} exited with 3\n#{(2..11).map { |i| "#{i}\n" }.join}",
      error.message
    noting { runs.run(["true"]) }

    assert_equal 1, @spawned.size
  end

  # One that can't start says why, and the Ruby process of its own runs
  # the next all the same.
  # (JRuby runs a program it can't find through the shell, which says
  # so, and exits with 127: but on Windows, where Duel finds it first.)
  def test_a_process_that_cant_start
    runs = sampler
    error = assert_raises(Duel::Failed) { noting { runs.run(["duel-no-such-program", "x"]) } }
    why = jruby_shell? ? /exited with 127\n.*duel-no-such-program: not found/ : /couldn't start: No such file or directory\b.*duel-no-such-program/

    assert_match(/\Ahead-1: duel-no-such-program x #{why}/, error.message)
    noting { runs.run(ruby("1")) }

    assert_equal 1, @spawned.size
  end

  # On Windows, a shell command whose environment has no COMSPEC: Ruby
  # can't find cmd.exe to run it.
  def test_a_shell_command_without_comspec_on_windows
    skip "Windows's alone" unless windows?

    ran = noting { Duel::ProcessSample.once(["exit 3"], {"PATH" => ENV.fetch("PATH")}, tmpdir, @log) }
    # (Duel runs one by cmd.exe itself, on JRuby: see Duel::Spawn.program.)
    if Duel::Platform::JRUBY_ON_WINDOWS
      assert_equal "exited with 3", ran.fetch("failed")
    else
      assert_equal({"cpu" => 0, "peak" => nil, "failed" => "couldn't start: No such file or directory - exit 3"}, ran)
    end
  end

  # What a command that can't start took: nothing.
  # (On JRuby, the shell's 127: see test_a_process_that_cant_start.)
  def test_once_that_cant_start
    ran = Duel::ProcessSample.once(["duel-no-such-program"], {"PATH" => ENV.fetch("PATH")}, tmpdir, @log)

    if jruby_shell?
      assert_equal "exited with 127", ran.fetch("failed")
    else
      assert_equal({"cpu" => 0, "peak" => nil, "failed" => "couldn't start: No such file or directory - duel-no-such-program"}, ran)
    end
  end

  # Its output's lines, a Windows program's ending with CRLF, shown with
  # LF.
  def test_a_process_that_fails_saying_crlf_lines
    command = ruby("$stdout.binmode; $stdout.write([97, 13, 10, 98, 13, 10].pack('C*')); exit 3")
    error = assert_raises(Duel::Failed) { sampler.run(command) }

    assert_equal "head-1: #{command.join(" ")} exited with 3\na\nb\n", error.message
  end

  # One a signal killed says which.
  def test_a_process_a_signal_killed
    skip "Windows kills with no signal" if windows?

    runs = sampler
    error = assert_raises(Duel::Failed) { noting { runs.run(["kill -TERM $$"]) } }

    assert_equal "head-1: kill -TERM $$ was killed by SIGTERM", error.message, "and said nothing"
  end

  # One that takes too long is killed, with what it started, and the Ruby
  # process that ran it: the next run starts another. (The timeout is
  # short only for the one that hangs. A run's time includes starting
  # its Ruby process, where there isn't one, and on a busy machine,
  # that can take more than a second.)
  def test_a_process_that_hangs
    started = File.join(tmpdir, "started")
    pids = File.join(tmpdir, "pids")
    # (Long enough for a Ruby to start another, under mutant's load.)
    timeout = (RUBY_ENGINE == "ruby") ? 2.0 : 15.0
    other = ended_child
    runs = sampler
    noting { runs.run(["true"]) }
    runs.instance_variable_set(:@timeout, timeout)
    # (Not Process.wait: JRuby's on Windows waits for nothing.)
    command = [*ruby("File.write(ARGV[1], ''); pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 60'); File.write(ARGV[0], pid.to_s); " \
      "sleep 0.1 while (Process.kill(0, pid) rescue nil)"), pids, started]
    error = assert_raises(Duel::Failed) { noting { runs.run(command) } }

    assert_equal "head-1: #{command.join(" ")} didn't end within #{timeout}s (killed)", error.message
    assert_path_exists started
    refute alive?(@spawned.first.first), "killed, and waited for"
    assert_still_to_wait_for(other, "and only it")
    pid = Integer(File.read(pids))

    # (JRuby on Windows says EPERM of a process that's gone.)
    assert_raises(Errno::ESRCH, Errno::EPERM, "what it started, killed too") do
      10.times { Process.kill(0, pid) && sleep(0.1) }
    end
    assert_equal [true, true], %i[@requests @replies].map { |pipe| runs.instance_variable_get(pipe).closed? }
    runs.instance_variable_set(:@timeout, 30.0)
    noting { runs.run(["true"]) }

    assert_equal 2, @spawned.size, "another, for the next"
  end

  # A reply read past the timeout, its pipe closed under it as its process
  # is killed, says nothing more.
  def test_a_reply_read_past_the_timeout
    runs = sampler
    noting { runs.run(["true"]) }
    runs.instance_variable_set(:@timeout, 0.1)
    real = runs.instance_variable_get(:@replies)
    replies = Object.new
    def replies.gets = sleep(0.3) && raise(IOError, "closed stream")
    runs.instance_variable_set(:@replies, replies)
    _, err = capture_io do
      stub(runs, :kill, -> {}) { assert_raises(Duel::Failed) { runs.run(["true"]) } }
      sleep 0.5
    end

    assert_empty err
  ensure
    runs&.instance_variable_set(:@replies, real)
  end

  # The timeout it's given is a run's. (The test above sets it once its
  # Ruby process has started, which a busy machine can take more than it
  # to do.)
  def test_its_timeout
    assert_in_delta 7.5, sampler(timeout: 7.5).instance_variable_get(:@timeout)
  end

  # A Ruby process of its own that ends (killed, say, here by what it
  # runs) fails the run, and is waited for: the next run starts another.
  def test_its_ruby_process_ends
    skip "JRuby's Process.ppid on Windows isn't its parent's" if Duel::Platform::JRUBY_ON_WINDOWS

    runs = sampler
    command = ruby("Process.kill('KILL', Process.ppid); sleep")
    error = assert_raises(Duel::Failed) { noting { runs.run(command) } }

    assert_equal "head-1: the process running #{command.join(" ")} exited", error.message
    refute alive?(@spawned.first.first), "waited for"
    noting { runs.run(["true"]) }

    assert_equal 2, @spawned.size
  end

  # One that doesn't end once its input is closed (on Windows, another
  # process can hold the input's other end) is killed, with what it
  # started, a while later: stopping never hangs.
  def test_stopping_one_that_doesnt_end
    runs = sampler
    noting { runs.run(["true"]) }
    held = runs.instance_variable_get(:@requests).dup
    pid = @spawned.first.first
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    killed = []
    kill_tree = Duel::Spawn.method(:kill_tree)
    stub(Duel::Spawn, :kill_tree, ->(*args) { (killed << args) && kill_tree.call(*args) }) { noting { runs.stop(wait: 0.3) } }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.3, "given the while"
    assert_equal [[pid]], killed
    refute alive?(pid), "and waited for"
    assert_equal [true, true], %i[@requests @replies].map { |pipe| runs.instance_variable_get(pipe).closed? }
    assert_equal 10, Duel::ProcessSample::STOP_WAIT
  ensure
    held&.close
  end

  # Where Process.spawn redirects nothing (JRuby on Windows: see
  # Duel::Spawn), its Ruby process is started through Open3, and runs,
  # stops, and is killed all the same.
  def test_its_ruby_process_through_open3
    runs = sampler(redirects: false)
    ran = runs.run(ruby("x = 0; 1_000_000.times { |i| x ^= i }; puts :logged"))

    assert_operator ran.fetch("timed").fetch("cpu"), :>, 0
    assert_equal "logged\n", logged
    error = assert_raises(Duel::Failed) { runs.run(ruby("puts :said; exit 3")) }

    assert_equal "head-1: #{ruby("puts :said; exit 3").join(" ")} exited with 3\nsaid\n", error.message
    pid = runs.instance_variable_get(:@pid)
    runs.stop

    refute alive?(pid), "ended, and waited for"
    assert_equal [true, true], %i[@requests @replies].map { |pipe| runs.instance_variable_get(pipe).closed? }
    runs.instance_variable_set(:@timeout, 0.5)
    piped = Duel::Spawn.method(:piped)
    started = []
    error = stub(Duel::Spawn, :piped, ->(*args, **options) { piped.call(*args, **options).tap { |(id)| started << [id, options] } }) do
      assert_raises(Duel::Failed) { runs.run(ruby("sleep")) }
    end

    assert_match(/didn't end within 0.5s \(killed\)\z/, error.message)
    pid, options = started.fetch(0)

    refute alive?(pid), "killed, and waited for"
    refute options.fetch(:redirects), "through Open3"
  end

  # A run through Open3: its output in its log, in its environment alone,
  # where it's told, how it ended, and what it took (its CPU time, as
  # Process.times has it, once it's waited for).
  def test_once_through_open3
    ENV["DUEL_TEST_OTHER"] = "not given"
    before = Duel::ProcessSample.cpu
    code = "$stdout.sync = true; x = 0; 1_000_000.times { |i| x ^= i }; puts ENV.values_at('X', 'DUEL_TEST_OTHER').inspect, File.basename(Dir.pwd); " \
           "warn :err; exit 3"
    # (On Windows, by a handle on its pid, as Open3 has it: see
    # test_once_on_windows.)
    ran = Duel::ProcessSample.once(ruby(code), {"PATH" => ENV.fetch("PATH"), "X" => "x"}, tmpdir, @log, windows: windows?, redirects: false)

    assert_equal "exited with 3", ran.fetch("failed")
    assert_operator ran.fetch("cpu"), :>, 0
    if windows?
      assert_operator ran.fetch("peak"), :>, 1_000_000
    else
      assert_nil ran.fetch("peak")
      assert_operator ran.fetch("cpu"), :<=, Duel::ProcessSample.cpu - before
    end

    assert_equal [%(["x", nil]), File.basename(tmpdir), "err"], File.readlines(@log, chomp: true).last(3)
    unless windows?
      killed = Duel::ProcessSample.once(ruby("Process.kill('KILL', $$)"), {}, tmpdir, @log, windows: false, redirects: false)

      assert_equal "was killed by SIGKILL", killed.fetch("failed")
    end

    missing = Duel::ProcessSample.once(["duel-no-such-program"], {}, tmpdir, @log, windows: false, redirects: false)
    if jruby_shell? # (see test_a_process_that_cant_start)
      assert_equal "exited with 127", missing.fetch("failed")
    else
      assert_equal({"cpu" => 0, "peak" => nil, "failed" => "couldn't start: No such file or directory - duel-no-such-program"}, missing)
    end
  end

  # Stopping gives its Ruby process STOP_WAIT seconds, by default.
  def test_stop_waits_ten_seconds_by_default
    runs = sampler
    noting { runs.run(["true"]) }
    waiter = runs.instance_variable_get(:@waiter)
    joined = []
    stub(waiter, :join, ->(*args) { (joined << args) && waiter.value && waiter }) { runs.stop }

    assert_equal [[10]], joined
  end

  # The fastest of a version's runs: their least CPU time, and least peak
  # memory, where each has one.
  def test_fastest
    samples = [[30, 7], [20, 5], [25, 6]].map { |cpu, peak| {"timed" => {"cpu" => cpu}, "counted" => {}, "heap" => 0, "peak" => peak} }

    assert_equal({"timed" => {"cpu" => 20}, "counted" => {}, "heap" => 0, "peak" => 5}, Duel::ProcessSample.fastest(samples))
    samples.last["peak"] = nil

    assert_nil Duel::ProcessSample.fastest(samples).fetch("peak")
  end

  # What runs in the process of its own, run here: a run for every line
  # of its input, until it ends, each reported on a line of its own as
  # soon as it's done: what that child took, in a process of its own (in
  # this process, the tests'), and how it ended. (What a run took is its
  # own: the children waited for before it, here the first run's, are no
  # part of the next run's CPU time.)
  def test_main
    other = ended_child
    # (On Windows, with COMSPEC, by which Ruby finds the shell, cmd.exe.)
    env = {"PATH" => ENV.fetch("PATH"), **(windows? ? {"COMSPEC" => ENV.fetch("COMSPEC")} : {})}
    spec = JSON.generate({"env" => env, "chdir" => tmpdir, "log" => @log})
    input, requests = IO.pipe
    replies, output = IO.pipe
    output.sync = false
    requests.puts spec
    thread = Thread.new { noting { Duel::ProcessSample.main(input: input, output: output) } }
    # (A signal's, off Windows, which kills with none. The exit's the
    # shell's, as a JVM's start, JRuby's, takes more CPU than the work.)
    commands = [ruby("x = 0; 1_000_000.times { |i| x ^= i }; puts :logged"), "exit 3", *(["kill -TERM $$"] unless windows?)]
    reports = commands.map do |command|
      requests.puts JSON.generate(command)

      assert replies.wait_readable(30), "reported at once"
      [JSON.parse(replies.gets), logged]
    end
    requests.close
    thread.join
    output.close
    (ran, logged), (failed,), (killed,) = reports

    assert_equal %w[cpu peak failed], ran.keys
    assert_operator ran.fetch("cpu"), :>, 1_000_000
    assert_operator failed.fetch("cpu"), :<, ran.fetch("cpu"), "an exit, not work too"
    assert_nil ran.fetch("failed")
    assert_equal "exited with 3", failed.fetch("failed")
    assert_equal "logged\n", logged, "its output in its log"
    assert_equal "was killed by SIGTERM", killed.fetch("failed") unless windows?

    assert_nil replies.gets, "nothing else"
    assert_equal commands.size, @spawned.size
    assert_still_to_wait_for(other, "only its own waited for")
  ensure
    [input, requests, replies, output].compact.each(&:close)
  end

  # A run: the CPU time of what this process waited for meanwhile, the
  # child's peak memory, in its environment as given, alone, where it's
  # told, reading nothing. (Off Windows: see test_once_on_windows.)
  def test_once
    ENV["DUEL_TEST_OTHER"] = "not given"
    env = {"PATH" => ENV.fetch("PATH"), "X" => "x"}
    FileUtils.mkdir_p(File.join(tmpdir, "in"))
    before = Duel::ProcessSample.cpu
    ran = stub(Duel::Native::Windows::Spawned, :open, ->(_) { flunk "a handle, off Windows" }) do
      noting do
        Duel::ProcessSample.once(ruby("x = 0; 1_000_000.times { |i| x ^= i }; p ENV.values_at('X', 'DUEL_TEST_OTHER'), " \
          "File.basename(Dir.pwd), $stdin.read; warn :err"), env, File.join(tmpdir, "in"), @log, windows: false)
      end
    end

    assert_equal Duel::ProcessSample.cpu - before, ran.fetch("cpu")
    assert_nil ran.fetch("failed")
    if Duel::Native::FIDDLE && !windows?
      assert_operator ran.fetch("peak"), :>, 1_000_000
    else
      assert_nil ran.fetch("peak")
    end
    # (TruffleRuby warns first, without LANG.)
    assert_equal [%(["x", nil]), %("in"), %(""), "err"], File.readlines(@log, chomp: true).last(4)
    _, args, options = @spawned.first

    # (By any case: on JRuby on Windows, ENV's own, Path.)
    assert_equal env, args.first.transform_keys { |var| env.each_key.find { |given| given.casecmp?(var) } || var }.slice(*env.keys)
    assert_equal [File.join(tmpdir, "in"), true, true], options.values_at(:chdir, :unsetenv_others, :close_others)
    # (Spawned: through Open3, see test_once_through_open3.)
    if Duel::Spawn::REDIRECTS
      out, err = options.values_at(:out, :err)

      assert_equal [@log, true, File::NULL], [out.path, out.closed?, options[:in]], "its log, opened here, and closed"
      assert_same out, err
    end
  ensure
    ENV.delete("DUEL_TEST_OTHER")
  end

  # On Windows, whose children's CPU time Process.times doesn't have,
  # what a handle of its own on the child says: its cycles, in
  # nanoseconds, and its peak working set. The handle is closed, however
  # the wait ends.
  def test_once_on_windows
    rate = Duel::CycleClock.instance_variable_get(:@rate)
    Duel::CycleClock.instance_variable_set(:@rate, 2.0)
    spawned = Struct.new(:cycles, :peak, :closed) { def close = self.closed = true }.new(3_000_000, 4096, false)
    opened = []
    ran = stub(Duel::Native::Windows::Spawned, :open, ->(pid) { (opened << pid) && spawned }) do
      noting { Duel::ProcessSample.once(ruby("exit 3"), {"PATH" => ENV.fetch("PATH")}, tmpdir, @log, windows: true) }
    end

    assert_equal [@spawned.first.first], opened
    assert_equal({"cpu" => 1_500_000, "peak" => 4096, "failed" => "exited with 3"}, ran)
    assert spawned.closed
    spawned.closed = false
    # (Waited for by Native::Child, or through Open3, by its thread.)
    stub(Duel::Native::Child, :wait, ->(_) { raise Interrupt }) do
      stub(Duel::Native::Child, :ended, ->(_) { raise Interrupt }) do
        stub(Duel::Native::Windows::Spawned, :open, ->(_) { spawned }) do
          assert_raises(Interrupt) { noting { Duel::ProcessSample.once(ruby("1"), {"PATH" => ENV.fetch("PATH")}, tmpdir, @log, windows: true) } }
        end
      end
    end

    assert spawned.closed, "however it ends"
    by_default = stub(Duel::Native::Windows::Spawned, :open, ->(_) { spawned }) do
      with_constants(Duel::Platform, WINDOWS: true) { noting { Duel::ProcessSample.once(ruby("1"), {"PATH" => ENV.fetch("PATH")}, tmpdir, @log) } }
    end

    assert_equal [1_500_000, 4096], by_default.values_at("cpu", "peak"), "on Windows, by default"
  ensure
    Duel::CycleClock.instance_variable_set(:@rate, rate)
  end

  # Without a handle (it couldn't be opened), what Process.times says.
  def test_once_on_windows_without_a_handle
    ran = stub(Duel::Native::Windows::Spawned, :open, ->(_) {}) do
      noting { Duel::ProcessSample.once(ruby("1"), {"PATH" => ENV.fetch("PATH")}, tmpdir, @log, windows: true) }
    end

    assert_nil ran.fetch("failed")
    assert_kind_of Integer, ran.fetch("cpu")
  end

  # What it starts gets no other file descriptors.
  def test_once_gives_nothing_else
    skip "JRuby's spawn ignores close_others" if RUBY_ENGINE == "jruby"
    skip "Windows's spawn ignores close_others: only a handle made inheritable is passed on" if windows?

    done = File.join(tmpdir, "done")
    IO.pipe do |reader, writer|
      writer.close_on_exec = false
      thread = Thread.new do
        noting { Duel::ProcessSample.once([*ruby("sleep 0.01 until File.exist?(ARGV[0])"), done], {}, tmpdir, @log) }
      end
      sleep 0.01 while @spawned.empty?
      writer.close

      assert_nil reader.read_nonblock(1, exception: false), "the pipe's only writer is closed, while it runs"
    ensure
      FileUtils.touch(done)
      thread&.join
    end
  end

  # An input that ends before it says what to run with runs nothing.
  def test_main_without_its_spec
    output = StringIO.new
    noting { Duel::ProcessSample.main(input: StringIO.new, output: output) }

    assert_equal ["", []], [output.string, @spawned]
  end

  # Its own input and output, unless it's given others.
  def test_main_on_its_own_input_and_output
    spec = JSON.generate({"env" => {"PATH" => ENV.fetch("PATH")}, "chdir" => tmpdir, "log" => @log})
    reader, writer = IO.pipe
    writer.puts spec
    writer.puts JSON.generate(["true"])
    writer.close
    stdin = $stdin
    $stdin = reader
    out, = capture_io { noting { Duel::ProcessSample.main } }

    assert_equal [nil], out.lines.map { |line| JSON.parse(line).fetch("failed") }
  ensure
    $stdin = stdin if stdin
  end

  # In nanoseconds: what children waited for took, user and system.
  def test_cpu
    times = Process::Tms.new(9.0, 9.0, 1.5, 0.2500000004)

    assert_equal 1_750_000_000, stub(Process, :times, -> { times }) { Duel::ProcessSample.cpu }
  end

  # How it ended: a signal by its name, where Ruby knows one, or else by
  # its number (JRuby on Windows names few, and raises for the rest).
  def test_why
    assert_equal "exited with 4", Duel::ProcessSample.why(4, nil)
    assert_equal "was killed by SIGKILL", stub(Signal, :signame, ->(signal) { (signal == 9) ? "KILL" : flunk }) { Duel::ProcessSample.why(nil, 9) }
    assert_equal "was killed by signal 99", stub(Signal, :signame, ->(_) {}) { Duel::ProcessSample.why(nil, 99) }
    assert_equal "was killed by signal 9", stub(Signal, :signame, ->(_) { raise ArgumentError }) { Duel::ProcessSample.why(nil, 9) }
  end
end
