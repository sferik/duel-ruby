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

The following GitHub Actions workflow does both. `duel init` writes it
for you, as `.github/workflows/perf.yml`, with a second workflow that
comments on a pull request when a benchmark fails (see
[Comment on a pull request](#comment-on-a-pull-request)):

```yaml
# .github/workflows/perf.yml
name: Perf

on:
  pull_request:
  merge_group: # (a merge queue's)
  push:
    branches: [main]
  schedule:
    - cron: "0 4 * * *"
  workflow_dispatch:

# The Duel job runs the branch's code (its benchmarks too), so it only
# reads. Commenting on a commit is the Comment on the commit job's, which
# runs none of it, and commenting on a pull request is the Perf comment
# workflow's.
permissions:
  contents: read
  pull-requests: read # for the pull request's labels (see c.accept_label)

jobs:
  duel:
    name: Duel
    runs-on: ubuntu-latest
    # Whether to comment (post, change or none), the run's status (passed,
    # failed or neutral), and whether to mark a push passed (true, or
    # nothing), from Duel.
    outputs:
      comment: ${{ steps.compare.outputs.comment }}
      status: ${{ steps.compare.outputs.status }}
      passed: ${{ steps.compare.outputs.passed }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # the baseline comes from history, tags included
          persist-credentials: false
      # (And whatever else your tests need set up: packages, services.)
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4" # (or none, with a .ruby-version)
          bundler-cache: true
      # The labels of the pull request (or for a push, of the one that
      # merged it), for c.accept_label in .duel.rb, as a JSON array. They're
      # read as the job runs, so after adding the label, run it again.
      - name: Find the pull request's labels
        id: labels
        if: github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.event_name == 'push'
        continue-on-error: true # (without them, nothing's accepted)
        env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
          QUEUED: ${{ github.event.merge_group.head_ref }}
        run: |
          # (In a merge queue, the last pull request queued, which the queue's
          # branch names: gh-readonly-queue/main/pr-123-<sha>.)
          if [ -n "$QUEUED" ]; then
            PR=${QUEUED##*/pr-}
            PR=${PR%%-*}
          fi
          if [ -n "$PR" ]; then
            labels=$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR/labels" --jq '[.[].name]')
          else
            labels=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '[.[0].labels[]?.name]')
          fi
          echo "labels=$labels" >> "$GITHUB_OUTPUT"
      # Against the branch it targets for a pull request, the queue's base
      # for a merge queue, what was there before for a push (or as
      # c.push_base in .duel.rb says, the last commit Duel passed), and the
      # last release on a schedule (slow creep). Duel adds its report to
      # the job's summary, writes it to duel.md for the comment, and sets
      # the step's outputs to say whether to comment, as c.comment in
      # .duel.rb says, whatever the outcome.
      - name: Compare
        id: compare
        env:
          DUEL_BASE: ${{ github.event_name == 'schedule' && 'last-release' || github.event_name == 'push' && github.event.before || github.event_name == 'merge_group' && github.event.merge_group.base_sha || '' }}
          # (Run by hand, it compares anyway: with nothing changed, the code
          # with itself, which checks the setup.)
          DUEL_FORCE: ${{ github.event_name == 'workflow_dispatch' && '1' || '' }}
          DUEL_LABELS: ${{ steps.labels.outputs.labels }}
        run: bundle exec duel --markdown "$RUNNER_TEMP/duel/duel.md"
      # For a pull request, what Duel said, for the Perf comment workflow,
      # which can't see this job's outputs.
      - name: Say whether to comment
        if: ${{ !cancelled() && github.event_name == 'pull_request' }}
        env:
          PR: ${{ github.event.pull_request.number }}
          COMMENT: ${{ steps.compare.outputs.comment }}
          STATUS: ${{ steps.compare.outputs.status }}
        run: |
          mkdir -p "$RUNNER_TEMP/duel"
          printf 'pr=%s\ncomment=%s\nstatus=%s\n' "$PR" "$COMMENT" "$STATUS" > "$RUNNER_TEMP/duel/comment.env"
      # The report, for the comments.
      - name: Keep the report
        if: ${{ !cancelled() && (github.event_name == 'pull_request' || github.event_name == 'push') }}
        uses: actions/upload-artifact@v7
        with:
          name: duel-report
          path: ${{ runner.temp }}/duel/
          if-no-files-found: ignore # none when Duel didn't get to compare
          retention-days: 1

  # The report, as a new comment on a pushed commit, which notifies its
  # author, when Duel says to, as for a pull request (see the Perf comment
  # workflow). It does only where a regression in a push passes, with
  # c.fail_on = :pull_requests in .duel.rb, so the comment says what the
  # check doesn't. Its last comment is the last one on any commit. This
  # job checks nothing out and runs none of the code.
  commit-comment:
    name: Comment on the commit
    needs: duel
    if: ${{ !cancelled() && github.event_name == 'push' && (needs.duel.outputs.comment == 'post' || needs.duel.outputs.comment == 'change') }}
    runs-on: ubuntu-latest
    permissions:
      contents: write # to comment on the commit with the report
    steps:
      - name: Get the report
        id: report
        continue-on-error: true # there's none when the Duel job failed before comparing
        uses: actions/download-artifact@v8
        with:
          name: duel-report
          path: ${{ runner.temp }}/report
      - name: Comment on the commit
        if: steps.report.outcome == 'success'
        env:
          GH_TOKEN: ${{ github.token }}
          COMMENT: ${{ needs.duel.outputs.comment }}
          STATUS: ${{ needs.duel.outputs.status }}
        run: |
          marker="<!-- duel"
          last=$(gh api --paginate "repos/$GITHUB_REPOSITORY/comments" \
            --jq ".[] | select(.user.login == \"github-actions[bot]\") | .body | split(\"\n\")[0] | rtrimstr(\"\r\") | select(startswith(\"$marker status=\"))" | tail -n 1)
          if [ "$COMMENT" = post ] || { [ -n "$last" ] && [ "$last" != "$marker status=$STATUS -->" ]; }; then
            { echo "$marker status=$STATUS -->"; cat "$RUNNER_TEMP/report/duel.md"; } > "$RUNNER_TEMP/comment.md"
            gh api --method POST "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/comments" -F body=@"$RUNNER_TEMP/comment.md" > /dev/null
          fi

  # With c.push_base = :last_passed in .duel.rb, a push is compared with
  # the last commit Duel passed, which a branch marks, so slowdowns too
  # small for any one push to fail add up until they fail one. This job
  # moves the branch to a push that passed (or makes it). It checks
  # nothing out and runs none of the code. To accept a regression, move
  # the branch yourself (git push origin main:duel/passed).
  passed:
    name: Mark the commit passed
    needs: duel
    if: ${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write # to move the branch
    steps:
      - name: Move the branch to the commit
        env:
          GH_TOKEN: ${{ github.token }}
          BRANCH: duel/passed
        run: |
          gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" -f sha="$GITHUB_SHA" -F force=true > /dev/null 2>&1 ||
            gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$GITHUB_SHA" > /dev/null
```

The workflow compares the following:

- A pull request, against the branch that it targets: usually `main`,
  but a stable branch, or another pull request's branch in a stack of
  them, too.
- A merge queue's group, against the queue's base, the commit that the
  group merges into. With a merge queue, a required Duel check must run
  on `merge_group` too, or the queue waits for it forever. A regression
  fails a merge queue's run as it fails a pull request's, and the run
  reads the labels of the last pull request queued, for
  [`c.accept_label`](#accept-a-regression-with-a-label).
- A push to `main`, against the commit before the push, or with
  [`c.push_base = :last_passed`](#compare-a-push-with-the-last-commit-that-passed),
  the last commit that Duel passed. If that commit isn't in the history,
  such as after a force push or for a branch's first push, Duel reports
  that there's nothing to compare against, and passes.
- On a schedule, the last release. Until you tag your first release,
  Duel reports that there's nothing to compare against, and passes.
- When you run the workflow manually, your code against itself. This
  checks that the benchmarks run on the CI machines.

Duel compares a change that touches your code (`lib/` or `ext/`, or what
`c.watch` names), your benchmarks, `.duel.rb`, or, with
`c.ruby = :version_file`, your version file. Each version runs your
branch's benchmarks and configuration, so a change to only those compares
the same code with itself, which checks that they run and pass. A change
to only the workflow has nothing to compare: to check it, run the
workflow manually.

## Comment on a pull request

The workflow writes Duel's report
([Report on a pull request](../README.md#report-on-a-pull-request))
to a file, and comments on the pull request with it when
[`c.comment`](configuration.md#choose-when-to-comment-on-a-pull-request)
says to. By default, it comments when a benchmark fails, or when Duel
couldn't compare. Whatever `c.comment` says, a regression fails the
check, because `duel` exits with a nonzero status, and the job's
summary has the report.

The workflow never edits or deletes a comment, so the pull request
keeps every report that it posted. Each comment starts with a hidden
marker that records the run's status: `<!-- duel status=passed -->`,
`status=failed` (a run that couldn't compare too), or `status=neutral`
(nothing to compare). When a run's outcome wouldn't get a comment of
its own, the workflow still posts one if it commented on the pull
request before, and its last comment's status differs from this run's.
With the default, after a comment that a benchmark failed, the first
push that passes gets one comment saying so, and the pushes after it
get none. So the last comment is never stale. A comment from Duel 0.1.0,
whose marker has no status, counts as a comment with another status.

The workflow finds its comments by the marker's start. For a project
in a subdirectory of its repository, the marker names the directory,
such as `<!-- duel gems/parser status=failed -->`, so each of a
monorepo's workflows has comments of its own.

Duel decides, because it knows the outcome and reads `.duel.rb`. On
GitHub Actions, the Compare step's `duel` sets two step outputs, which
the Duel job passes on as its own: `comment`, and `status` (`passed`,
`failed`, or `neutral`). `comment` is one of the following:

| `comment` | What the Perf comment workflow does |
|---|---|
| `post` | Posts a new comment. |
| `change` | Posts a new comment only if the pull request has one from the workflow, and the last one's status isn't this run's. |
| `none` | Nothing. |

The Duel job runs the pull request's code, its benchmarks included, so
it only reads (`contents: read`). It keeps the report as an artifact
for a day, with a file, `comment.env`, that says what Duel decided:
the pull request's number, `comment`, and `status`. A second workflow,
`.github/workflows/perf-comment.yml`, posts the report. It runs when
the Perf workflow completes (`workflow_run`), with your repository's
own copy of the workflow and a token that can write, so a pull request
from a fork gets a comment too. It checks nothing out and runs none of
the pull request's code. The pull request's code ran in the Duel job,
and could have written anything into the artifact, so the workflow
trusts only what Duel could have said there: a number that names the
pull request whose head the run compared, and a `comment` and a
`status` that Duel uses. The report's Markdown is the comment's body,
which can only say something on the pull request that the pull request
could say itself. When the Duel job fails before it compares, there's
no report, and no comment. GitHub runs a `workflow_run` workflow only
from your default branch, so the pull request that adds the workflow
gets no comment.

```yaml
# .github/workflows/perf-comment.yml
name: Perf comment

# Duel's report, as a new comment on the pull request, when Duel says to:
# always (post), or only when its last comment's status differs from the
# run's (change), so the latest comment is never stale. It never edits or
# deletes a comment. It runs once the Perf workflow has, with this
# repository's own workflow and a token that can write, so a pull request
# from a fork gets a comment too. It checks nothing out and runs none of
# the pull request's code, and of what the Duel job kept (where that code
# ran), it trusts only what that job could have said: the pull request's
# number, if it names the pull request the run compared, and the comment
# and the status, if they're ones Duel says. (The workflow must be on the
# default branch before it runs at all.)
on:
  workflow_run:
    workflows: ["Perf"]
    types: [completed]

permissions: {}

jobs:
  comment:
    name: Comment
    if: ${{ github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion != 'cancelled' }}
    runs-on: ubuntu-latest
    permissions:
      actions: read # to get the report from the Perf run
      pull-requests: write # to comment on the pull request with the report
    steps:
      - name: Get the report
        id: report
        continue-on-error: true # there's none when the Duel job failed before comparing
        uses: actions/download-artifact@v8
        with:
          name: duel-report
          path: ${{ runner.temp }}/report
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ github.token }}
      - name: Comment on the pull request
        if: steps.report.outcome == 'success'
        env:
          GH_TOKEN: ${{ github.token }}
          HEAD_SHA: ${{ github.event.workflow_run.head_sha }}
        run: |
          said() { grep -xE "$1=($2)" "$RUNNER_TEMP/report/comment.env" | tail -n 1 | cut -d= -f2; }
          PR=$(said pr '[0-9]+')
          COMMENT=$(said comment 'post|change')
          STATUS=$(said status 'passed|failed|neutral')
          [ -n "$PR" ] && [ -n "$COMMENT" ] && [ -n "$STATUS" ] || exit 0
          [ "$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq .head.sha)" = "$HEAD_SHA" ] || exit 0
          marker="<!-- duel"
          # The first line of the last comment Duel posted here: its marker,
          # with its status (none in Duel 0.1.0's, which counts as another).
          last=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR/comments" \
            --jq ".[] | select(.user.login == \"github-actions[bot]\") | .body | split(\"\n\")[0] | rtrimstr(\"\r\") | select(startswith(\"$marker status=\") or . == \"$marker -->\")" | tail -n 1)
          if [ "$COMMENT" = post ] || { [ -n "$last" ] && [ "$last" != "$marker status=$STATUS -->" ]; }; then
            { echo "$marker status=$STATUS -->"; cat "$RUNNER_TEMP/report/duel.md"; } > "$RUNNER_TEMP/comment.md"
            gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" -F body=@"$RUNNER_TEMP/comment.md" > /dev/null
          fi
```

## Comment on a pushed commit

With [`c.fail_on = :pull_requests`](configuration.md#fail-only-a-pull-request),
a regression in a push to `main` passes, and the workflow's Comment on
the commit job comments on the pushed commit with the report instead.
GitHub notifies the commit's author. It comments as `c.comment` says,
the way the Comment job does on a pull request, but its last comment is
the workflow's last one on any commit. So with the default, each push
that fails gets a comment, the first push after them that passes gets
one, and the passing pushes after it get none.

By default, a push gets no comment: Duel sets the `comment` output to
`none`, and a regression fails the push's check instead. The Comment on
the commit job checks nothing out either, and it alone gets the
`contents: write` permission that a commit comment takes.

## Accept a regression with a label

With [`c.accept_label`](configuration.md#accept-a-regression-with-a-label),
a pull request with that label passes a regression. The Duel job's Find
the pull request's labels step reads the labels of the pull request,
or for a push, of the pull request that merged it, and passes them to
`duel` as a JSON array, in `DUEL_LABELS`. That takes the
`pull-requests: read` permission. Without the labels, such as when
GitHub's API fails, nothing is accepted.

## Compare a push with the last commit that passed

By default, the workflow compares each push with the commit before it.
A series of pushes that are each a little slower each pass, and a push
that the workflow doesn't compare, such as one whose run was cancelled,
is never compared. With
[`c.push_base = :last_passed`](configuration.md#compare-a-push-with-the-last-commit-that-passed),
the workflow compares each push with the last commit that Duel passed,
so the slowdowns add up until they fail a push.

A branch, `duel/passed`, marks that commit. When a push passes, or has
nothing to compare, Duel sets the `passed` output to `true`, and the
Mark the commit passed job moves the branch to the push, or creates the
branch. That job checks nothing out either, and it gets the
`contents: write` permission that moving a branch takes. Until the
branch exists, and when the push's history doesn't have its commit,
Duel compares the push with the commit before it. For a project in a
subdirectory of its repository, the branch names the directory, such as
`duel/passed-gems-parser`.

After a regression, the branch stays where it is, so every push fails
(or with [`c.fail_on = :pull_requests`](#comment-on-a-pushed-commit),
is reported) until one is no slower. To accept a regression, move the
branch yourself:

```sh
git push origin main:duel/passed
```

If you set `c.push_base` back to `:before`, delete the branch too
(`git push origin --delete duel/passed`), because the step that finds
the baseline's Ruby uses it whenever it exists.

## Run each version on its own Ruby on CI

With [`c.ruby = :version_file`](configuration.md#run-each-version-on-its-own-ruby),
each version runs on the Ruby that its own version file names. On CI, a
setup step such as `ruby/setup-ruby` installs the Ruby that
runs `duel` where no version manager looks. That's enough while both
versions ask for that Ruby. A branch that upgrades Ruby needs the
baseline's Ruby installed too, where Duel finds it. For example, for a
project with a `.ruby-version`, in the
[GitHub Actions workflow](#catch-slow-creep), find the baseline that the
Compare step compares with, for each event: where `HEAD` left the main
branch for a pull request and a manual run, the commit before a push,
and the last release on a schedule. When its `.ruby-version` names
another Ruby than yours, install that Ruby with a second
`ruby/setup-ruby` step, with the bundle for it (`bundler-cache: true`),
and link it into `~/.rubies`, where Duel looks for Rubies the way that
chruby does. The baseline's workers load the same bundle as the
candidate's, and gems installed for one Ruby version don't load on
another, so without that bundle they can't load the code to compare. Without a baseline, such as for a
branch's first push, or before your first release, there's no Ruby to
install. The step finds the main branch and the last release the way
Duel does by default: if `.duel.rb` sets `c.main_branch` or
`c.release_tags`, set the step's `MAIN_BRANCH` or `RELEASE_TAGS` to
match. `duel init` adds these steps for a project that has a
`.ruby-version`:

```yaml
      # (Before the step that sets up the candidate's Ruby.)
      # Each version runs on the Ruby its own .ruby-version names (see
      # .duel.rb). When the baseline's names another Ruby than this code's,
      # that one is installed too, and linked where Duel finds it (as
      # chruby would), before the project's own Ruby, which runs Duel. The
      # baseline is the Compare step's: where HEAD left the branch a pull
      # request targets (or run by hand, the main branch), a merge queue's
      # base, the commit before a push (or the last commit Duel passed, PASSED, if there is
      # one: see the Mark the commit passed job), or on a schedule the last
      # release, the newest tag before HEAD that RELEASE_TAGS matches. (If
      # .duel.rb sets c.main_branch or c.release_tags, set MAIN_BRANCH or
      # RELEASE_TAGS to match.)
      - name: Find the baseline's Ruby
        id: baseline
        env:
          BEFORE: ${{ github.event.before }}
          QUEUE_BASE: ${{ github.event.merge_group.base_sha }}
          PASSED: origin/duel/passed
          MAIN_BRANCH: origin/${{ github.base_ref || github.event.repository.default_branch }}
          RELEASE_TAGS: "v*"
        run: |
          case "$GITHUB_EVENT_NAME" in
            push)
              base=$BEFORE
              if git merge-base --is-ancestor "$PASSED" HEAD 2>/dev/null; then base=$PASSED; fi ;;
            merge_group) base=$QUEUE_BASE ;;
            schedule) base=$(git describe --tags --abbrev=0 --match "$RELEASE_TAGS" HEAD^ 2>/dev/null) || base= ;;
            *) base=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null) || base= ;;
          esac
          ruby_of() { git show "$1:./.ruby-version" 2>/dev/null | awk 'NF { print $1; exit }'; }
          ruby=
          # (None without a baseline: a branch's first push, or no release yet.)
          if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
            ruby=$(ruby_of "$base")
            [ "$ruby" = "$(ruby_of HEAD)" ] && ruby=
          fi
          echo "ruby=$ruby" >> "$GITHUB_OUTPUT"
      - uses: ruby/setup-ruby@v1
        id: baseline-ruby
        if: steps.baseline.outputs.ruby != ''
        with:
          ruby-version: ${{ steps.baseline.outputs.ruby }}
          # The bundle for this Ruby too, which the baseline's workers load.
          # (Gems installed for one Ruby version don't load on another.)
          bundler-cache: true
      - name: Link the baseline's Ruby where Duel finds it
        if: steps.baseline.outputs.ruby != ''
        env:
          PREFIX: ${{ steps.baseline-ruby.outputs.ruby-prefix }}
        run: |
          mkdir -p ~/.rubies
          ln -sfn "$PREFIX" ~/.rubies/ruby-"$("$PREFIX/bin/ruby" -e 'print RUBY_VERSION')"
```
