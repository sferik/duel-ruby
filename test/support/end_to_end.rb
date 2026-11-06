# frozen_string_literal: true

require_relative "../test_helper"

# What the end-to-end tests share (the end_to_end_*_test.rb files, a
# theme each, so that parallel_tests can run them at once): whole
# comparisons of a small project's two versions, in worker processes.
#
# (Too slow for mutation testing: the code they run is covered there by
# faster tests, with its worker processes faked.)
module EndToEnd
  # Real workers: with a JIT that needs one (JRuby's, TruffleRuby's),
  # warmed up a little (the tests' code is quick to warm up).
  def settings(**overrides) = super(warm: Duel::JIT_WARM.zero? ? 0.0 : 1.5, **overrides)

  def compare(base, candidate, **overrides)
    config = Duel::Config.new(candidate)
    out = StringIO.new
    results = Duel::Runner.new(config, settings(candidate_dir: candidate, **overrides), base, out: out).run
    [results, out.string]
  end
end
