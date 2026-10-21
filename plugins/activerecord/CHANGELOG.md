# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

The first release. duel-activerecord is a Duel plugin, open source
under the MIT license. It needs Duel 0.1, Active Record 7.2 or later,
and Ruby 3.4 or later (or JRuby 10, or TruffleRuby 40).

### Added

- `c.use :activerecord`: the `active_record_queries`,
  `active_record_cached_queries`, `active_record_transactions` and
  `active_record_instantiations` metrics, from Active Record's
  notifications, and `active_record_query_time` when asked for
  (`query_time: true`), with `ignore:` to leave queries out. They're
  running totals (Duel's `c.metric`), subscribed to in workers only, as
  each worker opens the metric, and unsubscribed from as it closes it,
  when the worker ends. Where the queries regressed, Duel shows the
  statements each version sent most, and how many times an iteration
  (Duel's `details`). `active_record_query_time` is in nanoseconds
  (`unit: "ns"`), shown as time. The counts are in queries,
  transactions and records (`unit:`, each with its plural), so reports
  read "1 query → 2 queries".
- Mutation tested: mutant kills every change to the plugin's code, in
  CI.
- RBS signatures in sig/, checked with Steep.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-activerecord-v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-activerecord-v0.1.0
