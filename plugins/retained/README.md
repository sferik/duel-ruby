# duel-retained

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-retained](https://github.com/sferik/duel-ruby/actions/workflows/plugin-retained.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-retained.yml)
[![Gem Version](https://badge.fury.io/rb/duel-retained.svg)](https://rubygems.org/gems/duel-retained)

A [Duel](https://github.com/sferik/duel-ruby) plugin: every benchmark is
judged on what its iterations leave alive too, the Ruby objects still
there after a full garbage collection.

| Metric | What it is | A regression |
|---|---|---|
| `retained_objects` | the objects a sample's iterations left alive, beyond a few a sample (CRuby) | one more per two iterations |

So a leak, a cache that grows with every call, or memoization keyed by
input that never repeats, fails, though it allocates no more and takes
no longer than before. Allocations count what a benchmark makes, and CPU
time what it costs now, but neither sees what it keeps. Duel's `peak_memory`
does, coarsely: resident memory, in fresh workers, judged by the
megabyte. This counts the objects, exactly.

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-retained"
end
```

> [!NOTE]
> It measures on CRuby. On JRuby and TruffleRuby, whose garbage collectors
> can't be held off, or their live objects counted, it leaves itself out:
> benchmarks run, and are judged, as without it.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :retained }
```

Then a benchmark whose code keeps what it's given fails:

```ruby
# lib/my_formatter.rb, the candidate's: memoized, and never forgets
FORMATTED = {}
def self.format(value) = FORMATTED[value] ||= value.round(2).to_s.rjust(10)

# duel/formatter_duel.rb
duel("format: a number") { MyFormatter.format(rand) }
```

```
! format: a number    0.4s n=5528   ...   retained_objects 3→5531  allocations 11056
REGRESSION format: a number: worse retained_objects in every measurement
  retained_objects: 0.0005427 objects → 1.001 objects an iteration
  retained_objects (candidate): an iteration: 1 String (lib/my_formatter.rb:3)
```

What it retained beyond what's let through is shown by class, and where
it was made (the three most): see [What it retained](#what-it-retained).

Install it after any other plugin's metrics: those added after it are
read inside its measurement, and what they keep of their readings counts
toward its allowance.

A sample may leave 16 objects alive before any counts against it (its
allowance), and beyond that it's one more per two iterations (its
tolerance) that's a regression: see [below](#what-it-cant-help-counting).
Duel's `c.measure` changes either, or leaves the metric out:

```ruby
Duel.configure do |c|
  c.use :retained
  c.measure("retained_objects", allowance: 32, tolerance: 1) # or skip: true
end
```

## How it measures

Duel holds the garbage collector off during a sample, so that when it
runs isn't up to chance. `GC.start` still collects (CRuby leaves the
collector disabled after): before each sample it counts in, the plugin
collects all the garbage there is, a full collection twice (what a
finalizer, or a dynamic symbol, keeps alive goes in the second), and
counts the live objects (`GC.stat(:heap_live_slots)`). After the sample,
it does it again. What's left is what the sample's iterations kept.

That's outside the built-in metrics, so none of it is in a benchmark's
allocations, instructions or CPU time. And only in the samples Duel
counts in (three of each version's a benchmark, and as many again for
each time it measures one again before failing), not the timed ones. A
full collection takes about half a millisecond with 30,000 live objects,
and some 15 with a million: four a sample, so a fraction of a second a
benchmark, for even a large application.

What's measured is the count itself, every object more after the sample
than before it (or fewer, for one that let go of more than it kept), and
Duel judges it: a candidate that leaves more alive than the baseline, by
more than the allowance a sample and the tolerance an iteration, fails.

### What it can't help counting

Not every object a sample leaves alive is the benchmark's. Duel's own
record of the metrics inside this one is. And so is what's still on the
machine stack when the sample stops: the last iteration's result (or the
block's, given n) is no longer referenced, but CRuby scans the stack
conservatively, so a stale reference to it there, or to anything it
holds, keeps it alive through the collection. Nothing Duel or the plugin
can do from Ruby clears it: running the iterations on a stack of their
own (a Fiber) would, but it would change what `Thread.current[]` means to
the benchmark. They're the same few from sample to sample, but not
always to the object, so a sample is allowed 16 before any is counted.
On top of that, it's one more per two iterations, not one more, that's a
regression. So for a benchmark that runs thousands of iterations a
sample, as most do, one object kept an iteration fails. For one that
runs a few (a slow one, or one with `only: :count`, which runs four),
it takes more an iteration.

What a benchmark makes the first time and keeps (a constant it
memoizes, a method cache) isn't a leak: Duel runs each benchmark many
times before it counts, and none of that is counted.

Benchmarks with `only: :timing` aren't counted at all, so they aren't
judged on this either.

### Untimed blocks

Duel pauses every metric around an `untimed` block, and this one would
collect the garbage, twice, on each: in a benchmark with an `untimed`
block in every iteration, that's thousands of collections a sample. So
it doesn't pause: it measures the whole sample, and what an `untimed`
block makes counts only if it's still alive when the sample is over.
What it usually makes, the input a benchmark works on, isn't.

## What it retained

Where a sample retained more than Duel lets through (its allowance, and
its tolerance for its iterations, as `c.measure` leaves them), the
plugin says what, under the regression: the objects' classes, and where
they were made, the three most, an iteration (`1 String
(lib/my_formatter.rb:3)`), of the sample whose count was judged, on
each version that did. Files are from the working directory, the
project's, so the baseline's show their whole path, in its checkout
next to the project. Objects Duel makes for itself aren't shown.

It knows from Ruby's allocation tracing (`objspace`'s
`ObjectSpace.trace_object_allocations`), on during each sample it counts
in: that makes each allocation some four times slower, in samples that
aren't timed. Telling what's left apart walks every live object (some
twenty times as long as a full collection), so it's done only for a
sample that retained more than Duel lets through. A benchmark that
traces allocations itself, or clears the trace, shares the one Ruby
has.
