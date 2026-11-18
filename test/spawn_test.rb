# frozen_string_literal: true

require_relative "test_helper"

# Starting a process with its output in a log, or with a pipe each way:
# spawned with redirects (Directly), or through Open3 (ThroughOpen3, as
# on JRuby on Windows), and waiting for it and stopping it (Child).
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

  # Whether +pid+ is gone, and waited for (not a zombie), within ten
  # seconds.
  def reaped?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.01 while Process.kill(0, pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    false
  rescue Errno::ESRCH
    true
  end

  # The ways a process can start here: not Directly on JRuby on Windows,
  # whose spawn redirects nothing (and whose wait doesn't wait).
  def starters = (Duel::Spawn::STARTER == Duel::Spawn::Directly) ? [Duel::Spawn::Directly, Duel::Spawn::ThroughOpen3] : [Duel::Spawn::ThroughOpen3]

  def skip_unless_directly
    skip "JRuby's spawn on Windows redirects nothing" unless Duel::Spawn::STARTER == Duel::Spawn::Directly
  end

  # (A JRuby child on Windows copies a process it spawned's output itself,
  # which stops as it ends.)
  def skip_a_jruby_childs_children
    skip "a JRuby child's own children's output, on Windows, is the child's to copy" if Duel::Platform::JRUBY_ON_WINDOWS
  end

  # Process.spawn redirects and waits, and a process starts Directly,
  # but on JRuby on Windows.
  def test_redirects
    assert_equal [!Duel::Platform::JRUBY_ON_WINDOWS] * 2, [Duel::Spawn::REDIRECTS, Duel::Spawn::WAITS]
    assert_equal (Duel::Platform::JRUBY_ON_WINDOWS ? Duel::Spawn::ThroughOpen3 : Duel::Spawn::Directly), Duel::Spawn::STARTER
    assert_equal [5, 65_536], [Duel::Spawn::COPY_WAIT, Duel::Spawn::CHUNK]
  end

  # Spawned: its output and errors in the log (added to it, or in its
  # place), its input nothing, with the options given, and waited for as
  # any child.
  def test_logged_spawned
    skip_unless_directly
    File.write(@log, "before\n")
    size = File.size(@log) # (8 bytes on Windows, its line ending CRLF)
    calls = []
    code = "$stdout.sync = true; puts ENV['X'], File.basename(Dir.pwd), $stdin.read.inspect; warn :err; exit 3"
    child = noting(calls) { Duel::Spawn::Directly.logged(env, ruby(code), log: @log, mode: "a", chdir: tmpdir) }

    assert_equal 3, child.wait.first, "waited for as any child (with wait4, where it's there)"
    assert_equal "before\nx\n#{File.basename(tmpdir)}\n\"\"\nerr\n", File.read(@log)
    (called, options), = calls

    assert_equal [:spawn, File::NULL, tmpdir], [called, options[:in], options[:chdir]]
    assert_same options[:out], options[:err]
    assert_equal size, options[:at], "given at its end (where Windows's child writes)"
    assert_empty open_logs, "closed here"
    Duel::Spawn::Directly.logged(env, ruby("puts :again"), log: @log, mode: "w").wait

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
    child = stub(Open3, :popen2e, ->(*args, **options) { popen2e.call(*args, **options).tap { |opened| pipes.concat(opened.first(2)) } }) do
      stub(Duel::Spawn, :copy, ->(output, out, **options) { (copied << out.binmode?) && copy.call(output, out, **options) }) do
        noting(calls) { Duel::Spawn::ThroughOpen3.logged(env, ruby(code), log: @log, mode: "a", chdir: tmpdir) }
      end
    end

    assert_equal child.waiter.value.pid, child.pid
    assert_equal [3, nil, nil], child.wait, "as its thread says"
    assert_equal "before\nx\n#{File.basename(tmpdir)}\n\"\"\nerr\n", File.read(@log)
    assert_equal [[:popen2e, {chdir: tmpdir}]], calls.reject { |call| call.first == :spawn }
    assert_equal [true], copied, "copied to as it's written (not CRCRLF, on Windows)"
    assert_empty open_logs, "closed, once it's done"
    assert_equal [true, true], pipes.map(&:closed?), "its input at once, its output once it's done"
    child = Duel::Spawn::ThroughOpen3.logged(env, ruby("puts :again"), log: @log, mode: "w")

    assert_predicate child.waiter.value, :success?
    assert_equal "again\n", File.read(@log), "in its place"
    # (JRuby's Process.wait on Windows waits for nothing.)
    assert_raises(Errno::ECHILD, "waited for") { Process.wait(child.pid) } unless Duel::Platform::JRUBY_ON_WINDOWS
  end

  # What it says is in the log as it runs, for what waits on it to see.
  # (Within a minute: a JVM on a busy runner, JRuby's on macOS say, can
  # take more than ten seconds to start.)
  def test_logged_through_open3_as_it_runs
    child = Duel::Spawn::ThroughOpen3.logged(env, ruby("$stdout.sync = true; puts :ready; sleep"), log: @log, mode: "w")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    sleep 0.01 until File.read(@log).include?("ready") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert_includes File.read(@log), "ready", "while it runs"
  ensure
    Process.kill("KILL", child.pid) if child
    child&.waiter&.join
  end

  # All of what it says is in the log once it's ended, however much.
  def test_logged_through_open3_says_a_lot
    child = Duel::Spawn::ThroughOpen3.logged(env, ruby("$stdout.write('x' * 8_000_000)"), log: @log, mode: "w")

    assert_predicate child.waiter.value, :success?
    assert_equal 8_000_000, File.size(@log)
  end

  # What a process it started says after it ended is in the log too, if
  # it's said within COPY_WAIT seconds.
  def test_logged_through_open3_after_it_ends
    skip_a_jruby_childs_children
    code = "$stdout.sync = true; puts :first; Process.spawn(RbConfig.ruby, '-e', '$stdout.sync = true; sleep 0.5; puts :later')"
    # (Seconds enough for a JVM, JRuby's, to start on a busy machine.)
    child = with_constants(Duel::Spawn, COPY_WAIT: 60) do
      Duel::Spawn::ThroughOpen3.logged(env, ruby(code), log: @log, mode: "w").tap { |started| started.waiter.join }
    end

    assert_predicate child.waiter.value, :success?
    assert_equal "first\nlater\n", File.read(@log)
  end

  # The log is there as soon as it starts, for a failure to show.
  def test_the_log_is_there_at_once
    starters.each do |starter|
      FileUtils.rm_f(@log)
      child = starter.logged(env, ruby("sleep 0.2"), log: @log, mode: "a")

      assert_path_exists @log
      child.wait
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
      child = with_constants(Duel::Spawn, COPY_WAIT: 0.2) do
        Duel::Spawn::ThroughOpen3.logged(env, ruby(code, pids), log: @log, mode: "w").tap { |started| started.waiter.join }
      end

      assert_predicate child.waiter.value, :success?
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
    log = Duel::Spawn.method(:log)
    starters.each do |starter|
      opened = []
      error = stub(Duel::Spawn, :log, ->(*args) { log.call(*args).tap { |file| opened << file } }) do
        assert_raises(Errno::ENOENT) { starter.logged(env, ["duel-no-such-program"], log: @log, mode: "w") }
      end

      assert_kind_of Errno::ENOENT, error
      assert_equal [true], opened.map(&:closed?), starter.name
    end
  end

  # A pipe each way, spawned (its ends, not this process's, closed here)
  # or through Open3, with the options given, and a thread whose value is
  # how it ended.
  def test_piped
    {Duel::Spawn::Directly => :spawn, Duel::Spawn::ThroughOpen3 => :popen2}.slice(*starters).each do |starter, expected|
      calls = []
      child, input, output = noting(calls) do
        starter.piped(env, ruby("$stdout.sync = true; puts $stdin.gets.upcase, ENV['X'], File.basename(Dir.pwd); exit 4"), chdir: tmpdir)
      end
      input.puts "hi"
      input.close

      assert_equal ["HI", "x", File.basename(tmpdir)], output.read.split("\n")
      assert_equal [child.pid, 4], [child.waiter.value.pid, child.waiter.value.exitstatus], starter.name
      assert_equal [expected, tmpdir], [calls.first.first, calls.first.last[:chdir]]
      assert_equal 1, calls.count { |called, _| called == expected }, "started once"
      refute calls.first.last.key?(:pgroup) || calls.first.last.key?(:new_pgroup), "in no group of its own"
      output.close
    end
  end

  # In a group of its own, if it's asked, which killing it kills (or on
  # Windows, its tree, as for any). Elsewhere, it alone.
  def test_piped_in_a_group
    starters.product([true, false]).each do |starter, group|
      calls = []
      child, input, output = noting(calls) { starter.piped(env, ruby("$stdin.read"), group: group, chdir: tmpdir) }

      assert_equal (group ? Duel::Spawn.group : {}), calls.first.last.slice(:pgroup, :new_pgroup), "#{starter.name}, group: #{group}"
      assert_equal tmpdir, calls.first.last[:chdir], "and the options given"
      killed = []
      kill_tree = Duel::Spawn.method(:kill_tree)
      kill = Process.method(:kill)
      stub(Duel::Spawn, :kill_tree, ->(pid, **options) { (killed << :tree) && kill_tree.call(pid, **options) }) do
        stub(Process, :kill, ->(signal, pid) { (killed << :alone) && kill.call(signal, pid) }) { child.kill }
      end

      assert_equal (group || windows?) ? :tree : :alone, killed.first, "#{starter.name}, group: #{group}"
      input.close
      output.close
    end
  end

  # Spawned with a pipe each way, or its output this process's, it's
  # waited for on a thread from the start (Process.detach's), so it's
  # reaped as it ends, though nothing asks.
  def test_piped_and_started_reaped_as_they_end
    skip_unless_directly
    child, input, output = Duel::Spawn::Directly.piped(env, ruby("1"))
    started = Duel::Spawn::Directly.started(env, ruby("1"))

    assert reaped?(child.pid), "piped"
    assert reaped?(started.pid), "started"
    input.close
    output.close
  end

  # Through Open3, what Open3 started, alone.
  def test_piped_through_open3_alone
    opened = []
    popen2 = Open3.method(:popen2)
    spawned = []
    spawn = Process.method(:spawn)
    child, input, output = stub(Open3, :popen2, ->(*args, **options) { popen2.call(*args, **options).tap { |ends| opened.concat(ends) } }) do
      stub(Process, :spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |id| spawned << id } }) do
        Duel::Spawn::ThroughOpen3.piped(env, ruby("1"))
      end
    end
    input.close

    assert_equal opened, [input, output, child.waiter]
    assert_equal opened.last.pid, child.pid
    assert_predicate child.waiter.value, :success?
    output.close
    spawned.each { |id| Process.wait(id) }
  end

  # Started, its output this process's, and a thread whose value is how
  # it ended: spawned (and detached), or through Open3, its output copied
  # here (as where Process.spawn can't wait: JRuby on Windows).
  def test_started
    {Duel::Spawn::Directly => :spawn, Duel::Spawn::ThroughOpen3 => :popen3}.slice(*starters).each do |starter, expected|
      calls = []
      out, err = capture_subprocess_io do
        child = noting(calls) do
          starter.started(env, ruby("$stdout.sync = true; puts ENV['X'], $stdin.read.inspect; warn :err; exit 5"), close_others: true)
        end

        assert_equal [child.pid, 5], [child.waiter.value.pid, child.waiter.value.exitstatus]
        # (Through Open3, all of it copied once its thread has ended.)
        $stdout.flush
      end

      # (On Windows, this process's output in CRuby's text mode: CRCRLF.)
      assert_equal ["x\n\"\"\n", "err\n"], [out, err].map { |said| said.gsub(/\r+\n/, "\n") }, starter.name
      assert_equal [expected, true], [calls.first.first, calls.first.last[:close_others]]
      assert_equal File::NULL, calls.first.last[:in] if starter == Duel::Spawn::Directly
    end
  end

  # Through Open3, it's returned at once, its output copied meanwhile.
  def test_started_through_open3_at_once
    started = Thread.new { Duel::Spawn::ThroughOpen3.started(env, ruby("sleep")) }

    assert started.join(10), "not once it's ended"
    child = started.value
    Process.kill("KILL", child.pid)
    child.waiter.join
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
      child = with_constants(Duel::Spawn, COPY_WAIT: 0.2) do
        stub(Open3, :popen3, ->(*args, **options) { popen3.call(*args, **options).tap { |opened| pipes.concat(opened[1, 2]) } }) do
          Duel::Spawn::ThroughOpen3.started(env, ruby(code, pids)).tap { |started| started.waiter.join }
        end
      end

      assert_predicate child.waiter.value, :success?
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
      assert_equal ["out", :status], Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", "x", jruby_on_windows: false, chdir: "/d")
      stub(Duel::Spawn, :program, ->(command) { ["/bin/#{command.first}.cmd", *command.drop(1)] }) do
        stub(ENV, :to_h, -> { {"A" => "0", "B" => "2"} }) do
          Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", "x", jruby_on_windows: true, chdir: "/d")
          Duel::Spawn.open3(:capture2, "prog", jruby_on_windows: true)
        end
      end
      Duel::Spawn.open3(:capture2, "prog") unless Duel::Platform::JRUBY_ON_WINDOWS
    end

    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"B" => "2"} }) do
          with_constants(Duel::Platform, JRUBY_ON_WINDOWS: true) { Duel::Spawn.open3(:capture2, Class.new(Hash)["A", "1"], "prog") }
        end
      end
    end

    assert_equal [[{"B" => "2", "A" => "1"}, "prog"], {}], called.pop, "by default, on JRuby on Windows: an environment of a Hash's kind"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"A" => "0", "B" => "2"} }) { Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", jruby_on_windows: true, unsetenv_others: true) }
      end
    end

    assert_equal [[{"A" => "1", "B" => nil}, "prog"], {unsetenv_others: true}], called.pop, "the rest of ENV unset, which JRuby's doesn't"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"B" => "2"} }) { Duel::Spawn.open3(:capture2, {"A" => "1"}, "prog", jruby_on_windows: true, unsetenv_others: false) }
      end
    end

    assert_equal [[{"B" => "2", "A" => "1"}, "prog"], {unsetenv_others: false}], called.pop, "not unless it's asked"
    stub(Open3, :capture2, ->(*args, **options) { (called << [args, options]) && ["out", :status] }) do
      stub(Duel::Spawn, :program, ->(command) { command }) do
        stub(ENV, :to_h, -> { {"Path" => "C:/x", "B" => "2"} }) { Duel::Spawn.open3(:capture2, {"PATH" => "C:/mine"}, "prog", jruby_on_windows: true) }
      end
    end

    assert_equal [[{"Path" => "C:/mine", "B" => "2"}, "prog"], {}], called.pop, "a PATH given, by ENV's name for it, Path: Windows's are one"
    assert_equal [[[{"A" => "1"}, "prog", "x"], {chdir: "/d"}], [[{"A" => "1", "B" => "2"}, "/bin/prog.cmd", "x"], {chdir: "/d"}],
      [[{"A" => "0", "B" => "2"}, "/bin/prog.cmd"], {}], *([[["prog"], {}]] unless Duel::Platform::JRUBY_ON_WINDOWS)], called, "by default, as it is (here)"
    yielded = Duel::Spawn.open3(:popen2e, *ruby("print :hi"), jruby_on_windows: false) { |input, output, _| input.close || output.read }

    assert_equal "hi", yielded, "with a block"
    yielded = stub(Duel::Spawn, :program, ->(command) { command }) do
      Duel::Spawn.open3(:popen2e, *ruby("print :hi"), jruby_on_windows: true) { |input, output, _| input.close || output.read }
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
    skip_unless_directly
    pipes = []
    pipe = IO.method(:pipe)

    stub(IO, :pipe, -> { pipe.call.tap { |ends| pipes << ends } }) do
      assert_raises(Errno::ENOENT) { Duel::Spawn::Directly.piped(env, ["duel-no-such-program"]) }
    end
    (input, requests), (replies, output) = pipes

    assert_equal [true, false, false, true], [input, requests, replies, output].map(&:closed?)
  end

  # A process group of its own, or on Windows, a console's.
  def test_its_group
    assert_equal [{pgroup: true}, {new_pgroup: true}], [false, true].map { |windows| Duel::Spawn.group(windows: windows) }
    assert_equal({new_pgroup: true}, with_constants(Duel::Platform, WINDOWS: true) { Duel::Spawn.group }, "by default, on Windows")
  end

  # Its group killed, or on Windows, its tree, with taskkill (through
  # Spawn.open3, its output read, not shown).
  def test_killing_its_tree
    killed = []
    ran = []
    status = Struct.new(:success?).new(:tree)
    trees = stub(Process, :kill, ->(*args) { (killed << args) && :group }) do
      stub(Duel::Spawn, :open3, ->(*args, **options) { (ran << [args, options]) && ["SUCCESS", status] }) do
        [false, true].map { |windows| Duel::Spawn.kill_tree(42, windows: windows) } +
          [with_constants(Duel::Platform, WINDOWS: true) { Duel::Spawn.kill_tree(42) }]
      end
    end

    assert_equal %i[group tree tree], trees
    assert_equal [["KILL", -42]], killed
    assert_equal [[[:capture2e, "taskkill", "/T", "/F", "/PID", "42"], {}]] * 2, ran
    killed.clear
    gone = stub(Process, :kill, ->(*args) { (killed << args) && 1 }) do
      stub(Duel::Spawn, :open3, ->(*) { raise Errno::ENOENT, "taskkill" }) { Duel::Spawn.kill_tree(42, windows: true) }
    end

    assert_equal [1, [["KILL", 42]]], [gone, killed], "without taskkill, the process alone"
  end

  # How a process that failed ended: a signal by its name, where Ruby
  # knows one, or else by its number (CRuby's has none for one it doesn't
  # know, and JRuby's raises, as it does on Windows for KILL).
  def test_why
    assert_equal "exited with 4", Duel::Spawn.why(4, nil)
    assert_equal "was killed by SIGKILL", stub(Signal, :signame, ->(signal) { (signal == 9) ? "KILL" : flunk }) { Duel::Spawn.why(nil, 9) }
    assert_equal "was killed by signal 99", stub(Signal, :signame, ->(_) {}) { Duel::Spawn.why(nil, 99) }
    assert_equal "was killed by signal 9", stub(Signal, :signame, ->(_) { raise ArgumentError }) { Duel::Spawn.why(nil, 9) }
  end

  # The end of a log, for a failure to show: its last LOG_LINES lines,
  # each with LF alone (a Windows program's CRLF's CR taken out).
  def test_tail
    File.binwrite(@log, (1..12).map { |i| "line #{i}\r\n" }.join)

    assert_equal 10, Duel::Spawn::LOG_LINES
    assert_equal (3..12).map { |i| "line #{i}\n" }.join, Duel::Spawn.tail(@log)
    File.write(@log, "")

    assert_equal "", Duel::Spawn.tail(@log)
  end

  # A failure's message, with the end of its log where there's a log with
  # anything in it.
  def test_with_tail
    assert_equal "failed", Duel::Spawn.with_tail("failed", nil), "no log"
    File.write(@log, "")

    assert_equal "failed", Duel::Spawn.with_tail("failed", @log), "nothing in it"
    File.write(@log, "it ended\n")

    assert_equal "failed\nit ended\n", Duel::Spawn.with_tail("failed", @log)
  end

  # A Child's thread is the one it was given, or Process.detach's, made
  # once, as it's asked for, or detached (so that until then, it's waited
  # for as any child: see test_a_child_waited_for).
  def test_a_childs_thread
    detached = []
    thread = Thread.new { :status }
    child = Duel::Spawn::Child.new(42)

    stub(Process, :detach, ->(pid) { (detached << pid) && thread }) do
      assert_equal [42, []], [child.pid, detached], "not yet"
      assert_same child, child.detach
      assert_equal [42], detached, "detached, as it's asked"
      assert_same thread, child.waiter
      assert_same thread, child.waiter
    end
    assert_equal [42], detached, "once"
    thread.join

    refute_predicate child, :alive?
    given = Thread.new { sleep }

    assert_same given, Duel::Spawn::Child.new(42, given).waiter
    assert_predicate Duel::Spawn::Child.new(42, given), :alive?
  ensure
    given&.kill
  end

  # How it ended: as its thread says, or where it has none yet, as
  # Native::Child.wait waits for it (with its peak memory).
  def test_a_child_waited_for
    status = Struct.new(:exitstatus, :termsig).new(nil, 9)

    assert_equal [nil, 9, nil], Duel::Spawn::Child.new(42, Thread.new { status }).wait
    assert_equal [:waited, 42], stub(Duel::Native::Child, :wait, ->(pid) { [:waited, pid] }) { Duel::Spawn::Child.new(42).wait }
  end

  # Signalled, but on Windows, killed with its tree (see .kill_tree), by
  # default there. One that's gone (ESRCH, or JRuby on Windows's EPERM)
  # is let be.
  def test_signalling_a_child
    sent = []
    trees = []
    stub(Process, :kill, ->(*args) { sent << args }) do
      stub(Duel::Spawn, :kill_tree, ->(pid, windows:) { trees << [pid, windows] }) do
        Duel::Spawn::Child.new(42, windows: false).signal("TERM")
        Duel::Spawn::Child.new(43, windows: true).signal("TERM")
        with_constants(Duel::Platform, WINDOWS: true) { Duel::Spawn::Child.new(44) }.signal("INT")
      end
    end

    assert_equal [[["TERM", 42]], [[43, true], [44, true]]], [sent, trees]
    [Errno::ESRCH, Errno::EPERM].each do |error|
      assert_nil stub(Process, :kill, ->(*) { raise error }) { Duel::Spawn::Child.new(42, windows: false).signal("TERM") }
      assert_nil stub(Duel::Spawn, :kill_tree, ->(*, **) { raise error }) { Duel::Spawn::Child.new(42, windows: true).signal("TERM") }
    end
  end

  # Killed (with its group, if it has one of its own, or on Windows, its
  # tree), then waited for. One that's gone is let be.
  def test_killing_a_child
    sent = []
    trees = []
    killed = stub(Process, :kill, ->(*args) { sent << args }) do
      stub(Duel::Spawn, :kill_tree, ->(pid, windows:) { trees << [pid, windows] }) do
        [[false, false], [true, false], [false, true], [true, true]].map.with_index do |(group, windows), pid|
          waiter = Thread.new { sleep 0.01 }
          Duel::Spawn::Child.new(pid, waiter, group: group, windows: windows).kill
          waiter.alive?
        end
      end
    end

    assert_equal [[["KILL", 0]], [[1, false], [2, true], [3, true]]], [sent, trees]
    assert_equal [false] * 4, killed, "waited for"
    sent.clear
    stub(Process, :kill, ->(*args) { sent << args }) { Duel::Spawn::Child.new(4, Thread.new {}, windows: false).kill }

    assert_equal [["KILL", 4]], sent, "in no group of its own, by default"
    [Errno::ESRCH, Errno::EPERM].each do |error|
      waiter = Thread.new { sleep }

      assert_nil stub(Process, :kill, ->(*) { raise error }) { Duel::Spawn::Child.new(42, waiter, windows: false).kill }
      assert_predicate waiter, :alive?, "not waited for: gone already"
      waiter.kill
    end
  end

  # Stopping it waits up to the seconds given for it to end, then kills
  # it.
  def test_stopping_a_child
    ended = Duel::Spawn::Child.new(42, Thread.new {})
    running = Duel::Spawn::Child.new(43, Thread.new { sleep })
    killed = []
    stub(ended, :kill, -> { flunk "ended already" }) { ended.stop(10) }
    stub(running, :kill, -> { (killed << 43) && running.waiter.kill }) { running.stop(0.01) }

    assert_equal [43], killed
  end
end
