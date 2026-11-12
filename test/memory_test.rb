# frozen_string_literal: true

require_relative "test_helper"
require "duel/memory"

# The memory available to a run's workers, as Linux and macOS count it.
class MemoryTest < DuelTest
  cover "Duel::Memory*"

  MEMINFO = <<~INFO
    MemTotal:       16367024 kB
    MemFree:          962000 kB
    MemAvailable:    2048000 kB
    Buffers:           43000 kB
  INFO

  VM_STAT = <<~STAT
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                               10.
    Pages active:                           1000.
    Pages inactive:                           20.
    Pages speculative:                         3.
    Pages wired down:                        500.
    Pages purgeable:                          40.
  STAT

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(tmpdir, path)))
    File.write(File.join(tmpdir, path), content)
  end

  def available(vm_stat: nil) = Duel::Memory.available(root: tmpdir, vm_stat: -> { vm_stat }, windows: -> {})

  # Linux's MemAvailable, in bytes.
  def test_linux
    write("proc/meminfo", MEMINFO)

    assert_equal 2_048_000 * 1024, available(vm_stat: VM_STAT), "not macOS's"
  end

  # A cgroup's limit (a container's) leaves less, or doesn't.
  def test_a_cgroup
    write("proc/meminfo", MEMINFO)
    write("sys/fs/cgroup/memory.max", "1000000000\n")
    write("sys/fs/cgroup/memory.current", "400000000\n")

    assert_equal 600_000_000, available
    write("sys/fs/cgroup/memory.max", "9000000000\n")

    assert_equal 2_048_000 * 1024, available, "more than the machine has"
  end

  # A cgroup without a limit, or what it uses, leaves the machine's.
  def test_a_cgroup_without_a_limit
    write("proc/meminfo", MEMINFO)
    write("sys/fs/cgroup/memory.max", "max\n")
    write("sys/fs/cgroup/memory.current", "400000000\n")

    assert_equal 2_048_000 * 1024, available
    write("sys/fs/cgroup/memory.max", "1000000000\n")
    write("sys/fs/cgroup/memory.current", "\n")

    assert_equal 2_048_000 * 1024, available
    FileUtils.rm(File.join(tmpdir, "sys/fs/cgroup/memory.current"))

    assert_equal 2_048_000 * 1024, available
  end

  # macOS's free, inactive and speculative pages, in bytes: not those in
  # use, or purgeable.
  def test_macos
    assert_equal 33 * 16_384, available(vm_stat: VM_STAT)
    write("proc/meminfo", "MemTotal:       16367024 kB\nMemFree:          962000 kB\n")

    assert_equal 33 * 16_384, available(vm_stat: VM_STAT), "where Linux has no MemAvailable"
    assert_equal 10 * 16_384, available(vm_stat: VM_STAT.lines.first(2).join), "a kind it doesn't count as none"
  end

  # By default, what the vm_stat command prints, wherever Linux's
  # MemAvailable isn't there.
  def test_vm_stat_by_default
    command = ->(*args) { (args == ["vm_stat"]) ? VM_STAT : nil }

    assert_equal 33 * 16_384, stub(Duel::Memory, :command, command) { Duel::Memory.available(root: tmpdir) }
  end

  # Windows's, where it's neither Linux nor macOS: GlobalMemoryStatusEx's.
  def test_windows
    assert_equal 4096, Duel::Memory.available(root: tmpdir, vm_stat: -> {}, windows: -> { 4096 })
    write("proc/meminfo", MEMINFO)

    assert_equal 2_048_000 * 1024, Duel::Memory.available(root: tmpdir, vm_stat: -> {}, windows: -> { 4096 }), "Linux's first"
    assert_equal 33 * 16_384, Duel::Memory.available(root: File.join(tmpdir, "none"), vm_stat: -> { VM_STAT }, windows: -> { 4096 }),
      "macOS's first"
    windows = stub(Duel::Native::Windows, :available, -> { 8192 }) { Duel::Memory.available(root: File.join(tmpdir, "none"), vm_stat: -> {}) }

    assert_equal 8192, windows, "Native::Windows.available, by default"
  end

  # Neither, and Duel can't tell.
  def test_neither
    assert_nil available
    assert_nil available(vm_stat: "Pages free: 10.\n"), "no page size"
  end

  # What a command prints, but not its errors, which aren't the run's.
  def test_a_command
    out, err = capture_subprocess_io { assert_equal "hello\n", Duel::Memory.command("sh", "-c", "echo hello; echo oops >&2") }

    assert_equal ["", ""], [out, err]
    assert_nil Duel::Memory.command(File.join(tmpdir, "nothing"))
  end

  def test_reading_a_directory
    assert_nil Duel::Memory.read(tmpdir)
    write("file", "x")

    assert_equal "x", Duel::Memory.read(File.join(tmpdir, "file"))
  end

  # By default, this machine's: Linux's, or else macOS's.
  def test_this_machine
    assert_kind_of Integer, Duel::Memory.available if Duel::Native::OS.match?(/linux|darwin|mingw|mswin/)
  end
end
