# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A change to only the benchmarks or the configuration is compared. Duel
  watches what decides how the code is measured, as well as the code
  that `c.watch` names: the benchmarks' directory (`c.benchmarks` up to
  its first wildcard, `duel/` by default), the configuration's file
  (`.duel.rb`), and, with `c.ruby = :version_file`, the version files at
  the project's root. Each version runs the candidate's benchmarks and
  configuration, so such a change compares the code with itself, which
  checks that they run and pass, where before Duel passed saying there
  was nothing to compare. "Nothing to compare" messages, and the
  candidate's `uncommitted_changes` in JSON, cover them too.
- The Markdown report (`--markdown`, the job's summary and the pull
  request comment) is shorter. Its heading starts with 🟢 when every
  benchmark passed (`🟢 Duel: 100% of benchmarks passed`), 🟥 when one
  failed or Duel couldn't compare (`🟥 Duel: 3 benchmarks failed`), and
  ⚪ when there's nothing to compare. One line names the two commits,
  bare, so GitHub links them, and how the baseline was chosen. Only the
  benchmarks that failed are in view, in a table of what got worse and
  by how much, or the error, and where the most extra CPU time went.
  Everything else is collapsed, and the report no longer names the
  plugins or explains how Duel decides outside the collapsed details.
  The terminal and JSON reports are unchanged.

### Security

- The workflow that `duel init` writes no longer gives the job that runs
  a pull request's code the `pull-requests: write` permission. The Duel
  job only reads (`contents: read`, and its checkout keeps no
  credentials), and keeps the report as an artifact for a day. A
  Comment job of its own, which checks nothing out and runs none of the
  pull request's code, downloads the report and comments with it, for a
  pull request from the same repository.

### Fixed

- With `c.ruby = :version_file`, the workflow installs the bundle for
  the baseline's Ruby too, when it differs from the candidate's. The
  baseline's workers load that bundle, and gems installed for one Ruby
  version don't load on another, so a branch that changed the Ruby's
  minor version failed before it compared anything.

