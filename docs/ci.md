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
    branches: [main] # (and any other branch to guard, a stable one, say)
  schedule:
    - cron: "0 4 * * *"
  workflow_dispatch:

# A pull request's newer push cancels its run, if that's still going, as
# only its newest commit's result counts. Every other run (a push's, say)
# runs to the end, so that each push is compared.
concurrency:
  group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

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
      # The labels of the pull request (or for a push, of the one that
      # merged it), for c.accept_label in .duel.rb, as a JSON array. They're
      # read as the job runs, and adding the label (or taking it off) runs
      # the job again: see the Perf comment workflow.
      # On a schedule, the last commit since the last release that merged a
      # pull request with the label (ACCEPT_LABEL, as .duel.rb names it):
      # what that slowed down was accepted, so it's compared with instead.
      - name: Find the pull request's labels
        id: labels
        if: github.event_name == 'pull_request' || github.event_name == 'merge_group' || github.event_name == 'push' || github.event_name == 'schedule'
        continue-on-error: true # (without them, nothing's accepted)
        env:
          GH_TOKEN: ${{ github.token }}
          PR: ${{ github.event.pull_request.number }}
          QUEUED: ${{ github.event.merge_group.head_ref }}
          ACCEPT_LABEL: 'duel: accept'
          RELEASE_TAGS: "v*"
        run: |
          if [ "$GITHUB_EVENT_NAME" = schedule ]; then
            tag=$(git describe --tags --abbrev=0 --match "$RELEASE_TAGS" HEAD^ 2>/dev/null) || exit 0
            since=$(TZ=UTC git log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$tag")
            merged=$(gh pr list --repo "$GITHUB_REPOSITORY" --state merged --label "$ACCEPT_LABEL" --search "merged:>=$since" --limit 1000 \
              --json mergeCommit --jq '.[].mergeCommit.oid')
            accepted=$(git rev-list "$tag..HEAD" | grep -Fx -m 1 -f <(echo "$merged")) || accepted=
            echo "accepted=$accepted" >> "$GITHUB_OUTPUT"
            exit 0
          fi
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
      # (And whatever else your tests need set up: packages, services.)
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4" # (or none, with a .ruby-version)
          bundler-cache: true
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
          DUEL_ACCEPTED: ${{ steps.labels.outputs.accepted }}
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
```

A newer push to a pull request cancels the pull request's run, if it's
still going, because only the newest commit's result counts. Every other
run, such as a push's to `main`, runs to the end, so each push is
compared.

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
- On a schedule, the last release, or with
  [`c.accept_label`](#accept-a-regression-with-a-label), the last commit
  since then that merged a pull request with the label. Until you tag
  your first release, Duel reports that there's nothing to compare
  against, and passes.
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
`status` that Duel uses. For a pull request from a branch of your
repository, whose author can push to it anyway, the report's Markdown
is the comment's body. For one from a fork, the report is shown as text,
in a code block, since the fork's code wrote it: there, posted by
`github-actions[bot]`, it can't mention anyone, link anywhere or show an
image. A report too long for a comment is cut short. When the Duel job fails before it compares, there's
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
# and the status, if they're ones Duel says. A fork's report, which the
# fork's code wrote, is shown as text.
#
# And when the label that accepts a regression (c.accept_label in
# .duel.rb) is added to a pull request, or taken off, it runs the Duel
# job again, which reads the labels as it runs: a run that failed, once
# the label's added, or one that passed, once it's taken off.
#
# (The workflow must be on the default branch before it runs at all.)
on:
  workflow_run:
    workflows: ["Perf"]
    types: [completed]
  # (This repository's own workflow, as for the comment, with a token
  # that can run a workflow again: it checks nothing out, and runs none
  # of the pull request's code.)
  pull_request_target:
    types: [labeled, unlabeled]

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
          # (The pull request's head commit, and the repository it's from.)
          head=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR" --jq '"\(.head.sha) \(.head.repo.full_name)"')
          [ "${head%% *}" = "$HEAD_SHA" ] || exit 0
          # The report, as Markdown for a branch of this repository (whose
          # author can push here anyway), but for a fork's, as text: its run
          # ran the fork's code, which could have written anything in it. In
          # a code block, fenced with more backticks than any run of them in
          # the report, it can't mention anyone, link anywhere or show an
          # image. It's cut short where a comment couldn't hold it, and loses
          # any NUL bytes, which GitHub wouldn't take, and grep reads it as
          # text whatever's in it, so it finds every run of backticks.
          report() {
            if [ "${head#* }" = "$GITHUB_REPOSITORY" ]; then cat "$RUNNER_TEMP/report/duel.md" && return; fi
            text="$RUNNER_TEMP/report.txt"
            LC_ALL=C tr -d '\000' < "$RUNNER_TEMP/report/duel.md" | head -c 60000 > "$text"
            fence=$(LC_ALL=C grep -ao '``*' "$text" | awk '{ if (length > n) n = length } END { n = (n < 3) ? 3 : n + 1; while (n-- > 0) printf "`" }')
            printf 'From a fork, so shown as text:\n\n%s\n' "$fence"
            cat "$text"
            printf '\n%s\n' "$fence"
          }
          marker="<!-- duel"
          # The first line of the last comment Duel posted here: its marker,
          # with its status (none in Duel 0.1.0's, which counts as another).
          last=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR/comments" \
            --jq ".[] | select(.user.login == \"github-actions[bot]\") | .body | split(\"\n\")[0] | rtrimstr(\"\r\") | select(startswith(\"$marker status=\") or . == \"$marker -->\")" | tail -n 1)
          if [ "$COMMENT" = post ] || { [ -n "$last" ] && [ "$last" != "$marker status=$STATUS -->" ]; }; then
            { echo "$marker status=$STATUS -->"; report; } > "$RUNNER_TEMP/comment.md"
            gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" -F body=@"$RUNNER_TEMP/comment.md" > /dev/null
          fi

  again:
    name: Run Duel again
    if: >-
      github.event_name == 'pull_request_target' && github.event.label.name == 'duel: accept'
    runs-on: ubuntu-latest
    permissions:
      actions: write # to run the Perf workflow's jobs again
    steps:
      - name: Run Duel again
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
          ACTION: ${{ github.event.action }}
        run: |
          # The newest Perf run of the pull request's head commit, once it's
          # done (one that's running may have read the labels already).
          id=$(gh run list --workflow "Perf" --event pull_request --commit "$HEAD_SHA" --limit 1 \
            --json databaseId --jq '.[0].databaseId // empty')
          [ -n "$id" ] || exit 0
          gh run watch "$id" --interval 30 > /dev/null || true
          conclusion=$(gh run view "$id" --json conclusion --jq .conclusion)
          case "$ACTION:$conclusion" in
            labeled:failure) gh run rerun "$id" --failed ;;
            unlabeled:success) gh run rerun "$id" ;;
          esac
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

