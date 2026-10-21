# Run Duel in CI

This page describes the GitHub Actions workflow that `duel init` writes,
and how to compare a branch that upgrades Ruby on CI. For how to run
Duel as a CI step on any CI service, and for the report that it adds to
a pull request, see [Run Duel in CI](../README.md#run-duel-in-ci).

## Catch slow creep

A limit lets through any slowdown that's smaller than the limit. For
example, a series of changes that are each 1.5% slower would each pass.
To catch that kind of slow creep, also compare against your last release
on a schedule. The slowdowns add up there until they're a regression.

The following GitHub Actions workflow does both, and reports on each
pull request. `duel init` writes it for you, as
`.github/workflows/perf.yml`:

```yaml
# .github/workflows/perf.yml
name: Perf

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "0 4 * * *"
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write # to comment on a pull request with the report

jobs:
  duel:
    name: Duel
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # the baseline comes from history, tags included
      # (And whatever else your tests need set up: packages, services.)
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4" # (or none, with a .ruby-version)
          bundler-cache: true
      # Against the main branch for a pull request, what was there before
      # for a push, and the last release on a schedule (slow creep). Duel
      # adds its report to the job's summary, and writes it to duel.md for
      # the comment.
      - name: Compare
        env:
          DUEL_BASE: ${{ github.event_name == 'schedule' && 'last-release' || github.event_name == 'push' && github.event.before || '' }}
          # (Run by hand, it compares anyway: with nothing changed, the code
          # with itself, which checks the setup.)
          DUEL_FORCE: ${{ github.event_name == 'workflow_dispatch' && '1' || '' }}
        run: |
          # (A branch's first push, or one that rewrote history, has no
          # commit before it here to compare against.)
          if [ "$GITHUB_EVENT_NAME" = push ] && ! git cat-file -e "$DUEL_BASE^{commit}" 2>/dev/null; then
            echo "::notice::No commit before this push to compare against"
            exit 0
          fi
          bundle exec duel --markdown "$RUNNER_TEMP/duel.md"
      # The report, as a comment on the pull request: one comment, updated
      # on every push. (A pull request from a fork gets no comment, as its
      # token can't write one: the job's summary has the report.)
      - name: Comment on the pull request
        if: ${{ !cancelled() && github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository }}
        env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
        run: |
          [ -f "$RUNNER_TEMP/duel.md" ] || exit 0
          marker="<!-- duel -->"
          { echo "$marker"; cat "$RUNNER_TEMP/duel.md"; } > "$RUNNER_TEMP/comment.md"
          ids=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR/comments" \
            --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id")
          if [ -n "$ids" ]; then
            gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/${ids%%$'\n'*}" -F body=@"$RUNNER_TEMP/comment.md" > /dev/null
          else
            gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" -F body=@"$RUNNER_TEMP/comment.md" > /dev/null
          fi
```

The workflow compares the following:

- A pull request, against the main branch.
- A push to `main`, against the commit before the push. If that commit
  isn't in the history, such as after a force push or for a branch's
  first push, the workflow skips the comparison with a notice.
- On a schedule, the last release. Until you tag your first release,
  Duel reports that there's nothing to compare against, and passes.
- When you run the workflow manually, your code against itself. This
  checks that the benchmarks run on the CI machines.

## Comment on a pull request

The workflow writes Duel's report
([Report on a pull request](../README.md#report-on-a-pull-request))
to a file, and then comments on the pull request with it. It updates
the same comment on every push, rather than adding one each time. It
finds its comment by the hidden marker on the comment's first line, so
give each workflow that comments a marker of its own. Commenting takes
the `pull-requests: write` permission. A pull request from a fork gets
no comment, because its token can't write one, but the job's summary
still has the report.

## Run each version on its own Ruby on CI

With [`c.ruby = :version_file`](configuration.md#run-each-version-on-its-own-ruby),
each version runs on the Ruby that its own version file names. On CI, a
setup step such as `ruby/setup-ruby` installs the Ruby that
runs `duel` where no version manager looks. That's enough while both
versions ask for that Ruby. A pull request that upgrades Ruby needs the
baseline's Ruby installed too, where Duel finds it. For example, for a
project with a `.ruby-version`, in the
[GitHub Actions workflow](#catch-slow-creep), install the main branch's
Ruby with a second `ruby/setup-ruby` step, and link it into
`~/.rubies`, where Duel looks for Rubies the way that chruby does.
`duel init` adds these steps for a project that has a `.ruby-version`:

```yaml
      # (Before the step that sets up the candidate's Ruby.)
      - name: Find the baseline's Ruby
        id: baseline
        if: github.event_name == 'pull_request'
        run: echo "ruby=$(git show "origin/$GITHUB_BASE_REF:.ruby-version")" >> "$GITHUB_OUTPUT"
      - uses: ruby/setup-ruby@v1
        id: baseline-ruby
        if: github.event_name == 'pull_request'
        with:
          ruby-version: ${{ steps.baseline.outputs.ruby }}
      - name: Link the baseline's Ruby where Duel finds it
        if: github.event_name == 'pull_request'
        run: |
          prefix="${{ steps.baseline-ruby.outputs.ruby-prefix }}"
          mkdir -p ~/.rubies
          ln -sfn "$prefix" ~/.rubies/ruby-"$("$prefix/bin/ruby" -e 'print RUBY_VERSION')"
```
