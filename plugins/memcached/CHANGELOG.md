# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-26

No changes of its own: released in step with the other Duel gems.

## [0.1.0] - 2026-10-24

The first release. duel-memcached is a Duel plugin, open source under
the MIT license. It needs Ruby 3.4 or later, Duel 0.1, and `memcached`
(1.6 or later) on the `PATH`.

### Added

- `c.use :memcached`: a memcached server for each Duel worker, on a
  Unix socket, and the `memcached_operations`, `memcached_misses` and
  `memcached_bytes` metrics (and `memcached_cpu`, with `cpu: true`), from
  its statistics, read over a connection of the plugin's own whose
  traffic isn't counted.
- `Duel::Memcached.servers` and `Duel::Memcached.flush`, for benchmarks:
  `flush` opens a connection of its own, from the worker's
  `DUEL_MEMCACHED_SERVERS`. It's for `setup` hooks, and `once` and
  `untimed` blocks: while a benchmark is measured (`Duel.measuring?`) it raises `Duel::Error`,
  as the flush would be counted.
- `c.use :memcached` returns the plugin's own connection, opened in each
  worker (`c.in_worker`) and closed as it ends (`at_stop`). Its
  `value` fails outside a worker, saying so. The module keeps no
  connection.
- `memcached_cpu` is a `kind: :ratio` measure, left out of Duel's
  across-the-board check (`across: false`), in microseconds
  (`unit: "µs"`), so reports show it as time. `memcached_bytes` is in
  bytes (`unit: "B"`), shown after the number. `memcached_operations`
  and `memcached_misses` are in operations and misses (`unit:`, each
  with its plural), so reports read "1 operation → 2 operations".
- Its metrics are costly to read (Duel's `costly`): a benchmark with an
  `around_iteration` hook reads the server's statistics only as each
  sample starts and stops, not twice an iteration, and what the hook
  sends the server (a transaction's `BEGIN` and `ROLLBACK`, say) is
  learned in each worker and subtracted.
- Reading the statistics allocates little: the reply is read whole into
  a buffer the connection reuses (`Connection#stats_reply`), and each
  metric's statistics are found and read in place, digit by digit. On
  memcached 1.6's 94 statistics, `memcached_cpu`'s reading allocates
  nothing, and the counted metrics' allocates only their Hash.
  `Duel::Memcached.sum` takes that reply.


[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-memcached-v0.1.1...HEAD
[0.1.1]: https://github.com/sferik/duel-ruby/compare/duel-memcached-v0.1.0...duel-memcached-v0.1.1
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-memcached-v0.1.0
