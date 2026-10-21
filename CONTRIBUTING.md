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
```

The signatures in `sig/` ship with the gem, and Steep checks `lib/`
against them strictly (`Steepfile`). `steep/` has signatures for what
Duel uses that has none of its own (Fiddle, StackProf, Rake) or that
RBS's core gets wrong for Duel; they're only for the check. Where Steep
can't follow the code, a `# steep:ignore` names the diagnostic, below a
comment saying why it's safe.

CI runs the tests on CRuby 3.4, 4.0 and head, JRuby 10.1 and TruffleRuby
40.0, enforces the coverage (SimpleCov's strict profile, on CRuby 3.4),
runs [mutant](https://github.com/mbj/mutant), checks types (on CRuby 3.4
and 4.0) and lints.

Coverage only shows that code ran; mutant shows the tests would notice
if it were wrong. It changes Duel's code in small ways (a `>` for a
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

## Releasing

Update the version (`lib/duel/version.rb`) and the changelog (a dated
heading for the release, and its link at the bottom), commit, then:

```sh
bundle exec rake release
```

It builds the gem, tags the release (`v0.1.0`, say) and pushes the tag.
The tag runs the push workflow (`.github/workflows/push.yml`), which
builds the gem again, signs it with Sigstore, pushes it to RubyGems.org
with that attestation (trusted publishing: no API key) and makes the
GitHub release.

## License

By contributing, you agree that your contributions are licensed under
Duel's [MIT license](LICENSE).
