# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- The workflow that `rails generate duel:install` writes no longer gives
  the job that runs a pull request's code the `pull-requests: write`
  permission. The Duel job only reads (`contents: read`, and its
  checkout keeps no credentials), and keeps the report as an artifact
  for a day. A Comment job of its own, which checks nothing out and runs
  none of the app's code, downloads the report and comments with it, for
  a pull request from the same repository.

### Fixed

- With `c.ruby = :version_file`, the workflow installs the bundle for
  the baseline's Ruby too, when it differs from the candidate's. The
  baseline's workers load that bundle, and gems installed for one Ruby
  version don't load on another, so a branch that changed the Ruby's
  minor version failed before it compared anything.

- With a `.ruby-version`, the generated workflow installs the baseline's
  Ruby for every event that compares, not only for a pull request: the
  commit before a push, the last release on a schedule, and where HEAD
  left the main branch for a pull request and a manual run, when its
  `.ruby-version` names another Ruby than HEAD's.

## [0.1.0] - 2026-10-24

The first release. duel-rails is a Duel plugin for Rails apps, open
source under the MIT license. It needs Duel 0.1, duel-activerecord 0.1,
Rails 7.2 or later, and Ruby 3.4 or later.

### Added

- `c.use :rails`: each version of the app boots in the
  `benchmark` environment, from its own tree, and Duel compares a change
  to `app/`, `config/`, `db/`, `lib/`, `Gemfile`, `Gemfile.lock`, or
  `.ruby-version`.
- Each version's workers run its own bundle: its `Gemfile.lock`,
  installed once for the run, before its workers start (Duel's
  `c.prepare(:version)`), on the version's Ruby, and kept installed for
  each lockfile and Ruby. Duel puts its own gems and its plugins' ahead
  of the bundle.
- Each worker's own database (`database:`): a SQLite file, or a
  PostgreSQL or MySQL server from duel-postgresql or duel-mysql. Each
  worker loads its version's schema into it, then the fixtures
  (`fixtures:`) and seeds (`seeds:`) asked for, with Ruby's random
  numbers, and Faker's, seeded first (`seed:`). duel-rails uses
  duel-activerecord, and the database server's plugin, with `c.use`, so
  an app that uses one of them itself first, with options of its own,
  keeps them.
- `duel_request`: a benchmark of a request, sent through the app's whole
  Rack stack without a server, with `params:`, `json:`, and `headers:`,
  and a block to change its Rack environment. It fails on a status
  other than the one expected (`status:`, `200..399` by default). It
  takes Duel's hooks (`setup:`, `before_sample:`, and the rest), as
  `duel` does, and gets its file's hooks, as a benchmark that the file
  defines with `duel` does.
- `Duel::Rails::ROLLBACK`, an `around_iteration` hook that rolls back
  each iteration: for one benchmark
  (`around_iteration: Duel::Rails::ROLLBACK`), a file, or every
  benchmark (`c.around_iteration(&Duel::Rails::ROLLBACK)`). What a
  request writes is rolled back with it, so pinning the connections and
  rolling back aren't measured, and the rollback transaction doesn't
  count in `active_record_transactions`. `rollback: false` sends the
  request without it.
- With a server's database (`database: :postgresql`, `:mysql2`, or
  `:trilogy`), a request benchmark reads the server's statistics only
  as each sample starts and stops, not around every request, because
  the server's plugin says its metrics are costly to read. What pinning
  and rolling back add is learned in each worker and subtracted.
- Jobs that a benchmark enqueues are performed in an `after_iterations`
  hook, and measured with it: after each request, before it's rolled
  back, or after each sample's iterations otherwise. duel-rails's own
  queue is Active Job's adapter while benchmarking, on Rails 7.2, 8.0,
  and 8.1. `jobs: false` leaves jobs out.
- `reset: true` empties every table, and loads the fixtures and seeds
  again, before every sample (Duel's `c.before_sample`), for benchmarks
  that write without rolling back. `Duel::Rails.reset_data` does the
  same from a file's `before_sample` block.
- The `rails_views`, `rails_cache_reads`, `rails_cache_misses`, and
  `rails_cache_writes` metrics, from Rails's notifications, subscribed
  to as each worker opens them and unsubscribed from as it closes them.
  Where the views regressed, the views each version rendered most.
  Active Record's metrics too, from duel-activerecord (`active_record:`,
  `query_time:`).
- `rails generate duel:install`: `.duel.rb`, the `benchmark`
  environment, benchmarks of the app's requests (one for each action,
  however many paths reach it), `duel/boot_duel.rb`, a benchmark of the
  app's boot (`duel_process "boot: the app", "bin/rails", "runner",
  "1"`, whose processes run in the version's `RAILS_ENV`), a GitHub
  Actions workflow, and, in the `Gemfile`'s `development` group,
  `gem "stackprof", platforms: :mri` (for profiles of regressions,
  unless the `Gemfile` has StackProf) and the database server's plugin.
  The `benchmark` environment sets Active Job's queue adapter only in an
  app with Active Job.
- The generated workflow writes Duel's report in Markdown
  (`duel --markdown`) and comments on each pull request with it,
  updating one comment on every push. Duel adds the report to the job's
  summary too. The workflow asks for the `pull-requests: write`
  permission, and an app in a subdirectory of its repository gets a
  comment of its own.
- For an app with a `.ruby-version`, the generated `.duel.rb` sets
  `c.ruby = :version_file`, so each version runs on its own Ruby, and the
  generated workflow also installs the main branch's Ruby for a pull
  request.
- An app in a subdirectory of its repository (a monorepo's): the
  generator writes its workflow at the repository's root, named for the
  app's directory, and run there (`working-directory`).
- `rake duel`, in the app.
- Mutation tested: mutant kills every change to the plugin's code, in
  CI.
- RBS signatures in sig/, checked with Steep.

[Unreleased]: https://github.com/sferik/duel-ruby/compare/duel-rails-v0.1.0...HEAD
[0.1.0]: https://github.com/sferik/duel-ruby/releases/tag/duel-rails-v0.1.0
