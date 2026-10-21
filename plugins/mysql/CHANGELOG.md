# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

The first release. duel-mysql is a Duel plugin, open source under the
MIT license, and needs Duel 0.1, CRuby 3.4 or later (the trilogy gem is
a C extension, and TruffleRuby 40.0 fails inside it), and MySQL 8.0.30
or later (not MariaDB).

### Added

- `c.use :mysql`: a MySQL server for each Duel worker, on a Unix
  socket, its data directory copied from one made once (with Duel's
  `w.cached`, in the project's `tmp/duel/cache`), and the
  `mysql_queries`, `mysql_rows`, `mysql_rows_examined` and `mysql_time`
  metrics, from its status and `performance_schema`, as running totals
  (`c.metric`).
- `Duel::MySQL.url`, `Duel::MySQL.socket`, `Duel::MySQL.execute` and
  `Duel::MySQL.reset`, for benchmarks: `execute` and `reset` open a
  connection of their own, from the worker's `DUEL_MYSQL_SOCKET`.
  They're for `setup` hooks, and `once` and `untimed` blocks: while a
  benchmark is measured (`Duel.measuring?`) they raise `Duel::Error`, as what they run
  would be counted.
- A regression is explained by the statements (by digest) that did the
  most of it, on each version (Duel's `details`): how many times each
  ran an iteration, for `mysql_queries`, and their shares, for the rest.
- `mysql_time` is in µs (`unit: "µs"`), shown as time. `mysql_queries`,
  `mysql_rows` and `mysql_rows_examined` are in queries and rows
  (`unit:`, each with its plural), so reports read "1 query → 2
  queries".
- `mysql_time` is a `kind: :ratio` measure, left out of Duel's
  across-the-board check (`across: false`).
- `c.use :mysql` returns the plugin's own connection, opened in
  each worker (`c.in_worker`) and closed as it ends (`at_stop`). Its
  `value` fails outside a worker. The module keeps no connection.
- Built on Duel's plugin API: the server is spawned and set up with
  `Duel::Resource#spawn` and `#run`, its measures can be tuned or
  skipped like any (`c.measure("mysql_time", limit: 1.1)`), and its tests
  use `duel/testing`.
- Its metrics are costly to read (Duel's `costly`): a benchmark with an
  `around_iteration` hook reads the server's statistics only as each
  sample starts and stops, not twice an iteration, and what the hook
  sends the server (a transaction's `BEGIN` and `ROLLBACK`, say) is
  learned in each worker and subtracted.
- A reading reads only the statements that ran since the one before it
  (by their `LAST_SEEN`, from a second before it, so one counted while
  that one read is read again), and says which changed: explaining a
  stretch whose readings are one right after the other looks at those
  only, and one with a reading in between at every statement. Reading
  and explaining a sample cost what ran in it, not every statement the
  server has run so far. With 2000 statements and none run, the plugin's
  Ruby for a sample (two readings and its details) takes about 8µs and
  58 objects.
- A reading waits for clients only, not for the event scheduler or an
  event that's running: those whose thread shows a statement in
  `performance_schema.threads`, or counted in `Threads_running`, less
  the server's event threads.
- Mutation tested: mutant kills every change to the plugin's code, in
  CI.
- RBS signatures in sig/, checked with Steep.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-mysql-v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-mysql-v0.1.0
