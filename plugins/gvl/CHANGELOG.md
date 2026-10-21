# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

The first release. duel-gvl is a Duel plugin, open source under the MIT
license. It needs Duel 0.1 and CRuby 3.4 or later, where it builds a
small C extension (elsewhere it installs without it, and measures
nothing).

### Added

- `c.use :gvl`: the `gvl_wait` metric, how long threads waited
  for the GVL in each sample of a benchmark with threads of its own, from
  Ruby's thread event hooks, in a C extension (CRuby), loaded in Duel's
  workers. It's judged on samples that wait a tenth of their CPU time or
  more on either version (`cpu_floor: 0.1`), against a limit of 1.5, and
  not across the board (`across: false`). It's in nanoseconds
  (`unit: "ns"`), so reports show it as time (`51.16µs → 817.9µs an
  iteration`).

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-gvl-v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-gvl-v0.1.0
