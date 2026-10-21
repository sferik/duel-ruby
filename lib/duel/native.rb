# frozen_string_literal: true

require "etc"
require "fiddle"
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
    UINT64 = 8 # bytes, the size of every count read

    # A C function of the process's own libraries, by name, taking and
    # returning Fiddle types (:INT, :LONG, :VOIDP...).
    def self.function(name, args, returns)
      Fiddle::Function.new(Fiddle.dlopen(nil)[name], args.map { |type| Fiddle.const_get(:"TYPE_#{type}") },
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
        @buffer = Fiddle::Pointer.malloc(SIZE, Fiddle::RUBY_FREE)
      end

      def read = field(INSTRUCTIONS)

      def resident = field(RESIDENT)

      private

      def field(offset)
        @rusage.call(Process.pid, RUSAGE_INFO_V4, @buffer)
        @buffer[offset, UINT64].unpack1("Q")
      end
    end

    # This process's resident memory in bytes, or nil where it can't tell.
    module Memory
      STATM = "/proc/self/statm"
      # (Never false: Steep doesn't see that false || nil is nil.)
      MACOS = (FIDDLE && MacOS.open) || nil #: MacOS?

      # From /proc (Linux), else from macOS's counter, else nil.
      def self.resident(statm: STATM, macos: MACOS)
        return macos&.resident unless File.readable?(statm)

        # (The page size is always known.)
        page_size = Etc.sysconf(Etc::SC_PAGESIZE) #: Integer
        Integer(File.read(statm).split.fetch(1)) * page_size
      end
    end
  end
end
