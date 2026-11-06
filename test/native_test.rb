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

    assert_equal [296, Encoding::BINARY], [buffer.bytesize, buffer.encoding], "a struct's worth"
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

  # Fiddle is loaded as the first C function is made, not before (as Duel
  # loads, in a worker, before its version).
  def test_a_function_loads_fiddle_first
    unloaded = Class.new(StandardError)

    stub(Duel::Native, :require_fiddle, -> { raise unloaded }) do
      assert_raises(unloaded) { Duel::Native.function("getpid", [], :INT) }
    end
  end

  def test_a_counter_must_read
    assert_raises(NotImplementedError) { Duel::Native::Counter.new("thread").read }
  end

  def test_resident_memory_from_proc
    status = File.join(tmpdir, "status")
    File.write(status, "Name:\truby\nVmHWM:\t   99999 kB\nVmRSS:\t   25600 kB\nRssAnon:\t   12 kB\n")

    assert_equal 25_600 * 1024, Duel::Native::Memory.resident(status: status, macos: nil)
  end

  # Peak memory is measured in resident memory, but on JRuby, in the
  # JVM's heap in use (see the next test).
  def test_the_memory_in_use
    skip "the JVM's heap, on JRuby" if RUBY_ENGINE == "jruby"

    assert_equal 1234, stub(Duel::Native::Memory, :resident, -> { 1234 }) { Duel::Native::Memory.used }
  end

  # Off JRuby, the garbage is collected by a full collection, swept at
  # once (on JRuby, see the next test).
  def test_collecting_the_garbage
    skip "the JVM's collection, on JRuby" if RUBY_ENGINE == "jruby"

    collections = []
    stub(GC, :start, ->(**options) { collections << options }) { Duel::Native::Memory.collect }

    assert_equal [{full_mark: true, immediate_sweep: true}], collections
  end

  # On JRuby, the garbage is collected by the JVM, as GC.start collects
  # nothing there: what's in use falls by it.
  def test_collecting_the_garbage_on_jruby
    skip "GC.start, off JRuby" unless RUBY_ENGINE == "jruby"

    Random.bytes(32 << 20)
    before = Duel::Native::Memory.used
    Duel::Native::Memory.collect

    assert_operator before - Duel::Native::Memory.used, :>=, 32 << 20
  end

  # On JRuby, a benchmark's objects show in the heap in use, though
  # resident memory barely moves as they fill what the JVM took ahead.
  # The garbage collected first doesn't make room for them as they come.
  def test_the_memory_in_use_on_jruby
    skip "resident memory, off JRuby" unless RUBY_ENGINE == "jruby"

    Duel::Native::Memory.collect
    before = Duel::Native::Memory.used
    kept = Random.bytes(32 << 20)

    assert_operator Duel::Native::Memory.used - before, :>=, 32 << 20
    assert_equal 32 << 20, kept.bytesize
  end

  def test_resident_memory_from_macos
    missing = File.join(tmpdir, "none")

    assert_equal 4096, Duel::Native::Memory.resident(status: missing, macos: Struct.new(:resident).new(4096))
    assert_nil Duel::Native::Memory.resident(status: missing, macos: nil)
  end

  # A child, waited for with wait4(2): how it ended (WIFEXITED,
  # WEXITSTATUS and WTERMSIG, as both Linux and macOS have them), and its
  # ru_maxrss, in kilobytes on Linux and bytes on macOS.
  def test_waiting_for_a_child
    calls = []
    wait4 = lambda do |pid, status, options, rusage|
      calls << [pid, status.bytesize, status.encoding, options, rusage.bytesize, rusage.encoding]
      status[0, 4] = [(calls.size == 1) ? 3 << 8 : 15].pack("l")
      rusage[Duel::Native::Child::MAXRSS, 8] = [3000].pack("q")
      pid
    end

    assert_equal [3, nil, 3000 * 1024], Duel::Native::Child.wait(42, fiddle: true, platform: "x86_64-linux-gnu", wait4: wait4)
    assert_equal [nil, 15, 3000], Duel::Native::Child.wait(42, fiddle: true, platform: "arm64-darwin24", wait4: wait4)
    assert_equal [[42, 4, Encoding::BINARY, 0, 144, Encoding::BINARY]] * 2, calls
    found = []
    calls.clear
    ended = stub(Duel::Native, :function, ->(*args) { (found << args) && wait4 }) do
      with_constants(Duel::Native, FIDDLE: true, OS: "arm64-darwin24") { Duel::Native::Child.wait(42) }
    end

    assert_equal [[3, nil, 3000], [["wait4", %i[INT VOIDP INT VOIDP], :INT]]], [ended, found], "wait4(2), found, by default"
  end

  # A wait a signal interrupts is waited again, and one that fails
  # otherwise raises.
  def test_a_wait_that_fails
    errors = [Errno::EINTR::Errno, Errno::ECHILD::Errno]
    wait4 = lambda do |_, _, _, _|
      Fiddle.last_error = errors.shift
      -1
    end

    error = assert_raises(Errno::ECHILD) { Duel::Native::Child.wait(42, fiddle: true, wait4: wait4) }

    assert_equal "No child processes - wait4", error.message
    assert_empty errors, "after one interrupted"
  end

  # Without Fiddle, Process.wait2's (for that child alone): no peak
  # memory.
  def test_waiting_without_fiddle
    other = Process.spawn(RbConfig.ruby, "-e", "exit 3")
    sleep 0.01 until `ps -o stat= -p #{other}`.start_with?("Z")
    exited = Process.spawn(RbConfig.ruby, "-e", "exit 4")

    assert_equal [4, nil, nil], Duel::Native::Child.wait(exited, fiddle: false)
    assert_equal 3, Process.wait2(other).last.exitstatus
    killed = Process.spawn("sleep", "30")
    Process.kill("TERM", killed)

    assert_equal [nil, 15, nil], with_constants(Duel::Native, FIDDLE: false) { Duel::Native::Child.wait(killed) }
  end

  def test_resident_memory_here
    status = File.join(tmpdir, "status")
    File.write(status, "VmRSS:\t      25 kB\n")
    from_status = with_constants(Duel::Native::Memory, STATUS: status) { Duel::Native::Memory.resident(macos: nil) }

    assert_equal 25 * 1024, from_status
    from_macos = with_constants(Duel::Native::Memory, STATUS: File.join(tmpdir, "none")) do
      stub(Duel::Native::Memory, :macos_counter, -> { Struct.new(:resident).new(1) }) { Duel::Native::Memory.resident }
    end

    assert_equal 1, from_macos
  end
end

# This machine's own counters, for real. (Not for mutant: a mutation of
# how C functions are found can crash the process.)
class NativeHereTest < DuelTest
  def test_waiting_for_a_child_here
    skip "no Fiddle here" unless Duel::Native::FIDDLE

    code, signal, peak = Duel::Native::Child.wait(Process.spawn(RbConfig.ruby, "-e", "'a' * 80_000_000; exit 3"))

    assert_equal [3, nil], [code, signal]
    assert_operator peak, :>, 80_000_000
    killed = Process.spawn("sleep", "30")
    Process.kill("KILL", killed)

    assert_equal [nil, 9], Duel::Native::Child.wait(killed).first(2)
  end

  def test_the_counter_here
    counter = Duel::Native::Counter.open

    skip "no counters here" unless counter
    first = counter.read
    100_000.times { Math.sqrt(2) }

    assert_operator counter.read, :>, first
  end
end
