# frozen_string_literal: true

require_relative "support/end_to_end"

# Peak memory, and the garbage collector held off for allocation-heavy
# benchmarks.
class EndToEndMemoryTest < DuelTest
  include EndToEnd

  # Peak memory, for a benchmark that asks: one that needs 24 MB more at
  # its peak fails, and the same memory passes.
  def test_peak_memory
    skip "no way to tell the memory in use here" unless Duel::Native::Memory.used

    # (With a setup of its own: the fresh workers measuring it run no trial.)
    benchmarks = %(require "sample"\nduel("big", peak_memory: true) { once { @more = 0 }\n Sample.big.size + @more }\n)
    base = project(File.join(tmpdir, "base"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(1 << 20)")
    same = project(File.join(tmpdir, "same"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(1 << 20)")
    bigger = project(File.join(tmpdir, "bigger"), benchmarks: benchmarks, extra: "def self.big = Random.bytes(25 << 20)")
    passed, = compare(base, same, processes: 1)

    refute_includes passed.first.regressed, "peak_memory"
    assert_equal %w[baseline candidate], passed.first.memory.keys
    failed, out = compare(base, bigger, processes: 1)

    assert_includes failed.first.regressed, "peak_memory", out
    assert_match(/peak_memory \d+\.\dMB→\d+\.\dMB/, out)
  end

  # A run that allocates a lot but takes little CPU is held to what fits
  # HEAP_CAP (64 MB), as the garbage collector is held off meanwhile.
  def test_allocation_heavy_benchmarks_are_capped
    skip "CRuby holds the collector off" unless RUBY_ENGINE == "ruby"

    benchmarks = %(duel("big") { String.new(capacity: 32 << 20) }\n)
    base = project(File.join(tmpdir, "base"), benchmarks: benchmarks)
    candidate = project(File.join(tmpdir, "candidate"), benchmarks: benchmarks)
    result, = compare(base, candidate, processes: 1).first

    assert_operator result.n, :<=, 2
  end
end
