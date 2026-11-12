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
    pid = Process.spawn(RbConfig.ruby, "-e", code, File.join(@dir, "lock"), ready, **own_group)
    @holders << pid
    sleep 0.01 until File.exist?(ready)
    FileUtils.rm_f(ready)
    pid
  end

  def end_holder(pid) = end_group(pid)

  def test_holds_it_and_says_whose_it_is
    skip "Windows keeps a locked file from being read" if windows?

    held = Duel::Lock.hold(@dir) { [File.read(File.join(@dir, "lock")), :done] }

    assert_equal [Process.pid.to_s, :done], held
    # (Left by a run of an earlier Duel, which didn't remove it.)
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "lock"), "a much longer pid")
    written = Duel::Lock.hold(@dir) { File.read(File.join(@dir, "lock")) }

    assert_equal Process.pid.to_s, written, "only its own"
  end

  def test_another_run_holds_it
    pid = holder
    ran = false
    error = assert_raises(Duel::Error) { Duel::Lock.hold(@dir) { ran = true } }

    assert_equal "another duel run#{" (pid #{pid})" unless windows?} is using #{@dir}: wait for it to end, or stop it", error.message
    refute ran
    assert_equal pid.to_s, File.read(File.join(@dir, "lock")), "its, as it was" unless windows?
  end

  # On Windows, which keeps a locked file from being read, another run's
  # isn't named.
  def test_another_run_on_windows
    file = Struct.new(:read).new(nil)
    def file.read = raise(Errno::EACCES, "lock")

    assert_equal "", Duel::Lock.whose(file)
    assert_equal "123", Duel::Lock.whose(StringIO.new("123"))
  end

  # And a run removes its lock once it has closed it, Windows removing
  # none that's open.
  def test_removed_once_closed_on_windows
    path = File.join(@dir, "lock")
    removed = []
    rm_f = FileUtils.method(:rm_f)
    [false, true].each do |windows|
      stub(FileUtils, :rm_f, ->(target) { (removed << [windows, target, File.exist?(target)]) && rm_f.call(target) }) do
        Duel::Lock.hold(@dir, windows: windows) { nil }
      end
    end

    assert_equal [[false, path, true], [true, path, true], [true, path, false]], removed.select { |_, target| target == path }
    removed.clear
    stub(FileUtils, :rm_f, ->(target) { (removed << target) && rm_f.call(target) }) do
      with_constants(Duel::Native, WINDOWS: true) { Duel::Lock.hold(@dir) { nil } }
    end

    assert_equal [path, path], removed.select { |target| target == path }, "on Windows, by default"
  end

  # One that's still writing its pid isn't named.
  def test_another_run_that_hasnt_said_whose_it_is
    holder("''")
    error = assert_raises(Duel::Error) { Duel::Lock.hold(@dir) { flunk } }

    assert_equal "another duel run is using #{@dir}: wait for it to end, or stop it", error.message
  end

  # A run that ends removes its lock, and the directories that leaves
  # empty: tmp/duel, and tmp, where Duel made it.
  def test_removes_it_and_what_it_leaves_empty
    project = FileUtils.mkdir_p(File.join(tmpdir, "project")).first
    dir = File.join(project, "tmp", "duel")
    Duel::Lock.hold(dir) { FileUtils.mkdir_p(File.join(dir, "cache")) }

    assert_empty Dir.children(project), "nothing left"
    FileUtils.mkdir_p(File.join(project, "tmp"))
    Duel::Lock.hold(dir) { nil }

    assert_equal ["tmp"], Dir.children(project), "a tmp it didn't make stays, empty or not"
    FileUtils.mkdir_p(File.join(dir, "cache"))
    Duel::Lock.hold(dir) { nil }

    assert_empty Dir.children(File.join(project, "tmp")), "a tmp/duel that was there, emptied, is removed too"
  end

  # What it keeps stays: a cache's builds, and a baseline's checkout,
  # empty directories and all.
  def test_keeps_what_isnt_empty
    FileUtils.mkdir_p(File.join(@dir, "base", "log"))
    Duel::Lock.hold(@dir) { FileUtils.mkdir_p(File.join(@dir, "cache", "mysql-0.1.2-0123456789abcdef")) }

    assert_equal %w[base cache], Dir.children(@dir).sort, "no lock"
    assert_path_exists File.join(@dir, "base", "log"), "not in a checkout"
    assert_path_exists File.join(@dir, "cache", "mysql-0.1.2-0123456789abcdef")
  end

  # `duel --clean` removes tmp/duel, lock and all, while it's held.
  def test_removed_while_held
    project = FileUtils.mkdir_p(File.join(tmpdir, "project")).first
    dir = File.join(project, "tmp", "duel")

    assert_equal :cleaned, Duel::Lock.hold(dir) { FileUtils.rm_rf(dir) && :cleaned }
    assert_empty Dir.children(project), "tmp/duel gone, and the tmp it made"
  end

  # A lock its run removed after this opened it isn't the lock: this
  # opens the one there now.
  def test_a_lock_removed_after_it_was_opened
    FileUtils.mkdir_p(@dir)
    path = File.join(@dir, "lock")
    real = File.method(:identical?)
    looks = 0

    stub(File, :identical?, ->(*args) { ((looks += 1) == 1) ? false : real.call(*args) }) do
      assert_equal :ran, Duel::Lock.hold(@dir) { :ran }
    end

    assert_equal 2, looks
    refute_path_exists path
    looks = 0
    stub(File, :identical?, ->(*args) { (looks += 1) && real.call(*args) }) do
      Duel::Lock.hold(@dir) do
        FileUtils.rm_f(path)
        :ran
      end
    end

    assert_equal 1, looks
    exists = File.method(:exist?)
    gone = 0

    stub(File, :exist?, ->(file) { (file == path && (gone += 1) == 1) ? false : exists.call(file) }) do
      assert_equal :ran, Duel::Lock.hold(@dir) { :ran }
    end

    assert_equal 2, gone, "not there: opened again"
  end

  # Every lock file it opens, it closes: its own when it's done, another
  # run's, and one that run removed.
  def test_closes_what_it_opens
    opened = []
    real = File.method(:new)
    open = ->(*args, **options) { real.call(*args, **options).tap { |file| opened << file if args.first.to_s.end_with?("lock") } }
    stub(File, :new, open) { Duel::Lock.hold(@dir) { :ran } }
    identical = File.method(:identical?)
    looks = 0
    stub(File, :new, open) do
      stub(File, :identical?, ->(*args) { ((looks += 1) == 1) ? false : identical.call(*args) }) { Duel::Lock.hold(@dir) { :ran } }
    end
    holder

    stub(File, :new, open) { assert_raises(Duel::Error) { Duel::Lock.hold(@dir) { flunk } } }

    assert_equal 4, opened.size
    assert opened.all?(&:closed?), "every one closed"
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
    assert_equal "duel: another duel run#{" (pid #{pid})" unless windows?} is using #{File.realpath(@dir)}: wait for it to end, or stop it\n",
      err.string
  end
end
