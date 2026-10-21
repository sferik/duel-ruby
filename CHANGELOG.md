# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-22

The first release. Duel is open source under the MIT license, and
needs Ruby 3.4 or later (or JRuby 10, or TruffleRuby 40).

### Added

- `duel` and `Duel::RakeTask`: run every benchmark on a baseline (where
  HEAD left the main branch, a git ref, the last release tag, or a
  directory) and the candidate, side by side in worker processes of their
  own, and fail if the candidate is slower at any of them.
- Timings (CPU time, and any timed metric of a plugin's) are judged by a
  99% distribution-free confidence interval for the median of paired
  ratios, and whatever looks slower is measured again in fresh processes
  before it fails; allocations and counted metrics fail on any increase.
- Each version runs in several worker processes (three by default,
  `--processes`), paired in turn, so no one process's layout in memory
  biases a comparison.
- Instruction counts from the CPU's counters (Linux: the benchmark
  thread's; macOS: the process's), judged with a limit of their own (1%).
- Peak memory, for benchmarks that ask (`peak_memory: true`): each
  version's least in fresh workers.
- A StackProf profile of both versions with every regression in time,
  and where the extra CPU went.
- Conventions: benchmarks in `duel/**/*_duel.rb`; the gemspec's library
  required from each version; `rake compile` for a baseline of a
  project with `ext/`; the main branch from `origin/HEAD`.
- Across the board: every benchmark's median ratio, judged together, so
  a slowdown too small for any one benchmark still fails.
- A worker that doesn't load or answer within `--timeout` (60s) is
  killed, and its benchmark is an error; samples are held to 64 MB of
  allocations while the garbage collector is held off; `duel --clean`.
- `duel "name" do ... end`, in files named `*_duel.rb`, defines a
  benchmark: its block is timed, run as many times as a sample needs
  (or, given `|n|`, once a sample for n iterations); `setup { }` in it
  runs once, untimed, before anything's measured, and `untimed { }`
  pauses measuring. `setup` and `teardown` at the top of a file run in
  each worker around each of its duels. `only: :count` (work that's
  mostly waiting) or `only: :timing` (work on threads of its own)
  narrows what it's judged on, and `peak_memory: true` adds its peak
  memory. `.duel.rb` covers what the conventions don't: building,
  loading, per-worker resources and metrics of your own, which together
  make a plugin (a `duel-*` gem whose `install` takes the configuration,
  by convention). Nothing else is built in.
- Resources (`c.resource { |r| ... }`) get a `Duel::Resource`: a
  directory of the worker's own, `spawn` (logged there, and stopped with
  the worker, by its `stop_signal:`), `run`, `wait_until` (failing if a
  process exits, or after `--timeout`), `failed`, `at_stop`, and the
  version's `root`; the block returns the worker's environment, and two
  resources that set a variable differently fail.
- Metrics of running totals: `c.metric("name") { total }`, or several
  by their settings, and a sample measures what they grew by, less what
  reading a counted one adds to it (learned in each worker, unless
  `calibrate: false`). A `Duel::Metric` subclass covers the rest: its
  `measures` name what it measures, with their settings; its `start`
  gets the sample (`n`, `benchmark`), and it can `pause` and `resume`
  around `untimed` blocks its own way.
- Settings for metrics: `floor` (on either version), `limit`, `unit_ns`,
  `sizes_samples`, `tolerance` (per iteration) and `allowance` (per
  sample); `c.measure(name, ...)` changes any measure's, Duel's own
  too, or skips it. Two metrics that measure the same name fail.
- `c.worker { |w| }`: set-up that runs only in workers, once the
  benchmarks have loaded; what it gives `w.at_stop` runs when the
  worker ends. `c.per_worker { |w| }` makes something in each (a
  connection, say) and returns a handle whose `value` is the worker's.
- `r.cached(key) { |dir| }`: what a resource builds once, for every
  worker of a run and later runs (a database's initial files, say).
- A run's workers, and their resources, start at once and stop at once.
- A regression is explained an iteration, on each version
  (`cpu: 112.4µs → 121.5µs an iteration`), with what its metric says of
  it (`Metric#details`); results carry each version's raw medians.
- `unit:` for a measure (a time unit shows it as time, and gives
  `unit_ns`); settings there aren't, and kinds there aren't, fail;
  `Metric#settings` has a metric's settings after `c.measure`'s changes,
  every one filled in; running totals' `details { |stretches, sample| }`
  explains them, and their block can return `[totals, context]` to pass
  the context on (typed, with Steep); `Reading#total`; units show with
  regressions, and on the summary line unless the measure's name ends
  in them; `Duel::Testing.measure` returns what
  metrics said (`#details`) with what they measured.
- `kind: :ratio` (judged by paired ratios, as CPU time is) and
  `:counted`; `cpu_floor:` (a floor that's a share of CPU time) and
  `across: false` (not judged across the board).
- `duel/testing`: `Duel::Testing.resources`, `measure`, `worker`,
  `metrics`, `compare` and `project`, for plugins' tests.
- The candidate is built (`c.build`) before every run, as a baseline is,
  so a stale or missing build never decides a comparison.
- `--base` takes a git ref or a directory (a tree on disk, already
  built).
- `Metric#setting(:allowance)`, for a metric of one measure, and
  `Metric#within?(more, n)` (and `Metric.within?`): whether a count is
  within its tolerance and allowance, as Duel judges it.
- A unit that's a word comes with its plural (`unit: %w[row rows]`: 1
  row, 2 rows); a symbol (`"B"`) is one String.
- `Duel.measuring?`: whether a benchmark is being measured right now
  (not in setup or `untimed`), and `Duel.unmeasured!(name)`, for a
  plugin's helper to fail where what it does would be counted.
- Running totals are typed from their block (Integer totals stay
  Integer), and `Duel::Testing.measure` ends the worker it starts.
- `DUEL_BASE`, `DUEL_FILTER` and `DUEL_FORCE` set `--base`, `--filter`
  and `--force` where options are hard to pass (behind a rake task, or
  in a CI expression).
- Mutation tested: mutant kills every change to Duel's code, in CI.
- RBS signatures in sig/, checked with Steep.
- The public API is what the README documents; anything marked
  `@api private`, in lib/ and sig/, may change in any release.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/v0.1.0
