# duel-rails

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-rails](https://github.com/sferik/duel-ruby/actions/workflows/plugin-rails.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-rails.yml)
[![Gem Version](https://badge.fury.io/rb/duel-rails.svg)](https://rubygems.org/gems/duel-rails)

A [Duel](https://github.com/sferik/duel-ruby) plugin for Rails apps. It
fails a pull request that makes your app's requests slower, or makes
them query the database, render views, or allocate more.

```sh
$ bin/rake duel
Comparing 3 benchmarks, 2 at a time: baseline /src/.8e2f1c4 against candidate /src/my_app (slower: a 99.0% interval above 1.02)
  posts: index        2.7s n=4   cpu 1.004 [0.991, 1.018] same  active_record_queries 1→2  rails_views 4→7  allocations 988→1530
...
REGRESSION posts: index: worse active_record_queries, rails_views, allocations in every measurement
  active_record_queries: 1 query → 2 queries an iteration
  active_record_queries (candidate): an iteration: 1× SELECT "posts".* FROM "posts"; 1× SELECT COUNT(*) FROM "posts"
  rails_views (candidate): an iteration: 6× posts/_post.html.erb; 1× posts/index.html.erb; 1× layouts/application.html.erb
```

duel-rails sets Duel up so that each version of your app runs the way
production does, with everything of its own:

- **Booted like production.** Each version boots in a `benchmark`
  environment that's based on your production environment, with eager
  loading and YJIT, but without SSL, logging, or other databases.
- **Its own bundle and Ruby.** Each version runs its own `Gemfile.lock`,
  on the Ruby that its own `.ruby-version` names, so a pull request that
  upgrades a gem, Rails, or Ruby itself is compared too.
- **Its own database.** Each worker gets a database of its own, with its
  version's schema and your fixtures or seeds loaded into it.
- **Requests, through the whole stack.** A benchmark sends a request
  through your app's middleware, routing, controller, and views, without
  a server, performs the jobs that the request enqueued, and rolls back
  what it wrote. Only the request and its jobs are measured.
- **More than time.** Besides CPU time and allocations, each request is
  judged on its queries (with
  [duel-activerecord](https://github.com/sferik/duel-ruby/tree/main/plugins/activerecord)), the
  views it rendered, and its cache reads, misses, and writes.
- **Boot time.** A benchmark of your app's boot guards how long a fresh
  process takes to start.

## Install duel-rails

1. Add duel-rails to the `development` group of your `Gemfile`:

   ```ruby
   # Gemfile
   group :development do
     gem "duel-rails"
   end
   ```

2. Run `bundle install`.

3. Run the generator:

   ```sh
   bin/rails generate duel:install
   ```

   The generator makes the following files:

   | File | What it is |
   |---|---|
   | `.duel.rb` | Duel's configuration: `c.use :rails`, with your database, and your fixtures if you have any. If your app has a `.ruby-version`, also `c.ruby = :version_file`. See [Its own Ruby](#its-own-ruby). |
   | `config/environments/benchmark.rb` | The environment that each version boots in, based on production. |
   | `duel/requests_duel.rb` | A benchmark of each of your app's first 10 routes that a GET reaches without parameters. |
   | `duel/boot_duel.rb` | A benchmark of your app's boot. See [Benchmark your app's boot](#benchmark-your-apps-boot). |
   | `.github/workflows/perf.yml` | A GitHub Actions workflow that runs Duel on pull requests, on pushes to `main`, and nightly against your last release, and has the second workflow comment on a pull request with Duel's report when a benchmark fails. It never edits a comment, and after a failure, posts one more when a run passes. To comment on every run, or never, set `c.comment` in `.duel.rb`: see [Choose when to comment on a pull request](https://github.com/sferik/duel-ruby/blob/main/docs/configuration.md#choose-when-to-comment-on-a-pull-request) and [Report on a pull request](https://github.com/sferik/duel-ruby#report-on-a-pull-request). For an app in a subdirectory of its repository, the workflow is at the repository's root. See [An app in a monorepo](#an-app-in-a-monorepo). |
   | `.github/workflows/perf-comment.yml` | A second workflow, which comments on a pull request with the report once the first has run, with a token that can write, so a pull request from a fork gets a comment too. It runs none of the pull request's code. See [Comment on a pull request](https://github.com/sferik/duel-ruby/blob/main/docs/ci.md#comment-on-a-pull-request). |

   The generator also adds `gem "stackprof", platforms: :mri` to your
   `Gemfile`'s `development` group, unless it has StackProf already, so
   Duel can show where a regression spent its extra time. StackProf runs
   on CRuby only, so the gem isn't installed on JRuby or TruffleRuby. If
   your database is PostgreSQL or MySQL, the generator adds
   [duel-postgresql](https://github.com/sferik/duel-ruby/tree/main/plugins/postgresql) or
   [duel-mysql](https://github.com/sferik/duel-ruby/tree/main/plugins/mysql) too.
   Run `bundle install` again.

4. Review the generated files, and commit them.

5. Run the benchmarks against your main branch:

   ```sh
   bin/rake duel
   ```

   To compare your code with itself, which checks that the setup works,
   run `bin/rake duel DUEL_FORCE=1`.

The `rake duel` task comes with duel-rails. You can also run `bundle exec
duel`, with any of [Duel's options](https://github.com/sferik/duel-ruby#run-duel).

## Benchmark requests

Benchmarks go in files named `*_duel.rb` in `duel/`. To benchmark a
request, use `duel_request` with a name and the request's method and
path:

```ruby
# duel/requests_duel.rb
duel_request "posts: index", "GET /posts"
duel_request "posts: page 2", "GET /posts?page=2"
duel_request "posts: create", "POST /posts", params: {post: {title: "Hi"}}
duel_request "api: search", "POST /api/search", json: {q: "duel"}, headers: {"Accept" => "application/json"}
```

Each iteration sends the request once, through the whole Rack stack,
and then performs the jobs that the request enqueued. See
[Measure the jobs that a request enqueues](#measure-the-jobs-that-a-request-enqueues).
After each iteration, duel-rails rolls back what the request and its
jobs wrote to the database, so every request finds the same data.

duel-rails rolls back with an `around_iteration` hook,
`Duel::Rails::ROLLBACK`, so the rollback isn't measured. Before each
iteration, the hook pins each database connection that Active Record
writes through, in a transaction, and after the iteration it rolls the
transaction back, the way that Rails's transactional tests do. Duel
measures only the iteration: the request, its jobs, and the
transactions that they open, which become savepoints.

To leave the rollback out of what it measures, Duel pauses every metric
after each iteration, and resumes it before the next. A metric that
reads a server, such as duel-postgresql's statistics, is costly to read,
so Duel doesn't pause it: it reads the server only when a sample starts
and stops, and subtracts what pinning and rolling back add, which it
learns in each worker. Pausing the other metrics still takes a little
time per iteration. To measure a request without the rollback, and
without the pauses, pass `rollback: false`.

`duel_request` takes the following options:

| Option | Description |
|---|---|
| `params:` | Form parameters. For a GET, they go in the query string. |
| `json:` | A body, sent as JSON with a `Content-Type` of `application/json`. Use either `params:` or `json:`, not both. |
| `headers:` | Request headers, by name, for example `{"Accept" => "text/csv"}`. |
| `status:` | The status that the response must have: an Integer, or a Range. The default is `200..399`. Any other status fails the benchmark, because it's measuring an error page. |
| `rollback:` | `false` to keep what the request writes, and to run its iterations without pausing the metrics between them. The default is `true`. To start each sample with the same data anyway, see [Start every sample with the same data](#start-every-sample-with-the-same-data). |
| `only:`, `peak_memory:` | Duel's options for what the benchmark is judged on. See [Choose what a benchmark is judged on](https://github.com/sferik/duel-ruby/blob/main/docs/benchmarks.md#choose-what-a-benchmark-is-judged-on). |
| `setup:`, `teardown:`, `before_sample:`, `around_iteration:`, `after_iterations:` | The benchmark's own hooks, as `duel` takes them. See [Run code around a benchmark](https://github.com/sferik/duel-ruby/blob/main/docs/benchmarks.md#run-code-around-a-benchmark). An `around_iteration:` hook would replace the rollback, so it raises an `ArgumentError` unless you also pass `rollback: false`. To run a hook around the rollback, give it to the whole file instead. |

To change the request before it's sent, pass a block. The block
receives the request's Rack environment, and runs in the benchmark's
context, so it can use what the file's `setup` hooks set. For example,
to send a session cookie that a file's `setup` hook made, with a helper
of your own in `duel/duel_helper.rb`:

```ruby
setup { @cookie = session_cookie_for(User.find_by!(admin: true)) }

duel_request "admin: dashboard", "GET /admin" do |env|
  env["HTTP_COOKIE"] = @cookie
end
```

`duel_request` is a `duel`, so the hooks of its file and of `.duel.rb`
apply to it, and you can mix it with plain benchmarks of your models and
services:

```ruby
duel "invoice: totals for 100 lines" do
  once { @invoice = Invoice.includes(:lines).first }
  @invoice.recalculate_totals
end
```

### Roll back any benchmark

A plain `duel` that writes to the database, such as one that creates a
record, can roll back each iteration the way that a request does. Give
`Duel::Rails::ROLLBACK` as an `around_iteration` hook, at any level:

```ruby
# For one benchmark
duel "posts: create", around_iteration: Duel::Rails::ROLLBACK do
  Post.create!(title: "Hi")
end

# For every benchmark in a file, at its top
around_iteration(&Duel::Rails::ROLLBACK)

# For every benchmark, in .duel.rb
Duel.configure do |c|
  c.use :rails, fixtures: :all
  c.around_iteration(&Duel::Rails::ROLLBACK)
end
```

A `duel_request` already rolls back. Under a file's or `.duel.rb`'s
hook, its own rollback runs inside the outer one, which costs a little
more and changes nothing. A benchmark whose block takes the number of
iterations (`|n|`) can't run inside an `around_iteration` hook, so
don't give `.duel.rb` one if you have such benchmarks.

### Measure the jobs that a request enqueues

Some of a request's work runs later, in a job that it enqueues, such as
an email that it sends with `deliver_later`. So that a regression in
that work fails too, duel-rails performs the jobs that a benchmark
enqueues, and Duel measures them with the benchmark:

- In a request's benchmark, or any benchmark that's rolled back,
  duel-rails performs the jobs after each iteration, before it rolls
  back what the iteration wrote, so the jobs find its data.
- In any other benchmark, duel-rails performs the jobs after the
  iterations of each sample.

duel-rails performs them in an `after_iterations` hook, which Duel
measures with the iterations. For more information, see
[Run code around a benchmark](https://github.com/sferik/duel-ruby/blob/main/docs/benchmarks.md#run-code-around-a-benchmark).

duel-rails performs the jobs in order, along with any jobs that they
enqueue, and a job that's scheduled for later too. It discards the jobs
that were enqueued before a sample, such as by your seeds.

While Duel benchmarks your app, duel-rails's own queue is Active Job's
queue adapter, in place of the one that
`config/environments/benchmark.rb` sets. A job class that sets its own
`queue_adapter` keeps that adapter, so duel-rails doesn't perform its
jobs.

duel-rails performs jobs on Rails 7.2, 8.0, and 8.1 alike. In each,
a job that's enqueued inside a transaction can wait for the transaction
to commit, as Active Job decides: Rails 7.2 asks the adapter, and
duel-rails's says to wait, as Active Job's own adapters do. Rails 8.0
and later ask the job, with its `enqueue_after_transaction_commit`. The
transaction that duel-rails rolls each request back in doesn't count:
a job that waits is enqueued when the request's own transaction
commits.

To leave jobs out, and measure only what the request does itself, pass
`jobs: false` to `c.use :rails`.

### Start every sample with the same data

A benchmark that writes to the database without rolling back, such as a
`duel_request` with `rollback: false` or a plain `duel` that creates
records, leaves its writes for the samples after it. To start every
sample with the data that each worker loaded, pass `reset: true`:

```ruby
# .duel.rb
Duel.configure do |c|
  c.use :rails, fixtures: :all, reset: true
end
```

Before every sample of every benchmark, duel-rails then empties every
table, and loads your fixtures and seeds again. Duel doesn't measure
it, but it makes each run slower.

To reset only before the samples of one file's benchmarks, call
`Duel::Rails.reset_data` in the file's `before_sample` block:

```ruby
# duel/imports_duel.rb
before_sample { Duel::Rails.reset_data } # not measured

duel_request "imports: create", "POST /imports", params: {import: {rows: 100}}, rollback: false
```

### Benchmark your app's boot

The generator adds a benchmark of how long your app takes to boot:

```ruby
# duel/boot_duel.rb
duel_process "boot: the app", "bin/rails", "runner", "1"
```

Each sample runs `bin/rails runner` in a fresh process, for each
version, in turn. Duel judges it on its CPU time, including that of the
processes that it starts, and on its peak memory. For more information,
see Duel's [Benchmark a whole process](https://github.com/sferik/duel-ruby/blob/main/docs/benchmarks.md#benchmark-a-whole-process).

Each sample boots your app once for each version, so this benchmark
takes longer than a request's, from tens of seconds to a few minutes.

Each version's process runs with that version's bundle, in the
`benchmark` environment (`RAILS_ENV`). It doesn't get a database of its
own, so it measures your app's boot alone. If your app queries the
database as it boots, remove the benchmark.

## Each version's own

### The benchmark environment

Each version boots in the `benchmark` environment, from
`config/environments/benchmark.rb`. The generated file starts from your
production environment, and turns off what needs a deployment:

- SSL, host authorization, and forgery protection, because Duel sends
  requests without a server in front.
- Logging.
- Other databases: the cache uses memory, and Active Job uses its test
  adapter, so neither needs a database of its own.

Change it as your app needs, for example to stub a service that your
app calls over the network.

### Its own bundle

Each version runs its own `Gemfile` and `Gemfile.lock`. Before a
version's workers start, duel-rails installs its `Gemfile.lock`, on the
version's Ruby, once for each lockfile and Ruby, and keeps it installed
for later runs. So a pull request that upgrades a gem is measured with
the upgrade, and its baseline without it.

Duel loads itself, and every Duel plugin that the runner loaded,
duel-rails included, ahead of each version's bundle. That way, a
baseline from before you added Duel can still run, and both versions
are measured with the same Duel.

### Its own Ruby

If your app has a `.ruby-version`, the generated `.duel.rb` sets
`c.ruby = :version_file`. Each version then runs on the Ruby that its
own `.ruby-version` names, so a pull request that upgrades Ruby is
measured on the new Ruby, and its baseline on the old one. duel-rails
installs each version's bundle for its Ruby.

Each Ruby must be installed where Duel finds it: with rbenv, chruby,
mise, or asdf, or as the Ruby that runs Duel. For more information, see
Duel's [Run each version on its own Ruby](https://github.com/sferik/duel-ruby/blob/main/docs/configuration.md#run-each-version-on-its-own-ruby).
On GitHub Actions, the generated workflow installs your app's Ruby, and,
when the baseline's `.ruby-version` names another Ruby, that one too, so
a pull request, a push, or a nightly run against your last release
works there when your app upgrades Ruby.

To run both versions on the Ruby that runs Duel, remove
`c.ruby = :version_file`.

### Its own database

Each worker gets a database of its own, set in `DATABASE_URL`, which
Rails prefers to `config/database.yml`. Choose the database with
`database:`:

| `database:` | Each worker's database | Plugin |
|---|---|---|
| `:sqlite` (default) | A SQLite file in the worker's directory | None |
| `:postgresql` | A PostgreSQL server | [duel-postgresql](https://github.com/sferik/duel-ruby/tree/main/plugins/postgresql) |
| `:mysql2` or `:trilogy` | A MySQL server, through that adapter | [duel-mysql](https://github.com/sferik/duel-ruby/tree/main/plugins/mysql) |
| `nil` | None | None |

A database server's plugin also judges each request on what the server
did for it, by statement.

Each worker loads its version's schema into its database, from
`db/schema.rb` or `db/structure.sql`. So a pull request with a migration
is measured with its new schema, and its baseline with the old one.

### Its own data

Each worker then loads the data that you ask for. Its random numbers are
seeded first, and Faker's too if it's loaded, so both versions get the
same data:

```ruby
# .duel.rb
Duel.configure do |c|
  c.use :rails, database: :postgresql, fixtures: :all, seeds: true
end
```

Load data that every benchmark shares here. For data that one benchmark
needs, use a `setup` hook in its file, or a `once` block in the
benchmark.

> [!IMPORTANT]
> Duel loads the benchmark files before each worker's data, so don't
> query your database at the top level of a benchmark file. Do it in a
> `setup` hook or a `once` block.

## What each request is judged on

Besides Duel's own metrics (CPU time, instructions, and allocations),
each request is judged on the following:

| Metric | What it is | A regression |
|---|---|---|
| `active_record_queries` and the rest | Queries, cached queries, transactions, and records. See [duel-activerecord](https://github.com/sferik/duel-ruby/tree/main/plugins/activerecord). | Any increase |
| `rails_views` | Templates, partials, and layouts rendered. Each of a collection's partials counts. | Any increase |
| `rails_cache_reads` | Keys read from the cache | Any increase |
| `rails_cache_misses` | Keys read that weren't in the cache | Any increase |
| `rails_cache_writes` | Keys written to the cache | Any increase |

A regression in views shows which views a sample rendered most, as in
the example at the top of this page.

The transaction that duel-rails rolls each request back in isn't
measured, so it doesn't count in `active_record_transactions`, and the
queries that a request's jobs make count as the request's.

## Options

`c.use :rails` takes the following options:

| Option | Description |
|---|---|
| `database:` | Each worker's database. See [Its own database](#its-own-database). The default is `:sqlite`. |
| `fixtures:` | Fixtures from `test/fixtures` to load into each worker's database, by name, or `:all`. The default is none. |
| `seeds:` | `true` to run `db/seeds.rb` in each worker, after the fixtures. |
| `seed:` | What random numbers are seeded with. The default is 42. |
| `reset:` | `true` to empty every table, and load the fixtures and seeds again, before every sample. See [Start every sample with the same data](#start-every-sample-with-the-same-data). |
| `jobs:` | `false` to leave out the jobs that benchmarks enqueue. See [Measure the jobs that a request enqueues](#measure-the-jobs-that-a-request-enqueues). |
| `environment:` | The environment that each version boots in, and its processes run in. The default is `"benchmark"`. |
| `bundle:` | `false` to run every version with the runner's bundle. |
| `active_record:` | `false` to leave out Active Record's metrics, for an app without Active Record. |
| `query_time:` | `true` to also judge how long queries took. See [duel-activerecord](https://github.com/sferik/duel-ruby/tree/main/plugins/activerecord). |

Any other option goes to the database server's plugin, for example
`args:` or `setup:` for duel-mysql.

duel-rails uses duel-activerecord, and the database server's plugin,
with `c.use`. To give one of them options of its own, use it yourself,
before `c.use :rails`. duel-rails then uses the plugin that you
configured:

```ruby
# .duel.rb
Duel.configure do |c|
  c.use :activerecord, ignore: ->(payload) { payload[:sql].include?("pg_catalog") }
  c.use :rails, database: :postgresql, fixtures: :all
end
```

duel-rails also tells Duel to compare a change to `app/`, `config/`,
`db/`, `lib/`, `Gemfile`, `Gemfile.lock`, or `.ruby-version`, as well
as one to your benchmarks (`duel/`) or `.duel.rb`, which Duel always
watches.

## An app in a monorepo

Your app can be in a subdirectory of its repository, such as
`apps/blog`. Run the generator and `bin/rake duel` in the app's
directory, as usual. Duel checks out the whole repository for the
baseline, and compares the same subdirectory of it. The paths that
duel-rails watches are in the app's directory.

The generator writes the workflow at the repository's root, because
that's where GitHub Actions looks for it, and names it for the app's
directory, such as `.github/workflows/perf-apps-blog.yml`, so that
each app can have its own. The workflow runs Duel, and sets up Ruby
and the bundle, in the app's directory (`working-directory`).

## YJIT

Rails 7.2 and later turn YJIT on as the app boots. When YJIT is on,
Duel warms each benchmark up for two seconds before it measures it, so
that YJIT has compiled your app's code first.

## Requirements

duel-rails needs Rails 7.2 or later, and Ruby 3.4 or later. It doesn't
run on JRuby, whose Rails needs JDBC adapters.
