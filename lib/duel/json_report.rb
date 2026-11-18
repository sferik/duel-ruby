# frozen_string_literal: true

require "json"
require_relative "runner"
require_relative "summary"
require_relative "version"

module Duel
  # A run's report as JSON, for a program to read (`--json PATH`, see
  # CLI): the same results the Markdown report has (see Summary), in plain
  # JSON types, numbers as numbers. Its schema is documented in
  # docs/json.md, and SCHEMA is its version, raised for any change that
  # isn't a new key.
  # @api private
  class JSONReport
    SCHEMA = 2

    # A run that didn't compare: +status+ ("nothing_to_compare", or
    # "error"), its +exit+ status, and +message+, what it said.
    def self.note(status, exit, message, settings)
      none = [] #: Array[value]
      nothing = {} #: report
      head(status, exit, nil, message, settings).merge("seconds" => nil, "baseline" => nil, "candidate" => nil, "plugins" => none,
        "benchmarks" => none, "across" => nothing, "cut_short" => nil)
    end

    # What every report starts with.
    def self.head(status, exit, passed_anyway, message, settings)
      {"schema" => SCHEMA, "duel_version" => VERSION, "status" => status, "exit" => exit, "passed_anyway" => passed_anyway,
       "message" => message, "settings" => {"confidence" => settings.confidence, "limit" => settings.limit, "filter" => settings.filter.source,
                                            "jobs" => settings.jobs, "processes" => settings.processes, "timeout" => settings.timeout,
                                            "time_limit" => settings.time_limit, "warm" => settings.warm, "force" => settings.force}}
    end

    # +runner+ ran, and made +results+, comparing +baseline+ with
    # +candidate+ (each {"ref", "commit", "root"} or {"commit",
    # "uncommitted_changes", "root"}) as +settings+ say, and whether they
    # +passed+, exits with +exit+, and if they failed, passed anyway as
    # +passed_anyway+ says (see CLI#slower): "accept_label" (a pull
    # request's label accepted it), "fail_on" (only a pull request
    # fails), or nil.
    def initialize(runner, results, settings:, passed:, exit:, passed_anyway:, baseline:, candidate:)
      @runner = runner
      @results = results
      @settings = settings
      @passed = passed
      @exit = exit
      @passed_anyway = passed_anyway
      @versions = {"baseline" => baseline, "candidate" => candidate}
    end

    def to_h
      rubies = @runner.rubies
      JSONReport.head(@passed ? "passed" : "failed", @exit, @passed_anyway, nil, @settings).merge(
        "seconds" => @runner.seconds,
        **@versions.to_h { |side, version| [side, version.merge("ruby" => rubies.fetch(side))] },
        "plugins" => @runner.plugins.map(&:to_s),
        "benchmarks" => @results.map { |result| benchmark(result) },
        "across" => across,
        "cut_short" => @runner.cut_short
      )
    end

    private

    # (Runner#explained says nothing of a benchmark that didn't regress.)
    def benchmark(result)
      {"name" => result.name, "verdict" => Summary.verdict(result), "passed" => result.passed?, "regressed" => result.regressed,
       "iterations" => result.n, "seconds" => result.seconds,
       "confirmations" => result.confirmations.size, "timed" => timed(result), "counted" => counted(result),
       "peak_memory" => peak_memory(result), "details" => result.details,
       "explanation" => @runner.explained(result), "error" => result.error, "skipped" => result.skipped}
    end

    # Each timed measure: its ratio's median, interval and verdict, and
    # each version's median an iteration.
    def timed(result)
      # (Timed, so measured, with an n.)
      n = result.n #: Integer
      result.timed.to_h do |metric, t|
        [metric, {"ratio" => t.fetch("median"), "interval" => t.fetch("interval"), "limit" => t.fetch("limit"),
                  "pairs" => t.fetch("pairs"), "processes" => t["processes"], "verdict" => t.fetch("verdict"), "baseline" => t.fetch("baseline").fdiv(n),
                  "candidate" => t.fetch("candidate").fdiv(n), "unit" => t.fetch("unit"), "plural" => t.fetch("plural"),
                  "across" => t.fetch("across")}]
      end
    end

    # Each counted measure: each version's fewest an iteration, and its
    # verdict: "more" (worse: more than the metric tolerates), "fewer",
    # or "same" (or more, within what it tolerates).
    def counted(result)
      worse = result.worse
      result.counted.to_h do |metric, c|
        base, candidate = Result.per_iteration(c)
        verdict = if worse.include?(metric) then "more"
        elsif candidate < base then "fewer"
        else "same"
        end
        [metric, {"baseline" => base, "candidate" => candidate, "unit" => c.fetch("unit"), "plural" => c.fetch("plural"), "verdict" => verdict}]
      end
    end

    # Each version's peak memory, and its verdict: "more" (than Duel
    # tolerates), or "same".
    def peak_memory(result)
      result.memory&.then do |memory|
        {"baseline" => memory.fetch("baseline"), "candidate" => memory.fetch("candidate"), "unit" => "B",
         "verdict" => result.more_memory? ? "more" : "same"}
      end
    end

    def across
      @runner.across.transform_values do |v|
        {"ratio" => v.fetch("median"), "interval" => v.fetch("interval"), "limit" => v.fetch("limit"), "benchmarks" => v.fetch("benchmarks"),
         "processes" => v["processes"], "verdict" => v.fetch("verdict"), "confirmed" => v.fetch("confirmed", false)}
      end
    end
  end
end
