# duel-gvl

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-gvl](https://github.com/sferik/duel-ruby/actions/workflows/plugin-gvl.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-gvl.yml)
[![Gem Version](https://badge.fury.io/rb/duel-gvl.svg)](https://rubygems.org/gems/duel-gvl)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that runs
threads: every benchmark with threads of its own is judged on how long
they waited for the GVL too.

| Metric | What it is | A regression |
|---|---|---|
| `gvl_wait` | the time all threads spent waiting for the GVL, in ns | > 50% more, 99% confident (where it's a tenth of the sample's CPU time or more, on either version) |

A thread waiting for the GVL uses no CPU, so contention a change adds
doesn't show in CPU time: holding the GVL longer around I/O, a C call
that stops releasing it, more threads fighting over it. It shows here,
for two threads whose C call stopped releasing the GVL:

```
! wait                                              18.4s n=150    gvl_wait 34.093 [25.666, 41.575] slower  cpu 1.023 [0.959, 1.238] same
```

And under the regression, how long they waited an iteration on each
version (here, in another run):

```
REGRESSION wait: worse gvl_wait in every measurement
  gvl_wait: 51.16µs → 817.9µs an iteration (16.47x)
```

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-gvl"
end
```

> [!NOTE]
> It needs CRuby (3.4 or later), and builds a small C extension when it's
> installed. Elsewhere (JRuby and TruffleRuby, which have no GVL, Windows,
> or no C compiler) it installs without it, and there's no `gvl_wait`.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :gvl }
```

It measures only benchmarks marked `only: :timing`, as benchmarks with
threads of their own should be (their counts vary from run to run). The
rest have one thread and nothing to wait for:

```ruby
# duel/pool_duel.rb
duel "pool: 4 threads", only: :timing do |n|
  jobs = Thread::Queue.new(Array.new(n) { |i| i }).tap(&:close)
  Array.new(4) { Thread.new { while (job = jobs.pop) do MyPool.handle(job) end } }.each(&:join)
end
```

The threads are best started and joined in the benchmark, as here: one
that outlives a sample may be waiting in the next one.

## How it measures

Ruby tells the extension when a thread starts waiting for the GVL and
when it gets it (its thread event hooks), and it adds up the waits. The
hook is added only for a sample of a benchmark it measures, and removed
after it. Then each time a thread takes the GVL costs two clock readings
more: some 40-70 ns on macOS (5-8% of a loop of one-byte pipe reads and
writes), more where reading the clock is slow (some virtual machines),
nothing in code that doesn't release the GVL, and alike on both
versions.

How long threads wait depends on when the operating system runs them,
so on what else the machine is doing: on a busy one, the same code's
samples can wait half or twice as long. What contention a change adds
makes them wait many times as long, so `gvl_wait` is slower only past
half as much again (limit 1.5). And it isn't judged across the board
(`across: false`), where Duel looks for a slowdown too small for any
one benchmark in all of them together, with a quarter of the margin: an
eighth more is well within what the machine alone does to it.

Threads that hardly wait for each other still wait a little now and
then, as the scheduler has it (starting and ending a thread are
handoffs too): some 0.3-2.5% of their CPU time, on a busy machine
too. Threads that fight for it wait about as long as they run, or
longer: a thread that wants the GVL waits until the one holding it lets
go, or its time slice runs out. (Threads that mostly wait on I/O, and
only now and then want the GVL at once, wait anything from a twentieth
as long as they run to more than that, as the machine is busy.) So a
benchmark is judged on `gvl_wait` only when its samples wait a tenth of
their CPU time or more on either version (`cpu_floor: 0.1`): code that hardly waits on
both isn't judged on the noise, and code that starts waiting where it
hardly did is (its ratio is many times over). It's a share and not a
time since samples are as long as their CPU time needs to settle (some
10 ms, or more). `gvl_wait` doesn't size samples: CPU time does.

Duel's `c.measure` changes its settings, or leaves it out:

```ruby
c.measure("gvl_wait", cpu_floor: 0.5, limit: 2.0) # judged from half the CPU time, slower past twice as long
c.measure("gvl_wait", skip: true)
```
