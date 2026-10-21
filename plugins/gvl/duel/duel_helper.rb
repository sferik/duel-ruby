# frozen_string_literal: true

# What a metric's start_sample is given, as Duel gives it: a sample of one
# iteration, of a benchmark with +only+ (:timing for one with threads of
# its own).
def sample(only)
  benchmark = Data.define(:name, :only, :peak_memory).new(name: "work", only:, peak_memory: false)
  Data.define(:n, :benchmark).new(n: 1, benchmark:)
end

# Loads this version's extension (Duel::GVL::Hook), as a worker that uses
# the plugin does, and checks it's this version's own build:
# the candidate's lib/ is on the load path too, behind this version's,
# so a baseline whose build left none would quietly measure the
# candidate's.
def load_hook
  raise "the extension isn't built (bundle exec rake compile)" unless Duel::GVL.load_extension

  lib = File.expand_path("../..", Duel::GVL.method(:load_extension).source_location.first)
  extension = $LOADED_FEATURES.find { |feature| feature.end_with?("/duel_gvl/duel_gvl.#{RbConfig::CONFIG["DLEXT"]}") }
  raise "the extension loaded is #{extension}, not this version's (in #{lib})" unless extension&.start_with?(File.join(lib, ""))
end

# +metric+'s methods that start and stop a sample, as this version of the
# plugin names them (start_sample and stop_sample, or, before them, start
# and stop: Duel's own Metric, the runner's, may have both).
def sample_methods(metric)
  return [metric.method(:start_sample), metric.method(:stop_sample)] if metric.class.method_defined?(:start_sample, false)

  [metric.method(:start), metric.method(:stop)]
end
