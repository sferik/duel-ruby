# duel-redis

[![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
[![duel-redis](https://github.com/sferik/duel-ruby/actions/workflows/plugin-redis.yml/badge.svg)](https://github.com/sferik/duel-ruby/actions/workflows/plugin-redis.yml)
[![Gem Version](https://badge.fury.io/rb/duel-redis.svg)](https://rubygems.org/gems/duel-redis)

A [Duel](https://github.com/sferik/duel-ruby) plugin for code that talks
to Redis: each Duel worker gets a Redis server of its own, and every
benchmark is judged on what Redis did for it too.

| Metric | What it is | A regression |
|---|---|---|
| `redis_cpu` | the time Redis spent running the benchmark's commands, in µs | judged like CPU time |
| `redis_commands` | the commands it ran | any increase |
| `redis_round_trips` | the replies it wrote: one per round trip | any increase |

So a change that sends one more command per job, or stops pipelining,
fails even when its CPU time on the Ruby side doesn't change.

## Installation

```ruby
# Gemfile
group :development do
  gem "duel-redis"
end
```

> [!NOTE]
> It needs `redis-server` (Redis 6.2 or later, or Valkey) on the `PATH`.

## Usage

```ruby
# .duel.rb
Duel.configure { |c| c.use :redis }
```

Each worker's server listens only on a Unix socket in the worker's own
directory, with persistence off, and works in that directory too
(`--dir`): if your `args:` turn persistence on, its snapshots and
append-only files go there, never in your project. Its URL is in
`DUEL_REDIS_URL`, and in `REDIS_URL` too, so a client that reads that
finds it and nothing reaches another Redis. Benchmarks can call
`Duel::Redis.url` and `Duel::Redis.flush`.

> [!IMPORTANT]
> `Duel::Redis.flush` is for setting up: call it in a `setup` hook, or
> a `once` or `untimed` block. While a benchmark is measured (`Duel.measuring?`), it
> raises `Duel::Error` rather than have its `FLUSHALL` counted.

```ruby
# duel/cache_duel.rb
duel "cache: a hit" do
  once do
    Duel::Redis.flush                           # empties the worker's server (over a connection of its own)
    @cache = MyCache.new(url: Duel::Redis.url)  # its URL
    @cache.write("k", "v")
  end
  @cache.read("k")
end
```

Options:

```ruby
c.use :redis,
  server: "valkey-server",        # the program (default: DUEL_REDIS_SERVER, or redis-server)
  args: ["--maxmemory", "64mb"],  # more of its options
  env: %w[CACHE_URL]              # variables given its URL besides DUEL_REDIS_URL (default: REDIS_URL)
```

The metrics come from the server's `INFO` (command statistics and
`total_writes_processed`), read over a connection of the plugin's own,
opened as each worker starts (Duel's `c.in_worker`) and closed as it
ends. `c.use :redis` returns it, for a `.duel.rb` that reads the server
too (`connection.value`, in a worker only). Each reading is a command and a
reply itself, so Duel learns what readings add, and takes it away. Reports
count them: `redis_commands 4→6`, `redis_round_trips: 1 round trip → 2
round trips an iteration`.
