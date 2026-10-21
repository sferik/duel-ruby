# duel-activerecord

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-activerecord](https://github.com/sferik/duel-ruby/actions/workflows/plugin-activerecord.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-activerecord.yml)
[![Gem Version](https://badge.fury.io/rb/duel-activerecord.svg)](https://rubygems.org/gems/duel-activerecord)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that uses
Active Record: every benchmark is judged on what Active Record did for it
too, whatever the database.

| Metric | What it is | A regression |
|---|---|---|
| `active_record_queries` | the queries it sent the database: not schema queries, transactions' own statements (`BEGIN`, `COMMIT`...), or those the query cache answered | any increase |
| `active_record_cached_queries` | the queries the query cache answered | any increase |
| `active_record_transactions` | the transactions it opened, and savepoints | any increase |
| `active_record_instantiations` | the records it instantiated | any increase |
| `active_record_query_time` (when asked for) | how long its queries took, in elapsed time | > 5% slower, 99% confident |

So a change that adds an N+1 query, or saves records one transaction at
a time, fails on its counts, exactly, whatever its timings say. And on a
database server, whose work the benchmark's CPU time doesn't include,
the counts are the sign of it.

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-activerecord"
end
```

> [!NOTE]
> It needs Active Record 7.2 or later.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :activerecord }
```

`c.use` requires the plugin, so `.duel.rb` doesn't need to.

The plugin doesn't give workers a database: they connect as your
benchmarks do (in `duel/duel_helper.rb`, say), to one of their own (an
in-memory SQLite database, as here, or a file in the directory that
`c.prepare(:worker)` gives each worker) or to one all of them share. Then any benchmark is judged on
its queries:

```ruby
# duel/duel_helper.rb
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
load "db/schema.rb"
10.times { |i| Post.create!(title: "post #{i}").comments.create! }

# duel/posts_duel.rb
require_relative "duel_helper"

duel "posts: the index page" do
  PostsPresenter.new(Post.all).rows # one query for posts, one for their comments
end
```

A change that loads each post's comments on its own fails, and says
which statements each version sent most, and how many times an
iteration:

```
! posts: the index page   1.2s n=2   ...   active_record_queries 4→22  active_record_cached_queries 0  active_record_transactions 0  active_record_instantiations 40 records  ...
REGRESSION posts: the index page: worse instructions, cpu, active_record_queries, allocations in every measurement
  ...
  active_record_queries: 2 queries → 11 queries an iteration
  active_record_queries (candidate): an iteration: 10× SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?; 1× SELECT "posts".* FROM "posts"
  active_record_queries (baseline): an iteration: 1× SELECT "comments".* FROM "comments" WHERE "comments"."post_id" IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?); 1× SELECT "posts".* FROM "posts"
```

> [!TIP]
> Queries a benchmark makes to set itself up each time go in `untimed`,
> which pauses every metric, these too.

Options:

```ruby
c.use :activerecord,
  query_time: true,                                            # active_record_query_time too (default: false)
  ignore: ->(payload) { payload[:sql].start_with?("PRAGMA") } # queries not to count, nor time
```

`ignore` gets each query's `sql.active_record` payload (`:sql`, `:name`,
`:binds`...). Duel's `c.measure` changes a measure's settings, or leaves
it out (and the plugin doesn't subscribe to what no measure left needs):

```ruby
c.measure("active_record_query_time", limit: 1.1)
c.measure("active_record_instantiations", skip: true)
```

## How it measures

From Active Record's own notifications (`sql.active_record`,
`transaction.active_record` and `instantiation.active_record`), in every
thread of the worker, as running totals (Duel's `c.metric`). Reading
them queries nothing, so there's nothing for Duel to take away
(`calibrate: false`). Counts are shown in their units (queries,
transactions, records: `1 query`, `2 queries`, though the summary line
leaves out the one a name ends in), and
`active_record_query_time` is in nanoseconds (`unit: "ns"`), shown as
time.

It subscribes in each worker as Duel opens its metric (the metric's
`open`), once the benchmark files have loaded, so queries made while
they load (a schema, seeds) aren't counted, and the runner, which loads
`.duel.rb` too, never loads Active Support for it. It unsubscribes when
the worker ends (the metric's `close`).

It also keeps track of the statement each of the last 1,000 queries
sent, by its SQL (with binds, `WHERE id = ?`, the same statement for
every id). That's a hash of the SQL for each query, and no copy of it
(nothing a benchmark's allocations would count), but it holds on to the
SQL of the first eight statements sent since a sample was last
explained (with [duel-retained](https://github.com/sferik/duel-ruby/tree/main/plugins/retained),
that's within its allowance), and the rest are told as others. A regression
shows the three a sample sent most, and how many times an iteration
(and others'), of its last 1,000 queries, but those in `untimed` blocks,
with at most 100 characters of each.

`active_record_queries` counts what Rails' log counts as queries, but
leaves out cached ones, which never reach the database: they're
`active_record_cached_queries`. Transactions are counted on their own, once each
(not their `BEGIN` and `COMMIT`), and only those Active Record opened
(an empty `transaction` block opens none).

### Why `active_record_query_time` is off unless asked for

It's elapsed time, which Duel otherwise never judges: a busy machine
adds to it, and so does anything else the database is doing. With
SQLite, it's time the benchmark's CPU time already counts. With a
database server, it's mostly waiting: on the network, and on a server
that may be serving other workers too. Paired side by side, the two
versions see much the same of that, so it can settle a large
difference, and it's judged like CPU time but with a looser limit (5%),
and only for samples with 0.3 ms of it. But for what the server did, its
own statistics are the better measure (as
[duel-redis](https://github.com/sferik/duel-ruby/tree/main/plugins/redis) reads Redis's), and
the query counts catch most of what makes it slower.
