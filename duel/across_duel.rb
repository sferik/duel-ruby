# frozen_string_literal: true

require_relative "duel_helper"

# Its confidence interval's ranks are found in one pass over the
# binomial terms: the time grows with the benchmarks, not their cube.
[8, 100, 300].each do |benchmarks|
  duel "across: the verdict over #{benchmarks} benchmarks" do
    once do
      medians = ratios(benchmarks, center: 1.01)
      @results = Array.new(benchmarks) { |i| cpu_result("b#{i}", medians.fetch(i)) }
    end
    Subject::Duel::Across.new(@results, confidence: 0.99).verdicts
  end
end
