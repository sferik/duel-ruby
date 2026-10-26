# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-26

No changes of its own: released in step with the other Duel gems.

## [0.1.0] - 2026-10-24

The first release. duel-postgresql is a Duel plugin, open source under
the MIT license, and needs Duel 0.1, Ruby 3.4 or later (CRuby, or
TruffleRuby 40: the pg gem is a C extension), and PostgreSQL 14 or
later, with `pg_stat_statements`.

### Added

- `c.use :postgresql`: a PostgreSQL server for each Duel worker,
  on a Unix socket, its cluster copied from one made once (with Duel's
  `w.cached`, in the project's `tmp/duel/cache`), and
  the `postgres_queries`, `postgres_rows`, `postgres_blocks` and
  `postgres_time` metrics, from `pg_stat_statements`, as running totals
  (`c.metric`).
- `Duel::PostgreSQL.url`, `Duel::PostgreSQL.execute` and
  `Duel::PostgreSQL.reset`, for benchmarks: `execute` and `reset` open a
  connection of their own, from the worker's `DUEL_POSTGRESQL_URL`.
  They're for `setup` hooks, and `once` and `untimed` blocks: while a
  benchmark is measured (`Duel.measuring?`) they raise `Duel::Error`, as what they run
  would be counted.
- Each worker's server's URL is in `DUEL_POSTGRESQL_URL`, and in
  `DATABASE_URL` too, by default (`env:`). It names its user in its
  query, `postgres:///duel?host=...&port=5432&user=postgres`, so that
  Rails, which parses `DATABASE_URL` with Ruby's URI, boots with it
  (duel-rails with `database: :postgresql`).
- A regression is explained by the statements that did the most of it,
  on each version (Duel's `details`): how many times each ran an
  iteration, for `postgres_queries`, and their shares, for the rest.
- `postgres_time` is in µs (`unit: "µs"`), shown as time.
  `postgres_queries`, `postgres_rows` and `postgres_blocks` are in
  queries, rows and blocks (`unit:`, each with its plural), so reports
  read "1 query → 2 queries".
- `postgres_blocks` and `postgres_time` are `kind: :ratio` measures, and
  `postgres_time` is left out of Duel's across-the-board check
  (`across: false`).
- A query sent with the extended protocol (as Active Record sends
  every one) inside a transaction is counted as it runs, not as the
  connection's next statement does: before each reading, every
  connection of the worker's left idle in a transaction has its unnamed
  portal closed. So an iteration's last query, inside an
  `around_iteration` hook's transaction (duel-rails's
  `Duel::Rails::ROLLBACK`), is the iteration's, and the hook's `BEGIN`
  and `ROLLBACK` aren't.
- `c.use :postgresql` returns the plugin's own connection, opened
  in each worker (`c.in_worker`) and closed as it ends (`at_stop`). Its
  `value` fails outside a worker. The module keeps no connection.
- Built on Duel's plugin API: the server is spawned and set up with
  `Duel::Resource#spawn` and `#run`, its measures can be tuned or
  skipped like any (`c.measure("postgres_time", limit: 1.1)`), and its tests
  use `duel/testing`.
- Its metrics are costly to read (Duel's `costly`): a benchmark with an
  `around_iteration` hook reads the server's statistics only as each
  sample starts and stops, not twice an iteration, and what the hook
  sends the server (a transaction's `BEGIN` and `ROLLBACK`, say) is
  learned in each worker and subtracted.
- A reading of `pg_stat_statements` makes numbers only for the
  statements that changed since the last reading, and shares the rest
  with it, and a sample's statements are told from those that changed
  alone. pg decodes the counts and times (a type map), so no String is
  made for a number. Reading 2,000 statements, 10 of them changed,
  allocates 26 objects.
- Mutation tested: mutant kills every change to the plugin's code, in
  CI.
- RBS signatures in sig/, checked with Steep.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-postgresql-v0.1.1...HEAD
[0.1.1]: https://github.com/sferik/duel-ruby/compare/duel-postgresql-v0.1.0...duel-postgresql-v0.1.1
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-postgresql-v0.1.0
