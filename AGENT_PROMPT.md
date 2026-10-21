# Adopting Duel: a prompt for a coding agent

Give this to a coding agent (paste it, or point it here), in the project
you want to guard.

---

Add performance regression guards to this project with Duel
(https://github.com/sferik/duel-ruby), so a pull request that makes the
code slower fails CI.

First read Duel's README, and the guide in its `docs/` directory, in
full. After installing, find them with `bundle info duel --path`. Follow its conventions exactly, and don't guess
at the API.

1. **Install and set up.** Add `gem "duel"` to the Gemfile's
   development group (unless the Gemfile has it already), and run
   `bundle install`. Then, unless the project is a Rails app (see step
   4), run `bundle exec duel init`, and read what it wrote: `.duel.rb`,
   an example benchmark in `duel/`, the GitHub Actions workflow
   (`.github/workflows/perf.yml`), Duel's Rake task, if there's a
   Rakefile, and `gem "stackprof", platforms: :mri` in the Gemfile, for
   profiles of regressions. It lists what it did and what's next: run
   `bundle install` again for StackProf.

2. **Find what's worth guarding.** Read the code and its tests to find
   the work users depend on being fast:
   - The main public entry points.
   - Anything called in a loop or once per request.
   - Parsers, serializers and encoders.
   - Anything the docs or changelog make performance claims about.
   - Any existing benchmarks (`benchmark/`, `bench/`, benchmark-ips
     scripts).

   Prefer focused benchmarks over broad ones: 10–30 for a sizable
   library, fewer for a small one with few hot paths. Cover typical
   inputs and the small and large extremes, as separate benchmarks.
   Before writing any, list what you chose and why.

3. **Write the benchmarks** in `duel/*_duel.rb`, in place of the
   example that `duel init` wrote. Shared helpers go in
   `duel/duel_helper.rb`, and fixtures in `duel/fixtures/`.
   - Name each one "area: what it does", e.g. `"parse: a large document"`.
     `--filter` takes a regular expression and matches anywhere in a
     name, so `^parse:` picks out an area. Keep names under about 50
     characters, or they push the report's columns out of line.
   - Time only the work itself. Building inputs, reading fixtures and
     connecting go in `once { }`. For per-batch work, take `|n|` and wrap
     the per-batch preparation in `untimed`.
   - Make every iteration identical. Use fixed inputs, seed any
     randomness (`Random.new(42)`), and warm caches and memoization in
     `once`. Work that writes (records, files, a queue) changes what
     the next iteration sees: undo each iteration with an
     `around_iteration` hook (rolling back a transaction, say), and put
     back what a sample changed with a `before_sample` hook. Duel fails
     on even one extra allocation per two iterations, so anything that
     varies from run to run is a false alarm waiting to happen. That
     includes what differs between the two versions' workers, like a
     server's socket path or a worker's directory: don't time work on
     it.
   - Use the sizes the code really sees. Read it for limits and
     constants (a cap on how many items it ever handles, say) rather
     than guessing.
   - Time one iteration before writing a benchmark around it. Aim for
     microseconds to a few milliseconds per iteration, and split
     anything slower: a size the code never sees can take seconds, and
     an iteration that takes over a minute (`--timeout`) is an error.
   - Use only API the main branch already has. A benchmark the baseline
     can't run is skipped, so it guards nothing until it's merged.
   - Use `only: :count` for work that's mostly waiting, including
     anything that goes through a socket or makes system calls, even on
     the same machine: its timings are too noisy to settle. Use
     `only: :timing` for work done on threads of its own, and
     `peak_memory: true` where memory use matters.
   - Prefer one thread. Switching between threads costs microseconds,
     which swamps a small cost and leaves its timings unsettled: guard
     threaded code with a single thread exercising it where you can.
   - Don't change anything under `lib/` or `ext/`.

4. **Configure only if needed.** `duel init` wrote a `.duel.rb` for
   what it could tell of the project: a gemspec, `ext/`, and a
   `.ruby-version`. A conventional gem needs nothing more. If the
   project isn't one (a non-standard layout, a build step other than
   `rake compile`), change it, using only the settings that Duel's
   `docs/configuration.md` documents.

   If the code talks to Redis, PostgreSQL, MySQL or memcached, or uses
   Active Record, threads, or long-lived objects, use the matching
   plugin (duel-redis, duel-postgresql, duel-mysql, duel-memcached,
   duel-activerecord, duel-gvl, duel-retained): add its gem, and
   `c.use` it by name in `.duel.rb` (`c.use :redis`). Don't point
   benchmarks at a shared server.

   If the project is a Rails app, use duel-rails instead of `duel init`
   (which says so) or setting Duel up by hand: add it to the Gemfile's
   development group, run `bin/rails generate duel:install`, read what
   it made, and run `bundle install` again for what it added to the
   Gemfile (StackProf, and a database server's plugin). Then:
   - Benchmark the requests that matter most with `duel_request`, not
     only the GET routes the generator found: the pages users load
     most, and the forms and API calls that write. Give each request
     what it sends (`params:`, `json:`, `headers:`), and sign in with a
     block where the request needs a user.
   - Give the requests data to work with: `fixtures: :all` (or the
     fixtures the requests need), or `seeds: true`, in `.duel.rb`. A
     page with no records to show guards almost nothing.
   - Benchmark the app's slowest models and services with plain `duel`
     blocks too, with their data made in `once`. Roll back those that
     write with `around_iteration: Duel::Rails::ROLLBACK`.
   - Check `config/environments/benchmark.rb`: stub anything a request
     would call over the network.

   If the project is itself a Duel plugin, don't require or use it in
   its own `.duel.rb`. That would load the candidate's plugin into
   Duel's own workers, under the version being measured. Start any
   server its benchmarks need with `c.prepare(:worker)` directly, with
   every option the plugin itself starts it with: one left out can
   change what the server does (and what the plugin reads of it).

   If the project's boot time or load time matters (an app, or a library
   that's slow to require), add a `duel_process` benchmark of it, such as
   `duel_process "boot: the app", "bin/rails", "runner", "1"`.

   If the project pins its Ruby (`.ruby-version`, `.tool-versions`, or
   `mise.toml`), set `c.ruby = :version_file`, so that a branch that
   upgrades Ruby is compared on each version's own Ruby. `duel init`
   does this, and adds the steps in Duel's `docs/ci.md` that install
   the baseline's Ruby to the workflow, for a `.ruby-version`. For another version
   file, do both yourself (see step 6). Duel uses the Ruby that runs it
   when that's the one asked for, so CI needs nothing more until a
   branch changes the Ruby.

   If the project is in a subdirectory of its repository (a monorepo),
   put `.duel.rb` and `duel/` in that subdirectory, and run `duel` from
   there. Run `duel init` there too: it puts the workflow at the
   repository's root, and runs it in the subdirectory.

   Make sure the linter checks `.duel.rb`. It's a dotfile, so RuboCop
   leaves it out unless its config includes it (`AllCops: Include`,
   merged with the defaults by `inherit_mode`).

5. **Check that the guards hold.** While you're still writing
   benchmarks, run a few at a time (`bundle exec duel --force --filter
   <name>`): a whole run waits on its slowest benchmark, and shows
   nothing of one until it's measured. Duel runs one comparison at a
   time in a project: a second run fails, naming the first one's pid.

   If the project has a C extension, Duel checks that each version's
   workers load their own build, and fails, saying to set `c.build`, if
   one doesn't (a baseline with no build of its own would load the
   candidate's).

   Then do all three:
   - Run `bundle exec duel --force`. With `lib/` unchanged, it compares
     the code with itself and must pass. Run it three times: a noisy
     benchmark can pass twice by luck. A benchmark that fails or
     errors is broken. One reported unsettled in more than one run is
     noisy: fix it or drop it. (Across many benchmarks, one unsettled
     once is normal: it doesn't fail the run.) Benchmarks that run a
     lot of other code (a framework's whole query, say) to exercise a
     little of the project's are the noisiest: guard the project's part
     directly instead.
   - Make a deliberate regression in code that a few benchmarks
     exercise: an extra allocation in a hot method, then some extra
     work in a loop (in a C extension, the extra work). Confirm that
     `bundle exec duel` exits 1 and names those benchmarks. Then revert
     the change completely, check that `git diff lib/ ext/` is empty,
     and rebuild the extension if you changed one.
   - Run `bundle exec duel --force --filter <pattern>` for a single
     benchmark, and for one area (`--filter "^parse:"`), to confirm
     your names can be picked out. Without `--force`, an unchanged
     `lib/` has nothing to compare.

6. **Check CI.** `duel init` wrote Duel's GitHub Actions
   workflow (`.github/workflows/perf.yml`). Keep `fetch-depth: 0`:
   Duel's baseline comes from git history. Keep its check for a push
   with no commit before it in the history (a branch's first push, or a
   force push), which would otherwise fail the job. Keep its last step,
   which comments on a pull request with Duel's report (Duel also adds
   the report to the job's summary). Check that `ruby-version` is one
   the project supports, unless it has a `.ruby-version`. With
   `c.ruby = :version_file` and another version file than
   `.ruby-version`, add the steps in Duel's `docs/ci.md` that install the
   baseline's Ruby for a pull request. Add the project's other CI setup that its
   tests need (system packages, services) to the workflow as well. Keep
   the scheduled `last-release` run only if the project tags its
   releases (`v*` by default, or else set `c.release_tags`), or leave
   the schedule out. Until the first release is tagged, that run says
   there's nothing to compare against, and passes. Once it's pushed,
   run the workflow by hand: it compares the code with itself there,
   which shows that the benchmarks run on CI's machines (with their
   packages and services).

7. **Show the badge.** If the project's README already shows badges (CI
   status, gem version), add Duel's to that row, with exactly this
   markdown:

   ```markdown
   [![Duel](https://raw.githubusercontent.com/sferik/duel-ruby/main/assets/badge.svg)](https://github.com/sferik/duel-ruby)
   ```

   If the README has no badges, don't add a row just for Duel's.

8. **Report back** with:
   - The benchmarks you wrote and what each one guards.
   - What you chose not to benchmark, and why.
   - The output of the self-comparison and of the deliberate-regression
     check.
   - Anything you couldn't guard reliably.

Don't commit. Leave the changes for me to review.
