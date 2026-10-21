# duel-memcached

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-memcached](https://github.com/sferik/duel-ruby/actions/workflows/plugin-memcached.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-memcached.yml)
[![Gem Version](https://badge.fury.io/rb/duel-memcached.svg)](https://rubygems.org/gems/duel-memcached)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that talks
to memcached: each Duel worker gets a memcached server of its own, and
every benchmark is judged on what memcached did for it too.

| Metric | What it is | A regression |
|---|---|---|
| `memcached_operations` | the keys it fetched, stored, touched, deleted, incremented or decremented, and flushes | any increase |
| `memcached_misses` | the operations that found no key | any increase |
| `memcached_bytes` | the bytes it read and wrote: requests, replies, keys and values | more than one an iteration |
| `memcached_cpu` | its CPU time, in µs (only with `cpu: true`) | > 5% slower, 99% confident |

So a change that fetches one more key per request, stops finding what it
cached, or caches bigger values fails even when its CPU time on the Ruby
side doesn't change:

```
REGRESSION store: worse memcached_operations, memcached_bytes in every measurement
  memcached_operations: 1 operation → 2 operations an iteration
  memcached_bytes: 34 B → 70 B an iteration
```

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-memcached"
end
```

> [!NOTE]
> It needs `memcached` (1.6 or later) on the `PATH`.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :memcached }
```

Each worker's server listens only on a Unix socket in the worker's own
directory, with 32 MB of memory and one thread. The socket's path is in
`DUEL_MEMCACHED_SERVERS`, and in `MEMCACHE_SERVERS` too, so a client that
reads that (Dalli does) finds it and nothing reaches another memcached.
Benchmarks can call `Duel::Memcached.servers` and
`Duel::Memcached.flush`:

```ruby
# duel/cache_duel.rb
duel "cache: a hit" do
  once do
    Duel::Memcached.flush                                # empties the worker's server (over a connection of its own)
    @cache = Dalli::Client.new(Duel::Memcached.servers) # its socket
    @cache.set("k", "v")
  end
  @cache.get("k")
end
```

> [!IMPORTANT]
> `Duel::Memcached.flush` is for setting up: call it in a `setup` hook,
> or a `once` or `untimed` block. While a benchmark is measured (`Duel.measuring?`), it
> raises `Duel::Error` rather than have the flush counted.

Options:

```ruby
c.use :memcached,
  server: "/opt/memcached/bin/memcached", # the program (default: DUEL_MEMCACHED_SERVER, or memcached)
  args: ["-m", "256"],                    # more of its options (they win)
  env: %w[CACHE_SERVERS],                 # variables given its socket besides DUEL_MEMCACHED_SERVERS (default: MEMCACHE_SERVERS)
  cpu: true                               # judge memcached_cpu too
```

The metrics come from the server's `stats`, read over a connection of
the plugin's own, opened as each worker starts (Duel's `c.in_worker`)
and closed as it ends. `c.use :memcached` returns it, for a `.duel.rb`
that reads the server too (`connection.value`, in a worker only).
`Duel::Memcached.flush` opens a connection of its own, from the worker's
`DUEL_MEMCACHED_SERVERS`: a flush is an operation, and its bytes count
as any client's (so it fails while a benchmark is measured).
`memcached_operations` counts keys, not commands: a
`get_multi` of ten keys is ten. Memcached keeps no count of commands or
replies, so a change from one `get_multi` to ten `get`s shows in
`memcached_bytes`, not in operations.

`memcached_bytes` leaves out the plugin's own traffic, to the byte (a
reading's reply is longer when the numbers in it are), so it's exact.
But what the server makes up (CAS ids) grows a digit now and then, and so
may values of your code's (times, ids), so a byte more an iteration
isn't a regression.

`memcached_cpu` is off unless asked for: memcached's CPU time (from
`rusage_user` and `rusage_system`, to the microsecond) is the whole
process's, background threads and all, and depends on how fast the
client sends it work. It's noisy, and what it would catch (more work for
the server) usually shows exactly in operations and bytes first. When
it's on, it's judged above 300µs a sample (on either version), against
a limit of 1.05, and not across the board (where Duel judges every
benchmark's median together, with a margin a quarter of the limit's:
too fine for it).

Duel's `c.measure` changes any of their settings, or leaves one out:

```ruby
c.measure("memcached_bytes", tolerance: 8)  # values whose length varies more
c.measure("memcached_misses", skip: true)
```
