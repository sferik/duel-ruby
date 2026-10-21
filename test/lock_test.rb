# frozen_string_literal: true

require_relative "test_helper"

# One run at a time in a project: its lock is an flock that ends with
# the run's process, however that ends.
class LockTest < DuelTest
  cover "Duel::Lock*"

  # (In a directory of its own: what a mutation writes where it
  # shouldn't lands there.)
  def setup
    super
    @dir = File.join(tmpdir, "tmp", "duel")
    @holders = []
    @pwd = Dir.pwd
    Dir.chdir(FileUtils.mkdir_p(File.join(tmpdir, "cwd")).fetch(0))
  end

  def teardown
    Dir.chdir(@pwd)
    @holders.each { |pid| end_holder(pid) }
    super
  end

  # Another process holding the lock (another run's), having written
  # +written+ in its file: its pid, by default.
  def holder(written = "$$")
    FileUtils.mkdir_p(@dir)
    ready = File.join(tmpdir, "ready")
    code = "f = File.open(ARGV[0], File::RDWR | File::CREAT); f.flock(File::LOCK_EX); f.write(#{written}.to_s); f.flush; " \
      "File.write(ARGV[1], ''); sleep"
    pid = Process.spawn(RbConfig.ruby, "-e", code, File.join(@dir, "lock"), ready, pgroup: true)
    @holders << pid
    sleep 0.01 until File.exist?(ready)
    FileUtils.rm_f(ready)
    pid
  end

  def end_holder(pid)
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def test_holds_it_and_says_whose_it_is
    held = Duel::Lock.hold(@dir) { [File.read(File.join(@dir, "lock")), :done] }

    assert_equal [Process.pid.to_s, :done], held
    File.write(File.join(@dir, "lock"), "a much longer pid")
    written = Duel::Lock.hold(@dir) { File.read(File.join(@dir, "lock")) }

    assert_equal Process.pid.to_s, written, "only its own"
  end

  def test_another_run_holds_it
    pid = holder
    ran = false
    error = assert_raises(Duel::Error) { Duel::Lock.hold(@dir) { ran = true } }

    assert_equal "another duel run (pid #{pid}) is using #{@dir}: wait for it to end, or stop it", error.message
    refute ran
    assert_equal pid.to_s, File.read(File.join(@dir, "lock")), "its, as it was"
  end

  # One that's still writing its pid isn't named.
  def test_another_run_that_hasnt_said_whose_it_is
    holder("''")
    error = assert_raises(Duel::Error) { Duel::Lock.hold(@dir) { flunk } }

    assert_equal "another duel run is using #{@dir}: wait for it to end, or stop it", error.message
  end

  # A run that crashed holds nothing: its lock ended with it.
  def test_a_run_that_crashed
    end_holder(holder)

    assert_equal :ran, Duel::Lock.hold(@dir) { :ran }
  end

  # A run behind the duel command holds it, so another can't compare.
  def test_the_duel_command_holds_it
    pid = holder
    err = StringIO.new
    status = Dir.chdir(tmpdir) { Duel::CLI.new(["--base", tmpdir], env: {}, out: StringIO.new, err: err).run }

    assert_equal 2, status
    assert_equal "duel: another duel run (pid #{pid}) is using #{File.realpath(@dir)}: wait for it to end, or stop it\n",
      err.string
  end
end