`duel init` writes the Comment on the commit job only where `.duel.rb`
sets `c.fail_on = :pull_requests`, as it's the only time Duel says to
comment on a push, and the job's `contents: write` is otherwise unused.
To add it later, set `c.fail_on`, remove the workflow, and run
`duel init` again (it keeps `.duel.rb`), or add the job yourself:

```yaml
# .github/workflows/perf.yml, in jobs: (with c.fail_on = :pull_requests)
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

```

## Accept a regression with a label

With [`c.accept_label`](configuration.md#accept-a-regression-with-a-label),
a pull request with that label passes a regression. The Duel job's Find
the pull request's labels step reads the labels of the pull request,
or for a push, of the pull request that merged it, and passes them to
`duel` as a JSON array, in `DUEL_LABELS`. That takes the
`pull-requests: read` permission. Without the labels, such as when
GitHub's API fails, nothing is accepted.

The labels are read as the Duel job runs, so `perf-comment.yml` runs
the job again when the label changes. Its Run Duel again job runs on
`pull_request_target`, with this repository's own workflow, when a
label is added to a pull request or taken off. For the label `.duel.rb`
names, it waits for the Perf run of the pull request's head commit to
finish. Then it runs the failed jobs again where the label was added
to a run that failed, or the whole run again where the label was
taken off one that passed. It checks nothing out and runs none of the
pull request's code, and its only permission is `actions: write`. The
workflows name the label as `.duel.rb` did when `duel init` wrote them,
so if you rename it, rename it in both workflows too.

On a schedule, the same step looks for the pull requests merged since
the last release with the label, and passes `duel` the last commit
that merged one, in `DUEL_ACCEPTED`. Duel compares with that commit
instead of the release, as what it slowed down was accepted.

## Compare a push with the last commit that passed

By default, the workflow compares each push with the commit before it.
A series of pushes that are each a little slower each pass, and a push
that the workflow doesn't compare, such as one whose run was cancelled,
is never compared. With
[`c.push_base = :last_passed`](configuration.md#compare-a-push-with-the-last-commit-that-passed),
the workflow compares each push with the last commit that Duel passed,
so the slowdowns add up until they fail a push.

A branch, `duel/passed/main` for `main`, marks that commit. Each
branch that the workflow guards has its own (see
[Guard other branches](#guard-other-branches)). When a push passes, or has
nothing to compare, Duel sets the `passed` output to `true`, and the
Mark the commit passed job moves the branch to the push, or creates the
branch. It never moves the branch back: when two pushes run at once and
the older one finishes last, the branch stays at the newer push. The
job runs one at a time for each branch, so two runs can't race to
create the branch. After a force push rewrites the branch's history,
it moves the branch anyway.
That job checks nothing out either, and it gets the `contents: write`
permission that moving a branch takes. Until the branch exists, and
when the push's history doesn't have its commit, Duel compares the push
with the commit before it. For a project in a subdirectory of its
repository, the branch names the directory, such as
`duel/passed-gems-parser/main`.

Git can't have a branch named `duel` and a branch named
`duel/passed/main` at once, because a branch's name is a path, and
`duel` can't be both a file and a folder. If your repository has a
branch named `duel`, say the one that added Duel, the job can't make
its branch, and its error says so. Delete that branch
(`git push origin --delete duel`), or rename it.

After a regression, the branch stays where it is, so every push fails
(or with [`c.fail_on = :pull_requests`](#comment-on-a-pushed-commit),
is reported) until one is no slower. To accept a regression, move the
branch yourself:

```sh
git push origin main:duel/passed/main
```

If you set `c.push_base` back to `:before`, delete the branches too
(`git push origin --delete duel/passed/main`), because the step that
finds the baseline's Ruby uses one whenever it exists.

`duel init` writes the Mark the commit passed job only where `.duel.rb`
sets `c.push_base = :last_passed`, as the job's `contents: write` is
otherwise unused. To add it later, set `c.push_base`, remove the
workflow, and run `duel init` again (it keeps `.duel.rb`), or add the job
yourself:

```yaml
# .github/workflows/perf.yml, in jobs: (with c.push_base = :last_passed)
  # With c.push_base = :last_passed in .duel.rb, a push is compared with
  # the last commit Duel passed, which a branch marks (each branch pushed
  # has its own), so slowdowns too small for any one push to fail add up
  # until they fail one. This job moves the branch to a push that passed
  # (or makes it), but never back: where a newer push's run moved it
  # first, it stays. It checks nothing out and runs none of the code. To
  # accept a regression, move the branch yourself (for main, git push
  # origin main:duel/passed/main).
  passed:
    name: Mark the commit passed
    needs: duel
    # One at a time for each branch, so that two runs can't both find no
    # branch and race to make it (a push's run doesn't wait for the one
    # before it). One that's running is never cancelled, and one that's
    # waiting gives way to a newer push's, which moves it further anyway.
    concurrency:
      group: ${{ github.workflow }}-passed-${{ github.ref_name }}
      cancel-in-progress: false
    if: ${{ !cancelled() && github.event_name == 'push' && needs.duel.outputs.passed == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write # to move the branch
    steps:
      - name: Move the branch to the commit
        env:
          GH_TOKEN: ${{ github.token }}
          BRANCH: duel/passed/${{ github.ref_name }}
        run: |
          # (Git can't make a branch where another's name is a folder of its
          # name: a branch named duel blocks duel/passed/main. If one does,
          # this names it.)
          blocked() {
            prefix=$BRANCH
            while [ "${prefix%/*}" != "$prefix" ]; do
              prefix=${prefix%/*}
              if gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$prefix" > /dev/null 2>&1; then
                echo "::error::The branch $prefix keeps Duel from making $BRANCH, as Git can't have both. Delete it (git push origin --delete $prefix), or rename it."
              fi
            done
            exit 1
          }
          # (Forward: GitHub moves it only where it's behind the push. Where
          # there's no branch, and making it fails, it looks once more, as
          # something else may have made it: a push of it, say.)
          for _ in 1 2; do
            gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" -f sha="$GITHUB_SHA" > /dev/null 2>&1 && exit 0
            at=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$BRANCH" --jq .object.sha 2>/dev/null) || at=
            [ -n "$at" ] && break
            gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$GITHUB_SHA" > /dev/null && exit 0
          done
          [ -n "$at" ] || blocked
          compared=$(gh api "repos/$GITHUB_REPOSITORY/compare/$GITHUB_SHA...$at" --jq .status 2>&1) || case "$compared" in
            # (GitHub can't compare commits with no history in common.)
            *"No common ancestor"*) compared=unrelated ;;
          esac
          case "$compared" in
            # (A newer push's run moved it, or this one's did, run again.)
            ahead | identical) ;;
            # (History rewritten, a force push's, say, or replaced: moved anyway.)
            diverged | behind | unrelated) gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" -f sha="$GITHUB_SHA" -F force=true > /dev/null ;;
            *) echo "::error::Couldn't compare $BRANCH with this push: $compared" && exit 1 ;;
          esac

```

## Show whether the last push passed

With `--badge`, `duel init` adds the Update the badge job, which keeps a
badge that turns red when Duel fails. After each push to your default
branch, it writes `badge.svg` to a branch of its own, `duel/badge`, so
your README can show it:

```markdown
[![Duel](https://raw.githubusercontent.com/OWNER/REPO/duel/badge/badge.svg)](https://github.com/sferik/duel-ruby)
```

The badge says "perf guarded", in green, when Duel passed the push. It
says "perf regressed", in red, when Duel failed the push or found a
regression, even one that passed, with
[`c.fail_on = :pull_requests`](#comment-on-a-pushed-commit), or that a
label accepted. It says "not measured", in grey, when the Duel job
failed before Duel could judge the push, as when its runner ran out of
memory or a step before Duel's failed. A job that fails after Duel
passed the push leaves it green. A push with nothing to compare leaves
the badge as it was, and so does a run that finishes after a newer
push's, so the badge is always the newest push's that Duel compared.
The branch holds one commit, with the badge alone, whose message names
that push. The job checks nothing out, and it gets the `contents: write`
permission that moving a branch takes. For a project in a subdirectory
of its repository, the branch names the directory, such as
`duel/badge-gems-parser`.

Until the first push to your default branch after you add the job, the
branch doesn't exist, and the badge doesn't show.

`duel init` writes the job only with `--badge` (for a Rails app,
`bin/rails generate duel:install --badge`), as without the jobs for
pushes, it's the workflow's only job that writes to the repository. To
add it later, remove the workflow, and run `duel init --badge` again (it
keeps `.duel.rb`), or add the job yourself:

```yaml
# .github/workflows/perf.yml, in jobs: (with duel init --badge)
  # Duel's badge, for the README: green (perf guarded), red (perf
  # regressed) or grey (not measured), as the last push to the default
  # branch that Duel compared left it. It's red where Duel failed the push
  # or found a regression, even one that passed (with
  # c.fail_on = :pull_requests in .duel.rb), and grey where the Duel job
  # failed before Duel could judge the push (its runner ran out of memory,
  # say). A push with nothing to compare leaves it as it was, and so does
  # a run for an older push than the badge's. This job writes the badge,
  # alone, to a branch of its own, which the README shows:
  #
  #   [![Duel](https://raw.githubusercontent.com/OWNER/REPO/duel/badge/badge.svg)](https://github.com/sferik/duel-ruby)
  #
  # It checks nothing out, runs none of the code, and fetches nothing.
  badge:
    name: Update the badge
    needs: duel
    # One at a time, so that one run's check of which push the badge
    # shows can't interleave with another run's write (a push's run
    # doesn't wait for the one before it). A badge job that's running is
    # never cancelled, and one that's waiting gives way to a newer push's,
    # whose result the badge should show anyway.
    concurrency:
      group: ${{ github.workflow }}-badge
      cancel-in-progress: false
    if: ${{ !cancelled() && github.event_name == 'push' && github.ref_name == github.event.repository.default_branch && (needs.duel.result == 'failure' || needs.duel.outputs.status == 'passed' || needs.duel.outputs.status == 'failed') }}
    runs-on: ubuntu-latest
    permissions:
      contents: write # to move the badge's branch
    steps:
      - name: Update the badge
        env:
          GH_TOKEN: ${{ github.token }}
          BRANCH: duel/badge
          RESULT: ${{ needs.duel.result }}
          STATUS: ${{ needs.duel.outputs.status }}
        run: |
          # (Git can't make a branch where another's name is a folder of its
          # name: a branch named duel blocks duel/passed/main. If one does,
          # this names it.)
          blocked() {
            prefix=$BRANCH
            while [ "${prefix%/*}" != "$prefix" ]; do
              prefix=${prefix%/*}
              if gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$prefix" > /dev/null 2>&1; then
                echo "::error::The branch $prefix keeps Duel from making $BRANCH, as Git can't have both. Delete it (git push origin --delete $prefix), or rename it."
              fi
            done
            exit 1
          }
          # (Where the badge is a newer push's, that push's run has the say.
          # Its commit names the push.)
          last=$(gh api "repos/$GITHUB_REPOSITORY/commits/$BRANCH" --jq .commit.message 2>/dev/null | sed -n 's/^Duel.s badge, for \([0-9a-f]*\)$/\1/p') || true
          if [ -n "$last" ] && [ "$(gh api "repos/$GITHUB_REPOSITORY/compare/$GITHUB_SHA...$last" --jq .status 2>/dev/null)" = ahead ]; then exit 0; fi
          # (Its image, written here rather than fetched from anywhere: green,
          # red where Duel failed the push or found a regression, or grey
          # where the Duel job failed before Duel said either.)
          state="perf guarded" width=133 top="#34D058" bottom="#28A745" right="76.939C78.629 0 80 1.343 80"
          if [ "$STATUS" = failed ]; then
            state="perf regressed" width=142 top="#EA4A5A" bottom="#D73A49" right="85.939C87.629 0 89 1.343 89"
          elif [ "$RESULT" = failure ] && [ "$STATUS" != passed ]; then
            state="not measured" width=138 top="#959DA5" bottom="#6A737D" right="81.939C83.629 0 85 1.343 85"
          fi
          cat > "$RUNNER_TEMP/badge.svg" <<SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="$width" height="20">
            <title>Duel - $state</title>
            <defs>
              <linearGradient id="duel-fill" x1="50%" y1="0%" x2="50%" y2="100%">
                <stop stop-color="#444D56" offset="0%"></stop>
                <stop stop-color="#24292E" offset="100%"></stop>
              </linearGradient>
              <linearGradient id="state-fill" x1="50%" y1="0%" x2="50%" y2="100%">
                <stop stop-color="$top" offset="0%"></stop>
                <stop stop-color="$bottom" offset="100%"></stop>
              </linearGradient>
            </defs>
            <g fill="none" fill-rule="evenodd">
              <g font-family="'DejaVu Sans',Verdana,Geneva,sans-serif" font-size="11">
                <path d="M0,3 C0,1.3431 1.3552,0 3.02702703,0 L53,0 L53,20 L3.02702703,20 C1.3552,20 0,18.6569 0,17 L0,3 Z" fill="url(#duel-fill)" fill-rule="nonzero"></path>
                <text fill="#010101" fill-opacity=".3">
                  <tspan x="22.1981982" y="15" aria-hidden="true">Duel</tspan>
                </text>
                <text fill="#FFFFFF">
                  <tspan x="22.1981982" y="14">Duel</tspan>
                </text>
              </g>
              <g transform="translate(53)" font-family="'DejaVu Sans',Verdana,Geneva,sans-serif" font-size="11">
                <path d="M0 0h$right 3v14c0 1.657-1.37 3-3.061 3H0V0z" fill="url(#state-fill)" fill-rule="nonzero"></path>
                <text fill="#010101" fill-opacity=".3" aria-hidden="true">
                  <tspan x="4" y="15">$state</tspan>
                </text>
                <text fill="#FFFFFF">
                  <tspan x="4" y="14">$state</tspan>
                </text>
              </g>
              <g fill="#959DA5">
                <path d="M4.6 3.6L6.9 4.5L14.3 11.9L12.9 13.3L5.5 5.9Z M17.4 3.6L15.1 4.5L7.7 11.9L9.1 13.3L16.5 5.9Z"></path>
                <circle cx="16.6" cy="15.6" r="1.1"></circle>
                <circle cx="5.4" cy="15.6" r="1.1"></circle>
              </g>
              <g stroke="#959DA5" stroke-linecap="round">
                <path d="M12.1 14.5L15.5 11.1 M9.9 14.5L6.5 11.1" stroke-width="1.6"></path>
                <path d="M13.8 12.8L16 15 M8.2 12.8L6 15" stroke-width="1.8"></path>
              </g>
            </g>
          </svg>
          SVG
          tree=$(jq -n --rawfile svg "$RUNNER_TEMP/badge.svg" '{tree: [{path: "badge.svg", mode: "100644", type: "blob", content: $svg}]}' |
            gh api --method POST "repos/$GITHUB_REPOSITORY/git/trees" --input - --jq .sha)
          commit=$(gh api --method POST "repos/$GITHUB_REPOSITORY/git/commits" -f message="Duel's badge, for $GITHUB_SHA" -f tree="$tree" --jq .sha)
          gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" -f sha="$commit" -F force=true > /dev/null 2>&1 ||
            gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$commit" > /dev/null || blocked
```

## Guard other branches

The workflow compares the pushes to `main`. To guard another branch,
such as a stable branch that gets backports, add it to the workflow's
`push` branches:

```yaml
  push:
    branches: [main, 2-x-stable]
```

Duel compares a push to each branch with the commit before it, or with
`c.push_base = :last_passed`, with the last commit that Duel passed on
that branch, which a branch of its own marks: `duel/passed/2-x-stable`.
A pull request into the branch is compared with the branch, whatever
the workflow guards.

## Run Duel on GitLab CI

`duel init --gitlab` writes GitLab CI jobs, in
`.gitlab/duel.gitlab-ci.yml`, instead of the GitHub Actions workflows.
Include them from your `.gitlab-ci.yml`:

```yaml
include:
  - local: .gitlab/duel.gitlab-ci.yml
```

The Duel job compares a merge request with the branch that it targets,
a push to your default branch with the commit before it (or with
[`c.push_base = :last_passed`](#compare-a-push-with-the-last-commit-that-passed),
the last commit that Duel passed), and on a schedule, your last
release. It runs on the `ruby` image of the version that your
`.ruby-version` names, or else of your Ruby. On GitLab, a branch that
upgrades Ruby can't compare each version on its own Ruby, because the
image has only one. Duel reads GitLab's variables: a merge request's
target, and its labels, for
[`c.accept_label`](configuration.md#accept-a-regression-with-a-label).
A push's labels aren't available.

With [`c.fail_on = :pull_requests`](configuration.md#fail-only-a-pull-request),
a regression outside a merge request makes `duel` exit with status 3,
and the job lets that fail (`allow_failure: exit_codes: [3]`), so the
pipeline shows a warning, not a failure.

The Duel job writes what it decided to a dotenv report (`DUEL_OUTPUT`):
`DUEL_COMMENT`, `DUEL_STATUS`, and `DUEL_PASSED`. The jobs after it act
on them. They check nothing out and run none of the code. GitLab's own
job token can't comment, so they need project access tokens, in masked
CI/CD variables. Without them, the jobs don't run, and the Duel job's
log and its `duel.md` artifact have the report.

- `DUEL_COMMENT_TOKEN`, with the Reporter role and the `api` scope, and
  not protected, so a merge request's pipeline has it, to comment on a
  merge request. Every job in that pipeline has it, the Duel job too,
  which runs the merge request's code, so give it no more than the
  Reporter role.
- `DUEL_TOKEN`, with the Developer role and the `api` scope, and
  protected, so only your protected branches' pipelines have it, to
  comment on a pushed commit and to mark a push passed.

The comment on a pushed commit looks only at the comments on the commit
before it for its last status. A merge request from a fork runs its
pipeline in the fork, without your variables, so it gets no comment.

```yaml
# .gitlab/duel.gitlab-ci.yml
# Duel on GitLab CI: https://github.com/sferik/duel-ruby/blob/main/docs/ci.md#run-duel-on-gitlab-ci
#
# Include it from .gitlab-ci.yml:
#
#   include:
#     - local: .gitlab/duel.gitlab-ci.yml
#
# It compares a merge request with the branch it targets, a push to the
# default branch with the commit before it (or as c.push_base in .duel.rb
# says, the last commit Duel passed), and on a schedule, the last release.
# The Duel job's log, and its duel.md artifact, have the report. Comments
# need project access tokens, in masked CI/CD variables:
#
# - DUEL_COMMENT_TOKEN (the Reporter role, with the api scope, and not
#   protected), to comment on a merge request. Every job of a merge
#   request's pipeline has it, the Duel job too, which runs the merge
#   request's code, so the token can do no more than comment.
# - DUEL_TOKEN (the Developer role, with the api scope, and protected, so
#   only the default branch's pipelines have it), to comment on a pushed
#   commit (see c.fail_on), and to mark a push passed (see c.push_base).

duel:
  image: ruby:3.4
  stage: test
  variables:
    GIT_DEPTH: 0 # the baseline comes from history, tags included
    DUEL_OUTPUT: duel.env # whether to comment, and mark a push passed
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      variables:
        DUEL_BASE: $CI_COMMIT_BEFORE_SHA
    - if: $CI_PIPELINE_SOURCE == "schedule"
      variables:
        DUEL_BASE: last-release
    # (Run by hand, it compares anyway: with nothing changed, the code
    # with itself, which checks the setup.)
    - if: $CI_PIPELINE_SOURCE == "web"
      variables:
        DUEL_FORCE: "1"
  # A regression outside a merge request, where only a merge request
  # fails (c.fail_on in .duel.rb), exits 3: a warning.
  allow_failure:
    exit_codes: [3]
  before_script:
    # The branch a merge request targets, the last commits Duel passed,
    # and the releases.
    - git fetch --quiet --tags origin "+refs/heads/duel/*:refs/remotes/origin/duel/*"
    - if [ -n "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" ]; then git fetch --quiet origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"; fi
    - bundle install
  script:
    - bundle exec duel --markdown duel.md
  artifacts:
    when: always
    paths:
      - duel.md
    reports:
      dotenv: duel.env
    expire_in: 1 day

# The report, as a new comment on the merge request, when Duel says to:
# always (post), or only when its last comment's status differs from this
# run's (change), so the latest comment is never stale. It never edits or
# deletes a comment.
duel:comment:
  image: alpine:3
  stage: .post
  needs: [duel]
  rules:
    - if: $DUEL_COMMENT_TOKEN && $CI_PIPELINE_SOURCE == "merge_request_event"
      when: always
  variables:
    GIT_STRATEGY: none # it runs none of the code
  script:
    - apk add --no-cache --quiet curl jq
    - |
      case "$DUEL_COMMENT" in post|change) ;; *) exit 0 ;; esac
      report=duel.md
      [ -f "$report" ] || exit 0
      api="$CI_API_V4_URL/projects/$CI_PROJECT_ID"
      token="PRIVATE-TOKEN: $DUEL_COMMENT_TOKEN"
      marker="<!-- duel"
      me=$(curl -sf -H "$token" "$CI_API_V4_URL/user" | jq .id)
      # The first line of the last comment Duel posted here: its marker,
      # with its status.
      last=$(curl -sf -H "$token" "$api/merge_requests/$CI_MERGE_REQUEST_IID/notes?sort=desc&order_by=created_at&per_page=100" |
        jq -r --argjson me "$me" --arg marker "$marker status=" '.[] | select(.author.id == $me) | .body | split("\n")[0] | rtrimstr("\r") | select(startswith($marker))' | head -n 1)
      if [ "$DUEL_COMMENT" = post ] || { [ -n "$last" ] && [ "$last" != "$marker status=$DUEL_STATUS -->" ]; }; then
        { echo "$marker status=$DUEL_STATUS -->"; cat "$report"; } | jq -Rs '{body: .}' |
          curl -sf -H "$token" -H "Content-Type: application/json" --data @- "$api/merge_requests/$CI_MERGE_REQUEST_IID/notes" > /dev/null
      fi

# The report, as a new comment on a pushed commit, when Duel says to, as
# for a merge request: only where a regression in a push passes (see
# c.fail_on), so the comment says what the check doesn't. Its last comment
# is the commit before's.
duel:commit-comment:
  image: alpine:3
  stage: .post
  needs: [duel]
  rules:
    - if: $DUEL_TOKEN && $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: always
  variables:
    GIT_STRATEGY: none # it runs none of the code
  script:
    - apk add --no-cache --quiet curl jq
    - |
      case "$DUEL_COMMENT" in post|change) ;; *) exit 0 ;; esac
      report=duel.md
      [ -f "$report" ] || exit 0
      api="$CI_API_V4_URL/projects/$CI_PROJECT_ID"
      token="PRIVATE-TOKEN: $DUEL_TOKEN"
      marker="<!-- duel"
      me=$(curl -sf -H "$token" "$CI_API_V4_URL/user" | jq .id)
      last=$(curl -sf -H "$token" "$api/repository/commits/$CI_COMMIT_BEFORE_SHA/comments?per_page=100" |
        jq -r --argjson me "$me" --arg marker "$marker status=" '.[] | select(.author.id == $me) | .note | split("\n")[0] | rtrimstr("\r") | select(startswith($marker))' | tail -n 1)
      if [ "$DUEL_COMMENT" = post ] || { [ -n "$last" ] && [ "$last" != "$marker status=$DUEL_STATUS -->" ]; }; then
        { echo "$marker status=$DUEL_STATUS -->"; cat "$report"; } | jq -Rs '{note: .}' |
          curl -sf -H "$token" -H "Content-Type: application/json" --data @- "$api/repository/commits/$CI_COMMIT_SHA/comments" > /dev/null
      fi

# With c.push_base = :last_passed in .duel.rb, a push is compared with the
# last commit Duel passed, which a branch marks (duel/passed/main for
# main), so slowdowns too small for any one push to fail add up until they
# fail one. This job moves the branch to a push that passed (or makes it),
# but never back: where a newer push's job moved it first, it stays. To
# accept a regression, move the branch yourself (for main, git push
# origin main:duel/passed/main).
duel:passed:
  image: alpine:3
  stage: .post
  needs: [duel]
  # One at a time, as each deletes the branch and makes it again: two at
  # once could both delete it, and the second to make it would fail.
  resource_group: duel/passed
  rules:
    - if: $DUEL_TOKEN && $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  variables:
    GIT_STRATEGY: none # it runs none of the code
  script:
    - apk add --no-cache --quiet curl jq
    - |
      [ "$DUEL_PASSED" = true ] || exit 0
      api="$CI_API_V4_URL/projects/$CI_PROJECT_ID"
      token="PRIVATE-TOKEN: $DUEL_TOKEN"
      branch="duel/passed/$CI_COMMIT_BRANCH"
      at=$(curl -sf -H "$token" "$api/repository/branches/$(echo "$branch" | sed 's|/|%2F|g')" | jq -r '.commit.id // empty') || at=
      if [ -n "$at" ]; then
        base=$(curl -sf -H "$token" "$api/repository/merge_base?refs%5B%5D=$CI_COMMIT_SHA&refs%5B%5D=$at" | jq -r '.id // empty') || base=
        [ -n "$base" ] || { echo "Couldn't compare $branch with this push" && exit 1; }
        # (A newer push's job moved it, or this one's did, run again.)
        [ "$base" = "$CI_COMMIT_SHA" ] && exit 0
      fi
      curl -s -o /dev/null -H "$token" -X DELETE "$api/repository/branches/$(echo "$branch" | sed 's|/|%2F|g')"
      curl -sf -o /dev/null -H "$token" --data-urlencode "branch=$branch" --data-urlencode "ref=$CI_COMMIT_SHA" "$api/repository/branches" && exit 0
      # (Git can't make a branch where another's name is a folder of its
      # name: a branch named duel blocks duel/passed/main. If one does,
      # this names it.)
      prefix=$branch
      while [ "${prefix%/*}" != "$prefix" ]; do
        prefix=${prefix%/*}
        if curl -sf -o /dev/null -H "$token" "$api/repository/branches/$(echo "$prefix" | sed 's|/|%2F|g')"; then
          echo "The branch $prefix keeps Duel from making $branch, as Git can't have both. Delete it (git push origin --delete $prefix), or rename it."
        fi
      done
      exit 1
```

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
      # release, the newest tag before HEAD that RELEASE_TAGS matches
      # (or ACCEPTED, the last change accepted since then). (If
      # .duel.rb sets c.main_branch or c.release_tags, set MAIN_BRANCH or
      # RELEASE_TAGS to match.)
      - name: Find the baseline's Ruby
        id: baseline
        env:
          BEFORE: ${{ github.event.before }}
          QUEUE_BASE: ${{ github.event.merge_group.base_sha }}
          PASSED: origin/duel/passed/${{ github.ref_name }}
          MAIN_BRANCH: origin/${{ github.base_ref || github.event.repository.default_branch }}
          RELEASE_TAGS: "v*"
          ACCEPTED: ${{ steps.labels.outputs.accepted }}
        run: |
          case "$GITHUB_EVENT_NAME" in
            push)
              base=$BEFORE
              if git merge-base --is-ancestor "$PASSED" HEAD 2>/dev/null; then base=$PASSED; fi ;;
            merge_group) base=$QUEUE_BASE ;;
            schedule) base=${ACCEPTED:-$(git describe --tags --abbrev=0 --match "$RELEASE_TAGS" HEAD^ 2>/dev/null)} || base= ;;
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
