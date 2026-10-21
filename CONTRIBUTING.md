# Contributing to Duel

Thanks for helping. Duel is small, and means to stay that way: a guard
people can trust to fail only on real regressions.

## The policy Duel serves

Duel's purpose comes from [WebKit's performance policy](https://webkit.org/performance/):

> The way to make a program faster is to never let it get slower.

It's the work of the WebKit project, and Duel owes it everything: the
zero-tolerance stance, that a regression is backed out or fixed at once,
and that no reason, not even cleaner or more correct code, excuses one.
Duel only makes that policy practical for Ruby projects. Changes to Duel
are judged by whether they help a project hold to it.

That means two things above all:

- **No false alarms.** A guard that fails on noise teaches people to
  ignore it, which is worse than no guard. A change that makes Duel
  decide faster, but fail on identical code even rarely, isn't an
  improvement. Show it holds up: run identical trees against each other
  (`--base` and `--candidate-dir` pointing at copies of one tree)
  many times over, under load, and report what you saw.
  `ruby tasks/bias_check.rb 10` compares HEAD with itself ten times and
  sums up every benchmark's ratios across the runs, as the nightly bias
  check does.
- **No missed regressions it could catch.** A change that makes Duel
  quieter by letting real slowdowns through (raising limits, dropping a
  metric, giving up sooner) needs as good a reason as a regression in
  the code it guards.

## Development

```sh
bundle install
bundle exec rake test                     # Minitest, with 100% line, branch and method coverage (CRuby)
COVERAGE=false bundle exec ruby -Ilib -Itest test/stats_test.rb  # some of the tests
bundle exec mutant run                    # mutation testing (CRuby): every mutant killed
bundle exec rubocop && bundle exec standardrb
bundle exec rake typecheck                # rbs validate, then steep check (CRuby)
bundle exec duel                          # Duel's own benchmarks (duel/), against main
```

Duel guards its own speed with its own benchmarks, in `duel/`. Its
workers are Duel themselves, so each version's code is loaded apart, as
`Subject::Duel` (`duel/subject.rb`), and the Duel that measures is the
candidate's, for both versions.

The signatures in `sig/` ship with the gem, and Steep checks `lib/`
against them strictly (`Steepfile`). `steep/` has signatures for what
Duel uses that has none of its own (Fiddle, StackProf, Rake) or that
RBS's core gets wrong for Duel, only for the check. Where Steep
can't follow the code, a `# steep:ignore` names the diagnostic, below a
comment saying why it's safe.

CI runs the tests on CRuby 3.4 and 4.0 and JRuby 10.0 and 10.1, and on
the development versions of all three Rubies, CRuby's, JRuby's and
TruffleRuby's (which may fail without failing the build), enforces the
coverage (SimpleCov's strict profile, on CRuby 3.4),
runs [mutant](https://github.com/mbj/mutant), checks types (on CRuby 3.4
and 4.0), lints, and compares Duel's own benchmarks with the main
branch's (and nightly, with the last release's). Each is a workflow of
its own in `.github/workflows`:

```
test.yml       the tests, on every Ruby, and the coverage
lint.yml       RuboCop and Standard
mutant.yml     mutation testing
typecheck.yml  rbs validate and steep check
perf.yml       Duel's benchmarks against the main branch (nightly, the last release)
plugins.yml    every plugin's tests against Duel as changed (CRuby 3.4)
bias.yml       nightly, identical code compared with itself (see below)
push.yml       a release: signs the gem and pushes it to RubyGems.org
```

When Duel's code changes (`lib/`, `sig/`, `exe/`, the gemspec or the
`Gemfile`), the Plugins workflow runs every plugin's tests against it,
each in its own job, with the servers its tests start installed, so a
change to Duel can't break a plugin unnoticed. Run it by hand (Actions >
Plugins > Run workflow) to check them whatever changed.

The Bias workflow runs nightly (and by hand): it compares the main
branch with itself, ten times for Duel's own benchmarks and five for
duel-redis's (whose workers each start a Redis server), with
`tasks/bias_check.rb`. Identical code must compare even, so a run that
reports a regression fails it. Its log ends with every benchmark's
ratio in every run, and how each metric's ratios lean (above 1 is the
candidate slower). Duel calls each run on its own, so a lean that no
one run would call (the candidate faster nearly every time, say) shows
only there: the workflow warns when a metric leans one way more than
chance would have it.

Coverage only shows that code ran, while mutant shows the tests would
notice if it were wrong. It changes Duel's code in small ways (a `>` for a
`>=`, an argument left out, a line removed) and runs the tests that
cover it (each test class declares what it covers, with `cover`): every
change must make one fail. A change that survives is a test missing, or
code that does nothing, which is better removed. Only a change that
can't make a difference (`RUBY_ENGINE` is always `"ruby"` where mutant
runs, say) is marked `# mutant:disable -- why`. `bundle exec mutant
session subject` lists what survived the last run, and `bundle exec
mutant session subject 'Duel::Lane#judge'` shows how.

The end-to-end tests generate small projects and compare them in real
worker processes, so a change to how Duel measures or decides is
exercised for real: add to them when you change either. They're too slow
for mutant, which relies on faster tests of the same code with the
worker processes faked (`test/support/fake_workers.rb`), whose every
measure is exact, so every decision is too: add to those as well.

