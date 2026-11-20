# frozen_string_literal: true

require_relative "duel_helper"

# A plugin may ask, every sample, whether a count is worth explaining:
# asking allocates nothing.
duel "metric: whether a count is within what its one measure allows" do
  once do
    # (Its slack as the version names it: per_iteration: and per_sample:,
    # or before 0.3.0, tolerance: and allowance:.)
    slack = Subject::Duel::Metric::SETTINGS.include?(:per_iteration) ? {per_iteration: 0.5, per_sample: 2} : {tolerance: 0.5, allowance: 2}
    @metric = Class.new(Subject::Duel::Metric) { define_singleton_method(:measures) { {"rows" => slack} } }.new
  end
  @metric.within?(7, 10)
end
