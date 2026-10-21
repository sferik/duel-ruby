# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# A run's report in Markdown (see Duel::Summary), from whole runs with
# their worker processes faked.
class SummaryTest < DuelTest
  cover "Duel::Summary*"

  def candidate = File.join(tmpdir, "candidate")

  # A run of +workers+, and its Markdown (the run taking 12.4 seconds).
  def summarize(workers, baseline: "`abc1234`", candidate: "`def5678`", **overrides)
    runner = Duel::Runner.new(Duel::Config.new(self.candidate), settings(**overrides), File.join(tmpdir, "base"), out: StringIO.new)
    results = elsewhere { runner.run }
    runner.instance_variable_set(:@seconds, 12.4)
    Duel::Summary.new(runner, results, settings: settings(**overrides), baseline: baseline, candidate: candidate).markdown
  end

  def with_fake_workers
    workers = FakeWorkers.new
    stub(Duel::WorkerProcess, :new, ->(*args, **options) { workers.make(*args, **options) }) { yield workers }
  end

  # Each version's CPU time an iteration (+cpu+, by version) and
  # allocations (+allocations+), as a benchmark's measures.
  def measures(cpu: [100_000, 100_000], allocations: [2, 2], details: nil)
    lambda do |side, n, _|
      i = (side == "baseline") ? 0 : 1
      {"timed" => {"cpu" => n * cpu.fetch(i)}, "counted" => {"allocations" => n * allocations.fetch(i)}, "heap" => 0,
       "details" => details&.fetch(i)}.compact
    end
  end

  # A runner that ran (with these verdicts across the board, Rubies and
  # seconds), for results made by hand.
  def runner(across: {}, rubies: {"baseline" => "ruby 3.4", "candidate" => "ruby 3.4"}, seconds: 1.0, plugins: [])
    config = Duel::Config.new(candidate)
    config.define_singleton_method(:plugins) { plugins }
    Duel::Runner.new(config, settings, File.join(tmpdir, "base"), out: StringIO.new).tap do |r|
      r.instance_variable_set(:@across, across)
      r.instance_variable_set(:@rubies, rubies)
      r.instance_variable_set(:@seconds, seconds)
    end
  end

  def summary(results, runner: self.runner, **overrides)
    Duel::Summary.new(runner, results, settings: settings(**overrides), baseline: "`abc1234`", candidate: "`def5678`").markdown
  end

  # A result made by hand: +timed+ ({metric => verdict}, each with a
  # ratio of 1.0) and +counted+ ({metric => [baseline, candidate]}, of
  # one iteration).
  def result(name, timed: {"cpu" => "same"}, counted: {})
    Duel::Result.new(name).tap do |r|
      r.n = 1
      timed.each do |metric, verdict|
        r.timed[metric] = {"median" => 1.0, "interval" => [0.99, 1.01], "verdict" => verdict, "baseline" => 1000, "candidate" => 1000,
                           "unit" => "ns", "plural" => "ns", "limit" => 1.02, "across" => true}
      end
      counted.each do |metric, (base, candidate)|
        r.counted[metric] = {"baseline" => base, "candidate" => candidate, "n" => 1, "tolerance" => 0, "allowance" => 0, "unit" => nil,
                             "plural" => nil}
      end
    end
  end

  # A run with something of everything: what changed in a table,
  # regressions first, each explained, then the rest of what changed,
  # what's unsettled and what failed, and what didn't change collapsed.
  def test_a_run
    with_fake_workers do |workers|
      workers.benchmark("same: one", &measures)
      workers.benchmark("slow: work", &measures(cpu: [100_000, 110_000], allocations: [2, 3],
        details: [{"allocations" => "2 String"}, {"allocations" => "3 String"}]))
      workers.benchmark("fast: work", &measures(cpu: [100_000, 90_000]))
      workers.benchmark("fewer: allocations", &measures(allocations: [3, 2]))
      workers.benchmark("close: call", &measures(cpu: [100_000, 102_000]))
      workers.benchmark("broken")
      workers.benchmark("new")
      workers.benchmark("same: two", &measures)
      workers.fail("candidate-1", "setup", "broken")
      workers.fail("baseline-1", "setup", "new", error: Duel::Failed.new("baseline-1: NameError: no"))
      workers.profile("baseline", {"samples" => 100, "frames" => [["f", 10, 10]]})
      workers.profile("candidate", {"samples" => 110, "frames" => [["f", 20, 20]]})

      assert_equal <<~MARKDOWN, summarize(workers)
        ### Duel failed: 1 regression, 1 error

        - **Baseline:** `abc1234`
        - **Candidate:** `def5678`

        8 benchmarks in 12s. A timing is slower when a 99.0% confidence interval for its ratio, the candidate's to the baseline's, is above 1.02.

        | Benchmark | Verdict | Timings (ratio [interval]) | Counts an iteration |
        |---|---|---|---|
        | `slow: work` | **regressed** | cpu 1.100 [1.100, 1.100] slower | allocations 2 → 3 |
        | `broken` | **error** |  |  |
        | `close: call` | unsettled | cpu 1.020 [1.020, 1.020] undecided |  |
        | `fast: work` | faster | cpu 0.900 [0.900, 0.900] faster |  |
        | `fewer: allocations` | changed | cpu 1.000 [1.000, 1.000] | allocations 3 → 2 |
        | `new` | skipped | not on the baseline (baseline-1: NameError: no) |  |

        #### Regressions

        **`slow: work`**: worse cpu, allocations in every measurement

        ```text
        cpu: 100µs → 110µs an iteration (1.10x)
        allocations: 2 → 3 an iteration
        allocations (candidate): 3 String
        allocations (baseline): 2 String
        where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):
           +10.0%  +10.0%  f
        ```

        #### Unsettled

        A timing too close to the limit to settle doesn't fail the run, but one that's unsettled in run after run is noisy: `close: call`.

        #### Errors

        **`broken`**

        ```text
        Duel::Failed: candidate-1: RuntimeError: oops
        ```

        <details>
        <summary>2 benchmarks unchanged</summary>

        | Benchmark | Timings (ratio [interval]) |
        |---|---|
        | `same: one` | cpu 1.000 [1.000, 1.000] |
        | `same: two` | cpu 1.000 [1.000, 1.000] |

        </details>
      MARKDOWN
    end
  end

  # Nothing slower: a heading that says so, the settings' limit and
  # confidence, and nothing but the collapsed table.
  def test_a_run_that_passed
    with_fake_workers do |workers|
      workers.benchmark("a", &measures)

      assert_equal <<~MARKDOWN, summarize(workers, limit: 1.05, confidence: 0.95)
        ### Duel passed: none of 1 benchmark slower

        - **Baseline:** `abc1234`
        - **Candidate:** `def5678`

        1 benchmark in 12s. A timing is slower when a 95.0% confidence interval for its ratio, the candidate's to the baseline's, is above 1.05.

        <details>
        <summary>1 benchmark unchanged</summary>

        | Benchmark | Timings (ratio [interval]) |
        |---|---|
        | `a` | cpu 1.000 [1.000, 1.000] |

        </details>
      MARKDOWN
    end
  end

  # A little slower at every benchmark: across the board.
  def test_slower_across_the_board
    with_fake_workers do |workers|
      Array.new(8) { |i| workers.benchmark("b#{i}", &measures(cpu: [100_000, 101_000])) }
      markdown = summarize(workers)

      assert_equal "### Duel failed: slower across the board\n", markdown.lines.first
      assert_includes markdown, "\n\n#### Across the board\n\n- cpu 1.010 [1.010, 1.010] slower in both measurements (limit 1.0050, " \
        "8 benchmarks)\n\n<details>\n<summary>8 benchmarks unchanged</summary>\n"
    end
  end

  # Across the board: only the metrics with enough benchmarks to tell,
  # and "in both measurements" only where a second one confirmed it.
  def test_across_the_board
    across = {"cpu" => {"median" => 1.0, "interval" => [0.998, 1.002], "limit" => 1.005, "benchmarks" => 8, "verdict" => "same"},
              "few" => {"median" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2, "verdict" => "undecided"},
              "wait" => {"median" => 1.01, "interval" => [1.006, 1.02], "limit" => 1.005, "benchmarks" => 1, "verdict" => "slower",
                         "confirmed" => false}}
    markdown = summary([result("a")], runner: runner(across: across))

    assert_includes markdown, "\n\n#### Across the board\n\n- cpu 1.000 [0.998, 1.002] same (limit 1.0050, 8 benchmarks)\n" \
      "- wait 1.010 [1.006, 1.020] slower (limit 1.0050, 1 benchmark)\n\n<details>"
    assert_equal "### Duel passed: none of 1 benchmark slower\n", markdown.lines.first, "not confirmed"
    refute_includes summary([result("a")], runner: runner(across: across.slice("few"))), "Across"
  end

  # Each version's Ruby, where they differ.
  def test_rubies
    markdown = summary([result("a")], runner: runner(rubies: {"baseline" => "ruby 3.4", "candidate" => "ruby `4.0`"}))

    assert_includes markdown, "\n\n- **Baseline:** `abc1234` on `ruby 3.4`\n- **Candidate:** `def5678` on `` ruby `4.0` ``\n\n"
  end

  # The plugins used, after the versions.
  def test_plugins
    markdown = summary([result("a")], runner: runner(plugins: %i[rails activerecord]))

    assert_includes markdown, "\n- **Candidate:** `def5678`\n- **Plugins:** `rails`, `activerecord`\n\n"
    refute_includes summary([result("a")]), "Plugins"
  end

  def test_seconds_and_confidence
    assert_includes summary([result("a")], runner: runner(seconds: 61.6), confidence: 0.9994),
      "\n\n1 benchmark in 62s. A timing is slower when a 99.9% confidence interval"
  end

  # A regression of one timing in some measurements and another in the
  # rest; one with nothing to explain; and those past what fits
  # (LIMIT), named.
  def test_regressions
    mixed = result("mixed", timed: {"cpu" => "slower", "instructions" => "undecided"})
    mixed.confirmations << result("again", timed: {"cpu" => "undecided", "instructions" => "slower"})
    memory = result("memory", timed: {})
    memory.memory = {"baseline" => 1 << 20, "candidate" => 3 << 20}
    markdown = summary([mixed, memory])

    assert_includes markdown, "| `mixed` | **regressed** | cpu 1.000 [0.990, 1.010] slower<br>instructions 1.000 [0.990, 1.010] undecided |  |\n"
    assert_includes markdown, "| `memory` | **regressed** |  | peak_memory 1.0MB → 3.0MB |\n"
    assert_includes markdown, "\n\n#### Regressions\n\n**`mixed`**: slower in every measurement, by one of cpu, instructions\n\n```text\n" \
      "cpu: 1µs → 1µs an iteration (1.00x)\ninstructions: 1µs → 1µs an iteration (1.00x)\n```\n\n" \
      "**`memory`**: worse peak_memory in every measurement\n"
    assert markdown.end_with?("\n\n**`memory`**: worse peak_memory in every measurement\n"), "with nothing to explain"
    refute_includes markdown, "<details>", "none unchanged"
    explained = markdown.size
    one = with_constants(Duel::Summary, LIMIT: explained - 1) { summary([mixed, memory]) }

    assert_includes one, "\n\n**`mixed`**: slower in every measurement, by one of cpu, instructions\n\n```text\n"
    assert_includes one, "\n\n1 more regression explained in the job's log.\n"
    refute_includes one, "**`memory`**"
    none = with_constants(Duel::Summary, LIMIT: 10) { summary([mixed, memory]) }

    assert_includes none, "\n\n#### Regressions\n\n2 regressions explained in the job's log.\n"
    assert_equal markdown, with_constants(Duel::Summary, LIMIT: explained) { summary([mixed, memory]) }, "as long as it may be"
  end

  # Peak memory, on a benchmark's row, only where it grew too much.
  def test_peak_memory
    less = result("less", counted: {"allocations" => [2, 1]})
    less.memory = {"baseline" => 3 << 20, "candidate" => 1 << 20}

    assert_includes summary([less]), "| `less` | changed | cpu 1.000 [0.990, 1.010] | allocations 2 → 1 |\n"
  end

  # Counts an iteration, those that changed.
  def test_counts
    r = result("a", counted: {"allocations" => [4, 3], "same" => [2, 2], "queries" => [1, 1.5]})
    r.counted.fetch("allocations")["n"] = 2
    r.counted.fetch("queries")["tolerance"] = 1

    assert_includes summary([r]), "| `a` | changed | cpu 1.000 [0.990, 1.010] | allocations 2 → 1.5<br>queries 1 → 1.5 |\n"
  end

  # Faster at one timing, though the same at another.
  def test_faster
    assert_includes summary([result("a", timed: {"cpu" => "faster", "instructions" => "same"})]),
      "| `a` | faster | cpu 1.000 [0.990, 1.010] faster<br>instructions 1.000 [0.990, 1.010] |  |\n"
  end

  # A name, or why it was skipped, that would break a table's row.
  def test_cells
    r = result("a|b\nc|d")
    skipped = Duel::Result.new("new").tap { |s| s.skipped = "not on the baseline (x | y | z)" }
    markdown = summary([r, skipped])

    assert_includes markdown, "| `a\\|b c\\|d` | cpu 1.000 [0.990, 1.010] |\n"
    assert_includes markdown, "| `new` | skipped | not on the baseline (x \\| y \\| z) |  |\n"
    assert_includes markdown, "\n\n<details>\n<summary>1 benchmark unchanged</summary>\n\n"
  end

  # An error's first ERROR_LINES lines (a backtrace's, say), fenced off.
  def test_long_errors
    r = Duel::Result.new("a").tap { |e| e.error = Array.new(15) { |i| "line #{i}\n" }.join + "```\n" }
    shown = Array.new(12) { |i| "line #{i}" }.join("\n")

    assert_includes summary([r]), "\n\n#### Errors\n\n**`a`**\n\n```text\n#{shown}\n```\n(4 more lines in the job's log)\n"
    r.error = "x\n" * 13

    assert_includes summary([r]), "\n```\n(1 more line in the job's log)\n"
    r.error = "x\n" * 12
    other = Duel::Result.new("b").tap { |e| e.error = "y" }

    assert summary([r, other]).end_with?("\n**`a`**\n\n```text\n#{"x\n" * 12}```\n\n**`b`**\n\n```text\ny\n```\n"), "each, all of it"
  end

  def test_code
    assert_equal ["`a`", "``a`b``", "```a``b ```", "`` `a ``", "`` a` ``", "` `", "```a`b``c`d```"],
      ["a", "a`b", "a``b ", "`a", "a`", " ", "a`b``c`d"].map { |text| Duel::Summary.code(text) }
  end

  def test_block
    assert_equal ["```text\na\n```", "```text\na\n```", "````text\n```\n````", "`````text\n````\n`````", "``````text\n````` ```\n``````"],
      ["a", "a\n", "```", "````", "````` ```"].map { |text| Duel::Summary.block(text) }
  end

  def test_note
    assert_equal "### Duel: nothing to compare\n\n```text\nduel: lib unchanged\n```\n",
      Duel::Summary.note("nothing to compare", "duel: lib unchanged")
  end