Duel depends on nothing but Fiddle (Ruby's own gem, for the operating
system's counters), and should keep it that way: it runs inside other
projects' bundles. Anything more (StackProf, for profiles) is optional:
Duel uses it when it's there.

## Plugins

This repository holds Duel's plugins too, each in a directory of its
own under `plugins/`:

```
.                     Duel itself (duel.gemspec, lib/, test/, duel/, ...)
plugins/activerecord  duel-activerecord
plugins/gvl           duel-gvl
plugins/memcached     duel-memcached
plugins/mysql         duel-mysql
plugins/postgresql    duel-postgresql
plugins/rails         duel-rails
plugins/redis         duel-redis
plugins/retained      duel-retained
```

Each plugin is a gem of its own, released on its own, and its directory
is a project of its own: its gemspec, `Gemfile`, `Rakefile`, tests,
signatures and `Steepfile`, mutant, RuboCop and Standard configuration,
benchmarks (`duel/` and `.duel.rb`), README, changelog and license. Its
`Gemfile` takes Duel from this repository (`path: "../.."`), and
duel-rails takes duel-activerecord from `plugins/activerecord`, so a
plugin is always tested against the Duel next to it. Duel's own tasks
and configuration leave `plugins/` out: its tests, coverage, mutant,
Steep, RuboCop and Standard see only Duel.

To work on a plugin, run everything from its directory:

```sh
cd plugins/redis
bundle install
bundle exec rake test                     # its tests, with 100% coverage (CRuby)
bundle exec rubocop && bundle exec standardrb
bundle exec rake typecheck                # steep check (CRuby)
bundle exec mutant run --since main       # mutation testing of what changed
bundle exec duel                          # its benchmarks, against main
```

Duel works from a subdirectory: the baseline is a checkout of the whole
repository, and Duel uses its `plugins/redis`. `bundle exec rake
plugins` at the root runs every plugin's default task (its tests), each
in its own bundle, and `bundle exec rake plugins:redis` one plugin's.
Some plugins' tests start servers of their own, so they need them
installed: `redis-server`, `memcached`, PostgreSQL (with
`pg_stat_statements`) or MySQL.

Each plugin has one workflow, `.github/workflows/plugin-redis.yml` and
so on, with its tests, lint, types, mutation testing and benchmarks. It
runs only when something in the plugin's directory changes (duel-rails's
when duel-activerecord's does too), and Duel's own workflows don't run
when only plugins change. The Plugins workflow (`plugins.yml`) runs
every plugin's tests when Duel's code changes instead.

## Releasing

Duel and its plugins are released together, all nine gems at one
version. Prepare the release in one command:

```sh
bundle exec rake "release:bump[0.2.0]"    # RELEASE_DATE=2026-11-02 for a date other than today
```

It sets the version in all nine version files, and in each changelog
moves what's under `[Unreleased]` into a new section dated today (a
gem with no entries gets a line saying it had no changes of its own),
and links it at the bottom. A plugin's requirement of Duel (or of
duel-activerecord) that the new version wouldn't satisfy becomes
`~> 0.2`. Review the changes, commit and push them to main, then:

```sh
bundle exec rake release:all:dry_run      # or DRY_RUN=1 bundle exec rake release:all
bundle exec rake release:all
```

Both check everything first, and list every problem they find:

- every gem's version is Duel's (`lib/duel/version.rb` and each
  plugin's `lib/duel/<plugin>/version.rb`)
- every plugin's requirement of Duel (and duel-rails's of
  duel-activerecord) admits that version
- every changelog has a section for it dated today (or `RELEASE_DATE`),
  a link for it, and nothing under `[Unreleased]`
- the working tree is clean, on main, and at origin's main
- none of the release's tags (`v0.2.0`, `duel-redis-v0.2.0` and so on)
  exists, here or on origin
- every gem builds (`gem build`), as itself at that version, with no
  file that isn't its own (tracked by Git in its directory, and for
  Duel's, none of a plugin's)

The dry run stops there. `rake release:all` asks before it goes on
(`FORCE=1`, or `CI`, to skip the question), then makes an annotated
tag for each gem on HEAD and pushes them to origin. It pushes each tag
on its own, since GitHub runs no workflow for the tags of a push of
more than three. Each tag runs the push workflow for its gem, as below,
so the nine gems are built, signed and pushed in parallel.

A single gem can still be released on its own. For Duel, update its
version (`lib/duel/version.rb`) and its changelog (a dated heading for
the release, and its link at the bottom), commit, then:

```sh
bundle exec rake release
```

It builds the gem, tags the release (`v0.1.0`, say) and pushes the tag.
The tag runs the push workflow (`.github/workflows/push.yml`), which
builds the gem again, signs it with Sigstore, pushes it to RubyGems.org
with that attestation (trusted publishing: no API key) and makes the
GitHub release.

A plugin is released the same way, from its directory: update its
version (`lib/duel/redis/version.rb`, say) and its changelog, commit,
then run `bundle exec rake release` in `plugins/redis`. Its tags name
the plugin (`duel-redis-v0.1.0`), so they never clash with Duel's, and
its own `--base last-release` finds them (`c.release_tags` in its
`.duel.rb`). The tag runs the plugins' push workflow
(`.github/workflows/plugin-push.yml`), which does for the plugin what
the push workflow does for Duel.

## License

By contributing, you agree that your contributions are licensed under
Duel's [MIT license](LICENSE).
