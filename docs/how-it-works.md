# How Duel works

This page explains how Duel decides that a change made your code slower,
what it measures, how it explains a regression, where the baseline comes
from, and how it handles JIT compilers.

## How Duel tells a regression from noise

A policy of zero tolerance only works if the guard never cries wolf.
After one false alarm, people learn to rerun until the build is green.
So Duel is built to fail only when your code really got slower, and
never on noise, so that it can gate every pull request:

- **CPU time, not elapsed time.** Duel times each benchmark by its
  thread's CPU time, which other processes on the machine don't
  inflate. A sample is the fastest of several runs, because interference
  only ever adds time. Garbage collection is kept out of samples, and
  its cost shows in the allocation count instead, which is exact.
- **Side by side, many times over.** The two versions run in worker
  processes of their own, three of each by default, at the same time on
  the same machine. They take turns: one sample from each, in
  alternating order, and each pair from a different pair of processes.
  That way, a busy moment weighs on both versions alike, and no one
  process's luck decides anything. (Where things land in a process's
  memory can make the very same code a few percent faster or slower for
  the process's whole life.) There are no stored numbers and no
  thresholds to maintain, and any machine will do.
- **A confidence interval, not an average.** A timing is slower only
  when a 99% distribution-free confidence interval for the median of
  the paired ratios (candidate / baseline) lies entirely above the
  limit, which is 1.02 by default. No one outlier sample can decide it.
  Duel takes samples in rounds of 10 pairs, up to 60, until the interval
  settles the question. A process benchmark's sample is the fastest of
  a few fresh processes, and it can also stop after any pair once the
  interval shows that it isn't slower, which only ever ends a
  measurement before it could find a slowdown.
  Duel reports a timing that's still too close to the limit to call, and
  doesn't fail on it.
- **Measured again before failing.** Duel measures whatever looks
  slower again from scratch, up to three times, in fresh processes. It
  fails only if every measurement finds the same metric worse. A
  measurement whose timings are all still too close to call neither
  confirms a slowdown nor clears it, so Duel measures once more in its
  place, up to three more times. Every measurement that counts still has
  to find it worse, so identical code, which only rarely looks slower in
  any one measurement, still has to look slower in four or more.
- **Slower in time, whichever timing shows it.** A slowdown near the
  limits can be slower in CPU time in one measurement and in
  instructions in the next, with the other timing too close to call
  each time. Duel fails on that too, if in every measurement a timing
  is slower and none is the same or faster. Any timing can be the
  slower one, not only one in particular, so Duel measures once more
  before it fails, which keeps identical code from failing more often
  than it otherwise would.
- **Exact counts.** Allocations (on CRuby), and any counted metric of
  your own, fail on any increase: one more allocation per two
  iterations.
- **Across the board, too.** A slowdown that's too small for any one
  benchmark to settle, such as 1% everywhere, still shows in all of the
  benchmarks together. For each metric that's judged by ratio, every
  benchmark's median ratio is a sample. The candidate fails when a
  confidence interval for their median lies above a quarter of the
  metric's margin: 1.005, for CPU time's 1.02. This takes 8 benchmarks,
  so with fewer, Duel doesn't report it. Duel measures again before it
  fails, as it does for the rest.

## What Duel measures

Duel judges every benchmark on the following metrics:

