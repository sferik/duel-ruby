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
    SCHEMA = 1

    # A run that didn't compare: +status+ ("nothing_to_compare", or
    # "error"), its +exit+ status, and +message+, what it said.
    def self.note(status, exit, message, settings)
      none = [] #: Array[value]
      nothing = {} #: report
      head(status, exit, message, settings).merge("seconds" => nil, "baseline" => nil, "candidate" => nil, "plugins" => none,
        "benchmarks" => none, "across" => nothing, "errors" => none)
    end

    # What every report starts with.
    def self.head(status, exit, message, settings)
      {"schema" => SCHEMA, "duel_version" => VERSION, "status" => status, "exit" => exit, "message" => message,
       "settings" => {"confidence" => settings.confidence, "limit" => settings.limit, "filter" => settings.filter.source,
                      "jobs" => settings.jobs, "processes" => settings.processes, "timeout" => settings.timeout,
                      "warm" => settings.warm, "force" => settings.force}}
    end

    # +runner+ ran, and made +results+, comparing +baseline+ with
    # +candidate+ (each {"ref", "commit", "root"} or {"commit",
    # "uncommitted_changes", "root"}) as +settings+ say, and exits with
    # +exit+.
    def initialize(runner, results, settings:, exit:, baseline:, candidate:)
      @runner = runner
      @results = results
      @settings = settings
      @exit = exit
      @versions = {"baseline" => baseline, "candidate" => candidate}
    end

    def to_h
      rubies = @runner.rubies
      JSONReport.head(@exit.zero? ? "passed" : "failed", @exit, nil, @settings).merge(
        "seconds" => @runner.seconds,
        **@versions.to_h { |side, version| [side, version.merge("ruby" => rubies.fetch(side))] },
        "plugins" => @runner.plugins.map(&:to_s),
        "benchmarks" => @results.map { |result| benchmark(result) },
        "across" => across,
        "errors" => @results.select(&:error).map { |result| {"benchmark" => result.name, "message" => result.error} }
      )
    end

    private

    # (Runner#explained says nothing of a benchmark that didn't regress.)
    def benchmark(result)
      {"name" => result.name, "verdict" => Summary.verdict(result), "passed" => result.passed?, "regressed" => result.regressed,
       "unsettled" => result.unsettled?, "iterations" => result.n, "seconds" => result.seconds,
       "confirmations" => result.confirmations.size, "timed" => timed(result), "counted" => counted(result),
       "peak_memory" => peak_memory(result), "details" => result.details,
       "explanation" => @runner.explained(result), "error" => result.error, "skipped" => result.skipped}
    end

    # Each timed measure: its ratio's median, interval and verdict, and
    # each version's median an iteration.
    def timed(result)
      # (Timed, so measured, with an n.)
      result.timed.to_h do |metric, t|
        n = result.n #: Integer
        [metric, {"ratio" => t.fetch("median"), "interval" => t.fetch("interval"), "limit" => t.fetch("limit"),
                  "pairs" => t.fetch("pairs"), "verdict" => t.fetch("verdict"), "baseline" => t.fetch("baseline").fdiv(n),
                  "candidate" => t.fetch("candidate").fdiv(n), "unit" => t.fetch("unit"), "plural" => t.fetch("plural"),
                  "across" => t.fetch("across")}]
      end
    end

    # Each counted measure: each version's fewest an iteration, and
    # whether that's worse.
    def counted(result)
      worse = result.worse
      result.counted.to_h do |metric, c|
        n = c.fetch("n")
        [metric, {"baseline" => c.fetch("baseline").fdiv(n), "candidate" => c.fetch("candidate").fdiv(n), "unit" => c.fetch("unit"),
                  "plural" => c.fetch("plural"), "worse" => worse.include?(metric)}]
      end
    end

    def peak_memory(result)
      result.memory&.then do |memory|
        {"baseline" => memory.fetch("baseline"), "candidate" => memory.fetch("candidate"), "unit" => "B", "worse" => result.more_memory?}
      end
    end

    def across
      @runner.across.transform_values do |v|
        {"ratio" => v.fetch("median"), "interval" => v.fetch("interval"), "limit" => v.fetch("limit"), "benchmarks" => v.fetch("benchmarks"),
         "verdict" => v.fetch("verdict"), "confirmed" => v.fetch("confirmed", false)}
      end
    end
  end
end
