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
  processes of their own, at the same time on the same machine: twelve
  of each by default, or eight on JRuby and TruffleRuby, whose workers
  are JVMs. They take turns, one sample from each in alternating order,
  in rounds. Each round takes a sample from every worker, and pairs
  each baseline worker with a different candidate worker than the
  last round did. That way, a busy moment weighs on both versions
  alike. There are no stored numbers and no thresholds to maintain,
  and any machine will do.
- **A confidence interval over processes, not an average.** Where
  things land in a process's memory can make the very same code a few
  percent faster or slower for the process's whole life, and on JRuby,
  so can what its JIT compiled. So a sample from one process isn't
  independent of the next sample from it, and the unit Duel judges is
  the process: each worker's median. A timing is slower only when a
  99% distribution-free confidence interval for the ratio of the
  candidate's workers to the baseline's (the Mann-Whitney interval,
  over every candidate worker's median against every baseline
  worker's) lies entirely above the limit, which is 1.02 by default.
  No one outlier sample can decide it, and no one lucky or unlucky
  worker can either: the interval is as wide as the workers make it.
  An interval over the pairs would be as narrow as if every pair had
  processes of its own, and with identical code on both sides, it
  would often leave out 1. Duel takes rounds until the interval
  settles the question, from the fourth round on, and up to some 120
  pairs. Duel reports a timing that's still too close to the limit to
  call, and doesn't fail on it.

  The interval over workers takes five of each at least. With fewer
  (`--processes`), Duel judges over the pairs, as it does a process
  benchmark, and its first line says so. A process benchmark's
  sample is the fastest of a few fresh processes, so its pairs are
  independent already. It can also stop after any pair once the
  interval shows that it isn't slower, which only ever ends a
  measurement before it could find a slowdown.

  Duel measures one benchmark at a time for every two CPUs
  (`--jobs`), each with workers of its own, so a run can start many
  workers, and each one's resources (a database server, say) with it.
  Where they wouldn't fit in the memory available (Linux's
  MemAvailable, or a container's cgroup limit, or macOS's free and
  inactive pages), Duel measures fewer benchmarks at once, and where
  even one benchmark's workers wouldn't fit, it starts fewer workers.
  Running out would make the machine swap, or stop a CI runner from
  answering, so its job is lost. To find what they take, Duel starts
  one worker of each version first, and allows each pair a quarter
  more than that, or what its plugins say each worker's resources
  take at most, if that's more (a server takes more as it's used), and
  1 GB for everything else. Its first line says
  when it lowered either. A `--jobs` or `--processes` you give is
  kept as it is.
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
  iterations. Each worker's count is its fewest in three rounds of a
  sample from every worker, and a count fails when an interval over the
  workers, for how many more the candidate's are, lies above the
  tolerance. Where every worker counts the same, as CRuby's workers
  do, that's exactly how many more. Where workers differ, it's as few
  as they can tell apart, so one worker's luck can't fail a benchmark.
  With fewer than five workers of each version, a count is each
  version's fewest in three samples instead.
- **Across the board, too.** A slowdown that's too small for any one
  benchmark to settle, such as 1% everywhere, still shows in all of the
  benchmarks together. The same workers measure every benchmark, so a
  worker whose luck makes it slower is slower at all of them, and the
  unit is the worker again. Each worker has a score: the median, over
  the benchmarks it measured, of how much faster or slower it was than
  the other workers of its lane. The candidate fails when a confidence
  interval for the ratio of its workers' scores to the baseline's lies
  above a quarter of the metric's margin: 1.005, for CPU time's 1.02.
  Where the benchmarks were judged over pairs, every benchmark's median
  ratio is a sample instead, and the interval is for their median.
  Either takes 8 benchmarks, so with fewer, Duel doesn't report it.
  Duel measures again before it fails, as it does for the rest.

## What Duel measures

Duel judges every benchmark on the following metrics:

