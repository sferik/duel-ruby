# Write a Duel plugin

A plugin packages what [Duel](../README.md) needs for a server or a
library, such as a server for each worker, hooks, and metrics, so that
any project can use it. This document describes
how to write a plugin and how to test it. For the plugins that are
available, and how to use one, see [Plugins](../README.md#plugins).

## Plugin conventions

By convention, a plugin is a gem named `duel-` and what it's for, such
as `duel-redis`. A project uses it by name, with `c.use :redis` in
`.duel.rb`, which requires `duel/redis`. So the plugin's file is
`lib/duel/redis.rb`, and it registers the plugin under the same name,
`:redis`.

The plugin's module registers itself with `Duel.plugin`, and defines
`configure`, which `c.use` calls with the configuration and the options
that it's given. `configure` calls `c.prepare`, `c.in_worker`,
`c.metric`, and the hooks (`c.before_sample`, say), the same way that
any `.duel.rb` does, and returns what the project's tests or benchmarks
might want, such as the plugin's own connection to its server:

```ruby
# lib/duel/redis.rb
require "duel"

module Duel
  module Redis
    Duel.plugin(:redis, self)

    # Configures Duel for the plugin: c.use :redis, server: "redis-server"
    def self.configure(config, server: "redis-server")
      config.prepare(:worker) do |w|
        socket = w.path("redis.sock")
        w.spawn(server, "--port", "0", "--unixsocket", socket)
        w.wait_until { File.socket?(socket) }
        {"REDIS_URL" => "unix://#{socket}"}
      end
      connection = config.in_worker { |w| Connection.new.tap { |redis| w.at_stop { redis.close } } }
      config.metric("redis_commands") { connection.value.commands }.costly
      connection
    end
  end
end
```

Duel calls `configure` once for each configuration, the first time
that the plugin is used. A plugin that needs another, such as a plugin
for an app that needs a database's, calls `config.use` itself, with the
options it needs. If the project used that plugin first, with options
of its own, the project's use stands. A later use can repeat the
options of the first, but another option raises `Duel::Error`, so pass
only the options that you need. A plugin can also add its own kind of
benchmark to the DSL. For more information, see
[Add to the DSL](#add-to-the-dsl).

Duel puts the require paths of every gem named `duel` or `duel-*` that
the runner loaded on each worker's load path, ahead of the version's own
bundle. A worker that runs a version's own bundle (with
`BUNDLE_GEMFILE` set to the version's `Gemfile`, say) can still require
your plugin, even if that bundle doesn't have it, and both versions are
measured with the runner's copy. Duel doesn't do the same for your
plugin's dependencies, such as the library that it measures: those come
from the version's bundle.

When you write a plugin, follow these guidelines:

- Name its measures after the plugin, such as `redis_*`, so that two
  plugins' measures never clash.
- Give benchmarks helpers as module functions, such as
  `Duel::Redis.url`.
- Inside `module Duel`, write `::Redis` for the library's own constants,
  because `Redis` is the plugin's there.
- Make what a worker needs for itself with `c.in_worker`, and return
  what it returns from `configure`. Don't keep it in the module.
- Set up what a whole version needs once, such as its bundle, with
  `c.prepare(:version)`, not in each worker's `c.prepare(:worker)`. Run
  its commands on the version's Ruby: `v.env` puts it first on `PATH`.

> [!IMPORTANT]
> A helper that's meant for setup, such as one that runs a query, must
> call `Duel.unmeasured!` first, for example
> `Duel.unmeasured!("Duel::Redis.flush")`. It raises an error during a
> timed stretch (when `Duel.measuring?` is true), where what the helper
> does would be counted. That includes the block of
> `Duel::Testing.measure`, but not the block's `untimed` blocks.

Duel raises `Duel::Error` when something is used wrong, such as a
setting that doesn't exist, or a helper that's called where it would be
counted. A prepare block that fails (`w.failed`, `w.run`, or `w.wait_until`),
or a worker that dies or hangs, raises `Duel::Failed`, a subclass of
`Duel::Error`. A plugin's prepare block can raise it too.

## Add to the DSL

To give benchmarks a kind of benchmark of the plugin's own, such as a
request to an app, define a module named `DSL` inside the plugin's
module. Its public methods are DSL methods: once `.duel.rb` uses the
plugin, files of benchmarks can call them. Duel loads the files of
benchmarks after `.duel.rb`, so the plugin's registration with
`Duel.plugin` is all that a plugin needs. Duel calls a DSL method on the
object that files of benchmarks run on, so it can call `duel`:

```ruby
# lib/duel/my_app.rb
module Duel
  module MyApp
    Duel.plugin(:my_app, self)

    def self.configure(config)
      # ...
    end

    module DSL
      def duel_request(name, path, **options, &prepare)
        duel(name, around_iteration: ::MyApp::ROLLBACK, **options) do
          env = ::MyApp.env_for(path)
          instance_exec(env, &prepare) if prepare # in the benchmark's context
          ::MyApp.call(env)
        end
      end
    end
  end
end

# .duel.rb
Duel.configure { |c| c.use :my_app }

# duel/requests_duel.rb
duel_request "posts: index", "/posts"
```

Inside the plugin's module, `DSL` is the plugin's own module, so write
`Duel::DSL` for Duel's.

A benchmark that the method defines, with `duel` or `duel_process`,
belongs to the file of benchmarks that called the method, not to the
plugin's file. It gets that file's hooks, the same as a benchmark that
the file defines with `duel`. That holds even if the block that the
method gives `duel` is the plugin's, as in the previous example, or if
the method calls another DSL method. A hook that the method adds, such
as `before_sample { ... }`, is the calling file's too.

Pass the benchmark's own hooks on to `duel`, as options, such as
`setup:`, so that your method takes them the same way that `duel` does.

If a method's name is taken, `c.use` raises `Duel::Error` and names
what took it. A name is taken if the DSL already has a method of that
name, Duel's own or another plugin's, or if every object has one, such
as Kernel's `test`, which the DSL method would hide. So name the method
after the plugin, such as `duel_request` for a plugin for apps. A DSL
method is also a name that a project's helpers can't have. For more
information, see
[Share code between benchmarks](benchmarks.md#share-code-between-benchmarks).

Reopening `Duel::DSL` instead isn't supported: a method that you define
that way can silently replace Duel's or another plugin's.

## Run code around every benchmark

A plugin can give hooks for every benchmark that runs in a worker,
with the same names that `.duel.rb` uses. For what each hook does, and
the order of hooks at several levels, see
[Run code around a benchmark](benchmarks.md#run-code-around-a-benchmark).
A plugin's hooks are the configuration's, so they run before a file's
and a benchmark's own, in the order that they were given, and they run
where they're written, with the plugin's module as `self`:

- `c.before_sample { |benchmark| ... }` runs before every sample,
  warm-up samples included, and isn't measured. Use it to put back what
  earlier samples changed, such as reloading a database's fixtures, so
  that every sample starts alike. The block receives the benchmark,
  with its `name`, `only`, and `peak_memory`, if it takes it.
- `c.after_iterations { ... }` runs after each sample's iterations, and
  is the one hook that Duel measures, with them. Use it to do the work
  that the iterations started and left to be done later, such as jobs
  that they enqueued, so that the work counts as the benchmark's. For a
  benchmark with an `around_iteration` hook, Duel runs it after each
  iteration, inside the iteration, before the hook undoes anything.
- `c.around_iteration { |iteration| ... }` runs around each iteration of
  every benchmark, and calls `iteration.call` once. Only the iteration
  is measured. A benchmark whose block takes the number of iterations
  can't run inside one, so a plugin that gives one for every benchmark
  rules those out. To apply one to some benchmarks, such as rolling back
  each request, make it a lambda that a project can give to a file or
  to one benchmark (`around_iteration: MyApp::ROLLBACK`), or pass it to
  `duel` from the plugin's DSL method.

```ruby
def self.configure(config)
  config.before_sample { MyJobs.clear }
  config.after_iterations { MyJobs.run_pending }
end
```

A process benchmark (`duel_process`) runs no hooks.

## Set up and tear down a metric in each worker

A metric often needs something of its own in each worker, such as a
subscription to notifications. Running totals and a metric class use
the same names for it:

- For running totals, call `open` and `close` with blocks on what
  `c.metric` returns. Duel runs the `open` block when the worker opens
  the metric, before the metric's first reading, and the `close` block
  when the worker ends. `open`, `close`, `details`, and `costly` each
  return the metric, so you can chain them.
- For a subclass of `Duel::Metric`, define `open` and `close` methods.
  Duel makes and opens each metric once in each worker, after the
  `c.in_worker` blocks, and calls `close` when the worker ends. Its
  per-sample methods are `start_sample`, `stop_sample`,
  `pause_sample`, and `resume_sample`.

```ruby
def self.configure(config)
  counter = Counter.new
  config.metric(MEASURES) { counter.totals }
    .open { counter.subscribe }
    .close { counter.unsubscribe }
    .details { |stretches, sample| counter.details(stretches, sample.n) }
  counter
end
```

Duel closes a worker's metrics last first, and then runs what its
`c.in_worker` blocks gave `at_stop`. A metric whose measures are all
left out (`c.measure(name, skip: true)`) isn't made, so it's neither
opened nor closed. To set up nothing for one measure that's left out,
`open` can call `c.skip?(name)`.

## Explain a sample

A metric can say what it saw in a sample, so that a regression comes
with its cause, such as the statements that a benchmark sent most. Duel
shows what the metric said under each regression, for each version.

For running totals, call `details` with a block on what `c.metric`
returns. The block receives the following:

- `stretches`: an Array of the sample's measured stretches. Each
  stretch is a pair of readings, `[started, stopped]`, taken when Duel
  started measuring and when it stopped. A sample has one stretch, and
  one more for each `untimed` block in it. A sample of a benchmark with
  an `around_iteration` hook has one stretch for each iteration, and two
  more, before the first iteration and after the last, which measure
  next to nothing.
  For a costly metric (see
  [Account for the cost of reading](configuration.md#account-for-the-cost-of-reading)),
  it has one stretch, and one more for each `untimed` block, as any
  other sample does.
- `sample`: the sample. `sample.n` is its number of iterations, and
  `sample.benchmark` is the benchmark, with its `name`, `only`, and
  `peak_memory`.

A reading has the following:

- `totals`: the totals that the metric's block read, by name. A total
  that the block couldn't read is `nil`.
- `total(name)`: one total. It raises `Duel::Error` for a total that
  couldn't be read, or one that the metric doesn't measure.
- `context`: what else the block read with the totals, if it returned
  `[totals, context]`, or `nil`.

What a sample measured is the sum, over its stretches, of what each
total grew by, less what reading the totals costs. For a subclass of
`Duel::Metric`, `details` is a method, which explains the sample that
the metric last stopped, from what its `start_sample` and `stop_sample`
kept.

The block, or method, returns one of the following:

- A String, which explains each of the metric's measures.
- A Hash of Strings by measure name, which explains only those measures.
- `nil`, which explains nothing.

Duel calls it in the worker, right after each sample stops, outside what
it measures. That's after every sample, including warm-up samples and
those that a worker takes to calibrate an `around_iteration` hook, not
only after a regression. Duel doesn't call it after a stretch that
`untimed` paused.
So keep it cheap: return `nil` unless something looks worse, for
example `return if within?(more, sample.n)`. For a count, Duel shows
what the metric said of the sample that the count came from. For a
timing, it shows what the metric said of the latest sample.

## Test a plugin

`require "duel/testing"` provides what a plugin's tests need:

```ruby
config = Duel::Config.new
config.use :redis
Duel::Testing.prepare(config) do |env| # prepared as a worker is, env set
  Duel::Testing.measure(config) { Redis.new.set("k", "v") } # => {"redis_commands" => 1, ...}, with #details
end

base = Duel::Testing.project(dir, "lib/my_cache.rb" => "...", "duel/cache_duel.rb" => "...", ".duel.rb" => "...")
Duel::Testing.compare(base, candidate).passed? # whole comparisons, in workers
```

`Duel::Testing` has the following methods:

- `prepare(config)`: runs the configuration's `c.prepare(:version)`
  blocks, named for the version (`"candidate"`), and then its
  `c.prepare(:worker)` blocks, as Duel prepares a worker. It sets the
  environment that they return while its block runs, and stops what
  they started after. `name:` names the worker (`"candidate-1"` by
  default), and `root:` is the version's tree (the configuration's root
  by default). `cache:` is where `w.cached` builds go. By default,
  that's one directory for the whole test process. To look inside it,
  give your own.
- `measure(config)`: measures a sample of its block in a worker of its
  own, which runs its `c.in_worker` blocks and makes its metrics the
  way that a worker does, and which ends after the sample. It runs the
  configuration's hooks as a worker runs a benchmark's. Its block
  receives the benchmark's context, with `untimed`, as a benchmark's
  does: `measure(config) { |s| s.untimed { ... } }`. `n:` is the
  sample's number of iterations, and `only:` makes the sample a
  benchmark's that has, for example, `only: :timing`. It also takes the
  benchmark's own hooks, as `duel` does, such as `before_sample:`. It
  returns a Hash of what was measured, by name, whose `details` are
  what the metrics said of the sample, by measure. With an
  `around_iteration` hook, the configuration's or its own, the block is
  one iteration: `measure` runs it `n` times, each inside the hook, the
  way that a worker runs a benchmark with one, including what it learns
  first to subtract the hook's work from a costly metric.
- `in_worker(config) { ... }`: runs the block as a worker, and ends it
  the way that a worker ends, so what its `c.in_worker` blocks gave
  `at_stop` runs after the block. Every `measure` in the block is that
  worker's, and so is the `value` of what `c.in_worker` returned.
  Inside the block, `Duel::Testing.metrics(config)` returns the
  worker's metric instances. Check what a worker holds, such as a
  subscription or an open connection, inside the block: after a
  `measure` of its own, a worker has ended.
- `project(dir, files)`: writes a small project of the given files.
- `compare(base, candidate)`: compares two projects in workers. See the
  following paragraphs.
- `sample(n: 1)`: a stand-in sample of `n` iterations, which measures
  nothing, for a metric's `start_sample` or a `details` block. `name:`,
  `only:`, and `peak_memory:` describe its benchmark.
- `reading(totals, context)`: a stand-in reading of running totals, by
  name, with the context that was read with them. A sample's stretches
  are pairs of readings.
- `details(metric, stretches, sample)`: what the `details` block of
  running totals says of the stretches of a sample. `metric` is what
  `c.metric` returned, and `sample` is `sample` by default.

`measure` runs the configuration's `before_sample` hooks before the
sample, and its `after_iterations` hooks after its block, measured with
it, the same way that a worker does. With an `around_iteration` hook,
it runs the `after_iterations` hooks after each iteration. The
benchmark's own hooks run in its context, the same as a benchmark's
own hooks do, while the block keeps its own `self`.

A plugin whose metrics read a server says that they're costly, so that
a benchmark with an `around_iteration` hook doesn't make a round trip to
the server for each iteration. To check that what such a hook sends the
server isn't counted, measure with one:

```ruby
rolled_back = lambda do |iteration|
  pg.exec("BEGIN")
  iteration.call
  pg.exec("ROLLBACK")
end
Duel::Testing.measure(config, n: 20, around_iteration: rolled_back) { pg.exec("INSERT INTO items VALUES (1)") }
# => {"postgres_queries" => 20, "postgres_rows" => 20, ...}
```

To test or benchmark what a metric says of a sample, without a worker,
use the stand-ins:

```ruby
metric = config.metrics.first # what c.metric returned
stretches = [[Duel::Testing.reading({"rows" => 1}, views_before), Duel::Testing.reading({"rows" => 4}, views_after)]]
Duel::Testing.details(metric, stretches, Duel::Testing.sample(n: 3)) # => {"rows" => "an iteration: 1× ..."}
```

A plugin's tests find what the plugin added in `config.metrics`, the
metrics in order. Each metric has its `measures` and their `settings`,
with every setting filled in. For example,
`config.metrics.first.settings.fetch("redis_cpu")` is
`{kind: :ratio, unit: "µs", floor: 300, ...}`.

`compare` takes `duel`'s options as keywords: `processes:` (two unless
given), `timeout:`, `limit:`, `warm:`, and `filter:` (a Regexp). It
returns the comparison: `passed?`, its `output` (what `duel` would have
printed), and its `results`, one for each benchmark.
`comparison["name"]` finds one. A result has the following:

- Its `name`, `passed?`, and the measures that it `regressed` on. When
  no one timing was slower in every measurement, but each measurement
  had one that was, those are the timings that were slower in any.
- Each `timed` measure's `"verdict"`, `"median"` ratio, and
  `"interval"` (over its `"pairs"` of samples), the `"limit"` that it
  was judged by, whether it's judged `"across"` the board, and each
  version's median (`"baseline"` and `"candidate"`), by name.
- Each `counted` measure's fewest on each version (`"baseline"` and
  `"candidate"`) over a sample's `"n"` iterations, with its
  `"tolerance"` and `"allowance"` (both with their `"unit"` and
  `"plural"`), by name.
- What metrics said of it (`details`), by measure and by version.
- Its peak `memory`, by version, when it was asked for.
- Its iterations a sample (`n`), and its `seconds`.
- Why it was `skipped` (the baseline couldn't run it), or its `error`.
- Its `confirmations`: the measurements that confirmed it was worse.
