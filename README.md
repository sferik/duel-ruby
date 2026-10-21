# ⚔️ Duel

Performance regression guards for Ruby: Duel runs your benchmarks on two
versions of your code side by side, the baseline (by default, where your
branch left `main`) and the candidate (your working tree), and fails if
the candidate is slower at any of them.

```sh
$ bundle exec duel
Comparing 12 benchmarks: baseline /src/my_parser/tmp/duel/base against candidate /src/my_parser (2 at a time; slower means a 99.0% interval above 1.02)
  parse: a small document                            0.6s n=412    cpu 0.998 [0.991, 1.006] same  allocations 8240
! parse: a large document                            1.1s n=9      cpu 1.081 [1.062, 1.097] slower  allocations 52110
...
REGRESSION parse: a large document: worse cpu in every measurement
  cpu: 112.4µs → 121.5µs an iteration (1.08x)
12 benchmarks in 14s: 1 regressed, 0 errors, 0 with a timing too close to the limit to settle
```

## Never slower

Duel exists to enforce a policy the WebKit project sets out on its
[Performance](https://webkit.org/performance/) page:

> The way to make a program faster is to never let it get slower.

> We have a zero-tolerance policy for performance regressions. If a patch
> lands that regresses performance according to our benchmarks, then the
> person responsible must either back the patch out of the tree or drop
> everything immediately and fix the regression.

> Common excuses people give when they regress performance are, "But the
> new way is cleaner!" or "The new way is more correct." We don't care.
> No performance regressions are allowed, regardless of the reason. There
> is no justification for regressing performance. None.

WebKit backs those words with its benchmarks, and with the discipline to
treat a slowdown as seriously as a broken build. Duel is that idea,
packaged for Ruby: if you adopt the policy, Duel is how a pull
request finds out it broke it, before it lands. All credit for the idea
belongs to the WebKit project; any shortcomings in carrying it out are
Duel's.

## How it tells a regression from noise

A policy of zero tolerance only works if the guard never cries wolf: one
false alarm, and people learn to rerun until it's green. So Duel is built
to fail only when your code really got slower, never on noise, and can
gate every pull request:

- **CPU time, not elapsed time.** Each benchmark is timed by its thread's
  CPU time, which other processes on the machine don't inflate. A sample
  is the fastest of several runs (interference only ever adds time), and
  garbage collection is kept out of them (its cost shows in the
  allocation count, which is exact).
- **Side by side, many times over.** The two versions run in worker
  processes of their own (three of each, by default), at the same time on
  the same machine, and take turns: one sample from each, in alternating
  order, each pair from a different pair of processes, so a busy moment
  weighs on both alike, and no one process's luck (where things landed in
  its memory can make the very same code a few percent faster or slower
  for its whole life) decides anything. No stored numbers, no thresholds
  to maintain, and any machine will do.
- **A confidence interval, not an average.** A timing is slower only when
  a 99% distribution-free confidence interval for the median of the
  paired ratios (candidate / baseline) lies entirely above the limit
  (1.02 by default), so no one outlier sample can decide it. Samples are
  taken in rounds until the interval settles the question; one still too
  close to the limit to call is reported, and doesn't fail.
- **Measured again before failing.** Whatever looks slower is measured
  again from scratch, up to three times, in fresh processes, and fails
  only if every measurement agrees.
- **Counts are exact.** Allocations (CRuby), and any counted metric of
  your own, fail on any increase: one more allocation per two iterations.
- **Across the board, too.** A slowdown too small for any one benchmark
  to settle (1% everywhere, say) still shows in all of them together: for
  each metric judged by ratio, every benchmark's median ratio is a sample,
  and the candidate fails when a confidence interval for their median
  lies above a quarter of the metric's margin (1.005, for CPU's 1.02). It
  takes 8 benchmarks, and is measured again before it fails, like the
  rest.

Every benchmark is judged on:

| Metric | What it is | A regression |
|---|---|---|
| `cpu` | the benchmark thread's CPU time (or the process's) | > 2% slower, 99% confident |
| `instructions` | instructions retired, from the CPU's own counters | > 1% more, 99% confident |
| `allocations` | Ruby objects allocated (CRuby) | one more per two iterations |
| `peak_memory` | the most resident memory above the start that measured work reached (not `setup` or `untimed`), GC running as usual (when asked for) | > 10% and 1 MB more |
| yours | see [Metrics of your own](#metrics-of-your-own) | |

Instruction counts barely vary from run to run, so they catch slowdowns
too small for CPU time to settle; CPU time still catches what instructions
miss (cache misses, say). They come from the CPU's counters, where the
operating system lets Duel read them: on Linux the benchmark thread's
(through `perf_event_open`, which many virtual machines, CI runners among
them, don't offer), on macOS the whole process's (so not for benchmarks
with threads of their own). Elsewhere, and on JRuby and TruffleRuby,
there's no `instructions` metric: CPU time judges alone.

What regressed is shown an iteration, on each version (and what a
metric said of it, if it has something to say: see
[Metrics of your own](#metrics-of-your-own)). When something is slower
in time, Duel profiles both versions over the same iterations (with
[StackProf](https://github.com/tmm1/stackprof), if it's in your bundle)
and shows where the extra CPU went:

```
REGRESSION parse: a large document: worse instructions, cpu in every measurement
  instructions: 1.521e+06 → 1.629e+06 an iteration (1.07x)
  cpu: 112.4µs → 121.5µs an iteration (1.08x)
  where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):
     +6.8%   +7.1%  MyParser::Lexer#next_token
     +0.4%   +0.4%  String#byteslice
```

## Installation

```ruby
# Gemfile
group :development do
  gem "duel"
  gem "stackprof", platforms: :mri # for profiles of regressions
end
```

Duel needs Ruby 3.4 or later, JRuby 10 or TruffleRuby 40, and git for
its baselines.

## Benchmarks

Benchmarks go in files named `*_duel.rb` in `duel/`, as tests go in
`*_test.rb`. Your gem is already loaded (from each version's `lib/`), so
a benchmark is just this:

```ruby
# duel/parser_duel.rb
duel "parse: a small document" do
  MyParser.parse("[1, 2, 3]")
end
```

A duel's block is timed: Duel runs it as many times as a sample needs.
What it shouldn't time goes in `setup`, which runs once, before Duel
measures anything:

```ruby
duel "parse: a large document" do
  setup { @input = File.read("test/fixtures/large.json") } # not timed
  MyParser.parse(@input)                                  # timed
end
```

Work that's done for many items at once takes the number of iterations,
and runs once a sample. What it has to prepare each time goes in
`untimed`, which pauses measuring:

```ruby
duel "queue: drain the queue" do |n|
  queue = untimed { MyQueue.new(Array.new(n) { |i| i }) } # not timed
  queue.drain                                            # timed
end
```

A `setup` block at the top of a file runs in each worker before each of
the duels in it is measured, and a `teardown` block after each:

```ruby
# duel/client_duel.rb
setup { @client = MyClient.new(timeout: 1) }

duel("client: one request") { @client.get("/") }
duel("client: ten requests") { 10.times { @client.get("/") } }
```

What benchmarks share goes in `duel/duel_helper.rb`, which they require,
as tests do `test_helper.rb`. Methods defined at its top level are every
duel's to call, and instance variables they set are the duel's own:

```ruby
# duel/duel_helper.rb
def document(size) = "[" + (["1"] * size).join(",") + "]"

def build_parser = @parser = MyParser.new(strict: true)

# duel/parser_duel.rb
require_relative "duel_helper"

duel("parse: a thousand numbers") { MyParser.parse(document(1000)) }

duel "parse: strictly" do
  setup { build_parser }
  @parser.parse("[1]")
end
```

A benchmark is judged on its timings (CPU time, instructions, and those
of any metric of your own) and its counts (allocations, and the like).
Options change that:

- `only: :count` for work that's mostly waiting, too slow and light to
  time: judged on its counts alone, over a few iterations.
- `only: :timing` for work done by threads of the benchmark's own,
  which make its counts vary from run to run: judged on its timings
  alone, and its CPU time is the process's, not the benchmark thread's.
- `peak_memory: true` judges its peak memory too (each version's least
  in three fresh workers): the most resident memory its measured work
  reached, above where it started. What `setup` and `untimed` blocks
  leave isn't in it, as it's in no other measure.

```ruby
duel "server: 10 workers", only: :timing, peak_memory: true do |n|
  # ...
end
```

Benchmarks are always the candidate's: a new benchmark also runs on the
baseline, and is skipped if the baseline can't run it (it uses something
new: each worker runs every benchmark once, with its `setup`, before it's
measured). One that fails on the candidate is an error, and fails the
run.

## Running

```sh
bundle exec duel                       # against where HEAD left the main branch
bundle exec duel --base v1.4.0         # against any git ref
bundle exec duel --base last-release   # against the newest release tag before HEAD
bundle exec duel --filter parse        # only benchmarks whose names match
bundle exec duel --base ../old         # against a tree on disk, already built
```

`duel --help` lists the rest (`--processes`, `--timeout`, `--limit`...).
Where options are hard to pass (behind a rake task, or in a CI
expression), `DUEL_BASE`, `DUEL_FILTER` and `DUEL_FORCE=1` set `--base`,
`--filter` and `--force`; options win. The main branch is the one
`origin/HEAD` names (or `origin/main`, or `origin/master`). A git
baseline is checked out in `tmp/duel/base`, and built if your project has
`ext/` (`bundle exec rake compile`), and kept there (as a git worktree)
for the next run; `duel --clean` removes it, and git's record of it, with
the rest of `tmp/duel`. When nothing under `lib/` or `ext/` changed since
the baseline, there's nothing to compare, and Duel says so (`--force`
compares anyway). The candidate is built too, before every run (builds
are incremental, so one already done costs little): a stale or missing
build, a C extension your code quietly does without, never decides a
comparison.

A benchmark that hangs (or waits on a server that died) doesn't hang the
run: a worker that takes more than a minute (`--timeout`) to load or to
answer is killed, and that benchmark is an error.

It exits 0 when nothing got slower, 1 when something did (or a benchmark
failed), and 2 when it couldn't compare.

## In CI

Run `bundle exec duel` as a step: its exit status passes or fails the
job, and its output says what got slower, by how much, and where the
extra time went. On GitLab, say:

```yaml
duel:
  script: bundle exec duel
  variables:
    GIT_DEPTH: 0 # the baseline comes from history
```

Or from rake:

```ruby
require "duel/rake_task"
Duel::RakeTask.new(:perf)
Duel::RakeTask.new(:perf_since_release, "--base", "last-release")
```

## Slow creep

A limit lets through any slowdown smaller than itself: a run of changes,
each 1.5% slower, would each pass. Compare against your last release as
well, on a schedule, and creep adds up to a regression there:

```yaml
# .github/workflows/perf.yml
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "0 4 * * *"

jobs:
  duel:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # the baseline comes from history, tags included
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Compare
        env:
          DUEL_BASE: ${{ github.event_name == 'schedule' && 'last-release' || github.event_name == 'push' && github.event.before || '' }}
        run: bundle exec duel
```

## Configuration

Most projects need none: the conventions above cover a gem. `.duel.rb`,
at your project's root (loaded by the runner and by every worker), says
what's different:

```ruby
Duel.configure do |c|
  c.benchmarks = "perf/**/*_bench.rb"    # default: duel/**/*_duel.rb
  c.watch = %w[lib ext]                  # what a change must touch to be compared
  c.library = "my_gem"                   # required from each version (default: the gemspec's)
  c.build = "make"                       # for both versions (default: rake compile, with ext/)
  c.main_branch = "origin/trunk"
  c.release_tags = "release-*"           # default: v*

  # How a worker loads one version of your code, instead of the library.
  c.load_version { |root| require File.join(root, "config", "boot") }
end
```

`Duel.configure` yields the configuration, a `Duel::Config`, which
`Duel.config` returns too; `c.root` is your project's root.

### Resources

A resource is something each worker gets of its own, a server, say, so
the baseline and the candidate never share one. Its block gets a
`Duel::Resource`, a directory of the worker's own with help starting a
process there, and returns the environment the worker gets:

```ruby
Duel.configure do |c|
  c.resource do |r|
    socket = r.path("memcached.sock")
    r.spawn("memcached", "-s", socket) # its output goes to memcached.log, there
    r.wait_until { answers?(socket) }  # your check; fails if it exits, or takes over --timeout
    {"MEMCACHE_SERVERS" => socket}
  end
end
```

Duel stops what a resource spawned when its worker is done, after the
blocks it gave `r.at_stop`, last first: with TERM (or the
`stop_signal:` it was spawned with), then KILL. `r.spawn` takes a
`log:` name too, for a program like `ruby` that says little about
itself. `r.run` runs a command to its end (setting something up, say),
and fails, showing its log, if it fails; `r.failed("message")` fails
the same way, for anything else. `r.name` is the worker's
(`"baseline-1"`, say), `r.dir` the directory (`r.path` names a file
in it), and `r.root` the tree of the version it runs.

What takes long to make, and is the same for every worker (a
database's initial files, say), `r.cached` makes once: the first worker
to ask builds it, and the rest, in this run and later ones, get the
directory it's in, to copy or start from. Its key names it (put a
version in it); `duel --clean` removes them all.

```ruby
template = r.cached("postgres-#{version}") { |dir| r.run("initdb", "-D", dir) }
FileUtils.cp_r(template, r.path("data"))
```

A run's workers start at once, each with its resources, and stop at
once. Two resources that set a variable differently fail: say,
`DATABASE_URL`, from two plugins for two databases.

### Metrics of your own

Anything you can measure around a sample can be a metric. A counted
metric fails on any increase; a ratio one is judged like CPU time.

Most are running totals: give `c.metric` a name and a block that reads
the total, and a sample measures what it grew by. Active Record queries,
say, for a gem that adds to models:

```ruby
# .duel.rb
Duel.configure do |c|
  queries = 0
  c.worker do # (in workers only: .duel.rb is loaded by the runner too)
    ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
    end
  end
  c.metric("sql_queries") { queries }
end
```

A `c.worker` block is given the worker (`|w|`), and what it gives
`w.at_stop` runs when the worker ends.

Several totals read at once are named with their settings, and the
block returns them by name (or nil for one it can't read this time).
What Redis did for each benchmark, from its command statistics, over a
connection of the metric's own (not the one being measured), which
`c.per_worker` makes in each worker (its `value` fails anywhere else):

```ruby
Duel.configure do |c|
  redis = c.per_worker do |w|
    Redis.new(url: ENV.fetch("REDIS_URL")).tap { |r| w.at_stop { r.close } } # when the worker ends
  end
  c.metric(
    "redis_cpu" => {
      kind: :ratio,
      unit: "µs",    # shown as time (and sizing samples as CPU time does)
      floor: 300,    # µs: below this on both versions, a sample isn't judged on it
      limit: 1.05    # its own limit (default: the run's, 1.02)
    },
    "redis_commands" => {kind: :counted}
  ) do
    stats = redis.value.info("commandstats").values
    {"redis_cpu" => stats.sum { |s| Integer(s["usec"]) }, "redis_commands" => stats.sum { |s| Integer(s["calls"]) }}
  end
end
```

To explain a regression (see below), what `c.metric` returns for
running totals takes `details`, a block given the sample's stretches and
the sample (`sample.n` is its iterations). A stretch is the readings at
its start and its end, each with its `totals` (`total("name")` is one,
and fails if it couldn't be read); a sample is one stretch, or more
around `untimed` blocks. A reading can carry what the totals came from:
a block that returns `[totals, context]` has the context in its
readings, as their `context`. [Steep](https://github.com/soutaro/steep) types
both from the block: a block that reads Integers has Integer totals,
and its context's type.

```ruby
c.metric("sql_queries") { [queries, Statements.counts] }.details do |stretches, sample|
  Statements.top(3, stretches, per: sample.n) # each stretch's Statements.counts, at its start and its end
end
```

Reading a total can add to it: here, each `INFO` is one more command.
Duel takes care of that for counted totals: each worker reads them
twice in a row a few times first, and takes the least they grew by from
every sample. A total whose reading costs nothing, or a varying amount
the block takes away itself, says `calibrate: false`. (Timed ones are
left alone: a reading's cost isn't steady enough to take away.)

Settings, all optional:

| Setting | For | What it is |
|---|---|---|
| `kind:` | | `:counted` (the default: exact, any increase fails) or `:ratio` (judged by paired ratios with a confidence interval, as CPU time is) |
| `unit:` | | what it's in, as reports show it: `"ns"`, `"µs"`, `"ms"` or `"s"` (shown as time, and giving `unit_ns`), or any other: a word with its plural (`%w[row rows]`: 1 row, 2 rows; a word alone fails), or a symbol (`"B"`, `"KB"`), the same for any number |
| `floor:` | ratio | the least a sample must measure, on either version, to be judged |
| `cpu_floor:` | ratio | the least share of the sample's CPU time it must be (in time, by `unit_ns`), on either version, to be judged: `0.05` for 5% |
| `limit:` | ratio | its own ratio above which it's slower (default: the run's) |
| `unit_ns:` | ratio | nanoseconds per unit, to size samples by it (a time `unit:` gives it) |
| `sizes_samples:` | ratio | `false` for one too noisy to size samples by |
| `across:` | ratio | `false` for one too noisy to judge across the board, where the margin is a quarter of its limit |
| `tolerance:` | counted | how much more per iteration still isn't more |
| `allowance:` | counted | how much more per sample still isn't more (noise that doesn't grow with the iterations) |
| `calibrate:` | counted | `false`: don't take away what reading costs |

A setting there isn't fails (`toleranse:`, say), as does a kind there
isn't. Anyone can change a measure's settings, a plugin's or Duel's own,
or leave it out: `c.measure("redis_cpu", limit: 1.1)`,
`c.measure("cpu", limit: 1.05)`, `c.measure("instructions", skip: true)`.
(A plugin's worker block can ask `c.skip?("name")`, to set up nothing for
a measure that's left out.)

Metrics are read in the order they're added before a sample, and in
reverse after it, outside the built-in ones, so their own work isn't
counted in allocations, instructions or CPU. They're paused around
`untimed` blocks too, so those aren't counted.

What running totals can't express, a subclass of `Duel::Metric` can:
its `start(sample)` is called before every sample (`sample.n` is its
iterations, and `sample.benchmark` the benchmark: its `name`, `only`
and `peak_memory`), and `stop` after it returns what was measured (or a
Hash of them). Its `self.measures` names what it measures, with their
settings as above: `{"wait" => {kind: :ratio, unit: "ns"}}` (by
default, one counted measure named `self.metric_name`, the class's name
in snake case: `QueryCount` is `query_count`). Around an `untimed` block it's
`pause` and `resume`, by default `stop` and `start`. It leaves itself
out where it can't measure with `def self.available?`. Its `settings`,
by measure name, are as the configuration has them (after
`c.measure`'s changes), each with every setting filled in; one that
measures one thing has them by `setting(:allowance)`, say (another
names the measure: `setting(:allowance, "rows")`). `within?(more, n)`
says whether a count that grew by `more` over `n` iterations is still
within its tolerance and allowance, as Duel judges it
(`Duel::Metric.within?(more, n, tolerance:, allowance:)` for any). To
explain a regression, it can say something of the sample it last
stopped, with `details`: text (or text by measure name), shown under the
regression for each version (`retained_objects (candidate): 100 String,
50 Hash`); for a count, it's what was said of the sample the count came
from. It's asked after every sample the metric measured, so it should
cost little: say nothing, or what's cheap, unless something looks
worse (`return if within?(@retained, @n)`). Add it with
`c.metric(MyMetric)`.

### Plugins

A plugin packages resources and metrics, for a server or a library, for
any project to use:

- [duel-redis](https://github.com/sferik/duel-redis): a Redis server for
  each worker, and the Redis CPU time, commands and round trips each
  benchmark took.
- [duel-postgresql](https://github.com/sferik/duel-postgresql): a
  PostgreSQL server for each worker, and the queries, rows, blocks and
  time each benchmark took of it, by statement.
- [duel-mysql](https://github.com/sferik/duel-mysql): a MySQL server for
  each worker, and the queries, rows (returned and examined) and time
  each benchmark took of it, by statement.
- [duel-memcached](https://github.com/sferik/duel-memcached): a
  memcached server for each worker, and the operations, misses and bytes
  each benchmark took of it.
- [duel-activerecord](https://github.com/sferik/duel-activerecord): the
  queries, transactions and records each benchmark took, from Active
  Record's notifications (an N+1, say), with any database.
- [duel-gvl](https://github.com/sferik/duel-gvl): how long the threads
  of a benchmark with threads of its own waited for the GVL (CRuby).
- [duel-retained](https://github.com/sferik/duel-retained): the objects
  each benchmark left alive (a leak, or a cache that grows with every
  call; CRuby).

By convention a plugin is a gem named `duel-` and what it's for, with a
module under `Duel` whose `install` takes the configuration (and any
options):

```ruby
# .duel.rb
require "duel/redis"

Duel.configure { |c| Duel::Redis.install(c) }
```

There's no registry, and no keyword: `install` calls `c.resource`,
`c.metric` and `c.worker` like any `.duel.rb`. Name measures for the
plugin (`redis_*`), so two plugins' never meet; give benchmarks helpers
as module functions (`Duel::Redis.url`); and inside `module Duel`,
write `::Redis` for the library's own constants (`Redis` is the
plugin's there). What a worker needs of its own, `c.per_worker` makes,
and `install` returns its handle; the module keeps none. A helper meant
for setting up (one that runs a query, say) calls
`Duel.unmeasured!("Duel::Redis.flush")` first: it fails during a timed
stretch (`Duel.measuring?`), where what the helper does would be
counted, as in `Duel::Testing.measure`'s block, but not its `untimed`.

What Duel raises is a `Duel::Error`: a setting there isn't, a helper
called where it would be counted. A resource that fails (`r.failed`,
`r.run`, `r.wait_until`), or a worker that dies or hangs, raises
`Duel::Failed`, a kind of `Duel::Error`; so can a plugin's resource.

`require "duel/testing"` has what a plugin's tests need:

```ruby
config = Duel::Config.new
Duel::Redis.install(config)
Duel::Testing.resources(config) do |env| # started as a worker's, env set
  Duel::Testing.measure(config) { Redis.new.set("k", "v") } # => {"redis_commands" => 1, ...}, with #details
end

base = Duel::Testing.project(dir, "lib/my_cache.rb" => "...", "duel/cache_duel.rb" => "...", ".duel.rb" => "...")
Duel::Testing.compare(base, candidate).passed? # whole comparisons, in workers
```

`resources` starts them as the worker `name:` (`"candidate-1"`) would,
for the version at `root:` (the configuration's), with `r.cached`'s
builds in `cache:` (by default, one directory for the whole test
process; give your own to look inside it).

`measure` runs in a worker of its own (its worker blocks run, and its
metrics are made, as a worker does), ended after; its block gets
`untimed`, as a benchmark has (`measure(config) { |s| s.untimed { ... } }`),
`n:` is the sample's iterations, and `only:` makes it a benchmark's that
has, say, `only: :timing`. What it returns is a Hash of what was
measured, by name, whose `details` are what the metrics said of it, by
measure. `Duel::Testing.worker(config) { ... }` runs the block as a
worker, and ends it as a worker ends (what its worker blocks gave
`at_stop` runs after): every `measure` in it is that worker's, and
`Duel::Testing.metrics(config)` its metric instances. Check what a
worker holds (a subscription, an open connection) inside it: after a
`measure` of its own, the worker has ended. What a plugin added, its
tests find in `config.metrics` (the metrics, in order), each with its
`measures` and their `settings`, every one filled in:
`config.metrics.first.settings.fetch("redis_cpu")` is
`{kind: :ratio, unit: "µs", floor: 300, ...}`.

`compare` takes `duel`'s options as keywords (`processes:`, two
unless given; `timeout:`, `limit:`, `warm:`; `filter:`, a Regexp), and
returns the comparison: `passed?`, its `output` (what `duel` would have printed),
and its `results`, one for each benchmark (`comparison["name"]` finds
one). A result has its `name`, `passed?`, the measures it `regressed`
on; each `timed` measure's `"verdict"`, `"median"` ratio and its
`"interval"` (over its `"pairs"` of samples), the `"limit"` it was judged by, whether it's judged
`"across"` the board, and each version's median (`"baseline"`,
`"candidate"`); each `counted` one's fewest on each version
(`"baseline"`, `"candidate"`) over a sample's `"n"` iterations, with its
`"tolerance"` and `"allowance"` (both with their `"unit"` and
`"plural"`), by name; what metrics said of it (`details`, by measure, by
version); its peak `memory` (by version, when asked for); its
iterations a sample (`n`) and `seconds`; why it was `skipped` (the
baseline couldn't run it) or its `error`; and its `confirmations`, the
measurements that confirmed it was worse.

## JRuby and TruffleRuby

JRuby's and TruffleRuby's JITs keep compiling for seconds, so each
benchmark runs for five before it's measured (`--warm`), and their
timings stay noisier than CRuby's: small timing regressions there are
often left unsettled. Neither has an allocation count, an instruction
count or profiles, and each has peak memory only on Linux.

## Public API

What this README documents is Duel's public API, and follows
[Semantic Versioning](https://semver.org). Anything marked `@api private`
in the code or its signatures (`sig/`) is Duel's own, and may change in
any release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), including what Duel owes WebKit.

## License

MIT. See [LICENSE](LICENSE).
