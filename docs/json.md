# Read Duel's report as JSON

To read Duel's results from a program, such as a dashboard, a bot, or a
script that tracks benchmarks over time, write its report as JSON with
`--json`:

```sh
duel --json tmp/duel.json
```

The JSON report has the same results as the
[Markdown report](../README.md#report-on-a-pull-request), and more of
each: every timing's ratio, interval and verdict, each version's medians
an iteration, and every count. A relative path is relative to where
`duel` runs, and Duel makes the file's directory if it needs to. Each
run replaces the file.

Duel writes the report whatever the outcome: a comparison that passed or
failed, nothing to compare, or a comparison that couldn't run. It writes
nothing when the command line isn't valid, such as an unknown option,
and nothing for `--clean`, `--version`, or `duel init`, which aren't
comparisons. So a missing report means that `duel` didn't get as far as
comparing, or crashed.

## Versions of the schema

The report's `schema` key is the version of its schema, now `1`. A new
key can appear in any release without a new version, so ignore the keys
that you don't know. Any other change, such as a key removed or renamed,
or a value that means something else, comes with a new version. Check
`schema` before you read the rest, and stop if it isn't one that you
know.

The report uses only plain JSON types: objects, arrays, strings, numbers,
`true`, `false`, and `null`. Numbers are numbers, never strings. A key
that doesn't apply, such as a skipped benchmark's `iterations`, is
`null`, not missing, so every object of a kind has the same keys.

## An example

A run that found one regression, abridged to two benchmarks:

```json
{
  "schema": 1,
  "duel_version": "0.1.0",
  "status": "failed",
  "exit": 1,
  "message": null,
  "settings": {
    "confidence": 0.99,
    "limit": 1.02,
    "filter": "",
    "jobs": 4,
    "processes": 3,
    "timeout": 60.0,
    "warm": null,
    "force": false
  },
  "seconds": 14.2,
  "baseline": {
    "ref": "origin/main",
    "commit": "3f9c2a1d5e8b7c6a4f3e2d1c0b9a8f7e6d5c4b3a",
    "root": "/home/runner/work/my_parser/.3f9c2a1b",
    "ruby": "ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [x86_64-linux]"
  },
  "candidate": {
    "commit": "8e4d0b7f1a2c3e4d5b6a7f8e9d0c1b2a3f4e5d6c",
    "uncommitted_changes": false,
    "root": "/home/runner/work/my_parser/my_parser",
    "ruby": "ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [x86_64-linux]"
  },
  "plugins": [],
  "benchmarks": [
    {
      "name": "parse: a large document",
      "verdict": "regressed",
      "passed": false,
      "regressed": ["instructions", "cpu", "allocations"],
      "unsettled": false,
      "iterations": 9,
      "seconds": 3.1,
      "confirmations": 3,
      "timed": {
        "instructions": {
          "ratio": 1.071,
          "interval": [1.069, 1.073],
          "limit": 1.01,
          "pairs": 10,
          "verdict": "slower",
          "baseline": 1521000.0,
          "candidate": 1629000.0,
          "unit": null,
          "plural": null,
          "across": true
        },
        "cpu": {
          "ratio": 1.081,
          "interval": [1.062, 1.097],
          "limit": 1.02,
          "pairs": 10,
          "verdict": "slower",
          "baseline": 112400.0,
          "candidate": 121500.0,
          "unit": "ns",
          "plural": "ns",
          "across": true
        }
      },
      "counted": {
        "allocations": {
          "baseline": 5790.0,
          "candidate": 5791.0,
          "unit": null,
          "plural": null,
          "worse": true
        }
      },
      "peak_memory": null,
      "details": {},
      "explanation": [
        "instructions: 1.521e+06 → 1.629e+06 an iteration (1.07x)",
        "cpu: 112.4µs → 121.5µs an iteration (1.08x)",
        "allocations: 5790 → 5791 an iteration",
        "where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
        "   +6.8%   +7.1%  MyParser::Lexer#next_token"
      ],
      "error": null,
      "skipped": null
    },
    {
      "name": "parse: an empty document",
      "verdict": "same",
      "passed": true,
      "regressed": [],
      "unsettled": false,
      "iterations": 2400,
      "seconds": 0.8,
      "confirmations": 0,
      "timed": {
        "cpu": {
          "ratio": 1.002,
          "interval": [0.994, 1.009],
          "limit": 1.02,
          "pairs": 10,
          "verdict": "same",
          "baseline": 410.5,
          "candidate": 411.2,
          "unit": "ns",
          "plural": "ns",
          "across": true
        }
      },
      "counted": {
        "allocations": {
          "baseline": 3.0,
          "candidate": 3.0,
          "unit": null,
          "plural": null,
          "worse": false
        }
      },
      "peak_memory": null,
      "details": {},
      "explanation": [],
      "error": null,
      "skipped": null
    }
  ],
  "across": {
    "cpu": {
      "ratio": 1.004,
      "interval": [0.998, 1.012],
      "limit": 1.005,
      "benchmarks": 12,
      "verdict": "undecided",
      "confirmed": false
    }
  },
  "errors": []
}
```

A run with nothing to compare has the same keys, with nothing compared:

```json
{
  "schema": 1,
  "duel_version": "0.1.0",
  "status": "nothing_to_compare",
  "exit": 0,
  "message": "duel: lib, ext unchanged since the baseline, so there's nothing to compare (--force to anyway)",
  "settings": {"confidence": 0.99, "limit": 1.02, "filter": "", "jobs": 4, "processes": 3, "timeout": 60.0, "warm": null, "force": false},
  "seconds": null,
  "baseline": null,
  "candidate": null,
  "plugins": [],
  "benchmarks": [],
  "across": {},
  "errors": []
}
```

For example, to list the benchmarks that regressed, with
[jq](https://jqlang.org):

```sh
jq -r '.benchmarks[] | select(.verdict == "regressed") | .name' tmp/duel.json
```

## The report

| Key | What it is |
|---|---|
| `schema` | The schema's version: `1`. |
| `duel_version` | The version of Duel that wrote the report. |
| `status` | `"passed"`, `"failed"`, `"nothing_to_compare"`, or `"error"` (Duel couldn't compare). |
| `exit` | The exit status of `duel`: `0` for passed or nothing to compare, `1` for failed, `2` for an error. |
| `message` | What Duel said, for nothing to compare or an error, such as `"duel: no release tag (v*) before HEAD to compare against"`. Otherwise `null`. |
| `settings` | The settings that the run used (see below). |
| `seconds` | How long the comparison took. `null` without a comparison. |
| `baseline`, `candidate` | The two versions (see below). `null` without a comparison. |
| `plugins` | The names of the plugins in use, such as `["rails", "activerecord"]`. |
| `benchmarks` | Every benchmark compared, in the order Duel found them (see below). |
| `across` | The verdicts across the board, by metric (see below). |
| `errors` | The benchmarks that failed, each as `{"benchmark": name, "message": error}`. |

A run fails when a benchmark regressed, a benchmark failed, or a metric
was slower across the board and confirmed (`"confirmed": true`).

### Settings

| Key | What it is |
|---|---|
| `confidence` | The confidence of each interval, such as `0.99`. |
| `limit` | The ratio above which a timing is slower (`--limit`). A metric can have its own limit, which its timings show. |
| `filter` | The regular expression that picked the benchmarks (`--filter`), as source. `""` matches every one. |
| `jobs` | Benchmarks measured at once (`--jobs`). |
| `processes` | Worker processes for each version (`--processes`). |
| `timeout` | The seconds that a worker may take to load or to answer (`--timeout`). |
| `warm` | The seconds of warm-up for each benchmark (`--warm`), or `null` for the default, which depends on the Ruby. |
| `force` | Whether `--force` was given. |

### The versions

| Key | What it is |
|---|---|
| `ref` | The baseline's git ref: the one `--base` named, the release tag for `--base last-release`, or the main branch, such as `"origin/main"`, by default, where the baseline is the commit where `HEAD` left that branch. `null` for a baseline directory. |
| `commit` | The full hash of the commit compared. `null` for a baseline directory, or for a candidate outside a git repository. |
| `uncommitted_changes` | The candidate only: whether what `c.watch` names has changes that aren't committed. `null` outside a git repository. |
| `root` | The tree that was compared, as an absolute path. |
| `ruby` | The version's Ruby, as its `RUBY_DESCRIPTION`. |

### Benchmarks

| Key | What it is |
|---|---|
| `name` | The benchmark's name. |
| `verdict` | `"regressed"`, `"error"`, `"unsettled"` (a timing too close to its limit to settle), `"faster"`, `"changed"` (a count changed), `"skipped"`, or `"same"`, as in the Markdown report's table. |
| `passed` | Whether it regressed on nothing and didn't fail. |
| `regressed` | The metrics that it regressed on, in every measurement, such as `["cpu", "allocations"]`. Peak memory is `"peak_memory"`. |
| `unsettled` | Whether a timing was too close to its limit to settle. |
| `iterations` | The iterations in each sample. `null` for a benchmark that failed or was skipped. |
| `seconds` | How long its first measurement took. `null` for a benchmark that failed or was skipped. |
| `confirmations` | How many times it was measured again, from scratch, because it looked worse. |
| `timed` | Its timings, by metric (see below). |
| `counted` | Its counts, by metric (see below). |
| `peak_memory` | Each version's peak memory, as `{"baseline": bytes, "candidate": bytes, "unit": "B", "worse": true or false}`, for a benchmark that measures it. Otherwise `null`. |
| `details` | What metrics said of the last samples, by metric and then by version, such as `{"allocations": {"baseline": "2 String", "candidate": "3 String"}}`. |
| `explanation` | For a regression, the lines that explain it, as the terminal report and the Markdown report show them. Otherwise `[]`. |
| `error` | Why it failed, with any backtrace. Otherwise `null`. |
| `skipped` | Why it was skipped, such as a benchmark that isn't on the baseline. Otherwise `null`. |

Each timing in `timed`, such as `cpu`:

| Key | What it is |
|---|---|
| `ratio` | The median of the paired ratios, the candidate's to the baseline's. Above 1 is the candidate slower. |
| `interval` | The confidence interval for that median, as `[low, high]`. |
| `limit` | The ratio above which it's slower. |
| `pairs` | The pairs of samples measured. |
| `verdict` | `"slower"`, `"faster"`, `"same"`, or `"undecided"` (too close to the limit to settle). |
| `baseline`, `candidate` | Each version's median for one iteration, in `unit`. |
| `unit`, `plural` | The metric's unit, singular and plural, such as `"ns"`, or `null` for a plain number. |
| `across` | Whether it counts across the board. |

Each count in `counted`, such as `allocations`:

| Key | What it is |
|---|---|
| `baseline`, `candidate` | Each version's fewest for one iteration, in `unit`. |
| `unit`, `plural` | The metric's unit, singular and plural, such as `"query"` and `"queries"`, or `null` for a plain number. |
| `worse` | Whether the candidate's count is worse, by more than the metric tolerates. |

### Across the board

Each metric in `across`, such as `cpu`:

| Key | What it is |
|---|---|
| `ratio` | The median of every benchmark's ratio. |
| `interval` | The confidence interval for that median, as `[low, high]`, or `null` with too few benchmarks to tell. |
| `limit` | The ratio above which it's slower across the board. |
| `benchmarks` | The benchmarks that it's from. |
| `verdict` | `"slower"`, `"faster"`, `"same"`, or `"undecided"`. |
| `confirmed` | Whether it was slower again when every benchmark was measured a second time, which fails the run. |
