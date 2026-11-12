# frozen_string_literal: true

require "rbconfig"

module Duel
  # What the operating system can tell about this process, through Fiddle:
  # instructions retired (hardware counters) and resident memory. Each
  # answers nil where it can't, as on JRuby, where Fiddle's calls can
  # bring the JVM down.
  # @api private
  module Native
    FIDDLE = RUBY_ENGINE == "ruby"
    OS = RbConfig::CONFIG["host_os"]
    CPU = RbConfig::CONFIG["host_cpu"]
    # What host_os is on Windows: mingw's ("mingw32", "mingw-ucrt") or
    # mswin's ("mswin64_140").
    WINDOWS_OS = /mingw|mswin/
    WINDOWS = OS.match?(WINDOWS_OS)
    UINT64 = 8 # bytes, the size of every count read

    # Loads Fiddle, as the first C function is made (see .function): not
    # as Duel loads, which in a worker is before its version (in fiddle's
    # own repository, fiddle).
    # mutant:disable -- the tests' process has Fiddle loaded from the start,
    # so a require changes nothing there: WorkerTest's
    # test_loads_no_gem_a_version_could_be_before_the_version checks it, in
    # a process of its own
    def self.require_fiddle = require("fiddle")

    # A C function of the process's own libraries (or of +library+, a
    # DLL: on Windows, the process's own are only its program's), by
    # name, taking and returning Fiddle types (:INT, :LONG, :VOIDP...).
    def self.function(name, args, returns, library: nil)
      require_fiddle
      Fiddle::Function.new(Fiddle.dlopen(library)[name], args.map { |type| Fiddle.const_get(:"TYPE_#{type}") },
        Fiddle.const_get(:"TYPE_#{returns}"))
    end

    # Instructions retired in user space, from the CPU's counters.
    class Counter
      # The best counter here: the benchmark thread's (Linux), the
      # process's (macOS), or nil.
      def self.open(fiddle: FIDDLE) = (Linux.open || MacOS.open if fiddle)

      # "thread" or "process": whose instructions it counts.
      attr_reader :scope

      def initialize(scope) = @scope = scope

      def read = raise(NotImplementedError)
    end

    # Linux: perf_event_open(2), counting this thread's instructions in
    # user space. Unavailable in many virtual machines (no counters), and
    # where kernel.perf_event_paranoid forbids it.
    class Linux < Counter
      SYSCALL = {"x86_64" => 298, "aarch64" => 241}.freeze
      PERF_TYPE_HARDWARE = 0
      PERF_COUNT_HW_INSTRUCTIONS = 1
      # exclude_kernel and exclude_hv: user space only, which needs no
      # privileges.
      FLAGS = (1 << 5) | (1 << 6)
      PERF_FLAG_FD_CLOEXEC = 8
      ATTR_SIZE = 64 # PERF_ATTR_SIZE_VER0

      def self.open(platform: OS, cpu: CPU, syscall: nil)
        number = SYSCALL[cpu]
        return unless platform.include?("linux") && number

        syscall ||= Native.function("syscall", %i[LONG VOIDP INT INT INT LONG], :LONG)
        attr = [PERF_TYPE_HARDWARE, ATTR_SIZE, PERF_COUNT_HW_INSTRUCTIONS, 0, 0, 0, FLAGS, 0, 0, 0].pack("LLQQQQQLLQ")
        fd = syscall.call(number, attr, 0, -1, -1, PERF_FLAG_FD_CLOEXEC)
        new(IO.for_fd(fd)) unless fd.negative?
      rescue Fiddle::DLError # no such function
        nil
      end

      def initialize(io)
        super("thread")
        @io = io
      end

      def read = @io.pread(UINT64, 0).unpack1("Q")
    end

    # macOS: proc_pid_rusage(RUSAGE_INFO_V4), the process's instructions
    # and resident memory, no privileges needed.
    class MacOS < Counter
      RUSAGE_INFO_V4 = 4
      SIZE = 296 # sizeof(struct rusage_info_v4)
      RESIDENT = 64 # offsetof(ri_resident_size)
      INSTRUCTIONS = 248 # offsetof(ri_instructions)

      def self.open(platform: OS, rusage: nil)
        return unless platform.include?("darwin")

        rusage ||= Native.function("proc_pid_rusage", %i[INT INT VOIDP], :INT)
        counter = new(rusage)
        counter if counter.read.positive?
      rescue Fiddle::DLError # no such function
        nil
      end

      def initialize(rusage)
        super("process")
        @rusage = rusage
        # (A String of its own: Fiddle passes its bytes, for the call to
        # fill in place.)
        @buffer = "\0".b * SIZE
      end

      def read = field(INSTRUCTIONS)

      def resident = field(RESIDENT)

      private

      def field(offset)
        @rusage.call(Process.pid, RUSAGE_INFO_V4, @buffer)
        @buffer.unpack1("Q", offset: offset)
      end
    end

    # Windows: this process's working set (its resident memory), from
    # K32GetProcessMemoryInfo, and the memory available, from
    # GlobalMemoryStatusEx, both kernel32's, needing no privileges. (No
    # instructions: it counts none a process can read.)
    class Windows
      KERNEL32 = "kernel32"
      # GetCurrentProcess()'s handle, which needs no closing.
      CURRENT_PROCESS = -1
      COUNTERS = 72 # sizeof(PROCESS_MEMORY_COUNTERS), 64-bit
      PEAK_WORKING_SET = 8 # offsetof(PeakWorkingSetSize)
      WORKING_SET = 16 # offsetof(WorkingSetSize)
      STATUS = 64 # sizeof(MEMORYSTATUSEX)
      AVAILABLE = 16 # offsetof(ullAvailPhys)

      def self.open(platform: OS, memory_info: nil)
        return unless platform.match?(WINDOWS_OS)

        memory_info ||= Native.function("K32GetProcessMemoryInfo", %i[VOIDP VOIDP INT], :INT, library: KERNEL32)
        windows = new(memory_info)
        windows if windows.resident
      rescue Fiddle::DLError # no such function
        nil
      end

      # The bytes of physical memory available, or nil where it can't
      # tell.
      def self.available(platform: OS, status: nil)
        return unless platform.match?(WINDOWS_OS)

        status ||= Native.function("GlobalMemoryStatusEx", %i[VOIDP], :INT, library: KERNEL32)
        # (Each struct says its size first, as the call checks.)
        buffer = [STATUS].pack("L").ljust(STATUS, "\0")
        buffer.unpack1("Q", offset: AVAILABLE) unless status.call(buffer).zero?
      rescue Fiddle::DLError # no such function
        nil
      end

      # +handle+: the process's whose memory it reads (this one's, by
      # default).
      def initialize(memory_info, handle: CURRENT_PROCESS)
        @memory_info = memory_info
        @handle = handle
        @buffer = [COUNTERS].pack("L").ljust(COUNTERS, "\0")
      end

      # The bytes in its working set, or nil where the call fails.
      def resident = counter(WORKING_SET)

      # The most bytes its working set has held, or nil where the call
      # fails.
      def peak = counter(PEAK_WORKING_SET)

      # The CPU cycles charged to this thread (QueryThreadCycleTime) or
      # this process (QueryProcessCycleTime), counted as they run: CPU
      # time at full resolution, where Windows's own CPU times move in
      # ticks of 15.6 ms. Read without allocating, as the CPU metric's
      # readings are inside the count of allocations: the call takes the
      # count's address as an integer (a pointer Fiddle would wrap), and
      # the count is read back a byte at a time.
      class Cycles
        # GetCurrentThread()'s handle, which needs no closing.
        CURRENT_THREAD = -2
        QUERIES = {thread: ["QueryThreadCycleTime", CURRENT_THREAD], process: ["QueryProcessCycleTime", CURRENT_PROCESS]}.freeze #: Hash[:thread | :process, [String, Integer]]

        # +handle+: the thread's or process's (by default, this one).
        # mutant:disable -- Integer(), #to_int and #to_i are a Pointer's
        # address alike, and how its memory is freed (test_windows_cycles
        # checks it is) can't show in what's read
        def initialize(scope, query: nil, handle: nil)
          name, current = QUERIES.fetch(scope)
          @handle = handle || current
          @query = query || Native.function(name, %i[INTPTR_T INTPTR_T], :INT, library: KERNEL32)
          @count = Fiddle::Pointer.malloc(UINT64, Fiddle::RUBY_FREE)
          @address = @count.to_i
        end

        def read
          @query.call(@handle, @address)
          count = 0
          byte = UINT64
          count = (count << 8) + (@count[byte -= 1] & 0xff) while byte.positive?
          count
        end
      end

      # A child process, by a handle of its own (OpenProcess's), opened as
      # it starts: what it took, once it has ended, as Windows keeps no
      # account of a child's CPU time for its parent (Process.times has
      # none): its CPU cycles, and its peak working set. (Not those of the
      # processes it started, which Unix counts in.)
      class Spawned
        QUERY = 0x1000 # PROCESS_QUERY_LIMITED_INFORMATION

        # +pid+'s, or nil where it can't be opened. (Ruby holds a handle of
        # its own until it's waited for, so one that ended already can.)
        def self.open(pid, open_process: nil)
          open_process ||= Native.function("OpenProcess", %i[INT INT INT], :INTPTR_T, library: KERNEL32)
          handle = open_process.call(QUERY, 0, pid)
          new(handle) unless handle.zero?
        rescue Fiddle::DLError # no such function
          nil
        end

        def initialize(handle, cycles: nil, memory_info: nil, close: nil)
          @handle = handle
          @cycles = cycles || Cycles.new(:process, handle: handle)
          @memory = Windows.new(memory_info || Native.function("K32GetProcessMemoryInfo", %i[VOIDP VOIDP INT], :INT, library: KERNEL32),
            handle: handle)
          @close = close || Native.function("CloseHandle", %i[INTPTR_T], :INT, library: KERNEL32)
        end

        def cycles = @cycles.read

        # Its peak working set, in bytes, or nil.
        def peak = @memory.peak

        def close = @close.call(@handle)
      end

      private

      def counter(offset) = (@buffer.unpack1("Q", offset: offset) unless @memory_info.call(@handle, @buffer, COUNTERS).zero?)
    end

    # A child process of this one, waited for.
    module Child
      # wait4(2)'s struct rusage: its size, and where its ru_maxrss is (on
      # Linux and macOS, 64-bit).
      RUSAGE_SIZE = 144
      MAXRSS = 32
      # A wait a signal interrupted: waited again.
      EINTR = Errno::EINTR::Errno

      # Waits for the child +pid+, and returns how it ended (its exit
      # status, or nil, and the signal that killed it, or nil) and the most
      # resident memory it reached (its children's too), in bytes, or nil
      # where that can't be told (without Fiddle, or on Windows, which has
      # no wait4).
      def self.wait(pid, fiddle: FIDDLE, platform: OS, wait4: nil)
        if !fiddle || platform.match?(WINDOWS_OS)
          status = Process.wait2(pid).last
          return [status.exitstatus, status.termsig, nil]
        end

        wait4 ||= Native.function("wait4", %i[INT VOIDP INT VOIDP], :INT)
        status = "\0".b * 4
        rusage = "\0".b * RUSAGE_SIZE
        until wait4.call(pid, status, 0, rusage) == pid
          raise SystemCallError.new("wait4", Fiddle.last_error) unless Fiddle.last_error == EINTR
        end
        # (As WIFEXITED, WEXITSTATUS and WTERMSIG take it apart: what wait4
        # gives is a process's that exited or was killed, in 16 bits.)
        raw = status.unpack1("l") #: Integer
        signal = raw & 0x7f
        # (ru_maxrss is in kilobytes on Linux, bytes on macOS.)
        [(raw >> 8 if signal.zero?), (signal unless signal.zero?),
          rusage.unpack1("q", offset: MAXRSS) * (platform.include?("darwin") ? 1 : 1024)]
      end
    end

    # This process's resident memory in bytes, or nil where it can't tell.
    module Memory
      # (Its VmRSS line, in kB: no page size to know, as /proc/self/statm's
      # pages need, which would take Etc, a gem a worker would load before
      # its version.)
      STATUS = "/proc/self/status"
      # What reads resident memory where there's no /proc: macOS's
      # counter, or Windows's, or nil. Opened as resident memory is first
      # read, as opening it loads Fiddle.
      # mutant:disable -- kept only so as not to open it again: it's the
      # same reader however often it's opened
      def self.opened_reader
        return @reader if defined?(@reader)

        @reader = (MacOS.open || Windows.open if FIDDLE)
      end

      # From /proc (Linux), else from macOS's or Windows's reader, else
      # nil.
      def self.resident(status: STATUS, reader: opened_reader)
        return reader&.resident unless File.readable?(status)

        kb = File.read(status)[/^VmRSS:\s+(\d+) kB$/, 1] #: String
        Integer(kb) * 1024
      end

      # The memory a benchmark's peak is measured in (see MemorySample),
      # in bytes, or nil where it can't tell: resident memory, but on
      # JRuby, the JVM's heap in use.
      def self.used = resident

      # Collects every object that's garbage, so that what's in use (see
      # .used) is what's live: a full collection, swept at once.
      def self.collect = GC.start(full_mark: true, immediate_sweep: true)
    end

    # simplecov:disable JRuby's heap is the JVM's (JRuby's test run covers
    # this).
    if RUBY_ENGINE == "jruby"
      module Memory
        # The JVM takes memory for its heap ahead of time, and keeps what it
        # used while it started, so resident memory barely moves as a
        # benchmark's objects fill it: 24 MB more of them can show as none.
        # The heap in use shows them.
        HEAP = java.lang.management.ManagementFactory.getMemoryMXBean

        def self.used = HEAP.getHeapMemoryUsage.getUsed

        # JRuby's GC.start collects nothing. The JVM's own call does:
        # without it, a peak was measured above garbage that the benchmark's
        # objects then made room for, and came out tens of megabytes short.
        def self.collect = java.lang.System.gc
      end
    end
    # simplecov:enable
  end
end
