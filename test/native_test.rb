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
    skip "Windows's functions are its DLLs' (see test_a_libraries_function)" if windows?

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

    assert_equal 25_600 * 1024, Duel::Native::Memory.resident(status: status, reader: nil)
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

    assert_equal 4096, Duel::Native::Memory.resident(status: missing, reader: Struct.new(:resident).new(4096))
    assert_nil Duel::Native::Memory.resident(status: missing, reader: nil)
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

    error = assert_raises(Errno::ECHILD) { Duel::Native::Child.wait(42, fiddle: true, platform: "x86_64-linux-gnu", wait4: wait4) }

    assert_equal "No child processes - wait4", error.message
    assert_empty errors, "after one interrupted"
  end

  # Without Fiddle, Process.wait2's (for that child alone): no peak
  # memory.
  def test_waiting_without_fiddle
    other = ended_child
    exited = Process.spawn(RbConfig.ruby, "-e", "exit 4")

    assert_equal [4, nil, nil], Duel::Native::Child.wait(exited, fiddle: false)
    assert_equal 3, Process.wait2(other).last.exitstatus
  end

  # And the signal that killed it.
  def test_killed_without_fiddle
    skip "Windows kills with no signal" if windows?

    killed = Process.spawn("sleep", "30")
    Process.kill("TERM", killed)

    assert_equal [nil, 15, nil], with_constants(Duel::Native, FIDDLE: false) { Duel::Native::Child.wait(killed) }
  end

  def test_resident_memory_here
    status = File.join(tmpdir, "status")
    File.write(status, "VmRSS:\t      25 kB\n")
    from_status = with_constants(Duel::Native::Memory, STATUS: status) { Duel::Native::Memory.resident(reader: nil) }

    assert_equal 25 * 1024, from_status
    from_macos = with_constants(Duel::Native::Memory, STATUS: File.join(tmpdir, "none")) do
      stub(Duel::Native::Memory, :opened_reader, -> { Struct.new(:resident).new(1) }) { Duel::Native::Memory.resident }
    end

    assert_equal 1, from_macos
  end

  # A fake K32GetProcessMemoryInfo: writes +working_set+ where
  # PROCESS_MEMORY_COUNTERS has it (and the peak before it, never read),
  # or fails.
  def fake_memory_info(working_set, calls = [])
    lambda do |process, buffer, size|
      calls << [process, buffer.unpack1("L"), buffer.byteslice(4..).count("\0"), buffer.encoding, size]
      buffer[8, 8] = [working_set * 2].pack("Q")
      buffer[Duel::Native::Windows::WORKING_SET, 8] = [working_set].pack("Q")
      working_set ? 1 : 0
    end
  end

  def test_windows_reads_the_processes_working_set
    calls = []
    windows = Duel::Native::Windows.open(platform: "x64-mingw-ucrt", memory_info: fake_memory_info(8192, calls))

    assert_equal 8192, windows.resident
    assert_equal [-1, 72, 68, Encoding::BINARY, 72], calls.first, "this process's counters, a struct's worth of zeros, saying its size"
    assert_equal [-1, 72], calls.last.first(2), "into the same struct, read again"
  end

  def test_windows_finds_k32_get_process_memory_info
    found = []
    memory_info = fake_memory_info(5)
    windows = stub(Duel::Native, :function, ->(*args, **options) { (found << [args, options]) && memory_info }) do
      with_constants(Duel::Native, OS: "mswin64_140") { Duel::Native::Windows.open }
    end

    assert_equal [[["K32GetProcessMemoryInfo", %i[VOIDP VOIDP INT], :INT], {library: "kernel32"}]], found
    assert_equal 5, windows.resident
  end

  def test_windows_unavailable
    assert_nil Duel::Native::Windows.open(platform: "x86_64-linux-gnu", memory_info: fake_memory_info(5))
    failing = ->(*) { 0 }

    assert_nil Duel::Native::Windows.open(platform: "mingw32", memory_info: failing), "the call fails"
    missing = ->(*) { raise Fiddle::DLError, "no such function" }

    assert_nil Duel::Native::Windows.open(platform: "mingw32", memory_info: missing)
  end

  # GlobalMemoryStatusEx's ullAvailPhys, in a MEMORYSTATUSEX that says
  # its size.
  def test_windows_memory_available
    calls = []
    status = lambda do |buffer|
      calls << [buffer.unpack1("L"), buffer.byteslice(4..).count("\0"), buffer.encoding]
      buffer[8, 8] = [99].pack("Q")
      buffer[Duel::Native::Windows::AVAILABLE, 8] = [4 << 30].pack("Q")
      1
    end

    assert_equal 4 << 30, Duel::Native::Windows.available(platform: "x64-mingw-ucrt", status: status)
    assert_equal [[64, 60, Encoding::BINARY]], calls, "a struct's worth of zeros, saying its size"
    found = []
    available = stub(Duel::Native, :function, ->(*args, **options) { (found << [args, options]) && status }) do
      with_constants(Duel::Native, OS: "mswin64_140") { Duel::Native::Windows.available }
    end

    assert_equal [4 << 30, [[["GlobalMemoryStatusEx", %i[VOIDP], :INT], {library: "kernel32"}]]], [available, found]
  end

  def test_windows_memory_available_unknown
    assert_nil Duel::Native::Windows.available(platform: "arm64-darwin24", status: ->(_) { 1 })
    assert_nil Duel::Native::Windows.available(platform: "mingw32", status: ->(_) { 0 }), "the call fails"
    missing = ->(*) { raise Fiddle::DLError, "no such function" }

    assert_nil Duel::Native::Windows.available(platform: "mingw32", status: missing)
  end

  # A fake QueryThreadCycleTime (or QueryProcessCycleTime): writes
  # +count+ where it's told, as an unsigned 64-bit count.
  def fake_cycles(count, calls = [])
    lambda do |handle, address|
      calls << [handle, address]
      Fiddle::Pointer.new(address)[0, 8] = [count].pack("Q")
      1
    end
  end

  # The cycles charged to this thread, or this process, read from where
  # the call wrote them.
  def test_windows_cycles
    calls = []
    thread = Duel::Native::Windows::Cycles.new(:thread, query: fake_cycles(0x0001_0203_0405_0607, calls))
    read = thread.read

    assert_equal [0x0001_0203_0405_0607, Float], [read, read.class], "a Float, which Windows doesn't allocate"
    assert_equal 0xff << 56, Duel::Native::Windows::Cycles.new(:process, query: fake_cycles(0xff << 56)).read, "the last byte, unsigned"
    assert_equal 0xff, Duel::Native::Windows::Cycles.new(:process, query: fake_cycles(0xff)).read, "the first"
    process_calls = []
    Duel::Native::Windows::Cycles.new(:process, query: fake_cycles(5, process_calls)).read
    handle, address = calls.first

    assert_equal [-2, thread.instance_variable_get(:@count).to_i], [handle, address], "this thread's, into its count"
    assert_equal(-1, process_calls.first.first, "this process's")
    assert_raises(KeyError) { Duel::Native::Windows::Cycles.new(:machine, query: fake_cycles(1)) }
    assert_equal Fiddle::RUBY_FREE, thread.instance_variable_get(:@count).free.to_i, "freed with it"
  end

  # Read without allocating: the CPU metric's readings are inside the
  # count of allocations.
  def test_windows_cycles_allocate_nothing
    skip "CRuby's count of allocations" unless RUBY_ENGINE == "ruby"

    cycles = Duel::Native::Windows::Cycles.new(:thread, query: ->(_, _) { 1 })
    cycles.instance_variable_get(:@count)[0, 8] = [123_456_789].pack("Q")
    # (Measured again, once what the first takes, as Ruby warms up, is
    # taken.)
    allocated = lambda do
      before = GC.stat(:total_allocated_objects)
      100.times { cycles.read }
      GC.stat(:total_allocated_objects) - before
    end
    allocated.call

    assert_equal [123_456_789, 0], [cycles.read, allocated.call]
  end

  def test_windows_cycles_found_in_kernel32
    found = []
    query = fake_cycles(9)
    cycles = stub(Duel::Native, :function, ->(*args, **options) { (found << [args, options]) && query }) do
      %i[thread process].map { |scope| Duel::Native::Windows::Cycles.new(scope).read }
    end

    assert_equal [9, 9], cycles
    assert_equal %w[QueryThreadCycleTime QueryProcessCycleTime].map { |name| [[name, %i[INTPTR_T INTPTR_T], :INT], {library: "kernel32"}] },
      found, "taking integers, which Fiddle passes without allocating"
  end

  # Another process's memory, by its handle: its working set, and the
  # most it held.
  def test_windows_another_processes_memory
    calls = []
    windows = Duel::Native::Windows.new(fake_memory_info(4096, calls), handle: 77)

    assert_equal [4096, 8192], [windows.resident, windows.peak]
    assert_equal [77, 77], calls.map(&:first)
    assert_nil Duel::Native::Windows.new(->(*) { 0 }, handle: 77).peak, "the call fails"
  end

  def test_windows_another_processes_cycles
    calls = []
    Duel::Native::Windows::Cycles.new(:process, query: fake_cycles(3, calls), handle: 77).read

    assert_equal 77, calls.first.first
  end

  # A child, by a handle of its own: what it took, and closed.
  def test_windows_spawned
    opened = []
    open_process = ->(*args) { (opened << args) && 77 }
    spawned = stub(Duel::Native::Windows::Spawned, :new, ->(handle) { [:spawned, handle] }) do
      Duel::Native::Windows::Spawned.open(42, open_process: open_process)
    end

    assert_equal [[:spawned, 77], [[0x1000, 0, 42]]], [spawned, opened], "for querying, not inherited"
    made = []
    unopened = stub(Duel::Native::Windows::Spawned, :new, ->(handle) { made << handle }) do
      Duel::Native::Windows::Spawned.open(42, open_process: ->(*) { 0 })
    end

    assert_equal [nil, []], [unopened, made], "it can't be opened"
    missing = ->(*) { raise Fiddle::DLError, "no such function" }

    assert_nil Duel::Native::Windows::Spawned.open(42, open_process: missing)
    closed = []
    spawned = Duel::Native::Windows::Spawned.new(77, cycles: Struct.new(:read).new(12_345), memory_info: fake_memory_info(4096),
      close: ->(handle) { (closed << handle) && 1 })

    assert_equal [12_345, 8192], [spawned.cycles, spawned.peak]
    spawned.close

    assert_equal [77], closed
  end

  def test_windows_spawned_finds_its_functions
    found = []
    queried = []
    measured = []
    functions = {"OpenProcess" => ->(*) { 77 }, "QueryProcessCycleTime" => fake_cycles(5, queried),
                 "K32GetProcessMemoryInfo" => fake_memory_info(4096, measured), "CloseHandle" => ->(_) { 1 }}
    spawned = stub(Duel::Native, :function, ->(name, *args, **options) { (found << [name, args, options]) && functions.fetch(name) }) do
      Duel::Native::Windows::Spawned.open(42)
    end

    assert_equal [5, 8192, 1], [spawned.cycles, spawned.peak, spawned.close]
    assert_equal [77, 77], [queried.first.first, measured.first.first], "the child's, by its handle"
    assert_equal [["OpenProcess", [%i[INT INT INT], :INTPTR_T], {library: "kernel32"}],
      ["QueryProcessCycleTime", [%i[INTPTR_T INTPTR_T], :INT], {library: "kernel32"}],
      ["K32GetProcessMemoryInfo", [%i[VOIDP VOIDP INT], :INT], {library: "kernel32"}],
      ["CloseHandle", [%i[INTPTR_T], :INT], {library: "kernel32"}]], found
  end

  def test_windows_platforms
    assert_match Duel::Native::WINDOWS_OS, "mingw32"
    assert_match Duel::Native::WINDOWS_OS, "mswin64_140"
    refute_match Duel::Native::WINDOWS_OS, "darwin24"
    assert_equal RUBY_PLATFORM.match?(/mingw|mswin/), Duel::Native::WINDOWS
  end

  # A function of a library of its own (a DLL, on Windows).
  def test_a_libraries_function
    library = if Duel::Native::WINDOWS then "msvcrt"
    elsif Duel::Native::OS.include?("darwin") then "/usr/lib/libSystem.B.dylib"
    else "libc.so.6"
    end
    opened = []
    dlopen = Fiddle.method(:dlopen)
    found = stub(Fiddle, :dlopen, ->(name) { (opened << name) && dlopen.call(name) }) do
      Duel::Native.function("strlen", [:VOIDP], :LONG, library: library)
    end

    assert_equal [library], opened
    assert_equal Fiddle.dlopen(library)["strlen"], found.ptr
    assert_equal 5, found.call("hello")
  end

  # Windows has no wait4: Process.wait2's, without peak memory.
  def test_waiting_on_windows
    exited = Process.spawn(RbConfig.ruby, "-e", "exit 4")
    wait4 = ->(*) { raise "no wait4 on Windows" }

    assert_equal [4, nil, nil], Duel::Native::Child.wait(exited, fiddle: true, platform: "x64-mingw-ucrt", wait4: wait4)
  end

  # Windows's reader, where it's neither Linux nor macOS, and none
  # without Fiddle.
  def test_the_reader_on_windows
    was_opened = Duel::Native::Memory.instance_variable_defined?(:@reader)
    reader = Duel::Native::Memory.instance_variable_get(:@reader)
    opened = [true, false].map do |fiddle|
      Duel::Native::Memory.remove_instance_variable(:@reader) if Duel::Native::Memory.instance_variable_defined?(:@reader)
      stub(Duel::Native::MacOS, :open, -> {}) do
        stub(Duel::Native::Windows, :open, -> { :windows }) { with_constants(Duel::Native, FIDDLE: fiddle) { Duel::Native::Memory.opened_reader } }
      end
    end

    assert_equal [:windows, nil], opened
  ensure
    # (As it was: none opened yet, if none was, rather than none to open.)
    if was_opened
      Duel::Native::Memory.instance_variable_set(:@reader, reader)
    elsif Duel::Native::Memory.instance_variable_defined?(:@reader)
      Duel::Native::Memory.remove_instance_variable(:@reader)
    end
  end
end

# This machine's own counters, for real. (Not for mutant: a mutation of
# how C functions are found can crash the process.)
class NativeHereTest < DuelTest
  def test_waiting_for_a_child_here
    skip "no Fiddle here" unless Duel::Native::FIDDLE

    code, signal, peak = Duel::Native::Child.wait(Process.spawn(RbConfig.ruby, "-e", "'a' * 80_000_000; exit 3"))

    assert_equal [3, nil], [code, signal]
    if windows?
      assert_nil peak, "not on Windows, yet"
    else
      assert_operator peak, :>, 80_000_000
    end
  end

  def test_killed_child_here
    skip "no Fiddle here" unless Duel::Native::FIDDLE
    skip "Windows kills with no signal" if windows?

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
