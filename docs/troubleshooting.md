# Troubleshooting

This page lists what Duel says when it can't compare, or when a
comparison doesn't go as you expect, and what to do about it.

## Duel says there's nothing to compare

If nothing under `lib/` or `ext/`, your benchmarks, or `.duel.rb`
changed since the baseline, there's nothing to compare, and Duel passes.
To compare anyway, use `--force`. With nothing changed, Duel compares
your code with itself, which checks that your benchmarks run. To change
what a change must touch to be compared, set `c.watch`. See
[Choose what a change must touch to be compared](configuration.md#choose-what-a-change-must-touch-to-be-compared).

Against `--base last-release`, Duel also reports that there's nothing to
compare against until you tag your first release. Releases are tagged
`v*` by default. To match other tags, set `c.release_tags`.

## Duel finds no main branch, or no commits

Duel compares with where your branch left the main branch, so it needs
both a main branch and a commit. In a repository without any commits
yet, commit your work first, or compare with a copy of your project in
another directory: `duel --base DIR`. If your main branch isn't named
`main` or `master`, set `c.main_branch`. See
[Where the baseline comes from](how-it-works.md#where-the-baseline-comes-from).

## HEAD and the main branch have no commit in common

This happens in a shallow clone, which doesn't have the history that the
baseline comes from. To fix it, fetch the whole history. For example, on
GitHub Actions, set `fetch-depth: 0` for `actions/checkout`, and on
GitLab, set `GIT_DEPTH: 0`. See
[Where the baseline comes from](how-it-works.md#where-the-baseline-comes-from).

## Another run is in progress

Duel runs one comparison at a time in a project, because two runs would
share the project's `tmp/duel` directory and its baseline's checkout. A
second run fails and names the process that's running the first. A run
that crashes leaves nothing behind that blocks the next run.

## A benchmark is reported as an error after a minute

If a worker takes more than a minute to load or to answer, such as for a
benchmark that hangs or that waits on a server that died, Duel stops the
worker and reports the benchmark as an error. To change the limit, use
`--timeout`. If a benchmark's iterations are slow, split it into
smaller benchmarks.

## Duel tells you to set c.build

Duel checks that each version's workers load only native extensions that
were built in that version's directory. A version without a build of its
own would quietly load another build, such as the other version's, or an
installed gem's, and the comparison wouldn't be of its code. If that
happens, Duel stops and tells you to set `c.build` to a command that
builds each version, such as `c.build = "make"`. See
[Prepare each version](configuration.md#prepare-each-version).

## Duel says that the versions' paths differ in length

The baseline's path is as long and as deep as your project's, because
code that works with its own file paths takes longer on a longer or
deeper path. If Duel can't write next to your project, or something else
already has the baseline's name, it uses `tmp/duel/base` instead, and
says so. Make the directory that contains your project writable, or
move what has that name. See
[Where the baseline comes from](how-it-works.md#where-the-baseline-comes-from).

## A version asks for a Ruby that isn't installed

With `c.ruby = :version_file`, each version runs on the Ruby that its
version file names. If that Ruby isn't installed where rbenv, chruby,
mise, or asdf finds it, the run fails and says which Ruby it needs.
Install it. On CI, see
[Run each version on its own Ruby on CI](ci.md#run-each-version-on-its-own-ruby-on-ci).

## Two prepare blocks set the same environment variable

If two prepare blocks set the same environment variable to different
values, the run fails. For example, two plugins for two databases might
both set `DATABASE_URL`. A worker's prepare block also can't set a
variable that the version's environment sets to a different value. See [Prepare each worker](configuration.md#prepare-each-worker).

## A worker fails on a helper's name

A helper in `duel/duel_helper.rb` can't have the name of a method that
Duel gives benchmarks, such as `duel`, `untimed`, or a hook. Duel's
method would hide the helper, so the worker fails, and names the
helper's file and line. Rename the helper. See
[Share code between benchmarks](benchmarks.md#share-code-between-benchmarks).

## A timing is too close to the limit to settle

Duel reports a timing that's still too close to the limit to call, and
doesn't fail on it. A benchmark that's reported unsettled run after run
is noisy. Make every iteration do the same work, or, for work that's
mostly waiting, judge the benchmark on its counts alone with
`only: :count`. See
[Choose what a benchmark is judged on](benchmarks.md#choose-what-a-benchmark-is-judged-on)
and [How Duel tells a regression from noise](how-it-works.md#how-duel-tells-a-regression-from-noise).

On JRuby and TruffleRuby, timings stay noisier than on CRuby, so Duel
often leaves small timing regressions unsettled. See
[JRuby and TruffleRuby](how-it-works.md#jruby-and-truffleruby).
