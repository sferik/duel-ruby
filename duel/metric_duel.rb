# frozen_string_literal: true

require_relative "duel_helper"

# A plugin may ask, every sample, whether a count is worth explaining:
# asking allocates nothing.
duel "metric: whether a count is within its one measure's tolerance" do
  once { @metric = Class.new(Subject::Duel::Metric) { def self.measures = {"rows" => {tolerance: 0.5, allowance: 2}} }.new }
  @metric.within?(7, 10)
end