- With `c.ruby = :version_file`, the workflow that `duel init` writes
  installs the baseline's Ruby for every event that compares, not only
  for a pull request. It finds the baseline that the Compare step uses
  (where HEAD left the main branch for a pull request and a manual run,
  the commit before a push, and the last release on a schedule, with
  the release tags' glob in `RELEASE_TAGS`), and installs its Ruby only
  when its `.ruby-version` names another Ruby than HEAD's. Its scripts
  take the workflow's values from environment variables, not `${{ }}`.

## [0.1.0] - 2026-10-24

The first release. Duel is open source under the MIT license, and
needs Ruby 3.4 or later (or JRuby 10, or TruffleRuby 40).

### Added

- `duel` and `Duel::RakeTask`: run every benchmark on a baseline (where
  HEAD left the main branch, a git ref, the last release tag, or a
  directory) and the candidate, side by side in worker processes of their
  own, and fail if the candidate is slower at any of them.
- `duel init`: sets Duel up in a gem or an app that isn't a Rails app.
  It writes `.duel.rb` (with `c.build` for `ext/`, and
  `c.ruby = :version_file` for a `.ruby-version`), an example benchmark
  with advice on writing good ones, and the GitHub Actions workflow in
  docs/ci.md, adds Duel's Rake task to the Rakefile, and adds
  `gem "stackprof", platforms: :mri` to the Gemfile, for profiles of
  regressions (in its `development` group, if it has one, and not if it
  mentions StackProf already). It overwrites nothing without `--force`,
  and writes nothing with `--dry-run`. The workflow compares pull
  requests, pushes, and, nightly, the last release, and comments on each
  pull request with Duel's report, updating one comment on every push.
- A report in Markdown, for a pull request. On GitHub Actions
  (`GITHUB_STEP_SUMMARY`), Duel adds it to the job's summary, and
  `--markdown PATH` writes it to a file, to post as a comment. It has the
  verdict, the two versions (and their Rubies, where they differ), a
  table of the benchmarks that changed, regressions first, with each
  timing's ratio and interval and the counts that changed, each
  regression explained as the terminal report explains it, and the
  benchmarks that were unsettled or failed. Those that didn't change are
  collapsed. A run with nothing to compare, or that couldn't compare,
  says so in Markdown too.
- `--json PATH`: writes the report as JSON, for a program to read, with
  a versioned schema (`"schema": 1`, documented in docs/json.md). It
  has the run's status and exit status, its settings, the two versions
  (each one's ref, commit, tree and Ruby), the plugins in use, and every
  benchmark: its verdict, each timing's ratio, interval, limit, pairs,
  verdict and each version's median an iteration, each count on both
  versions an iteration, peak memory, what metrics said, each
  regression's explanation, and why it failed or was skipped. Then the
  verdicts across the board, and the errors. It's written whatever the
  outcome, nothing to compare and couldn't compare included, but not for
  a command line that isn't valid.
- Timings (CPU time, and any timed metric of a plugin's) are judged by a
  99% distribution-free confidence interval for the median of paired
  ratios, and whatever looks slower is measured again in fresh processes
  before it fails. A measurement whose timings are all too close to
  call neither confirms a slowdown nor clears it, so Duel measures once
  more in its place, up to three more times. A benchmark that's slower
  in time in every measurement fails even when no one timing is slower
  in all of them (CPU time in one, instructions in the next), as long as
  none says the same or faster, after one measurement more.
  Allocations and counted metrics fail on any increase.
- Each version runs in several worker processes (three by default,
  `--processes`), paired in turn, so no one process's layout in memory
  biases a comparison.
- A git baseline is checked out next to the project, at a path as long
  and as deep as the project's, so work a version does on its own paths
  doesn't make the baseline measure slower. Duel says so when the two
  versions' paths still differ in length. A project in a subdirectory
  of its repository (a monorepo's) is compared with the same
  subdirectory of a checkout of the whole repository. Without a merge
  base with the main branch (unrelated histories, or a shallow clone),
  or in a repository without commits, Duel says why.
- The candidate is built (`c.build`) before every run, as a baseline is,
  so a stale or missing build never decides a comparison. Duel checks
  that each version's workers load only native extensions built in that
  version's tree, and fails, saying to set `c.build`, when one loads
  another version's build or an installed gem's. Gems installed in the
  project's directory (`vendor/bundle`, say) are installed gems, not
  builds.
- One run at a time in a project: a second `duel` fails, naming the
  first one's pid. The lock is an flock, so a run that crashed leaves
  nothing behind.
- With YJIT on in a worker (an app, Rails's say, may turn it on as it
  boots), each benchmark warms up for two seconds before it's measured,
  unless `--warm` says otherwise.
- Instruction counts from the CPU's counters (the benchmark thread's on
  Linux, and the process's on macOS), judged with a limit of their own
  (1%).
- Peak memory, for benchmarks that ask (`peak_memory: true`): each
  version's least in fresh workers.
- A StackProf profile of both versions with every regression in time,
  and where the extra CPU went, on CRuby with StackProf in the bundle.
  StackProf is optional, and Duel doesn't use it on JRuby or
  TruffleRuby, even where it's installed. Profiles cover what Duel measures: they
  leave out work inside `untimed` and an `around_iteration` hook's own
  work, keep what `after_iterations` does, hold the garbage collector
  off as samples do, and show what garbage collection gained on a line
  of its own, not ranked with the code. On macOS, they sample elapsed
  time, because CPU-time samples there pile up on code that makes
  system calls.
- Conventions: benchmarks in `duel/**/*_duel.rb`, the gemspec's library
  required from each version, `rake compile` for a baseline of a
  project with `ext/`, and the main branch from `origin/HEAD` (or
  `origin/main`, `origin/master`, and without a remote, `main` or
  `master`).
- Across the board: every benchmark's median ratio, judged together, so
  a slowdown too small for any one benchmark still fails. It takes 8
  benchmarks, so with fewer, the report leaves it out.
- A worker that doesn't load or answer within `--timeout` (60s) is
  killed, and its benchmark is an error. Samples are held to 64 MB of
  allocations while the garbage collector is held off. `duel --clean`
  removes what runs leave behind.
- `duel "name" do ... end`, in files named `*_duel.rb`, defines a
  benchmark: its block is timed, run as many times as a sample needs
  (or, given `|n|`, once a sample for n iterations). `once { }` in it
  runs its block once, untimed, before anything's measured, and
  `untimed { }` pauses measuring. Duel's own work in an iteration allocates nothing,
  so a benchmark that allocates nothing counts no allocations, and an
  `untimed` block adds none. `only: :count` (work that's mostly waiting)
  or `only: :timing` (work on threads of its own) narrows what it's
  judged on, and `peak_memory: true` adds its peak memory. `.duel.rb`
  covers what the conventions don't: building, loading, preparing each
  worker, and metrics of your own, which together make a plugin (a
  `duel-*` gem that `c.use` uses by name). Nothing else is built in.
- Hooks, with one set of names at every level: in `.duel.rb`
  (`c.setup { }`), at the top of a file of benchmarks (`setup { }`), and
  as an option of one benchmark (`duel "x", setup: -> { }`). They're
  `setup` and `teardown` (once in each worker, around a benchmark's
  samples), `before_sample` (before every sample, not measured, so every
  sample starts alike), `around_iteration` (around each iteration, which
  it's given to run, and which alone is measured), and
  `after_iterations` (after each sample's iterations, measured with
  them: work that they left for later, such as jobs that they
  enqueued). `.duel.rb`'s run first, then the file's, then the
  benchmark's own (teardown's in reverse, and around_iteration's nested,
  outermost first). A file's and a benchmark's own run in the
  benchmark's context. What pausing and resuming the metrics around
  each iteration leaves is learned in each worker and taken away, and
  pausing allocates nothing.
- Helpers that files of benchmarks share, in `duel/duel_helper.rb`. A
  helper named as one of the methods that Duel gives benchmarks
  (`once`, `untimed`, a hook, or a DSL method) fails the worker, naming
  its file and line.
- `duel_process "name", command` (or `ruby: code`): a benchmark of a
  whole process, booting an app or requiring a library, say. Each sample
  is the fastest of a few fresh processes for each version (as many as
  take about a second of CPU time, up to 3, or `runs:`), the versions'
  processes in turn, in its tree and with its environment, judged on its
  CPU time (its children's too) and its peak memory (with a CRuby
  runner: each version's lowest). The processes are started and
  measured by a small Ruby process of Duel's, one for each worker, that
  lasts as long as the worker, so its start-up is paid once and not for
  every process. It's judged after every pair of samples,
  and stops as soon as it's settled that it isn't slower, but it's found
  slower only after a round of 10 pairs, so stopping early can't make
  identical code look slower. It runs in no worker, so it takes none of
  `duel`'s options (a hook such as `around_iteration:`, `only:`, or
  `peak_memory:` raises an `ArgumentError`), and runs no hooks.
- `c.prepare(:worker) { |w| ... }` prepares each worker with a
  `Duel::Resource`: a directory of the worker's own, `spawn` (logged
  there, and stopped with the worker, by its `stop_signal:`), `run`,
  `wait_until` (failing if a process exits, or after `--timeout`),
  `failed`, `at_stop`, the version's `root` and `ruby`, and `env`, the
  version's environment, which the commands that it starts get under
  their own. The block returns the worker's environment, and two
  prepare blocks that set a variable differently fail.
- `c.prepare(:version) { |v| ... }`: prepares each version once for a
  run, in the runner, before its workers start (installing its bundle,
  say). It gets a `Duel::Resource` for the version and returns the
  environment that the version's workers and process benchmarks get.
- `c.ruby` and `duel --ruby`: each version's Ruby. `:version_file` (or
  `--ruby version-file`) runs each version on the Ruby that its own
  `.ruby-version`, `.tool-versions`, or `mise.toml` names, found with
  rbenv, chruby, mise, or asdf. A path, or a block given the version's
  tree, says which otherwise. A version file that asks for the Ruby that
  runs `duel` (as CI's setup step installs it, where no manager looks)
  gets that Ruby. The report shows each version's `RUBY_DESCRIPTION`
  when they differ, and a Ruby that isn't installed fails the run.
- `c.in_worker { |w| }`: set-up that runs only in workers, once the
  benchmarks have loaded. What it gives `w.at_stop` runs when the
  worker ends. It returns what the block made in each (a connection,
  say), as `value`, the worker's.
- `w.cached(key) { |dir| }`: what a prepare block builds once, for every
  worker of a run and later runs (a database's initial files, say).
- A run's workers start at once, each prepared, and stop at once.
- Metrics of running totals: `c.metric("name") { total }`, or several
  by their settings, and a sample measures what they grew by, less what
  reading a counted one adds to it (learned in each worker, unless
  `calibrate: false`). A `Duel::Metric` subclass covers the rest: its
  `measures` name what it measures, with their settings, its
  `start_sample` gets the sample (`n`, `benchmark`), and it can
  `pause_sample` and `resume_sample` around `untimed` blocks its own
  way.
- `open { }` and `close { }` on what `c.metric` returns, and `open` and
  `close` methods of a `Duel::Metric` subclass: a metric's own setup and
  teardown in each worker. `details`, `open`, `close`, and `costly`
  return the metric, to chain them.
- `costly` on what `c.metric` returns, and `self.costly?` on a
  `Duel::Metric` subclass: a metric that's costly to read (a round trip
  to a server, say) isn't paused around each iteration inside an
  `around_iteration` hook, but read only as each sample starts and
  stops. What the hook adds to it is learned in each worker, from three
  samples of 10 iterations in which it's paused around each iteration,
  and subtracted, so the hook's own work (a transaction's `BEGIN` and
  `ROLLBACK`, say) still isn't counted, and the metric measures what
  pausing would have. The plugins that read a server (duel-postgresql,
  duel-mysql, duel-redis and duel-memcached) say so.
- Settings for metrics: `floor` (on either version), `limit`, `unit_ns`,
  `sizes_samples`, `tolerance` (per iteration) and `allowance` (per
  sample). `c.measure(name, ...)` changes any measure's, Duel's own
  too, or skips it. Two metrics that measure the same name fail.
- A regression is explained an iteration, on each version
  (`cpu: 112.4µs → 121.5µs an iteration`), with what its metric says of
  it (`Metric#details`), and results carry each version's raw medians.
  Each benchmark's line shows its counts an iteration too.
- `unit:` for a measure (a time unit shows it as time, and gives
  `unit_ns`). Settings there aren't, and kinds there aren't, fail.
  `Metric#settings` has a metric's settings after `c.measure`'s changes,
  every one filled in. Running totals' `details { |stretches, sample| }`
  explains them, and their block can return `[totals, context]` to pass
  the context on (typed, with Steep). `Reading#total` reads one total.
  Units show with regressions, and on the summary line unless the
  measure's name ends in them. `Duel::Testing.measure` returns what
  metrics said (`#details`) with what they measured.
- `kind: :ratio` (judged by paired ratios, as CPU time is) and
  `:counted`, with `cpu_floor:` (a floor that's a share of CPU time) and
  `across: false` (not judged across the board).
- `c.use :redis`: uses a plugin by name. It requires `duel/redis` and
  calls the `configure` method of the module that the file registers
  with `Duel.plugin(:redis, self)`, given the configuration and the
  options. A plugin is configured once, however many times it's used, so
  a plugin that needs another (duel-rails, duel-activerecord) uses it
  too, and an app's own use of it, with options, comes first. A plugin
  that isn't in the bundle fails, naming the gem to add. The report, in
  the terminal and in Markdown, lists the plugins used. Workers load
  Duel and every Duel plugin that the runner loaded (the `duel` and
  `duel-*` gems) from where the runner did, ahead of the version's own
  bundle, so a version whose bundle lacks them (or has other versions of
  them) is measured with the same.
- A plugin's own DSL methods: those of its module's `DSL` module, which
  files of benchmarks get once `.duel.rb` uses the plugin. A name that's
  taken, by the DSL, another plugin, or every object, raises
  `Duel::Error` instead of replacing it. A benchmark that the method
  defines, and a hook that it adds, belong to the file of benchmarks
  that called it, which gets that file's hooks.
- `duel/testing`, for plugins' tests: `Duel::Testing.prepare` (which
  runs the configuration's `c.prepare(:version)` blocks, then its
  `c.prepare(:worker)` blocks, as a run does), `measure`, `in_worker`
  (which ends as a worker ends, closing its metrics), `metrics`,
  `compare` and `project`. `measure(config, **hooks)` measures the
  block as a benchmark with the configuration's hooks and its own, as
  `duel` takes them. With an `around_iteration` hook, the block is one
  iteration, run `n` times, each inside the hook, costly metrics and
  all. The block gets the benchmark's context, with `untimed`.
- `Duel::Testing.sample`, `reading` and `details`: stand-ins for a
  sample and for readings of running totals, to test or benchmark what a
  metric says of a sample. docs/plugins.md documents what `details` is
  given and when it runs.
- `Metric#setting(:allowance)`, for a metric of one measure, and
  `Metric#within?(more, n)` (and `Metric.within?`): whether a count is
  within its tolerance and allowance, as Duel judges it.
- A unit that's a word comes with its plural (`unit: %w[row rows]`: 1
  row, 2 rows), and a symbol (`"B"`) is one String.
- `Duel.measuring?`: whether a benchmark is being measured right now
  (not in setup or `untimed`), and `Duel.unmeasured!(name)`, for a
  plugin's helper to fail where what it does would be counted.
- Running totals are typed from their block (Integer totals stay
  Integer), and `Duel::Testing.measure` ends the worker it starts.
- `DUEL_BASE`, `DUEL_FILTER` and `DUEL_FORCE` set `--base`, `--filter`
  and `--force` where options are hard to pass (behind a rake task, or
  in a CI expression). An invalid regular expression for `--filter` or
  `DUEL_FILTER` is a usage error, with exit status 2.
- Mutation tested: mutant kills every change to Duel's code, in CI.
- RBS signatures in sig/, checked with Steep.
- The public API is what the README and the guide in docs/ document.
  Anything marked `@api private`, in lib/ and sig/, may change in any
  release.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/v0.1.0