| Metric | What it is | A regression |
|---|---|---|
| `cpu` | The benchmark thread's CPU time (or the process's) | More than 2% slower, with 99% confidence |
| `instructions` | Instructions retired, from the CPU's own counters | More than 1% more, with 99% confidence |
| `allocations` | Ruby objects allocated (on CRuby) | One more per two iterations |
| `allocated_bytes` | Bytes allocated (on JRuby), by the JVM's count | More than 32 bytes more per iteration |
| `peak_memory` | The most resident memory (on JRuby, the JVM's heap in use), above the start, that measured work reached (not `once` or `untimed`), with garbage collection running as usual (when asked for) | More than 10% and 1 MB more |
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
record of it, and the rest of `tmp/duel` (see
[What Duel keeps in tmp/duel](#what-duel-keeps-in-tmpduel)), run
`duel --clean`.

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

### What Duel keeps in tmp/duel

Duel keeps what it needs between runs in your project's `tmp/duel`:

- `lock`, so that only one run at a time compares the project. A run
  removes it when it ends.
- `cache/`, what plugins build once and reuse, such as a database's
  initial files. A build is named for what it is, its version, and a
  hash, such as `mysql-0.1.2-3f9c2a1b7e5d4c6a`. When a run ends, Duel
  removes the builds of the same name that the ones it used replace,
  such as the files of a database server that you've since upgraded, so
  the cache keeps one build of each.
- `base/`, the baseline's checkout, when it can't go next to your
  project.

When a run ends, Duel removes `tmp/duel` if nothing is left in it, and
`tmp` too if Duel made it. A project without plugins that build
something keeps nothing there. `duel --clean` removes the rest. Each
run's sockets and server directories are in a temporary directory,
which the run removes when it ends.

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

If YJIT is on in a worker, Duel runs each benchmark until it's steady
before it measures it, for up to ten seconds. A small library's methods
are compiled within Duel's first samples, but in a big app, YJIT
compiles a method only after 120 calls. YJIT can be on because you
turned it on (`RUBY_YJIT_ENABLE=1`, for example), or because your code
did as it loaded, as Rails 7.2 and later do.

A worker is steady once the median of its samples over each of three
half seconds in a row is no more than 1% faster than over the last half
second that was, so a pause (a collection, say) doesn't end its warm-up,
and code that creeps faster by less a half second isn't steady. Duel
measures once every worker is steady, or the time is up. To warm up for
a set time instead, use `--warm`.

### JRuby and TruffleRuby

JRuby's and TruffleRuby's JIT compilers keep compiling for seconds, so
Duel runs each benchmark until it's steady, for up to a minute, before
it measures it (`--warm`). Code that a JIT compiles quickly is steady
in a few seconds, but some code is still several times faster after
five seconds than it was, and steady only after 10 or 20.

Each JVM's JIT also compiles the same code a little differently, so one
worker can run a benchmark faster or slower than another for its whole
life, however long it warms up. On JRuby, Duel starts each worker's JVM
with `-Xbatch`, which compiles in the foreground, so what it compiles is
less a matter of timing, and with the serial garbage collector, which
runs no threads of its own beside the code. That makes the workers about
twice as alike, but a CPU-time interval on JRuby is still some 5% to 8%
wide, as wide as the workers make it, so Duel leaves a timing regression
of a few percent unsettled there, where it would find it on CRuby. It
doesn't fail identical code on that noise: an interval over the pairs
would be narrower, but it would often leave out 1 for identical code.
The options come after any in `JRUBY_OPTS`, and Duel doesn't add the
serial collector where `JRUBY_OPTS` chooses another. The processes a
process benchmark starts don't get them, as their boot is what's
measured.

Their workers are big JVMs, and their compilers keep other CPUs busy,
so Duel starts eight workers of each version rather than twelve, and
measures one benchmark at a time for every four CPUs (`--jobs`), not
every two. More at once is no faster there, and takes more memory: some
500 MB a worker.

JRuby counts no objects allocated, but the JVM counts the bytes each
thread allocates, and Duel judges those instead (`allocated_bytes`):
more than 32 bytes more an iteration fails, about a small object's, and
a change that makes objects bigger counts too. Where every worker counts
the same, Duel finds one more small object an iteration. But the JIT can
do away with an allocation that never leaves a method (escape analysis),
and each JVM's JIT does away with different ones, so on some code,
workers' counts differ by thousands of bytes, and an interval over the
workers (see How Duel tells a regression from noise) is too wide to find
a few more. And an allocation the JIT does away with in every worker
isn't counted at all, as it isn't made. Turning escape analysis off
would count every allocation, but makes CPU time some three times
noisier, so Duel leaves it on. The count falls as the JIT compiles the
code, so it's taken after the warm-up. With fewer than five workers of
each version, it's each version's fewest in 10 samples, as a sample now
and then is some 31 bytes an iteration more than the rest. TruffleRuby
has no allocation count. Neither has an instruction count or profiles.
TruffleRuby has peak memory only on Linux. JRuby measures peak memory in
the JVM's heap in use, on any operating system, because the JVM takes
memory for its heap ahead of time, so resident memory barely moves as
a benchmark's objects fill it. The peak starts from the heap in use
after a collection that Duel asks the JVM for, as JRuby's `GC.start`
collects nothing. StackProf runs on CRuby only: Duel
doesn't use it on JRuby or TruffleRuby, even where it's installed.
