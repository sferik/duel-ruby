# frozen_string_literal: true

require_relative "test_helper"

# A process benchmark's runs: each a fresh process, run by a Ruby process
# of its own, kept for the worker's life, that measures what its children
# took.
class ProcessSampleTest < DuelTest
  cover "Duel::ProcessSample*"

  # (What it spawns is noted: the Ruby process of its own. And it runs
  # in a directory of its own, where what a mutation writes where it
  # shouldn't lands.)
  def setup
    super
    @log = File.join(tmpdir, "candidate-1.log")
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

  # Runs the block with what's spawned, and waited for, noted.
  def noting(&)
    spawned = @spawned
    waited = @waited
    spawn = Process.method(:spawn)
    wait = Process.method(:wait)
    stub(Process, :spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |pid| spawned << [pid, args, options] } }) do
      stub(Process, :wait, ->(*args) { (waited << args) && wait.call(*args) }, &)
    end
  end

  # A ProcessSample, stopped after the test.
  def sampler(env: {}, chdir: tmpdir, timeout: 30.0)
    Duel::ProcessSample.new("candidate-1", env: env, chdir: chdir, log: @log, timeout: timeout).tap { |sample| @samples << sample }
  end

  def run_once(*command, **options) = noting { sampler(**options).run(command) }

  def ruby(code) = [RbConfig.ruby, "-e", code]

  # A child of the test's that has ended, and not been waited for.
  def ended_child
    other = Process.spawn(RbConfig.ruby, "-e", "exit 3")
    sleep 0.01 until `ps -o stat= -p #{other}`.start_with?("Z")
    other
  end

  # Its Ruby process, out of the runner's bundle (its RUBYOPT and RUBYLIB
  # unset), with Duel's load path, given nothing else: started with the
  # first run, kept for the rest, and waited for once it's stopped.
  def test_the_ruby_process_of_its_own
    other = ended_child
    runs = sampler
    pipes = []
    pipe = IO.method(:pipe)
    stub(IO, :pipe, -> { pipe.call.tap { |ends| pipes << ends } }) { noting { 2.times { runs.run(["true"]) } } }

    assert_equal 1, @spawned.size, "one for every run"
    pid, args, options = @spawned.first
    env, ruby, *rest = args

    assert_equal [{"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby], [env, ruby]
    assert_equal [*Duel::WorkerProcess.load_path(RbConfig.ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/process_sample", "-e",
      "Duel::ProcessSample.main(*ARGV)"], rest[0...-1]
    assert_equal({"env" => ENV.to_h, "chdir" => tmpdir, "log" => @log}, JSON.parse(rest.last))
    (input, requests), (replies, output) = pipes

    assert_equal [input, output, true, true], options.values_at(:in, :out, :pgroup, :close_others), "a pipe each way"
    assert_equal [true, false, false, true], [input, requests, replies, output].map(&:closed?), "its ends, not this process's"
    assert_empty @waited
    noting { runs.stop }

    assert_equal [[pid]], @waited, "waited for"
    assert_equal [true, true], [requests, replies].map(&:closed?)
    assert_equal 3, Process.wait2(other).last.exitstatus, "and only it"
    noting { runs.stop }

    assert_equal [[pid]], @waited, "once"
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
    if Duel::Native::FIDDLE
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

    assert_equal "two\n", File.read(@log)
  end

  # Where it's told, with what it's given in its environment (over this
  # process's own, less what's unset), its output in its log.
  def test_where_and_with_what
    ENV["DUEL_TEST_KEPT"] = "kept"
    ENV["DUEL_TEST_UNSET"] = "set"
    run_once("echo $DUEL_TEST_GIVEN $DUEL_TEST_KEPT ${DUEL_TEST_UNSET:-unset} in $(pwd -P); echo err >&2",
      env: {"DUEL_TEST_GIVEN" => "given", "DUEL_TEST_UNSET" => nil})

    assert_equal "given kept unset in #{File.realpath(tmpdir)}\nerr\n", File.read(@log)
  ensure
    ENV.delete("DUEL_TEST_KEPT")
    ENV.delete("DUEL_TEST_UNSET")
  end

  # Measured out of the runner's bundle: what its Ruby needs, it loads
  # itself (the process gets the runner's environment, all the same).
  def test_out_of_the_runners_bundle
    ENV["RUBYOPT"] = "-rduel-no-such-library"
    run_once("echo $RUBYOPT")

    assert_equal "-rduel-no-such-library\n", File.read(@log)
  ensure
    ENV.delete("RUBYOPT")
  end

  # A process that fails is an error, with the end of its output. The
  # Ruby process of its own runs the next all the same.
  def test_a_process_that_fails
    runs = sampler
    error = assert_raises(Duel::Failed) { noting { runs.run(ruby("12.times { |i| puts i }; exit 3")) } }

    assert_equal "candidate-1: #{RbConfig.ruby} -e 12.times { |i| puts i }; exit 3 exited with 3\n#{(2..11).map { |i| "#{i}\n" }.join}",
      error.message
    error = assert_raises(Duel::Failed) { noting { runs.run(["kill -TERM $$"]) } }

    assert_equal "candidate-1: kill -TERM $$ was killed by SIGTERM", error.message, "and said nothing"
    noting { runs.run(["true"]) }

    assert_equal 1, @spawned.size
  end

  # One that takes too long is killed, with what it started, and the Ruby
  # process that ran it: the next run starts another. (Long enough for
  # that Ruby process to start: JRuby's takes seconds.)
  def test_a_process_that_hangs
    started = File.join(tmpdir, "started")
    pids = File.join(tmpdir, "pids")
    timeout = (RUBY_ENGINE == "ruby") ? 1.0 : 15.0
    other = ended_child
    runs = sampler(timeout: timeout)
    error = assert_raises(Duel::Failed) { noting { runs.run(["sh", "-c", "sleep 60 & echo $! > #{pids}; touch #{started}; wait"]) } }

    assert_equal "candidate-1: sh -c sleep 60 & echo $! > #{pids}; touch #{started}; wait didn't end within #{timeout}s (killed)",
      error.message
    assert_path_exists started
    assert_equal [[@spawned.first.first]], @waited, "waited for"
    assert_equal 3, Process.wait2(other).last.exitstatus, "and only it"
    pid = Integer(File.read(pids))

    assert_raises(Errno::ESRCH, "what it started, killed too") do
      10.times { Process.kill(0, pid) && sleep(0.1) }
    end
    assert_equal [true, true], %i[@requests @replies].map { |pipe| runs.instance_variable_get(pipe).closed? }
    noting { runs.run(["true"]) }

    assert_equal 2, @spawned.size, "another, for the next"
  end

  # A Ruby process of its own that ends (killed, say, here by what it
  # runs) fails the run, and is waited for: the next run starts another.
  def test_its_ruby_process_ends
    runs = sampler
    error = assert_raises(Duel::Failed) { noting { runs.run(["sh", "-c", "kill -KILL $PPID"]) } }

    assert_equal "candidate-1: the process running sh -c kill -KILL $PPID exited", error.message
    assert_equal [[@spawned.first.first]], @waited, "waited for"
    noting { runs.run(["true"]) }

    assert_equal 2, @spawned.size
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
    spec = JSON.generate({"env" => {"PATH" => ENV.fetch("PATH")}, "chdir" => tmpdir, "log" => @log})
    input, requests = IO.pipe
    replies, output = IO.pipe
    output.sync = false
    thread = Thread.new { noting { Duel::ProcessSample.main(spec, input: input, output: output) } }
    reports = [ruby("x = 0; 1_000_000.times { |i| x ^= i }; puts :logged"), ["exit 3"], ["kill -TERM $$"]].map do |command|
      requests.puts JSON.generate(command)

      assert replies.wait_readable(30), "reported at once"
      [JSON.parse(replies.gets), File.read(@log)]
    end
    requests.close
    thread.join
    output.close
    (ran, logged), (failed,), (killed,) = reports

    assert_equal %w[cpu peak failed], ran.keys
    assert_operator ran.fetch("cpu"), :>, 1_000_000
    assert_operator failed.fetch("cpu"), :<, ran.fetch("cpu"), "a shell's exit, not a Ruby's work too"
    assert_nil ran.fetch("failed")
    assert_equal "exited with 3", failed.fetch("failed")
    assert_equal "logged\n", logged, "its output in its log"
    assert_equal "was killed by SIGTERM", killed.fetch("failed")
    assert_nil replies.gets, "nothing else"
    assert_equal 3, @spawned.size
    assert_equal 3, Process.wait2(other).last.exitstatus, "only its own waited for"
  ensure
    [input, requests, replies, output].compact.each(&:close)
  end

  # A run: the CPU time of what this process waited for meanwhile, the
  # child's peak memory, in its environment as given, alone, where it's
  # told, reading nothing.
  def test_once
    ENV["DUEL_TEST_OTHER"] = "not given"
    env = {"PATH" => ENV.fetch("PATH"), "X" => "x"}
    FileUtils.mkdir_p(File.join(tmpdir, "in"))
    before = Duel::ProcessSample.cpu
    ran = noting do
      Duel::ProcessSample.once(ruby("x = 0; 1_000_000.times { |i| x ^= i }; p ENV.values_at('X', 'DUEL_TEST_OTHER'), " \
        "File.basename(Dir.pwd), $stdin.read; warn :err"), env, File.join(tmpdir, "in"), @log)
    end

    assert_equal Duel::ProcessSample.cpu - before, ran.fetch("cpu")
    assert_nil ran.fetch("failed")
    if Duel::Native::FIDDLE
      assert_operator ran.fetch("peak"), :>, 1_000_000
    else
      assert_nil ran.fetch("peak")
    end
    # (TruffleRuby warns first, without LANG.)
    assert_equal [%(["x", nil]), %("in"), %(""), "err"], File.readlines(@log, chomp: true).last(4)
    _, args, options = @spawned.first

    assert_equal env, args.first
    assert_equal [File.join(tmpdir, "in"), File::NULL, true, true], options.values_at(:chdir, :in, :unsetenv_others, :close_others)
    assert_equal [[@log, "w"], %i[child out]], options.values_at(:out, :err)
  ensure
    ENV.delete("DUEL_TEST_OTHER")
  end

  # What it starts gets no other file descriptors.
  def test_once_gives_nothing_else
    skip "JRuby's spawn ignores close_others" if RUBY_ENGINE == "jruby"

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

  # Its own input and output, unless it's given others.
  def test_main_on_its_own_input_and_output
    spec = JSON.generate({"env" => {}, "chdir" => tmpdir, "log" => @log})
    reader, writer = IO.pipe
    writer.puts JSON.generate(["true"])
    writer.close
    stdin = $stdin.dup
    $stdin.reopen(reader)
    out, = capture_io { noting { Duel::ProcessSample.main(spec) } }

    assert_equal [nil], out.lines.map { |line| JSON.parse(line).fetch("failed") }
  ensure
    $stdin.reopen(stdin) if stdin
  end

  # In nanoseconds: what children waited for took, user and system.
  def test_cpu
    times = Process::Tms.new(9.0, 9.0, 1.5, 0.2500000004)

    assert_equal 1_750_000_000, stub(Process, :times, -> { times }) { Duel::ProcessSample.cpu }
  end

  def test_why
    assert_equal "exited with 4", Duel::ProcessSample.why(4, nil)
    assert_equal "was killed by SIGKILL", Duel::ProcessSample.why(nil, 9)
  end
end
