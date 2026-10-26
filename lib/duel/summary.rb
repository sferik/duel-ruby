# frozen_string_literal: true

require_relative "runner"

module Duel
  # A run's report in Markdown, for a pull request: GitHub Actions' job
  # summary, or a comment (see CLI). In view, only what the author needs:
  # the verdict, the two commits, and what failed, in a table. The rest is
  # collapsed: what made each regression, every benchmark's timings, the
  # verdicts across the board, each version's Ruby where they differ, and
  # how Duel decides. So it stays short with hundreds of benchmarks.
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

    # What the heading starts with: a run that passed, one that failed (or
    # couldn't compare), and one with nothing compared.
    PASSED_MARK = "🟢"
    FAILED_MARK = "🟥"
    NEUTRAL_MARK = "⚪"

    # What an unsettled timing means.
    UNSETTLED = "An unsettled timing was too close to the limit to settle. It doesn't fail the run, but one that's unsettled " \
      "in run after run is noisy."

    # How Duel decides that a timing is slower, in its docs.
    DECIDES = "https://github.com/sferik/duel-ruby/blob/main/docs/how-it-works.md#how-duel-tells-a-regression-from-noise"

    # +text+ as code, in Markdown: in a span of more backticks than any it
    # has (and spaced from one at either end).
    def self.code(text)
      ticks = "`" * ([0, *text.scan(/`+/).map(&:size)].max + 1)
      padded = (text.start_with?("`") || text.end_with?("`")) ? " #{text} " : text
      "#{ticks}#{padded}#{ticks}"
    end

    # +text+ as it is, in Markdown: what Markdown, or the HTML in it, would
    # take for something else, escaped.
    def self.escape(text) = text.gsub(/[\\`*_\[\]<>|~&#]/) { |char| "\\#{char}" }

    # A run that didn't compare: a heading of +mark+ and +title+, and the
    # first line of +reason+, with all of it collapsed if it has more.
    def self.note(mark, title, reason)
      first, _, rest = reason.partition("\n")
      more = "\n\n<details>\n<summary>The whole message</summary>\n\n#{block(reason)}\n\n</details>" unless rest.empty?
      "### #{mark} Duel: #{title}\n\n#{escape(first)}#{more}\n"
    end

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
    # +candidate+ (each a description, in Markdown, whose commit stands
    # bare, so GitHub links it) as +settings+ say.
    def initialize(runner, results, settings:, baseline:, candidate:)
      @runner = runner
      @results = results
      @settings = settings
      @baseline = baseline
      @candidate = candidate
      @regressed = results.select { |r| Summary.verdict(r) == "regressed" }
      @failed = @regressed + results.select(&:error)
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
      [heading, compared, failures, across(confirmed: true), details(explained)].compact.join("\n\n") + "\n"
    end

    # The verdict: what failed (benchmarks, or a metric across the board),
    # or that every benchmark compared passed, and those skipped.
    def heading
      skipped = @results.count(&:skipped)
      compared = @results.size > skipped
      slower = @runner.regressed_across
      said = [("#{Runner.count(@failed.size, "benchmark")} failed" unless @failed.empty?),
        ("slower across the board in #{slower.join(", ")}" unless slower.empty?)].compact
      mark = if said.any? then FAILED_MARK
      elsif compared then PASSED_MARK
      else NEUTRAL_MARK
      end
      said << (compared ? "100% of benchmarks passed" : "no benchmarks compared") if said.empty?
      said << "#{skipped} skipped" if skipped.positive?
      "### #{mark} Duel: #{said.join(", ")}"
    end

    # The two versions, and why any benchmark was skipped.
    def compared
      skipped = @results.count(&:skipped)
      why = " The baseline can't run the skipped #{(skipped == 1) ? "benchmark" : "benchmarks"}." if skipped.positive?
      "Compared #{@candidate} with #{@baseline}.#{why}"
    end

    # The benchmarks that failed: what got worse and by how much, or the
    # error, and where the most extra CPU went, if a profile says.
    def failures
      return if @failed.empty?

      header = ["Benchmark", "Failure"]
      header << "Most extra CPU in" unless @failed.all? { |r| top(r).empty? }
      rows = @failed.map { |r| row([Summary.code(cell(r.name)), failure(r), top(r)].first(header.size)) }
      ([row(header), "|#{"---|" * header.size}"] + rows).join("\n")
    end

    # What got worse, or the error's first line.
    def failure(result)
      error = result.error
      return "error: #{Summary.code(cell(error.partition("\n").first))}" if error

      worse = result.regressed.map do |metric|
        timed = result.timed[metric]
        counted = result.counted[metric]
        if timed then format("%s %+.1f%%", metric, (timed.fetch("median") - 1) * 100)
        elsif counted
          n = counted.fetch("n")
          format("%s %.4g → %.4g", metric, counted.fetch("baseline").fdiv(n), counted.fetch("candidate").fdiv(n))
        else
          # (Peak memory, which grew too much.)
          memory = result.memory #: Hash[String, Integer]
          "#{metric} #{mb(memory.fetch("baseline"))} → #{mb(memory.fetch("candidate"))}"
        end
      end
      worse.join(result.mixed? ? " or " : ", ")
    end

    # The frame whose own share of the CPU grew the most, and by how much,
    # if there's a profile with one (or "").
    def top(result)
      profile = result.profile
      return "" unless profile && !profile.key?("unavailable")

      # (A Profile's: Steep doesn't narrow on key?.)
      grew = profile.fetch("grew") #: Array[Profile::growth]
      most = grew.first
      return "" unless most

      frame, own, = most
      format("%s %+.1f%%", Summary.code(cell(frame)), own * 100)
    end

    # The rest, collapsed: each regression explained, the errors, every
    # benchmark, the verdicts across the board, the Rubies, and how Duel
    # decides.
    def details(explained)
      unsettled = @results.count { |r| Summary.verdict(r) == "unsettled" }
      title = format("Details: %s in %.0fs%s", Runner.count(@results.size, "benchmark"), @runner.seconds,
        (", #{unsettled} unsettled" if unsettled.positive?))
      body = [*regressions(explained), *errors, table, (UNSETTLED if unsettled.positive?), across(confirmed: false), rubies, decides]
      "<details>\n<summary>#{title}</summary>\n\n#{body.compact.join("\n\n")}\n\n</details>"
    end

    # The results, in the order of their VERDICTS, and the run's order in
    # each (grouped, not sorted: Ruby's sort isn't stable everywhere).
    def sorted
      grouped = @results.group_by { |r| Summary.verdict(r) }
      VERDICTS.flat_map { |shown| grouped.fetch(shown, []) }
    end

    # Every benchmark, with its timings, and its counts where any changed.
    def table
      return if @results.empty?

      rows = sorted.map do |r|
        shown = Summary.verdict(r)
        [Summary.code(cell(r.name)), FAILED.include?(shown) ? "**#{shown}**" : shown, timings(r), counts(r)]
      end
      header = ["Benchmark", "Verdict", "Timings (ratio [interval])", "Counts an iteration"]
      columns = (rows.any? { |cells| !cells.last.empty? }) ? 4 : 3
      ([row(header.first(columns)), "|#{"---|" * columns}"] + rows.map { |cells| row(cells.first(columns)) }).join("\n")
    end

    # A table's row of +cells+.
    def row(cells) = "| #{cells.join(" | ")} |"

    # +text+ for a table's cell, on one line.
    def cell(text) = text.tr("\n", " ").gsub("|", "\\|")

    # Each timed measure's ratio and its interval, with its verdict where
    # it isn't the same (or why it was skipped).
    def timings(result)
      skipped = result.skipped
      return cell(skipped) if skipped

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
      shown = @regressed.first(explained).map do |r|
        what = r.mixed? ? "slower in every measurement, by one of #{r.regressed.join(", ")}" : "worse #{r.regressed.join(", ")} in every measurement"
        lines = @runner.explained(r)
        said = "**#{Summary.code(r.name)}**: #{what}"
        lines.empty? ? said : "#{said}\n\n#{Summary.block(lines.join("\n"))}"
      end
      rest = @regressed.size - shown.size
      shown << "#{Runner.count(rest, shown.empty? ? "regression" : "more regression")} explained in the job's log." if rest.positive?
      shown
    end

    # The verdicts across the board, of the metrics with enough
    # benchmarks to tell: those slower in both measurements, which fail
    # the run (+confirmed+), or the rest.
    def across(confirmed:)
      lines = @runner.across.filter_map do |metric, v|
        low, high = v.fetch("interval")
        next unless low && v.fetch("confirmed", false) == confirmed

        format("- %s %.3f [%.3f, %.3f] %s%s (limit %.4f, %s)", metric, v.fetch("median"), low, high, v.fetch("verdict"),
          (" in both measurements" if confirmed), v.fetch("limit"), Runner.count(v.fetch("benchmarks"), "benchmark"))
      end
      "Across the board:\n\n#{lines.join("\n")}" unless lines.empty?
    end

    # The errors of more than a line, all of them (up to ERROR_LINES):
    # their first lines are in view.
    def errors
      @failed.select { |r| r.error.to_s.chomp.include?("\n") }.map do |r|
        error = r.error #: String
        lines = error.lines
        cut = "\n(#{Runner.count(lines.size - ERROR_LINES, "more line")} in the job's log)" if lines.size > ERROR_LINES
        "**#{Summary.code(r.name)}**\n\n#{Summary.block(lines.first(ERROR_LINES).join)}#{cut}"
      end
    end

    # Each version's Ruby, where they differ.
    def rubies
      rubies = @runner.rubies
      return if rubies.values.uniq.size == 1

      "Baseline on #{Summary.code(rubies.fetch("baseline"))}, candidate on #{Summary.code(rubies.fetch("candidate"))}."
    end

    # How Duel decides that a timing is slower, as the settings have it.
    def decides
      format("A timing is slower when a %s%% confidence interval for its ratio, the candidate's to the baseline's, is above %s. " \
        "[How Duel decides](%s)", (@settings.confidence * 100).round(1), @settings.limit, DECIDES)
    end
  end
end