| Metric | What it is | A regression |
|---|---|---|
| `cpu` | The benchmark thread's CPU time (or the process's) | More than 2% slower, with 99% confidence |
| `instructions` | Instructions retired, from the CPU's own counters | More than 1% more, with 99% confidence |
| `allocations` | Ruby objects allocated (on CRuby) | One more per two iterations |
| `peak_memory` | The most resident memory, above the start, that measured work reached (not `once` or `untimed`), with garbage collection running as usual (when asked for) | More than 10% and 1 MB more |
| Yours | See [Add your own metrics](configuration.md#add-your-own-metrics) | |

Instruction counts barely vary from run to run, so they catch slowdowns
that are too small for CPU time to settle. CPU time still catches what
instructions miss, such as cache misses.

Instruction counts come from the CPU's counters, where the operating
system lets Duel read them:

- On Linux, they're the benchmark thread's, through `perf_event_open`,
  which many virtual machines, including CI runners, don't offer. So
  Linux doesn't count instructions for benchmarks with threads of their
  own.
- On macOS, they're the whole process's.
- Elsewhere, and on JRuby and TruffleRuby, there's no `instructions`
  metric, and CPU time judges alone.

## Where the extra time went

Duel shows what regressed per iteration, on each version, with what a
metric said of it if it had something to say. For more information, see
[Add your own metrics](configuration.md#add-your-own-metrics). When something is slower
in time, Duel profiles both versions over the same iterations with
[StackProf](https://github.com/tmm1/stackprof), if it's in your bundle
(`duel init` and duel-rails's generator add it to your `Gemfile`), and
shows where the extra CPU time went:

```
REGRESSION parse: a large document: worse instructions, cpu in every measurement
  instructions: 1.521e+06 → 1.629e+06 an iteration (1.07x)
  cpu: 112.4µs → 121.5µs an iteration (1.08x)
  where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):
     +6.8%   +7.1%  MyParser::Lexer#next_token
     +0.4%   +0.4%  String#byteslice
```

A profile covers only the work that Duel measures. Work inside
`untimed`, and what an `around_iteration` hook does before and after
each iteration, is left out. What an `after_iterations` hook does is in
it, because Duel measures that with the iterations. The garbage collector is held off
during each sample, as it is when Duel measures. Collecting what each
sample left behind isn't the benchmark's code, so it isn't ranked with
the frames. If it changed, Duel shows it on a line of its own, `in
garbage collection, apart from the code`. On macOS, the signal that a CPU-time interval
has passed arrives only when the process calls into the kernel, so a
CPU-time profile would blame whatever code makes system calls. There,
Duel profiles elapsed time instead, which a benchmark that's busy on the
CPU spends the same way.

When no one timing is slower in every measurement, but every
measurement has one that's slower (see
[How Duel tells a regression from noise](#how-duel-tells-a-regression-from-noise)),
the report names the timings that were:

```
REGRESSION parse: a large document: slower in every measurement, by one of cpu, instructions
```

On each benchmark's line, counts such as `allocations` are per
iteration, as they are in the explanation of a regression.

## Where the baseline comes from

The main branch is the one that `origin/HEAD` names. Without
`origin/HEAD`, Duel uses `origin/main`, and then `origin/master`. In a
repository without a remote, it uses `main`, and then `master`. To name
another branch, set `c.main_branch`. On GitHub Actions, for a pull
request, the main branch is the one that the pull request targets
(`GITHUB_BASE_REF`), such as a stable branch, or another pull request's
branch in a stack of them.

Duel checks out a git baseline as a git worktree next to your project,
under a hidden name that's as long as your project's directory name, for
example `.3f9c2a1b` next to `my_parser`. Duel keeps it there for the
next run. If your project has an `ext/` directory, Duel builds the
baseline with `bundle exec rake compile`. To remove the baseline, git's
record of it, and the rest of `tmp/duel`, run `duel --clean`.

If your project is in a subdirectory of its repository, as in a
monorepo, run `duel` in that subdirectory. Duel checks out the whole
repository next to the repository's directory, and the baseline is the
same subdirectory in that checkout. The paths in `c.watch` are from your
project's directory.

If `HEAD` and the main branch have no commit in common, Duel says so.
This happens in a shallow clone, which doesn't have the history that the
baseline comes from. To fix it, fetch the whole history. For example, on
GitHub Actions, set `fetch-depth: 0` for `actions/checkout`.

The baseline's path is as long and as deep as your project's, in a
subdirectory too, because what code does with its own file paths, such
as looking for a file that a request might be for, takes longer on a
longer or deeper path. A
baseline at a longer path would measure slower, and hide a regression
that small. If Duel can't write next to your project, or something else
already has that name, it uses `tmp/duel/base` instead. Whenever the two
versions' paths differ in length, Duel says so.

If nothing under `lib/` or `ext/`, your benchmarks, or `.duel.rb`
changed since the baseline, there's nothing to compare, and Duel says
so. To compare anyway, use `--force`. See
[Choose what a change must touch to be compared](configuration.md#choose-what-a-change-must-touch-to-be-compared).

Duel also builds the candidate before every run. Builds are incremental,
so a build that's already done costs little. A stale or missing build,
or a C extension that your code quietly does without, never decides a
comparison.

Duel also checks that each version's workers load only native extensions
that were built in that version's directory. A version without a build
of its own would quietly load another build, such as the other
version's, or an installed gem's, and the comparison wouldn't be of its
code. If that happens, Duel stops and tells you to set `c.build`. An
installed gem's extension is never taken for a version's build, even
when the gems are installed in the project's directory, as
`vendor/bundle` (where setup-ruby's `bundler-cache` puts them).

## JIT compilers

If YJIT is on in a worker, Duel runs each benchmark for two seconds
before it measures it. A small library's methods are compiled within
Duel's first samples, but in a big app, YJIT compiles a method only after
120 calls. YJIT can be on because you turned it on (`RUBY_YJIT_ENABLE=1`,
for example), or because your code did as it loaded, as Rails 7.2 and
later do. To warm up for a different time, use `--warm`.

### JRuby and TruffleRuby

JRuby's and TruffleRuby's JIT compilers keep compiling for seconds, so
Duel runs each benchmark for five seconds before it measures it
(`--warm`). Their timings stay noisier than CRuby's, so Duel often
leaves small timing regressions on them unsettled.

Neither has an allocation count, an instruction count, or profiles, and
each has peak memory only on Linux. StackProf runs on CRuby only: Duel
doesn't use it on JRuby or TruffleRuby, even where it's installed.
