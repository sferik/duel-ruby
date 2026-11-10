# frozen_string_literal: true

module Duel
  # The memory a run's workers can take (see Runner#fit): what the
  # machine has available, or what its cgroup's limit leaves, if that's
  # less (a container's, say).
  # @api private
  module Memory
    # The kinds of pages macOS's vm_stat counts that a process can have
    # without the system swapping: free, and cached but unused.
    MAC_PAGES = %w[free inactive speculative].freeze

    # Where Linux's proc and sys are.
    ROOT = "/"

    class << self
      # The bytes available, or nil where Duel can't tell: Linux's
      # MemAvailable (in +root+'s proc/meminfo), at most what the cgroup
      # mounted at sys/fs/cgroup leaves, or else macOS's free and
      # inactive pages (in what +vm_stat+ prints).
      def available(root: ROOT, vm_stat: -> { command("vm_stat") }) = linux(root) || mac(vm_stat.call)

      # MemAvailable, at most what the cgroup leaves, or nil.
      def linux(root)
        kb = read(File.join(root, "proc", "meminfo"))&.[](/^MemAvailable:\s+(\d+) kB$/, 1) or return
        [Integer(kb) * 1024, cgroup(File.join(root, "sys", "fs", "cgroup"))].compact.min
      end

      # What a cgroup (v2) at +dir+ leaves of its limit, or nil where it
      # has none ("max").
      def cgroup(dir)
        max, current = %w[memory.max memory.current].map { |file| Integer(read(File.join(dir, file)), exception: false) }
        max - current if max && current
      end

      # The bytes in the pages of MAC_PAGES that vm_stat's +output+
      # counts, or nil.
      def mac(output)
        page = output&.[](/page size of (\d+) bytes/, 1) or return
        MAC_PAGES.sum { |kind| Integer(output[/^Pages #{kind}:\s+(\d+)\./, 1] || 0) } * Integer(page)
      end

      # A file's contents, or nil where there's none.
      def read(path) = (File.read(path) if File.file?(path))

      # What a command prints, or nil where there's no such command.
      def command(*args)
        IO.popen(args, err: File::NULL, &:read)
      rescue SystemCallError
        nil
      end
    end
  end
end
