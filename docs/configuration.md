# Configure Duel

Most gems don't need any configuration: Duel's conventions cover them.
Benchmarks are in `duel/**/*_duel.rb`, each version's `lib/` is first on
the load path, a change is compared when it touches `lib/` or `ext/`
(or the benchmarks, or `.duel.rb`), and releases are tagged `v*`. If
your project differs, create a `.duel.rb` file at its root. Both the
runner and every worker load it:

```ruby
Duel.configure do |c|
  c.benchmarks = "perf/**/*_bench.rb"    # default: duel/**/*_duel.rb
  c.watch = %w[lib ext]                  # the code a change must touch to be compared
  c.library = "my_gem"                   # required from each version (default: the gemspec's)
  c.build = "make"                       # for both versions (default: rake compile, with ext/)
  c.main_branch = "origin/trunk"
  c.release_tags = "release-*"           # default: v*
  c.ruby = :version_file                 # each version's own Ruby (default: the runner's)
  c.comment = :results                   # when CI comments on a pull request (default: :failures)
  c.fail_on = :pull_requests             # which runs a regression fails (default: :every_run)
  c.push_base = :last_passed             # what CI compares a push with (default: :before)
  c.accept_label = "duel: accept"        # a pull request label that accepts a regression
  c.use :redis                           # a plugin (see Use plugins)

  # How a worker loads one version of your code, instead of the library.
  c.load { |root| require File.join(root, "config", "boot") }
end
```

`Duel.configure` yields the configuration, a `Duel::Config` object,
which `Duel.config` also returns. `c.root` is your project's root
directory. The configuration also takes hooks, such as
`c.before_sample`. See
[Run code around a benchmark](benchmarks.md#run-code-around-a-benchmark).

## Choose what a change must touch to be compared

When nothing that Duel watches changed since the baseline, there's
nothing to compare, and Duel passes without running the benchmarks.
`c.watch` names your code: `lib/` and `ext/` by default. Duel also
watches what decides how your code is measured:

- The benchmarks' directory: the part of `c.benchmarks` before its first
  wildcard, `duel/` by default, with its helpers and fixtures.
- The configuration's file, `.duel.rb`.
- With [`c.ruby = :version_file`](#run-each-version-on-its-own-ruby),
  the version files at your project's root (`.ruby-version`,
  `.tool-versions`, `mise.toml`, or `.mise.toml`).

Each version runs your branch's benchmarks and configuration, so a
change to only those compares your code with itself. That checks that
the changed benchmarks run, and pass on identical code, instead of
passing without running them. To compare a change to anything else, such
as your CI workflow, add it to `c.watch`:

```ruby
Duel.configure do |c|
  c.watch += %w[.github/workflows/perf.yml]
end
```

## Choose when to comment on a pull request

The [GitHub Actions workflow](ci.md#comment-on-a-pull-request) that
`duel init` writes comments on a pull request with Duel's report.
`c.comment` chooses when, and `duel --comment` overrides it:

| Value | When the workflow comments |
|---|---|
| `:always` | On every run, whatever the outcome. |
| `:results` | When the run passed or failed, but not when there was nothing to compare. |
| `:failures` | When a benchmark failed, or Duel couldn't compare. This is the default. |
| `:never` | Never. |

```ruby
Duel.configure do |c|
  c.comment = :results
end
```

The workflow never edits a comment: each one is new, so the pull
request keeps them all. Once the workflow has commented on a pull
request, it also comments on a run that it otherwise wouldn't, except
with `:never`, when the run's status (passed, failed, or nothing to
compare) differs from its last comment's. So with `:failures`, after a
comment that a benchmark failed, the first run that passes posts a
comment saying so, and the runs after it post nothing. The last comment
is never stale.

With `:never`, a regression still fails the check, because `duel` exits
with a nonzero status, and the job's summary still has the report.

`c.comment` takes only these four values: any other fails the run, and
says which values it takes.

## Fail only a pull request

By default, a regression fails every run: a pull request's, a push's,
and the schedule's. In a project where people push to `main` directly,
a failed push only gets GitHub's email that the run failed. To report a
regression in a push without failing it, set `c.fail_on`, and
`duel --fail-on` overrides it:

| Value | Which runs a regression fails |
|---|---|
| `:every_run` | Every run. This is the default. |
| `:pull_requests` | A pull request's (or a merge queue's), and a run outside GitHub Actions. |

