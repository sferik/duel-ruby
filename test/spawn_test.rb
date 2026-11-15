# frozen_string_literal: true

require_relative "test_helper"

# Starting a process with its output in a log, or with a pipe each way:
# spawned with redirects, or through Open3 (as on JRuby on Windows).
class SpawnTest < DuelTest
  cover "Duel::Spawn*"
  hangs_after 5

  def setup
    super
    @log = File.join(tmpdir, "x.log")
  end

  # (On JRuby on Windows, its JVM's command: see Duel::Rubies.launch.)
  def ruby(code, *args) = [*RUBY_COMMAND, "-e", code, *args]

  def env = {"PATH" => ENV.fetch("PATH"), "X" => "x"}

  # Runs the block noting each Process.spawn and Open3 call, by name, and
  # the options it's given.
  def noting(calls, &)
    spawn = Process.method(:spawn)
    popen2 = Open3.method(:popen2)
    popen2e = Open3.method(:popen2e)
    popen3 = Open3.method(:popen3)
    noted = ->(options) { options[:out].is_a?(File) ? options.merge(at: options[:out].pos) : options }
    stub(Process, :spawn, ->(*args, **options) { (calls << [:spawn, noted.call(options)]) && spawn.call(*args, **options) }) do
      stub(Open3, :popen2, ->(*args, **options) { (calls << [:popen2, options]) && popen2.call(*args, **options) }) do
        stub(Open3, :popen2e, ->(*args, **options) { (calls << [:popen2e, options]) && popen2e.call(*args, **options) }) do
          stub(Open3, :popen3, ->(*args, **options) { (calls << [:popen3, options]) && popen3.call(*args, **options) }, &)
        end
      end
    end
  end

  # The runner's Files open on the log, where ObjectSpace can tell
  # (JRuby's sees only classes).
  def open_logs
    return [] unless RUBY_ENGINE == "ruby"

    ObjectSpace.each_object(File).select { |f| !f.closed? && f.path == @log }
  end

  # Whether +redirects+ is one Process.spawn can be given here: not on
  # JRuby on Windows, whose spawn redirects nothing.
  def ways = Duel::Spawn::REDIRECTS ? [true, false] : [false]

  def skip_unless_spawn_redirects
    skip "JRuby's spawn on Windows redirects nothing" unless Duel::Spawn::REDIRECTS
  end

  # (A JRuby child on Windows copies a process it spawned's output itself,
  # which stops as it ends.)
  def skip_a_jruby_childs_children
    skip "a JRuby child's own children's output, on Windows, is the child's to copy" if Duel::Spawn::JAVA
  end

  # Process.spawn redirects, but on JRuby on Windows.
  def test_redirects
    assert_equal !(RUBY_ENGINE == "jruby" && Duel::Native::WINDOWS), Duel::Spawn::REDIRECTS
    assert_equal [5, 65_536], [Duel::Spawn::COPY_WAIT, Duel::Spawn::CHUNK]
  end

  # Spawned: its output and errors in the log (added to it, or in its
  # place), its input nothing, with the options given, and waited for as
  # any child.
  def test_logged_spawned
    skip_unless_spawn_redirects
    File.write(@log, "before\n")
    size = File.size(@log) # (8 bytes on Windows, its line ending CRLF)
    calls = []
    code = "$stdout.sync = true; puts ENV['X'], File.basename(Dir.pwd), $stdin.read.inspect; warn :err; exit 3"
    started = noting(calls) { Duel::Spawn.logged(env, ruby(code), log: @log, mode: "a", redirects: true, chdir: tmpdir) }

    assert_equal [started.first, nil], started
    assert_equal 3, Process.wait2(started.first).last.exitstatus
    assert_equal "before\nx\n#{File.basename(tmpdir)}\n\"\"\nerr\n", File.read(@log)
    (called, options), = calls

    assert_equal [:spawn, File::NULL, tmpdir], [called, options[:in], options[:chdir]]
    assert_same options[:out], options[:err]
    assert_equal size, options[:at], "given at its end (where Windows's child writes)"
    assert_empty open_logs, "closed here"
    pid, = Duel::Spawn.logged(env, ruby("puts :again"), log: @log, mode: "w", redirects: true)
    Process.wait(pid)

    assert_equal "again\n", File.read(@log), "in its place"
  end

  # Through Open3: the same, but waited for by the thread it returns,
  # whose value is how it ended, once its output is in the log, and the
  # log and the pipe are closed.
  def test_logged_through_open3
    File.write(@log, "before\n")
    calls = []
    code = "$stdout.sync = true; puts ENV['X'], File.basename(Dir.pwd), $stdin.read.inspect; warn :err; exit 3"
    pipes = []
    popen2e = Open3.method(:popen2e)
    copy = Duel::Spawn.method(:copy)
    copied = []
    pid, waiter = stub(Open3, :popen2e, ->(*args, **options) { popen2e.call(*args, **options).tap { |opened| pipes.concat(opened.first(2)) } }) do
      stub(Duel::Spawn, :copy, ->(output, out, **options) { (copied << out.binmode?) && copy.call(output, out, **options) }) do
        noting(calls) { Duel::Spawn.logged(env, ruby(code), log: @log, mode: "a", redirects: false, chdir: tmpdir) }
      end
    end

    assert_equal waiter.value.pid, pid
    assert_equal 3, waiter.value.exitstatus
    assert_equal "before\nx\n#{File.basename(tmpdir)}\n\"\"\nerr\n", File.read(@log)
    assert_equal [[:popen2e, {chdir: tmpdir}]], calls.reject { |call| call.first == :spawn }
    assert_equal [true], copied, "copied to as it's written (not CRCRLF, on Windows)"
    assert_empty open_logs, "closed, once it's done"
    assert_equal [true, true], pipes.map(&:closed?), "its input at once, its output once it's done"
    pid, waiter = Duel::Spawn.logged(env, ruby("puts :again"), log: @log, mode: "w", redirects: false)

    assert_predicate waiter.value, :success?
    assert_equal "again\n", File.read(@log), "in its place"
    # (JRuby's Process.wait on Windows waits for nothing.)
    assert_raises(Errno::ECHILD, "waited for") { Process.wait(pid) } unless Duel::Spawn::JAVA
  end

  # What it says is in the log as it runs, for what waits on it to see.
  def test_logged_through_open3_as_it_runs
    pid, waiter = Duel::Spawn.logged(env, ruby("$stdout.sync = true; puts :ready; sleep"), log: @log, mode: "w", redirects: false)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.01 until File.read(@log).include?("ready") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert_includes File.read(@log), "ready", "while it runs"
  ensure
    Process.kill("KILL", pid) if pid
    waiter&.join
  end

  # All of what it says is in the log once it's ended, however much.
  def test_logged_through_open3_says_a_lot
    _, waiter = Duel::Spawn.logged(env, ruby("$stdout.write('x' * 8_000_000)"), log: @log, mode: "w", redirects: false)

    assert_predicate waiter.value, :success?
    assert_equal 8_000_000, File.size(@log)
  end

  # What a process it started says after it ended is in the log too, if
  # it's said within COPY_WAIT seconds.
  def test_logged_through_open3_after_it_ends
    skip_a_jruby_childs_children
    code = "$stdout.sync = true; puts :first; Process.spawn(RbConfig.ruby, '-e', '$stdout.sync = true; sleep 0.5; puts :later')"
    # (Seconds enough for a JVM, JRuby's, to start on a busy machine.)
    _, waiter = with_constants(Duel::Spawn, COPY_WAIT: 60) do
      Duel::Spawn.logged(env, ruby(code), log: @log, mode: "w", redirects: false).tap { |_, thread| thread.join }
    end

    assert_predicate waiter.value, :success?
    assert_equal "first\nlater\n", File.read(@log)
  end

  # Spawned unless Process.spawn redirects nothing, by default.
  def test_logged_by_default
    calls = []
    pid, waiter = noting(calls) { Duel::Spawn.logged(env, ruby("1"), log: @log, mode: "w") }
    waiter ? waiter.join : Process.wait(pid)

    assert_equal (Duel::Spawn::REDIRECTS ? :spawn : :popen2e), calls.first.first
  end

  # The log is there as soon as it starts, for a failure to show.
  def test_the_log_is_there_at_once
    ways.each do |redirects|
      FileUtils.rm_f(@log)
      pid, waiter = Duel::Spawn.logged(env, ruby("sleep 0.2"), log: @log, mode: "a", redirects: redirects)

      assert_path_exists @log
      waiter ? waiter.join : Process.wait(pid)
    end
  end

  # One whose output something it started holds open (a daemon, say):
  # COPY_WAIT seconds after it ends, its thread ends, and its copy is
  # stopped (quietly), the log and the pipe closed.
  def test_output_held_open
    skip_a_jruby_childs_children
    pids = File.join(tmpdir, "pids")
    code = "$stdout.sync = true; puts :started; pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 30'); File.write(ARGV[0], pid.to_s)"
    _, err = capture_io do
      _, waiter = with_constants(Duel::Spawn, COPY_WAIT: 0.2) do
        Duel::Spawn.logged(env, ruby(code, pids), log: @log, mode: "w", redirects: false).tap { |_, thread| thread.join }
      end

      assert_predicate waiter.value, :success?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.01 until open_logs.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      assert_empty open_logs, "closed"
      assert_equal "started\n", File.read(@log)
    end

    assert_empty err, "the copy stopped quietly"
  ensure
    held = Integer(File.read(pids)) if pids && File.exist?(pids)
    begin
      Process.kill("KILL", held) if held
    rescue Errno::ESRCH # (ended with its parent's console, on Windows)
      nil
    end
  end

  # A command that can't start raises, as Process.spawn does, and leaves
  # nothing open.
  def test_logged_that_cant_start
    ways.each do |redirects|
      assert_raises(Errno::ENOENT) { Duel::Spawn.logged(env, ["duel-no-such-program"], log: @log, mode: "w", redirects: redirects) }
    end

    assert_empty open_logs
  end

  # A pipe each way, spawned (its ends, not this process's, closed here)
  # or through Open3, with the options given, and a thread whose value is
  # how it ended.
  def test_piped
    {true => :spawn, false => :popen2}.slice(*ways).each do |redirects, expected|
      calls = []
      pid, input, output, waiter = noting(calls) do
        Duel::Spawn.piped(env, ruby("$stdout.sync = true; puts $stdin.gets.upcase, ENV['X'], File.basename(Dir.pwd); exit 4"),
          redirects: redirects, chdir: tmpdir)
      end
      input.puts "hi"
      input.close

      assert_equal ["HI", "x", File.basename(tmpdir)], output.read.split("\n")
      assert_equal [pid, 4], [waiter.value.pid, waiter.value.exitstatus], "redirects: #{redirects}"
      assert_equal [expected, tmpdir], [calls.first.first, calls.first.last[:chdir]]
      assert_equal 1, calls.count { |called, _| called == expected }, "started once"
      output.close
    end
  end

  # Through Open3, what Open3 started, alone.
  def test_piped_through_open3_alone
    opened = []
    popen2 = Open3.method(:popen2)
    spawned = []
    spawn = Process.method(:spawn)
    pid, input, output, waiter = stub(Open3, :popen2, ->(*args, **options) { popen2.call(*args, **options).tap { |ends| opened.concat(ends) } }) do
      stub(Process, :spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |id| spawned << id } }) do
        Duel::Spawn.piped(env, ruby("1"), redirects: false)
      end
    end
    input.close

    assert_equal opened, [input, output, waiter]
    assert_equal opened.last.pid, pid
    assert_predicate waiter.value, :success?
    output.close
    spawned.each { |id| Process.wait(id) }
  end

  # Spawned unless Process.spawn redirects nothing, by default.
  def test_piped_by_default
    calls = []
    _, input, output, waiter = noting(calls) { Duel::Spawn.piped(env, ruby("1")) }
    input.close
    waiter.join
    output.close

    assert_equal (Duel::Spawn::REDIRECTS ? :spawn : :popen2), calls.first.first
  end

  # Started, its output this process's, and a thread whose value is how
  # it ended: spawned (and detached), or through Open3, its output copied
  # here (as where Process.spawn can't wait: JRuby on Windows).
  def test_started
    {true => :spawn, false => :popen3}.slice(*ways).each do |redirects, expected|
      calls = []
      out, err = capture_subprocess_io do
        pid, waiter = noting(calls) do
          Duel::Spawn.started(env, ruby("$stdout.sync = true; puts ENV['X'], $stdin.read.inspect; warn :err; exit 5"), redirects: redirects,
            close_others: true)
        end

        assert_equal [pid, 5], [waiter.value.pid, waiter.value.exitstatus]
        # (Through Open3, all of it copied once its thread has ended.)
        $stdout.flush
      end

      # (On Windows, this process's output in CRuby's text mode: CRCRLF.)
      assert_equal ["x\n\"\"\n", "err\n"], [out, err].map { |said| said.gsub(/\r+\n/, "\n") }, "redirects: #{redirects}"
      assert_equal [expected, true], [calls.first.first, calls.first.last[:close_others]]
      assert_equal File::NULL, calls.first.last[:in] if redirects
    end
  end

  # Spawned unless Process.spawn can't wait, by default. Through Open3,
  # it's returned at once, its output copied meanwhile.
  def test_started_by_default_and_at_once
    calls = []
    pid, waiter = noting(calls) { Duel::Spawn.started(env, ruby("1")) }
    waiter.join

    assert_equal [(Duel::Spawn::REDIRECTS ? :spawn : :popen3), pid], [calls.first.first, waiter.value.pid]
    started = Thread.new { Duel::Spawn.started(env, ruby("sleep"), redirects: false) }

    assert started.join(10), "not once it's ended"
    pid, waiter = started.value
    Process.kill("KILL", pid)
    waiter.join
  end

  # Through Open3, one whose output something it started holds open: its
  # thread ends COPY_WAIT seconds after it, and the copy stops, quietly,
  # its pipe closed, and this process's output left open.
  def test_started_output_held_open
    skip_a_jruby_childs_children
    pids = File.join(tmpdir, "pids")
    code = "$stdout.sync = true; puts :started; pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 30'); File.write(ARGV[0], pid.to_s)"
    pipes = []
    popen3 = Open3.method(:popen3)
    out, err = capture_subprocess_io do
      _, waiter = with_constants(Duel::Spawn, COPY_WAIT: 0.2) do
        stub(Open3, :popen3, ->(*args, **options) { popen3.call(*args, **options).tap { |opened| pipes.concat(opened[1, 2]) } }) do
          Duel::Spawn.started(env, ruby(code, pids), redirects: false).tap { |_, thread| thread.join }
        end
      end

      assert_predicate waiter.value, :success?
      sleep 0.01 until pipes.all?(&:closed?)
      $stdout.flush
    end

    # (On Windows, this process's output in CRuby's text mode: CRCRLF.)
    assert_equal ["started\n", ""], [out.gsub(/\r+\n/, "\n"), err], "the copy stopped quietly"
    refute_predicate $stdout, :closed?
  ensure
    held = Integer(File.read(pids)) if pids && File.exist?(pids)
    begin
      Process.kill("KILL", held) if held
    rescue Errno::ESRCH # (ended with its parent's console, on Windows)
      nil
    end
  end

  # Open3's methods, as they are, but on JRuby on Windows: ENV under the
  # environment given (its Open3 gives the JVM's own), and the program
  # found (it runs only an .exe, by name).
  def test_open3
    called = []
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      assert_equal ["out", :status], Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", "x", java: false, chdir: "/d")
      stub(Duel::Spawn, :program, ->(command) { ["/bin/#{command.first}.cmd", *command.drop(1)] }) do
        stub(ENV, :to_h, -> { {"A" => "0", "B" => "2"} }) do
          Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", "x", java: true, chdir: "/d")
          Duel::Spawn.open3(:capture2, "prog", java: true)
        end
      end
      Duel::Spawn.open3(:capture2, "prog") unless Duel::Spawn::JAVA
    end

    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"B" => "2"} }) do
          with_constants(Duel::Spawn, JAVA: true) { Duel::Spawn.open3(:capture2, Class.new(Hash)["A", "1"], "prog") }
        end
      end
    end

    assert_equal [[{"B" => "2", "A" => "1"}, "prog"], {}], called.pop, "by default, on JRuby on Windows: an environment of a Hash's kind"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"A" => "0", "B" => "2"} }) { Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", java: true, unsetenv_others: true) }
      end
    end

    assert_equal [[{"A" => "1", "B" => nil}, "prog"], {unsetenv_others: true}], called.pop, "the rest of ENV unset, which JRuby's doesn't"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"B" => "2"} }) { Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", java: true, unsetenv_others: false) }
      end
    end

    assert_equal [[{"B" => "2", "A" => "1"}, "prog"], {unsetenv_others: false}], called.pop, "not unless it's asked"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"Path" => "C:/x", "B" => "2"} }) { Duel::Spawn.open3(:capture2, {"PATH" => "C:/mine"}, "prog", java: true) }
      end
    end

    assert_equal [[{"Path" => "C:/mine", "B" => "2"}, "prog"], {}], called.pop, "a PATH given, by ENV's name for it, Path: Windows's are one"
    assert_equal [[[{"A" => "1"}, "prog", "x"], {chdir: "/d"}], [[{"A" => "1", "B" => "2"}, "/bin/prog.cmd", "x"], {chdir: "/d"}],
      [[{"A" => "0", "B" => "2"}, "/bin/prog.cmd"], {}], *([[["prog"], {}]] unless Duel::Spawn::JAVA)], called, "by default, as it is (here)"
    yielded = Duel::Spawn.open3(:popen2e, *ruby("print :hi"), java: false) { |input, output, _| input.close || output.read }

    assert_equal "hi", yielded, "with a block"
    yielded = stub(Duel::Spawn, :program, ->(command) { command }) do
      Duel::Spawn.open3(:popen2e, *ruby("print :hi"), java: true) { |input, output, _| input.close || output.read }
    end

    assert_equal "hi", yielded, "with a block, on JRuby on Windows"
  end

  # A program as Windows finds it: by name, in the PATH's directories,
  # with an extension of PATHEXT's where it has none, or by its path;
  # a lone String a shell runs, by cmd.exe; or Errno::ENOENT.
  def test_program
    dirs = %w[a b].map { |dir| FileUtils.mkdir_p(File.join(tmpdir, dir)).fetch(0) }
    path = dirs.join(File::PATH_SEPARATOR)
    FileUtils.touch([File.join(dirs[0], "tool"), File.join(dirs[1], "tool.cmd"), File.join(dirs[1], "gh.exe"), File.join(dirs[0], "x.rb")])
    exts = %w[.exe .cmd]
    found = ->(*command) { Duel::Spawn.program(command, path: path, exts: exts) }

    assert_equal [File.join(dirs[1], "tool.cmd"), %("a b"), "c"], found.call("tool", "a b", "c"), "not one without an extension; its arguments quoted"
    assert_equal [File.join(dirs[1], "gh.exe")], found.call("gh")
    assert_equal [File.join(dirs[0], "x.rb")], found.call("x.rb"), "one with an extension, as it is"
    assert_equal [File.join(dirs[1], "tool.cmd")], found.call(File.join(dirs[1], "tool")), "a path"
    if windows?
      assert_equal [File.join(dirs[1], "tool.cmd")], found.call(File.join(dirs[1], "tool").tr("/", "\\")).map { |file| file.tr("\\", "/") }
    end

    assert_equal ["cmd.exe", "/c", "tool a"], found.call("tool a"), "a shell's"
    assert_equal ["cmd.exe", "/c", "a|b"], found.call("a|b")
    spaced = FileUtils.mkdir_p(File.join(tmpdir, "with space")).fetch(0)
    FileUtils.touch(File.join(spaced, "tool.cmd"))

    assert_equal [File.join(spaced, "tool.cmd"), "x"], found.call(File.join(spaced, "tool"), "x"), "a program, given arguments"
    error = assert_raises(Errno::ENOENT) { found.call("missing", "x") }

    assert_equal "No such file or directory - missing", error.message
    assert_raises(Errno::ENOENT) { found.call(File.join(dirs[0], "missing")) }
    assert_equal [File.join(dirs[1], "tool.cmd")], stub(ENV, :fetch, ->(name, default) { {"PATH" => path, "PATHEXT" => ".exe;.cmd"}.fetch(name, default) }) { Duel::Spawn.program(["tool"]) }, "by default, ENV's"
    assert_raises(Errno::ENOENT) { stub(ENV, :fetch, ->(name, default) { (name == "PATH") ? path : default }) { Duel::Spawn.program(["tool"]) } }
    FileUtils.touch(File.join(dirs[0], "big.EXE"))

    assert_equal [File.join(dirs[0], "big.EXE")], stub(ENV, :fetch, ->(name, default) { (name == "PATH") ? path : default }) { Duel::Spawn.program(["big"]) },
      "by default, .EXE"
    assert_raises(Errno::ENOENT, "no PATH") { stub(ENV, :fetch, ->(_, default) { default }) { Duel::Spawn.program(["big"]) } }
  end

  # An argument as a Windows program's command line has it: as it is, but
  # where it's empty or has a space or a quote in it, quoted, a quote in
  # it after a backslash, and the backslashes before a quote, or before
  # its end, doubled (so a program takes it out as it was).
  def test_quote
    assert_equal "x", Duel::Spawn.quote("x")
    assert_equal 'a\b', Duel::Spawn.quote('a\b')
    assert_equal %(""), Duel::Spawn.quote("")
    assert_equal %("a b"), Duel::Spawn.quote("a b")
    assert_equal %("tab\tin"), Duel::Spawn.quote("tab\tin")
    assert_equal %("require \\"x\\""), Duel::Spawn.quote(%(require "x"))
    assert_equal %("a\\\\\\"b"), Duel::Spawn.quote(%(a\\"b))
    assert_equal %("a b\\\\"), Duel::Spawn.quote(%(a b\\))
    assert_equal %("a b\\\\\\\\"), Duel::Spawn.quote(%(a b\\\\))
    assert_equal %("\\"q\\""), Duel::Spawn.quote(%("q"))
  end

  # Spawned, the child's ends of its pipes are closed here, however the
  # spawn ends.
  def test_piped_that_cant_start
    skip_unless_spawn_redirects
    pipes = []
    pipe = IO.method(:pipe)

    stub(IO, :pipe, -> { pipe.call.tap { |ends| pipes << ends } }) do
      assert_raises(Errno::ENOENT) { Duel::Spawn.piped(env, ["duel-no-such-program"], redirects: true) }
    end
    (input, requests), (replies, output) = pipes

    assert_equal [true, false, false, true], [input, requests, replies, output].map(&:closed?)
  end
end
