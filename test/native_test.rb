# frozen_string_literal: true

require_relative "test_helper"

# The operating system's counters, through Fiddle, with the system calls
# faked: every platform's code runs on any machine.
class NativeTest < DuelTest
  cover "Duel::Native*"

  # A fake perf_event_open(2): a file holding an 8-byte count (and more
  # after it, never read).
  def fake_syscall(count, fd: nil)
    path = File.join(tmpdir, "counter")
    File.binwrite(path, [count, 7].pack("QQ"))
    calls = []
    syscall = ->(*args) { (calls << args) && (fd || IO.sysopen(path)) }
    [syscall, calls]
  end

  def linux(&) = with_constants(Duel::Native, OS: "x86_64-linux-gnu", CPU: "x86_64", &)

  def test_linux_counts_this_threads_user_space_instructions
    syscall, calls = fake_syscall(12_345)
    counter = linux { Duel::Native::Linux.open(syscall: syscall) }

    assert_equal "thread", counter.scope
    assert_equal 12_345, counter.read
    number, attr, pid, cpu, group, flags = calls.first

    assert_equal [298, 0, -1, -1, 8], [number, pid, cpu, group, flags]
    assert_equal [0, 64, 1, 0, 0, 0, (1 << 5) | (1 << 6), 0, 0, 0], attr.unpack("LLQQQQQLLQ"),
      "hardware instructions, user space only"
    assert_equal 241, Duel::Native::Linux::SYSCALL.fetch("aarch64")
  end

  def test_linux_finds_the_syscall_function
    syscall, = fake_syscall(1)
    found = []
    counter = stub(Duel::Native, :function, ->(*args) { (found << args) && syscall }) do
      linux { Duel::Native::Linux.open }
    end

    assert_equal [["syscall", %i[LONG VOIDP INT INT INT LONG], :LONG]], found
    assert_equal 1, counter.read
  end

  def test_linux_closes_its_counter_with_itself
    syscall, = fake_syscall(1)
    io = linux { Duel::Native::Linux.open(syscall: syscall) }.instance_variable_get(:@io)

    assert_predicate io, :autoclose?
  end

  def test_linux_unavailable
    syscall, = fake_syscall(1, fd: -1)

    assert_nil linux { Duel::Native::Linux.open(syscall: syscall) }, "refused"
    working, = fake_syscall(1)

    assert_nil Duel::Native::Linux.open(platform: "darwin", cpu: "x86_64", syscall: working), "not Linux"
    assert_nil Duel::Native::Linux.open(platform: "linux", cpu: "riscv64", syscall: working), "no syscall number known"
    missing = ->(*) { raise Fiddle::DLError, "no such function" }

    assert_nil Duel::Native::Linux.open(platform: "linux", cpu: "x86_64", syscall: missing)
  end

  # A fake proc_pid_rusage: writes +instructions+ and +resident+ into the
  # buffer where struct rusage_info_v4 has them.
  def fake_rusage(instructions, resident = 4096)
    lambda do |pid, flavor, buffer|
      raise "not this process" unless pid == Process.pid && flavor == 4

      buffer[Duel::Native::MacOS::INSTRUCTIONS, 8] = [instructions].pack("Q")
      buffer[Duel::Native::MacOS::INSTRUCTIONS + 8, 8] = [7].pack("Q")
      buffer[Duel::Native::MacOS::RESIDENT, 8] = [resident].pack("Q")
      0
    end
  end

  def macos(&) = with_constants(Duel::Native, OS: "arm64-apple-darwin24", &)

  def test_macos_counts_the_processes_instructions_and_memory
    counter = macos { Duel::Native::MacOS.open(rusage: fake_rusage(99, 8192)) }

    assert_equal "process", counter.scope
    assert_equal 99, counter.read
    assert_equal 8192, counter.resident
    buffer = counter.instance_variable_get(:@buffer)

    assert_equal [296, Fiddle::RUBY_FREE], [buffer.size, buffer.free.to_i], "a struct's worth, freed with the counter"
  end

  def test_macos_finds_proc_pid_rusage
    found = []
    rusage = fake_rusage(5)
    counter = stub(Duel::Native, :function, ->(*args) { (found << args) && rusage }) do
      macos { Duel::Native::MacOS.open }
    end

    assert_equal [["proc_pid_rusage", %i[INT INT VOIDP], :INT]], found
    assert_equal 5, counter.read
  end

  def test_macos_unavailable
    assert_nil Duel::Native::MacOS.open(platform: "darwin", rusage: fake_rusage(0)), "no counters"
    assert_nil Duel::Native::MacOS.open(platform: "linux", rusage: fake_rusage(5))
    missing = ->(*) { raise Fiddle::DLError, "no such function" }

    assert_nil Duel::Native::MacOS.open(platform: "darwin", rusage: missing)
  end

  def test_native_function
    getpid = Duel::Native.function("getpid", [], :INT)

    assert_equal Fiddle.dlopen(nil)["getpid"], getpid.ptr
    assert_equal Process.pid, getpid.call
    assert_equal 5, Duel::Native.function("strlen", [:VOIDP], :LONG).call("hello")
  end

  def counter_with(linux, macos, **options)
    stub(Duel::Native::Linux, :open, -> { linux }) do
      stub(Duel::Native::MacOS, :open, -> { macos }) { Duel::Native::Counter.open(**options) }
    end
  end

  def test_fiddle_where_it_works_by_default
    if Duel::Native::FIDDLE
      assert_equal :linux, counter_with(:linux, :macos)
    else
      assert_nil counter_with(:linux, :macos), "JRuby"
    end
  end

  def test_the_best_counter
    assert_equal :linux, counter_with(:linux, :macos, fiddle: true), "Linux's counts the thread's"
    assert_equal :macos, counter_with(nil, :macos, fiddle: true)
    assert_equal :linux, counter_with(:linux, nil, fiddle: true)
    assert_nil counter_with(nil, nil, fiddle: true)
  end

  def test_no_counters_without_fiddle
    assert_nil counter_with(:linux, :macos, fiddle: false)
  end

  def test_a_counter_must_read
    assert_raises(NotImplementedError) { Duel::Native::Counter.new("thread").read }
  end

  def test_resident_memory_from_proc
    statm = File.join(tmpdir, "statm")
    File.write(statm, "100 25 3 1 0 20 0\n")

    assert_equal 25 * Etc.sysconf(Etc::SC_PAGESIZE), Duel::Native::Memory.resident(statm: statm, macos: nil)
  end

  def test_resident_memory_from_macos
    missing = File.join(tmpdir, "none")

    assert_equal 4096, Duel::Native::Memory.resident(statm: missing, macos: Struct.new(:resident).new(4096))
    assert_nil Duel::Native::Memory.resident(statm: missing, macos: nil)
  end

  def test_resident_memory_here
    statm = File.join(tmpdir, "statm")
    File.write(statm, "100 25 3 1 0 20 0\n")
    from_statm = with_constants(Duel::Native::Memory, STATM: statm) { Duel::Native::Memory.resident(macos: nil) }

    assert_equal 25 * Etc.sysconf(Etc::SC_PAGESIZE), from_statm
    from_macos = with_constants(Duel::Native::Memory, STATM: File.join(tmpdir, "none"), MACOS: Struct.new(:resident).new(1)) do
      Duel::Native::Memory.resident
    end

    assert_equal 1, from_macos
  end
end

# This machine's own counters, for real. (Not for mutant: a mutation of
# how C functions are found can crash the process.)
class NativeHereTest < DuelTest
  def test_the_counter_here
    counter = Duel::Native::Counter.open

    skip "no counters here" unless counter
    first = counter.read
    100_000.times { Math.sqrt(2) }

    assert_operator counter.read, :>, first
  end
end
