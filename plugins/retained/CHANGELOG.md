# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

The first release. duel-retained is a Duel plugin, open source under
the MIT license. It needs Duel 0.1 and Ruby 3.4 or later, and measures
on CRuby alone (on JRuby and TruffleRuby it leaves itself out).

### Added

- `c.use :retained`: the `retained_objects` metric (CRuby), the
  objects each benchmark's iterations leave alive after a full garbage
  collection, with Duel's allowance of 16 a sample (for what's still on
  the machine stack when it stops) and tolerance of one per two
  iterations, both changed with `c.measure("retained_objects", ...)`.
  It measures straight through `untimed` blocks. Where a sample retained
  more than it's allowed (as `c.measure` leaves its allowance and
  tolerance), the regression shows what, an iteration: the
  objects' classes and where they were made, the three most (from
  allocation tracing during the sample).
- `retained_objects` is in objects (`unit: %w[object objects]`), so
  reports read "1 object → 2 objects an iteration" (the summary line,
  "retained_objects 3→5531", leaves out the unit its name ends in).
- Mutation tested: mutant kills every change to the plugin's code, in
  CI.
- RBS signatures in sig/, checked with Steep.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-retained-v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-retained-v0.1.0
