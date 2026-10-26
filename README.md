# ⚔️ Duel: Performance regression guards for Ruby

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![Test](https://github.com/sferik/duel-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/test.yml)
[![Lint](https://github.com/sferik/duel-ruby/actions/workflows/lint.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/lint.yml)
[![Mutant](https://github.com/sferik/duel-ruby/actions/workflows/mutant.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/mutant.yml)
[![Typecheck](https://github.com/sferik/duel-ruby/actions/workflows/typecheck.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/typecheck.yml)
[![Plugins](https://github.com/sferik/duel-ruby/actions/workflows/plugins.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugins.yml)
[![Gem Version](https://badge.fury.io/rb/duel.svg)](https://rubygems.org/gems/duel)

Duel runs your benchmarks on two versions of your code side by side and fails
if the new code is slower. Add it to your app's CI and it will prevent your
code from becoming slower.

```sh
$ duel
Comparing 12 benchmarks, 2 at a time: baseline /src/.3f9c2a1b against candidate /src/my_parser (slower: a 99.0% interval above 1.02)
  parse: a small document                            0.6s n=412    cpu 0.998 [0.991, 1.006] same  allocations 20
! parse: a large document                            1.1s n=9      cpu 1.081 [1.062, 1.097] slower  allocations 5790
...
REGRESSION parse: a large document: worse cpu in every measurement
  cpu: 112.4µs → 121.5µs an iteration (1.08x)
12 benchmarks in 14s: 1 regressed, 0 errors, 0 with a timing too close to the limit to settle
```

## Never slower

Duel exists to enforce a policy that the WebKit project sets out on its
[Performance](https://webkit.org/performance/) page:

> The way to make a program faster is to never let it get slower.
>
> We have a zero-tolerance policy for performance regressions. If a patch
> lands that regresses performance according to our benchmarks, then the
> person responsible must either back the patch out of the tree or drop
> everything immediately and fix the regression.
>
> Common excuses people give when they regress performance are, "But the
> new way is cleaner!" or "The new way is more correct." We don't care.
> No performance regressions are allowed, regardless of the reason. There
> is no justification for regressing performance. None.

WebKit backs those words with its benchmarks, and with the discipline to
treat a slowdown as seriously as a broken build. Duel brings that idea
to Ruby. If you adopt the policy, Duel tells a pull request that it made
your code slower before the pull request is merged. All credit for the
idea belongs to the WebKit project, and any shortcomings in carrying it
out are Duel's.

## Install Duel

1. Add Duel to the `development` group of your `Gemfile`:

   ```ruby
   # Gemfile
   group :development do
     gem "duel"
   end
   ```

2. Run `bundle install`.

3. Set Duel up in your project:

   ```sh
   bundle exec duel init
   ```

   It adds StackProf to your `Gemfile`, for profiles of regressions, so
   run `bundle install` again.

### Set up a project

`duel init` sets Duel up in a gem or an app, and writes the following:

| File | What it's for |
|---|---|
| `.duel.rb` | Duel's configuration. It builds a project that has an `ext/` directory with `rake compile`, and runs each version on its own Ruby when the project has a `.ruby-version`. Without a gemspec to name the library, it names the only file in `lib/`, or leaves the library for you to set. See [Configure Duel](docs/configuration.md). |
| `duel/<library>_duel.rb` | An example benchmark to replace with your own, with advice on writing benchmarks that tell a regression from noise. See [Write a benchmark](#write-a-benchmark). |
| `.github/workflows/perf.yml` | The GitHub Actions workflow in [Run Duel in CI](docs/ci.md#catch-slow-creep). For a project in a subdirectory of its repository, the workflow is at the repository's root, named after the subdirectory, and runs in it. |
| `Rakefile` | If there is one, `duel init` adds Duel's Rake task to it, as `rake duel`. See [Run Duel in CI](#run-duel-in-ci). |
| `Gemfile` | Unless it mentions StackProf already, `duel init` adds `gem "stackprof", platforms: :mri` to its `development` group (or, without one, to its end), so Duel can show where a regression spent its extra time. StackProf runs on CRuby only, so the gem isn't installed on JRuby or TruffleRuby. |

`duel init` doesn't overwrite a file that exists. To overwrite it, use
`--force`. To see what `duel init` would do without writing anything,
use `--dry-run`. When it's done, `duel init` lists the next steps.

For a Rails app, use
[duel-rails](https://github.com/sferik/duel-ruby/tree/main/plugins/rails)
instead: add it to your `Gemfile`, and run
`bin/rails generate duel:install`.

### Adopt Duel with an agent

[AGENT_PROMPT.md](AGENT_PROMPT.md) is a prompt that tells a coding agent
how to add Duel to your project. The agent does the following:

* Picks the code that's worth guarding.
* Writes benchmarks that don't vary from run to run.
* Checks that the benchmarks pass against the unchanged code, and that
  they catch a deliberate slowdown.
* Adds the CI workflow.

To use the prompt, paste it into the agent, or point the agent at the
file. The prompt also ships with the gem. After you install Duel, it's
in the directory that `bundle info duel --path` prints.

## Write a benchmark

By convention, add benchmarks in files named `*_duel.rb` in the `duel/`
directory.

```ruby
# duel/parser_duel.rb
duel "parse: a small document" do
  MyParser.parse("[1, 2, 3]")
end
```

Duel times the block that you pass to `duel`, and runs it as many times
as a sample needs. To do work that you don't want timed, put it in a
`once` block. Duel runs it once, the first time that the benchmark runs,
before it measures anything:

```ruby
duel "parse: a large document" do
  once { @input = File.read("test/fixtures/large.json") } # not timed
  MyParser.parse(@input)                                  # timed
end
```

If your code handles many items at once, give the block a parameter.
Duel then runs the block once per sample, and passes it the number of
iterations. To prepare each sample's work without timing it, wrap the
preparation in `untimed`, which pauses measuring:

```ruby
duel "queue: drain the queue" do |n|
  queue = untimed { MyQueue.new(Array.new(n) { |i| i }) } # not timed
  queue.drain                                             # timed
end
```

Benchmarks can do much more, such as run code around their samples or
iterations, undo what each iteration changes, and time a whole process,
such as your app's boot. For more information, see
[Write benchmarks](docs/benchmarks.md).

## Run Duel

Run `duel` from your project's root. By default, it compares your
working tree with the commit where `HEAD` left the main branch:

```sh
duel                       # against where HEAD left the main branch
duel --base v1.4.0         # against any git ref
duel --base last-release   # against the newest release tag before HEAD
duel --filter "^parse:"    # only benchmarks whose names match (a regular expression)
duel --base ../old         # against a tree on disk, already built
```

To see every option, such as `--processes`, `--timeout`, and `--limit`,
run `duel --help`. To write the report in Markdown too, use
`--markdown`. For more information, see
[Report on a pull request](#report-on-a-pull-request). To write it as
JSON, for a program to read, use `--json`. For more information, see
[Read Duel's report as JSON](docs/json.md).

Duel runs one comparison at a time in a project, because two runs would
share the project's `tmp/duel` directory and its baseline's checkout. A
second run fails and names the process that's running the first. A run
that crashes leaves nothing behind that blocks the next run.

Where it's hard to pass options, such as behind a Rake task or in a CI
expression, set these environment variables instead:

| Variable | Option |
|---|---|
| `DUEL_BASE` | `--base` |
| `DUEL_FILTER` | `--filter` |
| `DUEL_FORCE=1` | `--force` |

An option on the command line takes precedence over its variable, and
an empty variable counts as unset.

For where the baseline comes from, how Duel checks it out and builds it,
and how it compares a project in a subdirectory of its repository, see
[Where the baseline comes from](docs/how-it-works.md#where-the-baseline-comes-from).

### Timeouts and exit status

A benchmark that hangs, or that waits on a server that died, doesn't
hang the run. If a worker takes more than a minute to load or to answer,
Duel stops the worker and reports the benchmark as an error. To change
the limit, use `--timeout`.

`duel` exits with one of the following statuses:

| Status | Meaning |
|---|---|
| `0` | Nothing got slower, or there was nothing to compare. |
| `1` | Something got slower, or a benchmark failed. |
| `2` | Duel couldn't compare. |

## Run Duel in CI

Run `bundle exec duel` as a step in your CI job. Its exit status passes
or fails the job, and its output shows what got slower, by how much, and
where the extra time went. For example, on GitLab:

```yaml
duel:
  script: bundle exec duel
  variables:
    GIT_DEPTH: 0 # the baseline comes from history
```

To run Duel from Rake, define a task with `Duel::RakeTask`. Any
arguments after the task's name are passed to `duel`:

```ruby
require "duel/rake_task"
Duel::RakeTask.new(:perf)
Duel::RakeTask.new(:perf_since_release, "--base", "last-release")
```

`duel init` writes a GitHub Actions workflow,
`.github/workflows/perf.yml`. It compares each pull request with the
main branch, each push to `main` with the commit before it, and, on a
schedule, your last release, to catch slow creep. It also comments on a
pull request with Duel's report when a benchmark fails. For the
workflow, and for a branch that upgrades Ruby, see
[Run Duel in CI](docs/ci.md).

### Report on a pull request

On GitHub Actions, Duel adds its report to the job's summary, in
Markdown, whatever the outcome: a comparison, nothing to compare, or an
error. To write the same Markdown to a file, for example to post it as a
comment, use `--markdown`:

```sh
duel --markdown tmp/duel.md
```

The report is short. In view, it has the verdict, the two commits that
Duel compared (bare, so GitHub links them), and how the baseline was
chosen. When a benchmark fails, a table shows what got worse and by how
much, or the error, and the frame where the most extra CPU time went.
Everything else is collapsed: each regression explained as it is in the
terminal, every benchmark's timings, the timings too close to call, the
verdicts across the board, each version's Ruby when they differ, and
how Duel decides. So the report stays short with hundreds of
benchmarks:

````markdown
### 🔻 Duel: 1 benchmark failed

Compared 8e4d0b7 with 3f9c2a1 (where HEAD left `origin/main`).

| Benchmark | Failure | Most extra CPU in |
|---|---|---|
| `parse: a large document` | instructions +7.1%, cpu +8.1%, allocations 5790 → 5791 | `MyParser::Lexer#next_token` +6.8% |

<details>
<summary>Details: 12 benchmarks in 14s</summary>

**`parse: a large document`**: worse instructions, cpu, allocations in every measurement

```text
instructions: 1.521e+06 → 1.629e+06 an iteration (1.07x)
cpu: 112.4µs → 121.5µs an iteration (1.08x)
allocations: 5790 → 5791 an iteration
where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):
   +6.8%   +7.1%  MyParser::Lexer#next_token
   +0.4%   +0.4%  String#byteslice
```

| Benchmark | Verdict | Timings (ratio [interval]) | Counts an iteration |
|---|---|---|---|
| `parse: a large document` | **regressed** | instructions 1.071 [1.069, 1.073] slower<br>cpu 1.081 [1.062, 1.097] slower | allocations 5790 → 5791 |
| `parse: a short line` | same | instructions 1.000 [1.000, 1.000]<br>cpu 1.002 [0.992, 1.017] |  |

...

</details>
````

When every benchmark passes, the heading says `🟢 Duel: 100% of
benchmarks passed`, and only the commits are in view. A timing too
close to the limit to call doesn't fail the run, and is in the details.
A benchmark that the baseline can't run (a new one, say) is skipped, and
the heading counts it. A run that has nothing to compare, or no release
to compare against, says so under ⬜, and one that couldn't compare
says why under 🔻.

The workflow that `duel init` writes posts this report as a comment on
the pull request when a benchmark fails, or when Duel couldn't compare.
After such a comment, the first run that passes posts one more, so the
last comment is never stale. It never edits a comment, so the pull
request keeps every report. To comment on every run, on every result
but nothing to compare, or never, set
[`c.comment`](docs/configuration.md#choose-when-to-comment-on-a-pull-request)
in `.duel.rb`. For more information, see
[Comment on a pull request](docs/ci.md#comment-on-a-pull-request).

In a project where people push to `main` directly, set
[`c.fail_on = :pull_requests`](docs/configuration.md#fail-only-a-pull-request)
to pass a regression in a push, with a warning, and comment on the
pushed commit with the report instead.

### Show that a project is guarded

To show that Duel guards your project, add its badge to your README,
next to your other badges:

```markdown
[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
```

The badge links to Duel. It doesn't show whether a comparison passed:
your CI's status does that.

## Plugins

A plugin packages what a server or a library needs, such as a server for
each worker, hooks, and metrics, for any project to use. The following
plugins are available:

| Plugin | Build | What it adds |
|---|---|---|
| [Rails](https://github.com/sferik/duel-ruby/tree/main/plugins/rails) | [![duel-rails](https://github.com/sferik/duel-ruby/actions/workflows/plugin-rails.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-rails.yml) | For a Rails app: each version booted like production, with its own bundle and database, and benchmarks of its requests, judged on its queries, views, and cache use too. |
| [ActiveRecord](https://github.com/sferik/duel-ruby/tree/main/plugins/activerecord) | [![duel-activerecord](https://github.com/sferik/duel-ruby/actions/workflows/plugin-activerecord.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-activerecord.yml) | The queries, transactions, and records that each benchmark took, from Active Record's notifications (for example, an N+1), with any database. |
| [PostgreSQL](https://github.com/sferik/duel-ruby/tree/main/plugins/postgresql) | [![duel-postgresql](https://github.com/sferik/duel-ruby/actions/workflows/plugin-postgresql.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-postgresql.yml) | A PostgreSQL server for each worker, and the queries, rows, blocks, and time that each benchmark took of it, by statement. |
| [MySQL](https://github.com/sferik/duel-ruby/tree/main/plugins/mysql) | [![duel-mysql](https://github.com/sferik/duel-ruby/actions/workflows/plugin-mysql.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-mysql.yml) | A MySQL server for each worker, and the queries, rows (returned and examined), and time that each benchmark took of it, by statement. |
| [Redis](https://github.com/sferik/duel-ruby/tree/main/plugins/redis) | [![duel-redis](https://github.com/sferik/duel-ruby/actions/workflows/plugin-redis.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-redis.yml) | A Redis server for each worker, and the Redis CPU time, commands, and round trips that each benchmark took. |
| [Memcached](https://github.com/sferik/duel-ruby/tree/main/plugins/memcached) | [![duel-memcached](https://github.com/sferik/duel-ruby/actions/workflows/plugin-memcached.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-memcached.yml) | A memcached server for each worker, and the operations, misses, and bytes that each benchmark took of it. |
| [GVL](https://github.com/sferik/duel-ruby/tree/main/plugins/gvl) | [![duel-gvl](https://github.com/sferik/duel-ruby/actions/workflows/plugin-gvl.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-gvl.yml) | How long the threads of a benchmark with threads of its own waited for the GVL, on CRuby. |
| [Retained](https://github.com/sferik/duel-ruby/tree/main/plugins/retained) | [![duel-retained](https://github.com/sferik/duel-ruby/actions/workflows/plugin-retained.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-retained.yml) | The objects that each benchmark left alive (for example, a leak, or a cache that grows with every call), on CRuby. |

To use a plugin, add its gem to your `Gemfile`, and call `c.use` in
`.duel.rb` with the plugin's name and any of its options:

```ruby
# .duel.rb
Duel.configure do |c|
  c.use :redis
  c.use :activerecord, query_time: true
end
```

For what `c.use` does, and how a plugin's options work, see
[Use plugins](docs/configuration.md#use-plugins). To write your own
plugin, see [Write a Duel plugin](docs/plugins.md).

## Learn more

The [Duel guide](docs/README.md) covers the rest:

- [Write benchmarks](docs/benchmarks.md): hooks, undoing each
  iteration, sharing code, choosing what a benchmark is judged on, and
  benchmarking a whole process.
- [Configure Duel](docs/configuration.md): `.duel.rb`, preparing each
  worker and each version, each version's own Ruby, your own metrics,
  and plugins.
- [Run Duel in CI](docs/ci.md): the GitHub Actions workflow, slow creep,
  and comments on pull requests.
- [How Duel works](docs/how-it-works.md): how it tells a regression from
  noise, what it measures, profiles, where the baseline comes from, and
  JIT compilers.
- [Troubleshooting](docs/troubleshooting.md): what to do when Duel
  can't compare, or reports what you don't expect.
- [Write a Duel plugin](docs/plugins.md): plugin conventions, hooks,
  metrics, and tests.
