# frozen_string_literal: true

require_relative "runner"

module Duel
  # A run's report in Markdown, for a pull request: GitHub Actions' job
  # summary, or a comment (see CLI). It has the verdict, the two versions
  # (and their Rubies, where they differ), a table of the benchmarks that
  # changed, regressions first, each regression explained as the terminal
  # report explains it, those unsettled and those that failed. The rest
  # are collapsed, so it stays short with hundreds of benchmarks.
  # @api private
  class Summary
    # The most characters it has (a GitHub comment has at most 65,536):
    # past it, regressions go unexplained, from the last, and the job's
    # log has the rest.
    LIMIT = 60_000

    # The most lines of an error it shows.
    ERROR_LINES = 12

    # A benchmark's verdict, and where it goes in the table (in that
    # order).
    VERDICTS = %w[regressed error unsettled faster changed skipped same].freeze

    # The verdicts that fail a run, which stand out.
    FAILED = %w[regressed error].freeze

    # +text+ as code, in Markdown: in a span of more backticks than any it
    # has (and spaced from one at either end).
    def self.code(text)
      ticks = "`" * ([0, *text.scan(/`+/).map(&:size)].max + 1)
      padded = (text.start_with?("`") || text.end_with?("`")) ? " #{text} " : text
      "#{ticks}#{padded}#{ticks}"
    end

    # A run that didn't compare (+title+ says why), with what it said.
    def self.note(title, message) = "### Duel: #{title}\n\n#{block(message)}\n"

    # +text+ in a fenced block of its own: fenced with more backticks than
    # any run of them it has, three at least.
    def self.block(text)
      fence = "`" * [3, *text.scan(/`{3,}/).map { |run| run.size + 1 }].max
      "#{fence}text\n#{text.chomp}\n#{fence}"
    end

    # +result+'s verdict (see VERDICTS): the JSON report's too (see
    # JSONReport).
    def self.verdict(result)
      if result.error then "error"
      elsif result.skipped then "skipped"
      elsif result.regressed.any? then "regressed"
      elsif result.unsettled? then "unsettled"
      elsif result.timed.any? { |_, t| t.fetch("verdict") == "faster" } then "faster"
      elsif changed_counts(result).any? then "changed"
      else "same"
      end
    end

    # {metric => [baseline, candidate]}, an iteration, of the counted
    # measures that differ.
    def self.changed_counts(result)
      result.counted.to_h do |metric, c|
        n = c.fetch("n")
        [metric, [c.fetch("baseline").fdiv(n), c.fetch("candidate").fdiv(n)]] #: [String, [Float, Float]]
      end.reject { |_, (base, candidate)| base == candidate }
    end

    # +runner+ ran, and made +results+, comparing +baseline+ with
    # +candidate+ (each a description, in Markdown) as +settings+ say.
    def initialize(runner, results, settings:, baseline:, candidate:)
      @runner = runner
      @results = results
      @settings = settings
      @versions = {"baseline" => baseline, "candidate" => candidate}
      @regressed = results.select { |r| Summary.verdict(r) == "regressed" }
    end

    # The Markdown: every regression explained, or as many as LIMIT has
    # room for.
    def markdown
      explained = @regressed.size
      text = render(explained)
      text = render(explained -= 1) while text.size > LIMIT && explained.positive?
      text
    end

    private

    # The Markdown, with the first +explained+ regressions explained.
    def render(explained)
      same, changed = sorted.partition { |r| Summary.verdict(r) == "same" }
      [heading, versions, overview, table(changed), regressions(explained), across, unsettled, errors, unchanged(same)]
        .compact.join("\n\n") + "\n"
    end

    def heading
      errors = @results.count(&:error)
      failed = [(Runner.count(@regressed.size, "regression") unless @regressed.empty?),
        ("slower across the board" unless @runner.regressed_across.empty?),
        (Runner.count(errors, "error") unless errors.zero?)].compact
      return "### Duel failed: #{failed.join(", ")}" unless failed.empty?

      "### Duel passed: none of #{Runner.count(@results.size, "benchmark")} slower"
    end

    # Each version, on its Ruby where theirs differ, and the plugins
    # used.
    def versions
      rubies = @runner.rubies
      plugins = @runner.plugins
      lines = @versions.map do |side, described|
        ruby = " on #{Summary.code(rubies.fetch(side))}" if rubies.values.uniq.size > 1
        "- **#{side.capitalize}:** #{described}#{ruby}"
      end
      lines << "- **Plugins:** #{plugins.map { |plugin| Summary.code(plugin.to_s) }.join(", ")}" unless plugins.empty?
      lines.join("\n")
    end

    def overview
      format("%s in %.0fs. A timing is slower when a %s%% confidence interval for its ratio, the candidate's to the " \
        "baseline's, is above %s.", Runner.count(@results.size, "benchmark"), @runner.seconds,
        (@settings.confidence * 100).round(1), @settings.limit)
    end

    # The results, in the order of their VERDICTS, and the run's order in
    # each (grouped, not sorted: Ruby's sort isn't stable everywhere).
    def sorted
      grouped = @results.group_by { |r| Summary.verdict(r) }
      VERDICTS.flat_map { |shown| grouped.fetch(shown, []) }
    end

    def table(changed)
      return if changed.empty?

      rows = changed.map do |r|
        shown = Summary.verdict(r)
        row(Summary.code(name(r)), FAILED.include?(shown) ? "**#{shown}**" : shown, timings(r), counts(r))
      end
      ([row("Benchmark", "Verdict", "Timings (ratio [interval])", "Counts an iteration"), "|---|---|---|---|"] + rows).join("\n")
    end

    # Those that didn't change, collapsed.
    def unchanged(same)
      return if same.empty?

      rows = same.map { |r| row(Summary.code(name(r)), timings(r)) }
      "<details>\n<summary>#{Runner.count(same.size, "benchmark")} unchanged</summary>\n\n" \
        "#{[row("Benchmark", "Timings (ratio [interval])"), "|---|---|", *rows].join("\n")}\n\n</details>"
    end

    # A table's row of +cells+.
    def row(*cells) = "| #{cells.join(" | ")} |"

    # A benchmark's name, for a table's cell.
    def name(result) = result.name.tr("\n", " ").gsub("|", "\\|")

    # Each timed measure's ratio and its interval, with its verdict where
    # it isn't the same (or why it was skipped).
    def timings(result)
      skipped = result.skipped
      return skipped.gsub("|", "\\|") if skipped

      result.timed.map do |metric, t|
        low, high = t.fetch("interval")
        shown = t.fetch("verdict")
        format("%s %.3f [%.3f, %.3f]%s", metric, t.fetch("median"), low, high, (" #{shown}" unless shown == "same"))
      end.join("<br>")
    end

    # Each counted measure that changed, an iteration, and peak memory
    # that grew too much.
    def counts(result)
      counted = Summary.changed_counts(result).map do |metric, (base, candidate)|
        format("%s %.4g → %.4g", metric, base, candidate)
      end
      if result.more_memory?
        memory = result.memory #: Hash[String, Integer]
        counted << "peak_memory #{mb(memory.fetch("baseline"))} → #{mb(memory.fetch("candidate"))}"
      end
      counted.join("<br>")
    end

    def mb(bytes) = format("%.1fMB", bytes / 1_048_576.0)

    # The first +explained+ regressions, explained as the terminal report
    # explains them (and the rest named).
    def regressions(explained)
      return if @regressed.empty?

      shown = @regressed.first(explained).map do |r|
        what = r.mixed? ? "slower in every measurement, by one of #{r.regressed.join(", ")}" : "worse #{r.regressed.join(", ")} in every measurement"
        lines = @runner.explained(r)
        said = "**#{Summary.code(r.name)}**: #{what}"
        lines.empty? ? said : "#{said}\n\n#{Summary.block(lines.join("\n"))}"
      end
      rest = @regressed.size - shown.size
      shown << "#{Runner.count(rest, shown.empty? ? "regression" : "more regression")} explained in the job's log." if rest.positive?
      "#### Regressions\n\n#{shown.join("\n\n")}"
    end

    # The verdicts across the board, of the metrics with enough
    # benchmarks to tell.
    def across
      lines = @runner.across.filter_map do |metric, v|
        low, high = v.fetch("interval")
        next unless low

        confirmed = " in both measurements" if v["confirmed"]
        format("- %s %.3f [%.3f, %.3f] %s%s (limit %.4f, %s)", metric, v.fetch("median"), low, high, v.fetch("verdict"), confirmed,
          v.fetch("limit"), Runner.count(v.fetch("benchmarks"), "benchmark"))
      end
      "#### Across the board\n\n#{lines.join("\n")}" unless lines.empty?
    end

    def unsettled
      names = @results.select { |r| Summary.verdict(r) == "unsettled" }.map { |r| Summary.code(r.name) }
      return if names.empty?

      "#### Unsettled\n\nA timing too close to the limit to settle doesn't fail the run, but one that's unsettled in run " \
        "after run is noisy: #{names.join(", ")}."
    end

    def errors
      failed = @results.select(&:error)
      return if failed.empty?

      shown = failed.map do |r|
        error = r.error #: String
        lines = error.lines
        cut = "\n(#{Runner.count(lines.size - ERROR_LINES, "more line")} in the job's log)" if lines.size > ERROR_LINES
        "**#{Summary.code(r.name)}**\n\n#{Summary.block(lines.first(ERROR_LINES).join)}#{cut}"
      end
      "#### Errors\n\n#{shown.join("\n\n")}"
    end
  end
end