```ruby
Duel.configure do |c|
  c.fail_on = :pull_requests
end
```

With `:pull_requests`, a regression on GitHub Actions outside a pull
request (a push, the schedule, or a run by hand) passes, with a warning
in the run's summary, and the job's summary still has the report. On
GitLab CI, a regression outside a merge request exits with status 3,
which the [job](ci.md#run-duel-on-gitlab-ci) that `duel init --gitlab`
writes shows as a warning. The
[GitHub Actions workflow](ci.md#comment-on-a-pushed-commit) that
`duel init` writes then comments on a pushed commit with the report,
as `c.comment` says, which notifies the commit's author. A run that
couldn't compare fails either way, and on your machine, a regression
always fails.

## Accept a regression with a label

Sometimes a change is slower on purpose: it's correct where the old
code wasn't, say. To let a pull request through anyway, name a label
that accepts its regression:

```ruby
Duel.configure do |c|
  c.accept_label = "duel: accept"
end
```

On GitHub Actions, the [workflow](ci.md#accept-a-regression-with-a-label)
that `duel init` writes passes Duel the pull request's labels. With
that label, a regression passes, with a warning, and the report says
that the label accepted it. The labels are read when the workflow runs,
so after you add the label, run the workflow again (Re-run jobs, on the
pull request's Checks tab). For a push, Duel reads the labels of the
pull request that merged it, so with
[`c.push_base = :last_passed`](#compare-a-push-with-the-last-commit-that-passed),
the merged regression becomes the commit that later pushes are compared
with. By default, there's no such label.

## Compare a push with the last commit that passed

The [GitHub Actions workflow](ci.md#compare-a-push-with-the-last-commit-that-passed)
that `duel init` writes compares a push to `main` with the commit
before it. A series of pushes that are each a little slower then each
pass. `c.push_base` chooses what a push is compared with:

| Value | What the workflow compares a push with |
|---|---|
| `:before` | The commit before the push. This is the default. |
| `:last_passed` | The last commit that Duel passed, which a branch marks: `duel/passed/main` for `main`. |

```ruby
Duel.configure do |c|
  c.push_base = :last_passed
end
```

With `:last_passed`, the slowdowns add up until they fail a push. After
a regression, every push fails until one is no slower, or until you
move the branch to accept the regression:
`git push origin main:duel/passed/main`.

## Prepare each worker

Each worker can get things of its own, such as a server, so that the
baseline and the candidate never share one. To prepare each worker,
call `c.prepare(:worker)` with a block. Duel runs the block in the
runner, as each worker starts. The block receives a `Duel::Resource`,
which gives the worker a directory of its own, and helps start
processes there. The block returns the environment variables that the
worker gets:

```ruby
Duel.configure do |c|
  c.prepare(:worker) do |w|
    socket = w.path("memcached.sock")
    w.spawn("memcached", "-s", socket) # its output goes to memcached.log, there
    w.wait_until { answers?(socket) }  # your check (it fails if the program exits, or takes over --timeout)
    {"MEMCACHE_SERVERS" => socket}
  end
end
```

A prepare block can use the following methods:

| Method | Description |
|---|---|
| `w.spawn(*command)` | Starts a process. Its output goes to a log in the worker's directory, named after the program. For a program like `ruby` that says little about itself, give the log a name with `log:`. To stop it with a signal other than `TERM`, pass `stop_signal:`. |
| `w.wait_until { ... }` | Waits until the block returns true. Fails if a spawned process exits first, or if the wait takes longer than `--timeout`. |
| `w.run(*command)` | Runs a command to completion, for example to set something up. Fails, and shows the command's log, if the command fails. |
| `w.failed("message")` | Fails the same way, for any other reason. |
| `w.at_stop { ... }` | Runs the block when the worker stops. |
| `w.cached(key) { \|dir\| ... }` | Makes something once, for every worker. See the following example. |
| `w.name` | The worker's name, for example `"baseline-1"`. |
| `w.dir` | The worker's directory. `w.path("name")` returns the path of a file in it. |
| `w.root` | The tree of the version that the worker runs. |
| `w.ruby` | The path of the Ruby that the version runs on. See [Run each version on its own Ruby](#run-each-version-on-its-own-ruby). |
| `w.env` | The version's environment variables. See the following paragraph. |

The commands that `w.spawn` and `w.run` start get the version's
environment variables, `w.env`: what the version's own prepare blocks
return (see [Prepare each version](#prepare-each-version)), and, for a
version on another Ruby than the runner's, that Ruby's directory first
on `PATH`. A command's own environment variables take precedence, so a
command that sets its whole environment should include `w.env`.

When a worker is done, Duel runs the blocks that its prepare blocks
gave `w.at_stop`, last first. Then Duel stops what they spawned, first
with `TERM` (or the `stop_signal:` that the process was spawned with),
and then with `KILL`.

Some things take long to make, and are the same for every worker, such
as a database's initial files. `w.cached` makes them once. The first
worker that asks builds the directory, and the other workers, in this
run and in later ones, get its path, to copy or to start from. The key
names what's cached, so put a version in it. `duel --clean` removes
every cached directory.

```ruby
template = w.cached("postgres-#{version}") { |dir| w.run("initdb", "-D", dir) }
FileUtils.cp_r(template, w.path("data"))
```

A run's workers start at the same time, each prepared, and stop at the
same time.

> [!WARNING]
> If two prepare blocks set the same environment variable to different
> values, the run fails. For example, two plugins for two databases
> might both set `DATABASE_URL`.

## Prepare each version

Some setup is for a version as a whole, not for each worker, such as
installing the version's bundle. To prepare each version once, call
`c.prepare(:version)` with a block. Duel runs the block in the runner,
for the baseline and then the candidate, before any of that version's
workers start. The block receives a `Duel::Resource` for the version,
with the same methods as a worker's, and returns the environment
variables that the version's workers and process benchmarks get:

```ruby
require "bundler"
require "digest"

Duel.configure do |c|
  c.prepare(:version) do |v|
    gemfile = File.join(v.root, "Gemfile")
    lock = Digest::SHA256.file("#{gemfile}.lock").hexdigest[0, 16]
    v.cached("bundle-#{lock}") do |_|
      # (Outside the runner's own bundle.)
      env = Bundler.unbundled_env.merge(v.env, "BUNDLE_GEMFILE" => gemfile)
      v.run(env, "bundle", "install", log: "bundle", unsetenv_others: true)
    end
    {"BUNDLE_GEMFILE" => gemfile}
  end
end
```

`v.name` is `"baseline"` or `"candidate"`, and `v.root` is the version's
directory. What the block spawns stops when the run ends. A worker's
prepare blocks get the version's environment too, as `w.env`. If a
worker's prepare block sets a variable that the version's environment
sets to a different value, the run fails.

To build each version, such as its C extension, set `c.build` to a
shell command instead, such as `c.build = "make"`. Duel runs it in the
baseline's tree when it checks the baseline out, and in the candidate's
before every run.

## Run code in each worker

The runner loads `.duel.rb` too, so code at its top level runs in the
runner as well as in every worker. For what only a worker does, such as
loading data that its benchmarks share, give `c.in_worker` a block.
Duel runs it in each worker, once the version and the benchmarks have
loaded, and before the worker makes its metrics. The block receives the
worker (`|w|`), and what you pass to `w.at_stop` runs when the worker
ends.

`c.in_worker` returns what its block returns, in each worker, as
`value`, such as a connection of the worker's own. Outside a worker,
`value` fails:

```ruby
Duel.configure do |c|
  redis = c.in_worker do |w|
    Redis.new(url: ENV.fetch("REDIS_URL")).tap { |r| w.at_stop { r.close } } # when the worker ends
  end
  c.metric("redis_commands") { redis.value.info("stats").fetch("total_commands_processed").to_i }.costly
end
```

## Run each version on its own Ruby

By default, both versions run on the Ruby that runs `duel`. To compare a
branch that upgrades Ruby, set `c.ruby = :version_file`, or run
`duel --ruby version-file`. Duel then runs each version on the Ruby that
its own version file names: `.ruby-version`, `.tool-versions`, or
`mise.toml`, in the version's directory or the nearest directory above
it. If that's the Ruby that runs `duel`, Duel uses it. As the version
managers do, Duel takes a version with or without a `ruby-` prefix,
another Ruby by its name (`jruby-10.1.2.0`), and a partial version, such
as `3.4`, as any version that starts with it. Otherwise, Duel finds that
Ruby with whichever of rbenv, chruby, mise, and asdf has it installed. A
version without a version file runs on the runner's Ruby. If a version
asks for a Ruby that isn't installed, the run fails and says which Ruby
it needs.

`c.ruby` also takes the path of a Ruby for both versions, or a block
that receives the version's directory and returns the path of its Ruby:

```ruby
c.ruby = ->(root) { File.join(Dir.home, ".rubies", File.read(File.join(root, ".ruby-version")).strip, "bin", "ruby") }
```

When the two versions run on different Rubies, the report shows each
version's `RUBY_DESCRIPTION`. A version on another Ruby needs its bundle
installed for that Ruby. For example, install it with
[`c.prepare(:version)`](#prepare-each-version), whose `bundle install`
runs on the version's Ruby. To install the baseline's Ruby on CI, see
[Run each version on its own Ruby on CI](ci.md#run-each-version-on-its-own-ruby-on-ci).

## Add your own metrics

Anything that you can measure around a sample can be a metric. A metric
is one of the following kinds:

- A *counted* metric fails on any increase.
- A *ratio* metric is judged the same way as CPU time.

### Measure running totals

Most metrics are running totals. Give `c.metric` a name and a block that
reads the total, and Duel measures how much the total grows during each
sample. For example, the following counts the Active Record queries of a
gem that adds to models:

```ruby
# .duel.rb
Duel.configure do |c|
  queries = 0
  subscriber = nil
  c.metric("sql_queries") { queries }
    .open do # (in workers only: .duel.rb is loaded by the runner too)
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end
    end
    .close { ActiveSupport::Notifications.unsubscribe(subscriber) }
end
```

The runner loads `.duel.rb` too, so set up what the metric reads in each
worker with `open`, and let go of it with `close`. In each worker, Duel
runs the `open` block when it opens the metric, before the metric reads
anything, and the `close` block when the worker ends. A metric whose
measures are all left out (see [Metric settings](#metric-settings))
isn't made, so its blocks don't run. `open`, `close`, `details`, and
`costly` each return the metric, so you can chain them. A
[metric class](#write-a-metric-class) has the same four, as methods.

For other setup that only a worker needs, see
[Run code in each worker](#run-code-in-each-worker).

To read several totals at once, pass `c.metric` a Hash of names and
their settings. The block returns the totals by name, or `nil` for a
total that it can't read this time.

The following example measures what Redis did for each benchmark, from
its command statistics. It reads them over a connection of the metric's
own, not the one that's being measured. `c.in_worker` makes that
connection in each worker, and its `value` fails anywhere else:

```ruby
Duel.configure do |c|
  redis = c.in_worker do |w|
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

### Explain a regression

To explain a regression, call `details` with a block on what `c.metric`
returns. Duel passes the block the sample's *stretches* and the sample
itself. `sample.n` is the sample's number of iterations.

A stretch is the pair of readings at its start and its end. Each reading
has its `totals`, and `total("name")` returns one of them, or fails if
it couldn't be read. A sample is one stretch, or several if it has
`untimed` blocks, or if its benchmark runs inside an `around_iteration`
hook and the metric isn't costly.

A reading can also carry what its totals came from. If the metric's
block returns `[totals, context]`, each reading has that context as its
`context`. [Steep](https://github.com/soutaro/steep) infers both types
from the block. For example, a block that reads Integers has Integer
totals.

```ruby
c.metric("sql_queries") { [queries, Statements.counts] }.details do |stretches, sample|
  Statements.top(3, stretches, per: sample.n) # each stretch's Statements.counts, at its start and its end
end
```

Duel calls the `details` block after every sample, not only after a
regression, so keep it cheap. Return nothing, or something cheap, unless
something looks worse. For everything that the block receives, and when
Duel calls it, see [Explain a sample](plugins.md#explain-a-sample).

### Account for the cost of reading

Reading a total can add to it. In the Redis example, each `INFO` is one
more command. Duel corrects for this in counted totals: each worker
first reads them twice in a row a few times, and then subtracts the
smallest growth from every sample.

If reading a total costs nothing, such as a count that your own code
keeps, Duel finds that it costs nothing, and subtracts nothing, so you
don't need to say so. If your block subtracts a varying cost of its own
reading, set `calibrate: false`. Duel doesn't correct ratio totals,
because a reading's cost isn't steady enough to subtract.

If reading the totals takes time, such as a round trip to a server,
call `costly` on what `c.metric` returns:

```ruby
c.metric("redis_commands") { redis.value.info["total_commands_processed"] }.costly
```

Duel then reads the totals only when a sample starts and stops, even
for a benchmark with an `around_iteration` hook, and subtracts what the
hook adds to them. For more information, see
[Undo each iteration](benchmarks.md#undo-each-iteration). Don't call `costly` on a
metric that's cheap to read, such as a count that your own code keeps,
because learning what the hook adds takes a few samples of each
benchmark with one.

### Metric settings

Every setting is optional:

| Setting | Applies to | Description |
|---|---|---|
| `kind:` | All | `:counted` (the default), which is exact and fails on any increase, or `:ratio`, which is judged by paired ratios with a confidence interval, the same way as CPU time. |
| `unit:` | All | What the metric is in, as reports show it. `"ns"`, `"µs"`, `"ms"`, and `"s"` show it as time, and set `unit_ns`. Any other unit is either a word with its plural, such as `%w[row rows]` (1 row, 2 rows), or a symbol that's the same for any number, such as `"B"` or `"KB"`. A word without its plural fails. |
| `floor:` | Ratio | The least that a sample must measure, on either version, to be judged. |
| `cpu_floor:` | Ratio | The least share of the sample's CPU time that the metric must be (in time, by `unit_ns`), on either version, to be judged. For example, `0.05` for 5%. |
| `limit:` | Ratio | The ratio above which the metric is slower. The default is the run's limit. |
| `unit_ns:` | Ratio | Nanoseconds per unit, to size samples by the metric. A time `unit:` sets it. |
| `sizes_samples:` | Ratio | `false` for a metric that's too noisy to size samples by. |
| `across:` | Ratio | `false` for a metric that's too noisy to judge across the board, where the margin is a quarter of its limit. |
| `tolerance:` | Counted | How much more per iteration still doesn't count as more. |
| `allowance:` | Counted | How much more per sample still doesn't count as more, for noise that doesn't grow with the iterations. |
| `calibrate:` | Counted | `false` to keep what a reading costs in the total, for a block that subtracts it itself. A reading that costs nothing needs no setting. |

A setting that doesn't exist fails, such as `toleranse:`, and so does a
kind that doesn't exist.

You can change the settings of any measure, including a plugin's and
Duel's own, or leave a measure out, with `c.measure`:

```ruby
c.measure("redis_cpu", limit: 1.1)
c.measure("cpu", limit: 1.05)
c.measure("instructions", skip: true)
```

To set up nothing for a measure that's left out, a metric's `open` can
call `c.skip?("name")`.

Duel reads metrics in the order that you add them before a sample, and
in reverse order after it, outside the built-in metrics. That way, the
metrics' own work isn't counted in allocations, instructions, or CPU
time. Duel also pauses metrics around `untimed` blocks, and around what
an `around_iteration` hook does outside each iteration, so that work
isn't counted. A costly metric isn't paused around the hook's work,
which Duel subtracts instead.

### Write a metric class

For what running totals can't express, write a subclass of
`Duel::Metric`. It uses the same names as running totals: `open`,
`close`, `details`, and `costly?`. Its per-sample methods end in
`_sample`, so they're never mistaken for those that run once in each
worker. A subclass defines the following methods:

| Method | Description |
|---|---|
| `self.measures` | Names what the metric measures, with the settings in [Metric settings](#metric-settings), for example `{"wait" => {kind: :ratio, unit: "ns"}}`. By default, it's one counted measure named `self.metric_name`, the class's name in snake case: `QueryCount` is `query_count`. |
| `self.available?` | Returns `false` where the metric can't measure, to leave it out. |
| `self.costly?` | Returns `true` for a metric that's costly to read, such as one that queries a server, so that Duel doesn't pause it around each iteration inside an `around_iteration` hook. For more information, see [Account for the cost of reading](#account-for-the-cost-of-reading). |
| `open` | Called once in each worker, after its `c.in_worker` blocks, to set up what the metric reads, such as a subscription. |
| `start_sample(sample)` | Called before every sample. `sample.n` is the sample's number of iterations, and `sample.benchmark` is the benchmark, with its `name`, `only`, and `peak_memory`. |
| `stop_sample` | Called after the sample. Returns what was measured, or a Hash of measurements by name. |
| `pause_sample` and `resume_sample(sample)` | Called around an `untimed` block, and around what an `around_iteration` hook does outside each iteration (unless the metric is costly). By default, they call `stop_sample` and `start_sample`. |
| `details` | Explains a regression. See the following paragraphs. |
| `close` | Called when the worker ends, to let go of what `open` set up. Duel closes metrics last first. |

A metric also has the following methods to call:

- `settings`: its settings by measure name, as the configuration has
  them after `c.measure`'s changes, with every setting filled in. A
  metric that measures one thing gets one setting with
  `setting(:allowance)`. Otherwise, name the measure:
  `setting(:allowance, "rows")`.
- `within?(more, n)`: whether a count that grew by `more` over `n`
  iterations is still within its tolerance and allowance, as Duel judges
  it. `Duel::Metric.within?(more, n, tolerance:, allowance:)` does the
  same for any count.

To explain a regression, define `details`. It returns text, or text by
measure name, about the sample that the metric last stopped. Duel shows
it under the regression for each version, for example
`retained_objects (candidate): 100 String, 50 Hash`. For a count, Duel
shows what the metric said of the sample that the count came from.

For when Duel calls `details`, see [Explain a sample](plugins.md#explain-a-sample).
Duel calls `details` after every sample that the metric measured, so
keep it cheap. Return nothing, or something cheap, unless something
looks worse, for example `return if within?(@retained, @n)`.

To add the metric, pass its class to `c.metric`:
`c.metric(MyMetric)`.

## Use plugins

A plugin packages what a server or a library needs, such as a server for
each worker, hooks, and metrics. For the plugins that are available, and
how to add one, see [Plugins](../README.md#plugins).

`c.use :redis` requires `duel/redis`, from the duel-redis gem, and
configures Duel for the plugin, once. A plugin that needs another uses
it too, such as duel-rails, which uses duel-activerecord. Using a plugin
again does nothing more, and returns what the first use returned, such
as the plugin's own connection to its server. To give a plugin options,
use it yourself, before a plugin that uses it: a later use can repeat
the options that the first use gave, but another option fails, because
the plugin is configured already.

Duel's report lists the plugins that the configuration used.

Each worker loads Duel, and every plugin that the runner loaded, from
where the runner loaded them, ahead of the version's own bundle. Both
versions are measured with the same Duel and plugins, even a version
whose bundle doesn't have them, or has older versions of them.

To write your own plugin, see [Write a Duel plugin](plugins.md).
