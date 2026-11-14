# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-14

### Added

- `tcp: true` starts each worker's server on a port of 127.0.0.1's
  alone, its URL `redis://127.0.0.1:PORT`, rather than a Unix socket:
  the default on Windows, whose builds of Redis (Cygwin's, MSYS2's)
  have Unix sockets of their own, which Windows's Ruby can't reach.

## [0.1.8] - 2026-11-12

No changes of its own: released in step with the other Duel gems.

## [0.1.7] - 2026-11-10

No changes of its own: released in step with the other Duel gems.

## [0.1.6] - 2026-11-10

No changes of its own: released in step with the other Duel gems.

## [0.1.5] - 2026-11-08

No changes of its own: released in step with the other Duel gems.

## [0.1.4] - 2026-11-06

No changes of its own: released in step with the other Duel gems.

## [0.1.3] - 2026-11-04

No changes of its own: released in step with the other Duel gems.

## [0.1.2] - 2026-11-02

No changes of its own: released in step with the other Duel gems.

## [0.1.1] - 2026-10-26

No changes of its own: released in step with the other Duel gems.

## [0.1.0] - 2026-10-24

The first release. duel-redis is a Duel plugin, open source under the MIT
license. It needs Ruby 3.4 or later, Duel 0.1, and `redis-server`
(Redis 6.2 or later, or Valkey) on the `PATH`.

### Added

- `c.use :redis`: a Redis server for each Duel worker, on a Unix
  socket, and the `redis_cpu`, `redis_commands` and `redis_round_trips`
  metrics.
- `Duel::Redis.url` and `Duel::Redis.flush`, for benchmarks: `flush`
  opens a connection of its own, from the worker's `DUEL_REDIS_URL`.
- `c.use :redis` returns the plugin's own connection, made in each
  worker (`c.in_worker`) and closed as it ends (`at_stop`). Its `value`
  fails outside a worker. The module keeps no connection.
- `redis_commands` and `redis_round_trips` are in commands and round
  trips (`unit:`), so reports read "1 command → 2 commands".
- `Duel::Redis.flush` raises `Duel::Error` while a benchmark is measured
  (`Duel.measuring?`): it's for `setup` hooks, and `once` and `untimed`
  blocks, where its `FLUSHALL` isn't counted.
- Its metrics are costly to read (Duel's `costly`): a benchmark with an
  `around_iteration` hook reads the server's statistics only as each
  sample starts and stops, not twice an iteration, and what the hook
  sends the server (a transaction's `BEGIN` and `ROLLBACK`, say) is
  learned in each worker and subtracted.
- Each worker's server works in the worker's own directory (`--dir`),
  so persistence that `args:` turn on writes its snapshots and
  append-only files there, never in the project.
- The plugin's connection (`Duel::Redis::Connection#call`) reads every
  type of reply RESP2 has, whole: a nil bulk string (a missing key's),
  an array (returned as an `Array`, nested ones and nil included, any
  error in it a `RuntimeError`), and an integer, as an `Integer`. It
  never sends `HELLO`, so it reads RESP2 only: a reply of another type
  (RESP3's) closes the connection and raises `IOError`, rather than
  read the next reply out of step.


[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.2.0...HEAD
[0.2.0]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.8...duel-redis-v0.2.0
[0.1.8]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.7...duel-redis-v0.1.8
[0.1.7]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.6...duel-redis-v0.1.7
[0.1.6]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.5...duel-redis-v0.1.6
[0.1.5]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.4...duel-redis-v0.1.5
[0.1.4]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.3...duel-redis-v0.1.4
[0.1.3]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.2...duel-redis-v0.1.3
[0.1.2]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.1...duel-redis-v0.1.2
[0.1.1]: https://github.com/sferik/duel-ruby/compare/duel-redis-v0.1.0...duel-redis-v0.1.1
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-redis-v0.1.0
