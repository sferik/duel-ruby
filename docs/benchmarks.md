# Write benchmarks

This page covers what a benchmark can do beyond timing a block: run
code around its samples and iterations, share code with other
benchmarks, choose what it's judged on, and benchmark a whole process.
For a first benchmark, with `once`, `untimed`, and a block that takes
the number of iterations, see
[Write a benchmark](../README.md#write-a-benchmark).

## Run code around a benchmark

A *hook* runs code around a benchmark's samples or iterations, such as
setting up a client once, or emptying a queue before every sample. Duel
has the following hooks:

| Hook | When it runs, in each worker | Measured |
|---|---|---|
| `setup` | Once, before the benchmark's samples | No |
| `teardown` | Once, after the benchmark's samples | No |
| `before_sample` | Before every sample, warm-up samples included | No |
| `around_iteration` | Around each iteration, which it's given to run | Only the iteration |
| `after_iterations` | After each sample's iterations, or after each iteration with `around_iteration` | Yes |

You can give a hook at three levels, with the same name at each:

- In `.duel.rb`, for every benchmark: `c.before_sample { ... }`.
- At the top of a file of benchmarks, for every benchmark in the file:
  `before_sample { ... }`.
- As an option of one benchmark, with a lambda:
  `duel "name", before_sample: -> { ... } do ... end`.

```ruby
# duel/client_duel.rb
setup { @client = MyClient.new(timeout: 1) }
teardown { @client.close }

duel("client: one request") { @client.get("/") }
duel("client: ten requests", setup: -> { @client.warm }) { 10.times { @client.get("/") } }
```

When several levels give the same hook, Duel runs `.duel.rb`'s first,
then the file's, then the benchmark's own, each in the order that it was
given. `teardown` runs in the reverse order, so what's set up last is
torn down first. `around_iteration` hooks nest, outermost first: the
hook from `.duel.rb` runs around the file's, which runs around the
benchmark's.

A file's hooks and a benchmark's own run in the benchmark's context, so
they share its instance variables. Hooks in `.duel.rb` run where they're
written, which suits a plugin's hooks. `setup`, `teardown`, and
`before_sample` receive the benchmark, with its `name`, `only`, and
`peak_memory`, if they take a parameter.

Inside a benchmark's own block, `once { ... }` runs its block the first
time that the benchmark runs, and isn't timed, as in
[Write a benchmark](../README.md#write-a-benchmark). It's for what one
benchmark needs, in its own block, where the `setup` hook is for what
it needs before its block runs, or for what every benchmark in a file
needs.

A process benchmark (`duel_process`) doesn't run in a worker, so it
runs no hooks. See [Benchmark a whole process](#benchmark-a-whole-process).

## Start every sample alike

A worker measures each benchmark over many samples. If a benchmark
changes something that later samples see, such as rows that it inserts
or items that it pushes onto a queue, later samples measure different
work. A `before_sample` hook puts back what earlier samples changed, so
that every sample starts alike. Duel doesn't measure it:

```ruby
# duel/queue_duel.rb
setup { @queue = MyQueue.new }
before_sample { @queue.clear } # not measured

duel("queue: push") { @queue.push(1) }
```

To start every sample of every benchmark alike, for example by emptying
a database's tables, give the hook in `.duel.rb`:

```ruby
Duel.configure do |c|
  c.before_sample { |benchmark| MyDatabase.truncate_all } # not measured
end
```

## Undo each iteration

Some work changes what the next iteration sees, such as a request that
creates a record. To undo each iteration without measuring the undo,
use an `around_iteration` hook. Duel runs the hook around each
iteration, and the hook calls `iteration.call` exactly once. Duel
measures only the iteration: nothing else that the hook does is timed
or counted.

```ruby
rolled_back = lambda do |iteration|
  Post.transaction do
    iteration.call
    raise ActiveRecord::Rollback
  end
end

duel "posts: create", around_iteration: rolled_back do
  Post.create!(title: "Hello")
end
```

`iteration.call` returns what the iteration returns. A benchmark that
runs inside an `around_iteration` hook, from any level, can't take a
block parameter, because the hook runs once for each iteration.

To leave out what the hook does, Duel pauses every metric after each
iteration and resumes it before the next one. That reads each metric
twice per iteration, and part of that reading lands inside the
iteration. Duel learns how much in each worker, before it measures the
benchmark, and subtracts it from every iteration. Pausing allocates
nothing, so counts stay exact.

A metric that's costly to read, such as one that queries a database
server's statistics, would take a round trip to the server twice per
iteration. So Duel doesn't pause a metric that says it's costly (see
[Account for the cost of reading](configuration.md#account-for-the-cost-of-reading)).
It reads that metric only when a sample starts and stops, and subtracts
what the hook adds to it instead. Duel learns that in each worker,
before it measures the benchmark, from a few samples of their own, in
which it pauses the metric around each iteration. The hook's own work,
such as a transaction's `BEGIN` and `ROLLBACK`, isn't counted, and
neither is work of the hook's that depends on the iteration, such as
deleting what the iteration wrote. The plugins for servers, such as
[PostgreSQL](https://github.com/sferik/duel-ruby/tree/main/plugins/postgresql),
say that their metrics are costly.

The pausing still adds a little to each iteration, the same on both
versions, and it takes time that Duel doesn't measure. On an Apple M1
Max, with macOS and Ruby 3.4, an empty iteration with an
`around_iteration` hook measures less than 100 ns of CPU time and a few
hundred instructions more than an empty iteration without one, and no
more allocations. It also takes from 2 µs to 50 µs longer to run,
depending on how busy the machine is, mostly to read the CPU's
instruction counter, which takes a system call on macOS. Use
`around_iteration` for iterations that take tens of microseconds or
more, such as a database write. For cheaper work, give the block a
parameter, and prepare each sample's work in `untimed`.

## Measure the work that a benchmark leaves for later

Some of the work that a benchmark starts runs later, such as jobs that
it enqueues, or messages that it broadcasts. To measure that work as
part of the benchmark, give an `after_iterations` hook that does it
now:

```ruby
Duel.configure do |c|
  c.after_iterations { MyJobs.run_pending } # measured: the jobs are the benchmark's work
end
```

`after_iterations` is the one hook that Duel measures. It runs inside
the timed part of each sample, after the sample's iterations, and Duel
measures it with them. For a benchmark with an `around_iteration` hook,
it runs inside each iteration, after the iteration's own work, so that
what the hook undoes after the iteration is still there for the pending
work. Its work counts as the benchmark's, in every metric and in a
regression's profile.

## Share code between benchmarks

Put code that several files share in `duel/duel_helper.rb`, and require
it from each file, the same way that tests require `test_helper.rb`.
Every benchmark can call the methods that the helper defines at its top
level. Instance variables that those methods set belong to the
benchmark that calls them:

```ruby
# duel/duel_helper.rb
def document(size) = "[" + (["1"] * size).join(",") + "]"

def build_parser = @parser = MyParser.new(strict: true)

# duel/parser_duel.rb
require_relative "duel_helper"

duel("parse: a thousand numbers") { MyParser.parse(document(1000)) }

duel "parse: strictly" do
  once { build_parser }
  @parser.parse("[1]")
end
```

A helper can have any name except those of the methods that Duel gives
benchmarks: `duel`, `duel_process`, `once`, `untimed`, the hooks
(`setup`, `teardown`, `before_sample`, `around_iteration`, and
`after_iterations`), and any that a plugin used in `.duel.rb` adds.
Duel's method would hide a helper of the same name, so the worker
fails, and names the helper's file and line.

## Choose what a benchmark is judged on

By default, Duel judges each benchmark on its timings and its counts:

- Timings: CPU time, instructions, and the timings of any metric of your
  own.
- Counts: allocations, and any other exact counts.

To change that, pass these options to `duel`:

- `only: :count`: for work that's mostly waiting, too slow and light to
  time. Duel judges the benchmark on its counts alone, over a few
  iterations.
- `only: :timing`: for work done by threads that the benchmark starts,
  which make its counts vary from run to run. Duel judges the benchmark
  on its timings alone, and takes the process's CPU time instead of the
  benchmark thread's.
- `peak_memory: true`: also judges the benchmark's peak memory, which is
  the most resident memory that its measured work reached, above where
  it started. Duel takes each version's lowest peak from three fresh
  workers. Like every other measure, peak memory leaves out what
  `once` and `untimed` blocks leave behind.

```ruby
duel "server: 10 workers", only: :timing, peak_memory: true do |n|
  # ...
end
```

## Benchmark a whole process

To guard how long your app takes to boot, or your library to load, use
`duel_process`. Each sample starts fresh processes for each version,
in that version's directory and with its environment, and the two
versions take turns, as they do for every other benchmark. Give
`duel_process` a command, or Ruby code to run with `ruby:`:

```ruby
# duel/boot_duel.rb
duel_process "boot: the app", "bin/rails", "runner", "1"
duel_process "boot: require the library", ruby: %(require "my_gem")
```

Duel runs a command the way that `Process.spawn` does, so a single
string with spaces runs in a shell. It runs Ruby code on the version's
Ruby, with the version's `lib/` first on the load path.

Duel judges a process benchmark on the following:

- `cpu`: the CPU time that the process took, including the CPU time of
  the processes that it started and waited for.
- `peak_memory`: the most resident memory that the process reached,
  when Duel's runner is CRuby. Duel takes each version's lowest peak.

Each sample is the fastest of a few processes for each version, with
the two versions' processes taking turns: the lowest CPU time, and the
lowest peak memory. Interference from the rest of the machine only ever
adds time, so the fastest of a few is steadier than any one, and fewer
pairs settle the verdict. A sample takes as many processes as take
about a second of CPU time, up to 3, judging by a first pair of
processes that Duel doesn't measure. A short process, whose time varies
the most, gets 3, and an app that takes a second or more to boot gets
1, since its pairs take long enough as they are. To set the number
yourself, pass `runs:`:

```ruby
duel_process "boot: require the library", ruby: %(require "my_gem"), runs: 5
```

Duel starts and measures the processes from a small Ruby process of its
own, one for each worker, that lasts as long as the worker. It does
nothing else while a process runs, so the CPU time that it reads is the
process's alone, and its own start-up is paid once, not for every
process.

A process that exits with a status other than 0 is an error, and Duel
shows the end of its output. A process benchmark has no profile.

Each process takes a while, so Duel judges a process benchmark after
every pair of samples, and stops as soon as it finds that the
candidate isn't slower. It finds a process benchmark slower only after
a round of 10 pairs, as it does any benchmark, so stopping early never
makes the same code look slower.

A process benchmark doesn't run in a worker, so nothing that runs there
applies to it: hooks, from `.duel.rb` or its file, and the metrics that
plugins add. `duel_process` doesn't take the options of `duel`
(`only:`, `peak_memory:`, and the hooks, such as `around_iteration:`),
and raises an `ArgumentError` if it's given one.