end

# What a run keeps for its summary: each version's Ruby, the seconds it
# took, and each regression's explanation.
class RunnerSummaryTest < DuelTest
  cover "Duel::Runner*"

  def test_what_a_run_keeps
    workers = FakeWorkers.new
    workers.benchmark("a") { |side, n, _| {"timed" => {"cpu" => n * ((side == "candidate") ? 110_000 : 100_000)}, "counted" => {}, "heap" => 0} }
    workers.rubies["candidate"] = "ruby 4.0.0"
    workers.profile("baseline", {"samples" => 100, "frames" => [["f", 10, 10]]})
    workers.profile("candidate", {"samples" => 110, "frames" => [["f", 20, 20]]})
    runner = Duel::Runner.new(Duel::Config.new(tmpdir), settings, File.join(tmpdir, "base"), out: (out = StringIO.new))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = stub(Duel::WorkerProcess, :new, ->(*args, **options) { workers.make(*args, **options) }) { elsewhere { runner.run } }

    assert_equal({"baseline" => RUBY_DESCRIPTION, "candidate" => "ruby 4.0.0"}, runner.rubies)
    assert_operator runner.seconds, :<=, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator runner.seconds, :>, 0
    explained = ["cpu: 100µs → 110µs an iteration (1.10x)",
      "where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):", "   +10.0%  +10.0%  f"]

    assert_equal explained, runner.explained(results.first)
    assert_includes out.string, "\nREGRESSION a: worse cpu in every measurement\n#{explained.map { |line| "  #{line}\n" }.join}"
  end
end
