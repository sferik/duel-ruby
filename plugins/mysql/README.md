# duel-mysql

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-mysql](https://github.com/sferik/duel-ruby/actions/workflows/plugin-mysql.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-mysql.yml)
[![Gem Version](https://badge.fury.io/rb/duel-mysql.svg)](https://rubygems.org/gems/duel-mysql)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that talks
to MySQL: each Duel worker gets a MySQL server of its own, and every
benchmark is judged on what MySQL did for it too.

| Metric | What it is | A regression |
|---|---|---|
| `mysql_queries` | the statements clients sent it (`Questions`) | any increase |
| `mysql_rows` | the rows they returned or changed | any increase |
| `mysql_rows_examined` | the rows it read to run them | any increase |
| `mysql_time` | the time it spent running them, in µs | judged like CPU time |

So a change that adds a query per record (an N+1), fetches rows it
doesn't use, or stops a query using an index (and so examines every row
of a table) fails even when its CPU time on the Ruby side doesn't
change.

A regression says which statements did it: under each version's
numbers, the three that did the most of that measure, by their digests
(Duel's `details`), with how many times each ran an iteration for
`mysql_queries`, and their shares of it for the rest:

```
mysql_rows_examined: 2 rows → 1001 rows an iteration
mysql_rows_examined (candidate): SELECT NAME FROM `items` WHERE `id` = ? (99.9%); SELECT * FROM `users` WHERE `id` = ? (0.0999%)
mysql_rows_examined (baseline): SELECT * FROM `users` WHERE `id` = ? (50%); SELECT NAME FROM `items` WHERE `id` = ? (50%)
```

They're of the sample the numbers came from, but for its `untimed`
blocks, if it has any. Queries and rows are counted in their units
(`1 query`, `2 rows`, though the summary line leaves out the one a name
ends in: `mysql_queries 4→8`), and `mysql_time` is shown as time
(`mysql_time: 412µs → 1.31ms an iteration`).

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-mysql"
end
```

> [!NOTE]
> It needs MySQL 8.0.30 or later (not MariaDB: its `performance_schema`
> differs) and the [trilogy](https://github.com/trilogy-libraries/trilogy)
> gem, so CRuby (TruffleRuby 40.0 fails inside trilogy once benchmarks
> run). Your code can use any client: trilogy is only the plugin's own.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :mysql }
```

`c.use` requires the plugin, so `.duel.rb` doesn't need to.

Each worker's server listens only on a Unix socket in the worker's own
directory (no `my.cnf` is read), with no binary log, little memory,
nothing written to disk that needn't be, and InnoDB's statistics left as
they are (recalculated on their own, they'd change a query's plan while
it's measured: `ANALYZE TABLE` in a setup if you need them). Its URL is
in `DUEL_MYSQL_URL`, and in `DATABASE_URL` too, so a client that reads
that finds it and nothing reaches another database. The socket's path
is in `DUEL_MYSQL_SOCKET`. Benchmarks can call `Duel::MySQL.url`,
`Duel::MySQL.socket`, `Duel::MySQL.execute` and `Duel::MySQL.reset`
(each of these two opens a connection of its own, from the worker's
`DUEL_MYSQL_SOCKET`, and closes it).

> [!IMPORTANT]
> `execute` and `reset` are for setting up: call them in a `setup` hook,
> or a `once` or `untimed` block, not the code that's measured, where their statements
> would count, as any client's. While a benchmark is measured
> (`Duel.measuring?`) they raise `Duel::Error`.

```ruby
# duel/orders_duel.rb
setup do
  Duel::MySQL.reset                                  # empties every table
  Duel::MySQL.execute("INSERT INTO orders (total) VALUES (1), (2), (3)")
  @store = OrderStore.new(socket: Duel::MySQL.socket) # its socket
end

duel("orders: the largest ten") { @store.largest(10) }
```

Options:

```ruby
c.use :mysql,
  server: "/usr/local/mysql/bin/mysqld",    # the program (default: DUEL_MYSQL_SERVER, or mysqld)
  args: ["--sort-buffer-size=4M"],          # more of its options
  setup: File.read("db/structure.sql"),     # SQL each worker's database runs first
  env: %w[DATABASE_URL PRIMARY_URL],        # variables given its URL besides DUEL_MYSQL_URL
  scheme: "trilogy"                         # the URL's (Rails takes it for the adapter, mysql2 by default)
```

> [!WARNING]
> `env` matters with another plugin that sets `DATABASE_URL`
> (`duel-postgresql`, say): two prepare blocks that set a variable differently
> fail, so give one of them other names (`env: %w[PRIMARY_URL]`, or
> `env: []`).

Initializing a data directory takes seconds, so it's done once (Duel's
`w.cached`): the first worker to start makes one, with the `duel`
database created in it, in your project's `tmp/duel/cache`, and every
worker (in that run and the next ones) starts with a copy. One is made
for each server program (and version of the plugin): another MySQL gets
its own. `duel --clean` deletes them. (`args` are the running server's,
not its initialization's.)

The metrics come from the server's status (`Questions`) and
`performance_schema` (its statement summaries), which MySQL updates as
each statement ends (MySQL 8.0's just after its client hears it has: a
reading waits, a second at most, until no other client is running a
statement: the server's own threads, the event scheduler's and its
events', aren't waited for), read over a connection of the plugin's own, opened as
each worker starts (Duel's `c.in_worker`, and closed as it ends): running totals (Duel's
`c.metric`). `c.use` returns that connection, for a `.duel.rb` that
reads the server too (`connection.value`, in a worker only). Each
reading takes that connection's own totals from the server's, so its statements
are left out (and connections that have closed still count), and
there's nothing to take away (`calibrate: false`). The
statements a regression names come from the statement summaries by
digest (`events_statements_summary_by_digest`), the plugin's readings
left out: each reading reads only the statements run since the one
before it (by their `LAST_SEEN`, from a second before it), so it costs
what ran, not what the server has run so far.

`mysql_time` is the server's time on the clock, not CPU time, and
another process's, so what else the machine does shows in it: it's
judged for each benchmark, but left out of Duel's across-the-board
check (`across: false`), whose margin is a quarter of its limit.

Like any measure, each can be tuned or left out in `.duel.rb`:
`c.measure("mysql_time", limit: 1.1)`,
`c.measure("mysql_rows_examined", skip: true)`.
