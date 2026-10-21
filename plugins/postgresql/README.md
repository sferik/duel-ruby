# duel-postgresql

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-postgresql](https://github.com/sferik/duel-ruby/actions/workflows/plugin-postgresql.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-postgresql.yml)
[![Gem Version](https://badge.fury.io/rb/duel-postgresql.svg)](https://rubygems.org/gems/duel-postgresql)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that talks
to PostgreSQL: each Duel worker gets a PostgreSQL server of its own, and
every benchmark is judged on what PostgreSQL did for it too.

| Metric | What it is | A regression |
|---|---|---|
| `postgres_queries` | the statements it ran (`BEGIN` and `COMMIT` too) | any increase |
| `postgres_rows` | the rows they returned or changed | any increase |
| `postgres_blocks` | the shared buffer blocks they touched, cached or not | judged like CPU time |
| `postgres_time` | the time it spent planning and running them, in µs | judged like CPU time |

So a change that adds a query per record (an N+1), or fetches rows it
doesn't use, fails even when its CPU time on the Ruby side doesn't
change. One that stops a query using an index fails on the blocks it
reads instead. Blocks are nearly the same from run to run, but not
quite (a table that's updated grows, say), so they're judged like time,
on paired ratios, not counted.

A regression says which statements did it: under each version's
numbers, the three that did the most of that measure (Duel's
`details`), with how many times each ran an iteration for
`postgres_queries`, and their shares of it for the rest:

```
postgres_queries: 2 queries → 6 queries an iteration
postgres_queries (candidate): an iteration: 5× SELECT count(*) FROM comments WHERE post_id = $1; 1× SELECT * FROM posts
postgres_queries (baseline): an iteration: 1× SELECT * FROM comments WHERE post_id = ANY($1); 1× SELECT * FROM posts
```

They're of the sample the numbers came from, but for its `untimed`
blocks, if it has any. Queries, rows and blocks are counted in their
units (`1 query`, `12 rows`, though the summary line leaves out the one
a name ends in: `postgres_rows 12→40`), and `postgres_time` is shown as time
(`postgres_time: 412µs → 1.31ms an iteration`).

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-postgresql"
end
```

> [!NOTE]
> It needs PostgreSQL 14 or later, with `pg_stat_statements` (it's in
> PostgreSQL's contrib, which most packages include), and the
> [pg](https://github.com/ged/ruby-pg) gem, so CRuby or TruffleRuby.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :postgresql }
```

`c.use` requires the plugin, so `.duel.rb` doesn't need to.

Each worker's server listens only on a Unix socket in the worker's own
directory, with nothing written to disk that needn't be, and no
autovacuum (which would change what a query reads, and its plan, while
it's measured). Its URL is in `DUEL_POSTGRESQL_URL`, and in
`DATABASE_URL` too, and libpq's `PGHOST`, `PGPORT`, `PGUSER` and
`PGDATABASE` point at it, so a client that reads any of them finds it
and nothing reaches another database. Benchmarks can call
`Duel::PostgreSQL.url`, `Duel::PostgreSQL.execute` and
`Duel::PostgreSQL.reset` (each of these two opens a connection of its
own, from the worker's `DUEL_POSTGRESQL_URL`, and closes it).

> [!IMPORTANT]
> `execute` and `reset` are for setting up: call them in a `setup` hook,
> or a `once` or `untimed` block. While a benchmark is measured (`Duel.measuring?`) they
> raise `Duel::Error`, rather than have what they run counted.

```ruby
# duel/orders_duel.rb
setup do
  Duel::PostgreSQL.reset                           # empties every table
  Duel::PostgreSQL.execute("INSERT INTO orders (total) SELECT g FROM generate_series(1, 100) g")
  @store = OrderStore.new(Duel::PostgreSQL.url)    # its URL
end

duel("orders: the largest ten") { @store.largest(10) }
```

Options:

```ruby
c.use :postgresql,
  bin: "/usr/lib/postgresql/17/bin",       # its programs (default: DUEL_POSTGRESQL_BIN, or found)
  settings: {work_mem: "64MB"},             # more of its settings
  setup: File.read("db/structure.sql"),     # SQL each worker's database runs first
  env: %w[DATABASE_URL PRIMARY_URL]        # variables given its URL besides DUEL_POSTGRESQL_URL
```

> [!WARNING]
> `env` matters with another plugin that sets `DATABASE_URL`
> (`duel-mysql`, say): two prepare blocks that set a variable differently
> fail, so give one of them other names (`env: %w[PRIMARY_URL]`, or
> `env: []`).

`bin` is found as the directory of the `postgres` on the `PATH`, links
followed (Homebrew's `initdb` on the `PATH` may be libpq's, of another
version), or Debian's newest under `/usr/lib/postgresql`.

A database cluster takes `initdb`, and that's slow, so it's done once
(Duel's `w.cached`): the first worker to start makes one, with the
`duel` database and `pg_stat_statements` created in it, in your
project's `tmp/duel/cache`, and every worker (in that run and the next
ones) starts with a copy. One is made for each server's programs (and
version of the plugin): another PostgreSQL gets its own. `duel --clean`
deletes them.

The metrics come from `pg_stat_statements`, which PostgreSQL updates as
each statement ends, before its client hears it has, read by statement
over a connection of the plugin's own, opened as each worker starts
(Duel's `c.in_worker`, and closed as it ends): running totals (Duel's
`c.metric`). `c.use` returns that connection, for a `.duel.rb` that
reads the server too (`connection.value`, in a worker only). The
reading's own statement is left out (by its query id), so there's
nothing to take away (`calibrate: false`). `postgres_time` counts
planning too (`pg_stat_statements.track_planning`), as a change that
stops reusing prepared statements plans every time. Up to 10,000
distinct statements are kept: a benchmark that makes more (with `IN`
lists of every length, say) loses the oldest, and its counts with them.

`postgres_time` is the server's time on the clock, not CPU time, and
another process's, so what else the machine does shows in it: it's
judged for each benchmark, but left out of Duel's across-the-board
check (`across: false`), whose margin is a quarter of its limit.

Like any measure, each can be tuned or left out in `.duel.rb`:
`c.measure("postgres_time", limit: 1.1)`,
`c.measure("postgres_rows", skip: true)`.
