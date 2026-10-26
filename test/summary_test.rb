# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_workers"

# A run's report in Markdown (see Duel::Summary), from whole runs with
# their worker processes faked.
class SummaryTest < DuelTest
  cover "Duel::Summary*"

  def candidate = File.join(tmpdir, "candidate")

  # A run of +workers+, and its Markdown (the run taking 12.4 seconds).
  def summarize(workers, baseline: BASELINE, candidate: "def5678", **overrides)
    runner = Duel::Runner.new(Duel::Config.new(self.candidate), settings(**overrides), File.join(tmpdir, "base"), out: StringIO.new)
    results = elsewhere { runner.run }
    runner.instance_variable_set(:@seconds, 12.4)
    Duel::Summary.new(runner, results, settings: settings(**overrides), baseline: baseline, candidate: candidate).markdown
  end

  # The baseline, as CLI describes it: its commit bare, so GitHub links
  # it.
  BASELINE = "abc1234 (where HEAD left `main`)"

  # How Duel decides, as the report's details end.
  DECIDES = "A timing is slower when a 99.0% confidence interval for its ratio, the candidate's to the baseline's, is above 1.02. " \
    "[How Duel decides](https://github.com/sferik/duel-ruby/blob/main/docs/how-it-works.md#how-duel-tells-a-regression-from-noise)"

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
    Duel::Summary.new(runner, results, settings: settings(**overrides), baseline: BASELINE, candidate: "def5678").markdown
  end

  # A result made by hand: +timed+ ({metric => verdict}, each with a
  # ratio of +median+) and +counted+ ({metric => [baseline, candidate]},
  # of one iteration).
  def result(name, timed: {"cpu" => "same"}, counted: {}, median: 1.0)
    Duel::Result.new(name).tap do |r|
      r.n = 1
      timed.each do |metric, verdict|
        r.timed[metric] = {"median" => median, "interval" => [0.99, 1.01], "verdict" => verdict, "baseline" => 1000, "candidate" => 1000,
                           "unit" => "ns", "plural" => "ns", "limit" => 1.02, "across" => true}
      end
      counted.each do |metric, (base, candidate)|
        r.counted[metric] = {"baseline" => base, "candidate" => candidate, "n" => 1, "tolerance" => 0, "allowance" => 0, "unit" => nil,
                             "plural" => nil}
      end
    end
  end

  def errored(name, error) = Duel::Result.new(name).tap { |r| r.error = error }

  def skipped(name) = Duel::Result.new(name).tap { |r| r.skipped = "not on the baseline (NameError: no)" }

  # A run with something of everything: the verdict, the versions, and
  # what failed in view, and the rest collapsed: each regression
  # explained, every benchmark, failing ones first, what unsettled means,
  # and how Duel decides.
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
      workers.profile("baseline", {"samples" => 100, "frames" => [["f", 10, 10], ["g", 5, 5]]})
      workers.profile("candidate", {"samples" => 110, "frames" => [["f", 20, 20], ["g", 6, 6]]})

      assert_equal <<~MARKDOWN, summarize(workers)
        ### 🔻 Duel: 2 benchmarks failed, 1 skipped

        Compared def5678 with abc1234 (where HEAD left `main`). The baseline can't run the skipped benchmark.

        | Benchmark | Failure | Most extra CPU in |
        |---|---|---|
        | `slow: work` | cpu +10.0%, allocations 2 → 3 | `f` +10.0% |
        | `broken` | error: `Duel::Failed: candidate-1: RuntimeError: oops` |  |

        <details>
        <summary>Details: 8 benchmarks in 12s, 1 unsettled</summary>

        **`slow: work`**: worse cpu, allocations in every measurement

        ```text
        cpu: 100µs → 110µs an iteration (1.10x)
        allocations: 2 → 3 an iteration
        allocations (candidate): 3 String
        allocations (baseline): 2 String
        where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):
           +10.0%  +10.0%  f
            +1.0%   +1.0%  g
        ```

        | Benchmark | Verdict | Timings (ratio [interval]) | Counts an iteration |
        |---|---|---|---|
        | `slow: work` | **regressed** | cpu 1.100 [1.100, 1.100] slower | allocations 2 → 3 |
        | `broken` | **error** |  |  |
        | `close: call` | unsettled | cpu 1.020 [1.020, 1.020] undecided |  |
        | `fast: work` | faster | cpu 0.900 [0.900, 0.900] faster |  |
        | `fewer: allocations` | changed | cpu 1.000 [1.000, 1.000] | allocations 3 → 2 |
        | `new` | skipped | not on the baseline (baseline-1: NameError: no) |  |
        | `same: one` | same | cpu 1.000 [1.000, 1.000] |  |
        | `same: two` | same | cpu 1.000 [1.000, 1.000] |  |

        An unsettled timing was too close to the limit to settle. It doesn't fail the run, but one that's unsettled in run after run is noisy.

        #{DECIDES}

        </details>
      MARKDOWN
    end
  end

  # Nothing slower: a heading that says so, the versions, and the rest
  # collapsed, with the settings' limit and confidence.
  def test_a_run_that_passed
    with_fake_workers do |workers|
      workers.benchmark("a", &measures)
      workers.benchmark("b", &measures)

      assert_equal <<~MARKDOWN, summarize(workers, limit: 1.05, confidence: 0.95)
        ### 🟢 Duel: 100% of benchmarks passed

        Compared def5678 with abc1234 (where HEAD left `main`).

        <details>
        <summary>Details: 2 benchmarks in 12s</summary>

        | Benchmark | Verdict | Timings (ratio [interval]) |
        |---|---|---|
        | `a` | same | cpu 1.000 [1.000, 1.000] |
        | `b` | same | cpu 1.000 [1.000, 1.000] |

        A timing is slower when a 95.0% confidence interval for its ratio, the candidate's to the baseline's, is above 1.05. [How Duel decides](#{Duel::Summary::DECIDES})

        </details>
      MARKDOWN
    end
  end

  # A note (an accepted regression's, say) goes under the heading.
  def test_a_note
    with_fake_workers do |workers|
      workers.benchmark("a", &measures)
      runner = Duel::Runner.new(Duel::Config.new(candidate), settings, File.join(tmpdir, "base"), out: StringIO.new)
      results = elsewhere { runner.run }
      markdown = Duel::Summary.new(runner, results, settings: settings, baseline: BASELINE, candidate: "def5678", note: "Accepted.").markdown

      assert markdown.start_with?("### 🟢 Duel: 100% of benchmarks passed\n\nAccepted.\n\nCompared def5678 with ")
    end
  end

  # A timing too close to call doesn't fail the run: it's only in the
  # details, which say what it means.
  def test_a_run_that_passed_unsettled
    markdown = summary([result("close", timed: {"cpu" => "undecided"}, median: 1.02), result("a")])

    assert_equal <<~MARKDOWN, markdown
      ### 🟢 Duel: 100% of benchmarks passed

      Compared def5678 with abc1234 (where HEAD left `main`).

      <details>
      <summary>Details: 2 benchmarks in 1s, 1 unsettled</summary>

      | Benchmark | Verdict | Timings (ratio [interval]) |
      |---|---|---|
      | `close` | unsettled | cpu 1.020 [0.990, 1.010] undecided |
      | `a` | same | cpu 1.000 [0.990, 1.010] |

      An unsettled timing was too close to the limit to settle. It doesn't fail the run, but one that's unsettled in run after run is noisy.

      #{DECIDES}

      </details>
    MARKDOWN
  end

  # One benchmark failed (and "benchmark", not "benchmarks"), without a
  # profile to point to: no column for one.
  def test_one_failed
    markdown = summary([result("slow", timed: {"cpu" => "slower"}, median: 1.0456), result("a")])

    assert_equal "### 🔻 Duel: 1 benchmark failed\n\nCompared def5678 with abc1234 (where HEAD left `main`).\n\n" \
      "| Benchmark | Failure |\n|---|---|\n| `slow` | cpu +4.6% |\n\n<details>\n<summary>Details: 2 benchmarks in 1s</summary>\n\n" \
      "**`slow`**: worse cpu in every measurement\n\n```text\ncpu: 1µs → 1µs an iteration (1.05x)\n```\n\n", markdown.split("| Benchmark | Verdict").first
  end

  # Several failed: each in the table, in view, regressions first.
  def test_several_failed
    markdown = summary([errored("e", "boom"), result("s1", timed: {"cpu" => "slower"}, median: 1.1), result("a"),
      result("s2", timed: {"cpu" => "slower"}, median: 1.2)])

    assert_equal "### 🔻 Duel: 3 benchmarks failed\n", markdown.lines.first
    assert_includes markdown, "\n\n| Benchmark | Failure |\n|---|---|\n| `s1` | cpu +10.0% |\n| `s2` | cpu +20.0% |\n" \
      "| `e` | error: `boom` |\n\n<details>\n"
  end

  # A benchmark that failed with an error: its first line in view, and
  # one of more lines whole in the details, before the table.
  def test_errored
    one = summary([errored("a|b", "Duel::Failed: no | yes\n")])

    assert_equal "### 🔻 Duel: 1 benchmark failed\n\nCompared def5678 with abc1234 (where HEAD left `main`).\n\n| Benchmark | Failure |\n" \
      "|---|---|\n| `a\\|b` | error: `Duel::Failed: no \\| yes` |\n\n<details>\n<summary>Details: 1 benchmark in 1s</summary>\n\n" \
      "| Benchmark | Verdict | Timings (ratio [interval]) |\n|---|---|---|\n| `a\\|b` | **error** |  |\n\n#{DECIDES}\n\n</details>\n", one
    two = summary([errored("a", "first\nsecond"), errored("b", "only")])

    assert_includes two, "| `a` | error: `first` |\n| `b` | error: `only` |\n\n"
    assert_includes two, "<summary>Details: 2 benchmarks in 1s</summary>\n\n**`a`**\n\n```text\nfirst\nsecond\n```\n\n| Benchmark | Verdict"
  end

  # Benchmarks the baseline can't run are skipped, which fails nothing.
  def test_skipped
    markdown = summary([result("a"), skipped("new"), skipped("newer")])

    assert_equal "### 🟢 Duel: 100% of benchmarks passed, 2 skipped\n\nCompared def5678 with abc1234 (where HEAD left `main`). " \
      "The baseline can't run the skipped benchmarks.\n\n<details>\n", markdown.lines.first(5).join
    assert_includes markdown, "| `new` | skipped | not on the baseline (NameError: no) |\n"
    assert_equal "### ⬜ Duel: no benchmarks compared, 1 skipped\n", summary([skipped("new")]).lines.first, "nothing but skipped"
    assert_includes summary([skipped("new")]), "The baseline can't run the skipped benchmark.\n"
  end

  # None at all (a filter that matched none, say).
  def test_no_benchmarks
    assert_equal "### ⬜ Duel: no benchmarks compared\n\nCompared def5678 with abc1234 (where HEAD left `main`).\n\n<details>\n" \
      "<summary>Details: 0 benchmarks in 1s</summary>\n\n#{DECIDES}\n\n</details>\n", summary([])
  end

  # A little slower at every benchmark: across the board, in view.
  def test_slower_across_the_board
    with_fake_workers do |workers|
      Array.new(8) { |i| workers.benchmark("b#{i}", &measures(cpu: [100_000, 101_000])) }
      markdown = summarize(workers)

      assert_equal "### 🔻 Duel: slower across the board in cpu\n", markdown.lines.first
      assert_includes markdown, "(where HEAD left `main`).\n\nAcross the board:\n\n- cpu 1.010 [1.010, 1.010] slower in both " \
        "measurements (limit 1.0050, 8 benchmarks)\n\n<details>\n<summary>Details: 8 benchmarks in 12s</summary>\n"
      assert_equal 1, markdown.scan("Across the board").size, "not in the details too"
    end
  end

  # Across the board: only the metrics with enough benchmarks to tell,
  # those not confirmed slower in the details.
  def test_across_the_board
    across = {"cpu" => {"median" => 1.0, "interval" => [0.998, 1.002], "limit" => 1.005, "benchmarks" => 8, "verdict" => "same"},
              "few" => {"median" => 1.0, "interval" => nil, "limit" => 1.005, "benchmarks" => 2, "verdict" => "undecided"},
              "wait" => {"median" => 1.01, "interval" => [1.006, 1.02], "limit" => 1.005, "benchmarks" => 1, "verdict" => "slower",
                         "confirmed" => false},
              "gc" => {"median" => 1.01, "interval" => [1.006, 1.02], "limit" => 1.005, "benchmarks" => 9, "verdict" => "slower",
                       "confirmed" => true}}
    markdown = summary([result("a")], runner: runner(across: across))

    assert_equal "### 🔻 Duel: 1 benchmark failed, slower across the board in gc\n", summary([errored("e", "x")], runner: runner(across: across)).lines.first
    assert_includes markdown, "abc1234 (where HEAD left `main`).\n\nAcross the board:\n\n- gc 1.010 [1.006, 1.020] slower in both measurements " \
      "(limit 1.0050, 9 benchmarks)\n\n<details>\n"
    assert_includes markdown, "\n\nAcross the board:\n\n- cpu 1.000 [0.998, 1.002] same (limit 1.0050, 8 benchmarks)\n" \
      "- wait 1.010 [1.006, 1.020] slower (limit 1.0050, 1 benchmark)\n\n#{DECIDES}\n"
    both = across.merge("cpu" => across.fetch("gc"))

    assert_equal "### 🔻 Duel: slower across the board in cpu, gc\n", summary([result("a")], runner: runner(across: both)).lines.first
    quiet = summary([result("a")], runner: runner(across: across.slice("few")))

    assert_equal "### 🟢 Duel: 100% of benchmarks passed\n", quiet.lines.first
    refute_includes quiet, "Across"
  end

  # Each version's Ruby, where they differ, in the details.
  def test_rubies
    markdown = summary([result("a")], runner: runner(rubies: {"baseline" => "ruby 3.4", "candidate" => "ruby `4.0`"}))

    assert_includes markdown, "\n\nBaseline on `ruby 3.4`, candidate on `` ruby `4.0` ``.\n\n#{DECIDES}\n"
    refute_includes summary([result("a")]), "Baseline on"
  end

  # Not the plugins used.
  def test_plugins
    refute_includes summary([result("a")], runner: runner(plugins: %i[rails activerecord])), "rails"
  end

  def test_seconds_and_confidence
    markdown = summary([result("a")], runner: runner(seconds: 61.6), confidence: 0.9994)

    assert_includes markdown, "<summary>Details: 1 benchmark in 62s</summary>"
    assert_includes markdown, "\n\nA timing is slower when a 99.9% confidence interval"
  end

  # What got worse, in view: a timing by how much slower, a count an
  # iteration, peak memory, and one of some timings (slower in each
  # measurement by one or another).
  def test_failures
    counted = result("counted", counted: {"allocations" => [4, 5]})
    counted.counted.fetch("allocations")["n"] = 2
    memory = result("memory", timed: {})
    memory.memory = {"baseline" => 1 << 20, "candidate" => 3 << 20}
    mixed = result("mixed", timed: {"cpu" => "slower", "instructions" => "undecided"}, median: 1.031)
    mixed.confirmations << result("again", timed: {"cpu" => "undecided", "instructions" => "slower"})
    markdown = summary([counted, memory, mixed])

    assert_includes markdown, "| Benchmark | Failure |\n|---|---|\n| `counted` | allocations 2 → 2.5 |\n| `memory` | peak_memory 1.0MB → 3.0MB |\n" \
      "| `mixed` | cpu +3.1% or instructions +3.1% |\n\n"
  end

  # Where a regression's extra CPU went most, from its profile: none
  # where it's unavailable, or grew nowhere.
  def test_profiles
    profiled = result("profiled", timed: {"cpu" => "slower"})
    profiled.profile = {"grew" => [["A#b|c", 0.0512, 0.06], ["d", 0.01, 0.01]], "gc" => 0.0, "baseline" => {}, "candidate" => {}}
    unavailable = result("unavailable", timed: {"cpu" => "slower"})
    unavailable.profile = {"unavailable" => "no stackprof"}
    nowhere = result("nowhere", timed: {"cpu" => "slower"})
    nowhere.profile = {"grew" => [], "gc" => 0.01, "baseline" => {}, "candidate" => {}}

    assert_includes summary([profiled, unavailable, nowhere, errored("e", "x")]), "| Benchmark | Failure | Most extra CPU in |\n|---|---|---|\n" \
      "| `profiled` | cpu +0.0% | `A#b\\|c` +5.1% |\n| `unavailable` | cpu +0.0% |  |\n| `nowhere` | cpu +0.0% |  |\n" \
      "| `e` | error: `x` |  |\n\n"
    assert_includes summary([unavailable, nowhere]), "| Benchmark | Failure |\n|---|---|\n"
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
    assert_includes markdown, "</summary>\n\n**`mixed`**: slower in every measurement, by one of cpu, instructions\n\n```text\n" \
      "cpu: 1µs → 1µs an iteration (1.00x)\ninstructions: 1µs → 1µs an iteration (1.00x)\n```\n\n" \
      "**`memory`**: worse peak_memory in every measurement\n\n| Benchmark | Verdict"
    explained = markdown.size
    one = with_constants(Duel::Summary, LIMIT: explained - 1) { summary([mixed, memory]) }

    assert_includes one, "</summary>\n\n**`mixed`**: slower in every measurement, by one of cpu, instructions\n\n```text\n"
    assert_includes one, "```\n\n1 more regression explained in the job's log.\n\n| Benchmark | Verdict"
    refute_includes one, "**`memory`**"
    none = with_constants(Duel::Summary, LIMIT: 10) { summary([mixed, memory]) }

    assert_includes none, "</summary>\n\n2 regressions explained in the job's log.\n\n| Benchmark | Verdict"
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
      "| `a` | faster | cpu 1.000 [0.990, 1.010] faster<br>instructions 1.000 [0.990, 1.010] |\n"
  end

  # A name, or why it was skipped, that would break a table's row.
  def test_cells
    r = result("a|b\nc|d")
    skipped = Duel::Result.new("new").tap { |s| s.skipped = "not on the baseline (x | y\nz)" }
    markdown = summary([r, skipped])

    assert_includes markdown, "| `a\\|b c\\|d` | same | cpu 1.000 [0.990, 1.010] |\n"
    assert_includes markdown, "| `new` | skipped | not on the baseline (x \\| y z) |\n"
  end

  # An error's first ERROR_LINES lines (a backtrace's, say), fenced off.
  def test_long_errors
    r = errored("a", Array.new(15) { |i| "line #{i}\n" }.join + "```\n")
    shown = Array.new(12) { |i| "line #{i}" }.join("\n")

    assert_includes summary([r]), "</summary>\n\n**`a`**\n\n```text\n#{shown}\n```\n(4 more lines in the job's log)\n\n| Benchmark"
    r.error = "x\n" * 13

    assert_includes summary([r]), "\n```\n(1 more line in the job's log)\n"
    r.error = "x\n" * 12
    other = errored("b", "y\nz")

    assert_includes summary([r, other]), "</summary>\n\n**`a`**\n\n```text\n#{"x\n" * 12}```\n\n**`b`**\n\n```text\ny\nz\n```\n\n| Benchmark",
      "each, all of it"
  end

  def test_code
    assert_equal ["`a`", "``a`b``", "```a``b ```", "`` `a ``", "`` a` ``", "` `", "```a`b``c`d```"],
      ["a", "a`b", "a``b ", "`a", "a`", " ", "a`b``c`d"].map { |text| Duel::Summary.code(text) }
  end

  def test_block
    assert_equal ["```text\na\n```", "```text\na\n```", "````text\n```\n````", "`````text\n````\n`````", "``````text\n````` ```\n``````"],
      ["a", "a\n", "```", "````", "````` ```"].map { |text| Duel::Summary.block(text) }
  end

  def test_escape
    assert_equal "a \\\\ \\` \\* \\_ \\[ \\] \\< \\> \\| \\~ \\& \\# (b) c.d -e! f/g",
      Duel::Summary.escape("a \\ ` * _ [ ] < > | ~ & # (b) c.d -e! f/g")
  end

  # A run that didn't compare: a heading of its own, and why, in a line
  # (with the whole of a longer reason collapsed).
  def test_note
    assert_equal "### ⬜ Duel: nothing to compare\n\nlib, ext unchanged (v\\*)\n", Duel::Summary.note("⬜", "nothing to compare", "lib, ext unchanged (v*)")
    assert_equal "### 🔻 Duel: couldn't compare\n\nbuilding failed:\n\n<details>\n<summary>The whole message</summary>\n\n" \
      "```text\nbuilding failed:\nmake: *** no\n```\n\n</details>\n", Duel::Summary.note("🔻", "couldn't compare", "building failed:\nmake: *** no\n")
    assert_equal "### ⬜ Duel: x\n\ny\n", Duel::Summary.note("⬜", "x", "y\n"), "a line, ended"
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
