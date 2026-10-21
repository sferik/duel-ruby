# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class ActiveRecordTest < PluginTest
  cover "Duel::ActiveRecord*"

  COUNTED = %w[active_record_queries active_record_cached_queries active_record_transactions active_record_instantiations].freeze

  # The plugin registers itself, as c.use :activerecord finds it, and is
  # configured once however many times it's used.
  def test_registered
    config, counter = use

    assert_same Duel::ActiveRecord, Duel.plugins.fetch(:activerecord)
    assert_equal [:activerecord], config.plugins
    assert_same counter, config.use(:activerecord)
    assert_equal 1, config.metrics.size
  end

  def test_its_measures
    config, = use
    settings = config.metrics.first.settings

    assert_equal COUNTED, settings.keys
    assert settings.values.all? { |s| s.fetch(:kind) == :counted }
    assert_equal [%w[query queries], %w[query queries], %w[transaction transactions], %w[record records]],
      settings.values.map { |s| s.values_at(:unit, :plural) }
  end

  # Reading the totals queries nothing, so there's nothing to take away.
  def test_reading_costs_nothing
    config, = use

    assert_equal COUNTED.to_h { |name| [name, 0] }, measure(config) {}
  end

  # Running totals, from nothing.
  def test_totals
    _, counter = use
    _, timing = use(query_time: true)

    assert_equal COUNTED.to_h { |name| [name, 0] }, counter.totals
    assert_equal [*COUNTED, "active_record_query_time"].to_h { |name| [name, 0] }, timing.totals
  end

  def test_counts_queries_sent_to_the_database
    config, = use
    measured = measure(config) do
      Post.first.comments.to_a                             # two queries
      Post.connection.execute("SELECT 1")                  # one more
      Post.transaction { Post.count }                      # one, in one transaction
      Post.transaction {}                                  # none: no transaction either
      Post.cache { 2.times { Post.where(title: "x").to_a } } # one, then one cached
    end

    assert_equal({"active_record_queries" => 5, "active_record_cached_queries" => 1, "active_record_transactions" => 1,
                  "active_record_instantiations" => 3}, measured)
    assert_empty Thread.current[Duel::ActiveRecord::Counter::STARTED].to_a, "no query's start kept, untimed"
  end

  # What other code sends as Active Record's queries: without a name, or
  # saying it wasn't cached.
  def test_counts_queries_from_elsewhere
    config, = use
    measured = measure(config) do
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1")
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 2", name: "Other", cached: false)
    end

    assert_equal [2, 0], measured.values_at("active_record_queries", "active_record_cached_queries")
  end

  def test_counts_transactions_and_savepoints
    config, = use
    measured = measure(config) do
      Post.create!(title: "a")                                       # one
      Post.transaction { Post.create!(title: "b").comments.create! } # one, for both
      Post.transaction do                                            # one
        Post.create!(title: "c")
        Post.transaction(requires_new: true) { Post.create!(title: "d") } # and a savepoint
      end
    end

    assert_equal 4, measured.fetch("active_record_transactions")
    assert_equal 5, measured.fetch("active_record_queries"), "not BEGIN, COMMIT or SAVEPOINT"
  end

  def test_counts_records_instantiated
    Post.create!(title: "second").comments.create!
    config, = use

    assert_equal 5, measure(config) { Post.includes(:comments).to_a }.fetch("active_record_instantiations")
  end

  def test_leaves_out_schema_queries
    config, = use

    assert_equal 0, measure(config) { Post.connection.columns("posts") }.fetch("active_record_queries")
  end

  def test_leaves_out_what_its_told_to
    config, = use(query_time: true, ignore: ->(payload) { payload[:sql].include?("pragma") })
    measured = measure(config) { Post.connection.execute("SELECT 1 -- pragma") }

    assert_equal [0, 0], measured.values_at("active_record_queries", "active_record_query_time")
    assert_equal 1, measure(config) { Post.count }.fetch("active_record_queries")
  end

  def test_times_queries_when_asked
    config, = use(query_time: true)
    name, settings = config.metrics.first.settings.to_a.last
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    measured = measure(config) { Post.transaction { Post.count } }
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started

    assert_equal "active_record_query_time", name
    assert_equal({kind: :ratio, unit: "ns", plural: "ns", floor: 300_000, cpu_floor: 0, limit: 1.05, unit_ns: 1,
                  sizes_samples: true, across: true, tolerance: 0, allowance: 0}, settings)
    assert_equal 1, measured.fetch("active_record_queries")
    assert_operator measured.fetch("active_record_query_time"), :>, 0, "BEGIN and COMMIT too"
    assert_operator measured.fetch("active_record_query_time"), :<, took
    assert_instance_of Integer, measured.fetch("active_record_query_time"), "in nanoseconds"
    assert_empty Thread.current[Duel::ActiveRecord::Counter::STARTED], "every start finished"
  end

  # A query inside another (a transaction's BEGIN, sent just before the
  # query that needs it) is timed on its own, and the outer one from its
  # own start, though the inner one isn't counted (as a schema query
  # isn't).
  def test_times_queries_inside_queries
    _, counter = use(query_time: true)
    counter.subscribe(["active_record_query_time"])
    clock = [100, 110, 120, 150].each
    counter.define_singleton_method(:monotonic) { clock.next }
    sql = Duel::ActiveRecord::Counter::SQL
    counter.start(sql, "outer", {})
    counter.start(sql, "inner", {})
    counter.finish(sql, "inner", {name: "SCHEMA", sql: "PRAGMA table_info(posts)"})
    counter.finish(sql, "outer", {name: "Post Count", sql: "SELECT COUNT(*) FROM posts"})

    assert_equal [1, 50], counter.totals.values_at("active_record_queries", "active_record_query_time")
  end

  def test_times_queries_in_other_threads
    config, = use(query_time: true)
    measured = measure(config) { Thread.new { Post.count }.join }

    assert_operator measured.fetch("active_record_query_time"), :>, 0
  end

  # Subscribing waits for the worker, as it opens the metric (once the
  # benchmarks have loaded): the runner, which only loads .duel.rb, never
  # loads Active Support for it. It unsubscribes when the worker ends, as
  # it closes the metric.
  def test_subscribes_in_the_worker
    config, = use
    notifier = ActiveSupport::Notifications.notifier

    refute notifier.listening?("instantiation.active_record")
    Duel::Testing.in_worker(config) do
      assert notifier.listening?("instantiation.active_record")
      assert_equal 1, measure(config) { Post.count }.fetch("active_record_queries")
    end

    refute notifier.listening?("instantiation.active_record")
    out, status = Open3.capture2(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", <<~RUBY)
      require "duel"
      require "duel/testing"
      config = Duel::Config.new
      config.use(:activerecord)
      print defined?(ActiveSupport).inspect
      Duel::Testing.in_worker(config) { print " ", ActiveSupport::Notifications.notifier.listening?("sql.active_record") }
    RUBY

    assert_predicate status, :success?
    assert_equal "nil true", out
  end

  # Unsubscribing leaves everyone else's subscriptions to the same events.
  def test_unsubscribes_only_itself
    config, = use
    theirs = ActiveSupport::Notifications.subscribe("sql.active_record") {}
    Duel::Testing.in_worker(config) {}

    assert ActiveSupport::Notifications.notifier.listening?("sql.active_record")
  ensure
    ActiveSupport::Notifications.unsubscribe(theirs)
  end

  # What c.measure leaves out isn't subscribed to, nor timed.
  def test_what_it_skips
    config, = use(query_time: true)
    config.measure("active_record_instantiations", skip: true)
    config.measure("active_record_query_time", skip: true)
    notifier = ActiveSupport::Notifications.notifier
    Duel::Testing.in_worker(config) do
      assert notifier.listening?("sql.active_record")
      refute notifier.listening?("instantiation.active_record")
      assert_equal 0, measure(config) { Post.count }.fetch("active_record_query_time")
    end
  end

  # Where the queries regressed, the statements a sample sent most, and
  # how many times an iteration (the most first, and by their SQL).
  def test_details
    config, = use
    measured = measure(config, n: 2) { 2.times { Post.first.comments.to_a } }

    assert_match(/\Aan iteration: 1× SELECT "comments"\.\* FROM "comments" WHERE "comments"\."post_id" = \? ?.*; 1× SELECT "posts"\.\* FROM "posts" .*LIMIT.*\z/,
      measured.details.fetch("active_record_queries"))
    assert_equal ["active_record_queries"], measured.details.keys
    measured = measure(config, n: 4) do
      3.times { Post.count }
      Post.first
    end

    assert_match(/\Aan iteration: 0.75× SELECT COUNT\(\*\) FROM "posts"; 0.25× SELECT "posts".*\z/, measured.details.fetch("active_record_queries"))
  end

  # It keeps the SQL of the first few statements, and tells the rest as
  # others; it shows the few most, on one line, and only so much of each.
  def test_details_of_many_statements
    config, = use
    long = "SELECT 1 AS #{"a" * 120}"
    measured = measure(config) do
      4.times { Post.connection.execute("  SELECT\n  2,\t3\n") }
      Post.connection.execute(long)
      8.times { |i| Post.connection.execute("SELECT #{i + 10}") }
    end

    assert_equal "an iteration: 4× SELECT 2, 3; 1× SELECT 1 AS #{"a" * 85}...; 1× SELECT 10; 7× others",
      measured.details.fetch("active_record_queries")
    measured = measure(config) do
      8.times { |i| Post.connection.execute("SELECT #{i + 10}") }
      5.times { Post.connection.execute("SELECT 20") }
    end

    assert_equal "an iteration: 1× SELECT 10; 1× SELECT 11; 1× SELECT 12; 10× others", measured.details.fetch("active_record_queries"),
      "SELECT 20's SQL not kept"
  end

  # It forgets the SQL it kept, once it's said what it was: the next
  # sample's statements are kept.
  def test_details_forget
    config, = use
    measure(config) { 8.times { |i| Post.connection.execute("SELECT #{i + 10}") } }

    assert_equal "an iteration: 1× SELECT 20", measure(config) { Post.connection.execute("SELECT 20") }.details.fetch("active_record_queries")
  end

  # Of the rest, it keeps only a hash of their SQL, not the SQL itself
  # (which it would keep alive).
  def test_keeps_a_hash_of_the_sql
    config, counter = use
    sql = "SELECT 1"
    measure(config) { Post.connection.execute(sql) }

    assert_equal [sql.hash], counter.instance_variable_get(:@recent)
  end

  # Of a sample of more queries than it keeps track of, the last it did.
  def test_details_of_many_queries
    config, = use
    measured = measure(config) do
      Post.connection.execute("SELECT 1")
      Duel::ActiveRecord::Counter::KEPT.times { Post.connection.execute("SELECT 2") }
    end

    assert_equal "an iteration: 1000× SELECT 2", measured.details.fetch("active_record_queries")
  end

  # What it doesn't count (cached queries, transactions', and those in
  # an untimed block), it doesn't show, but what's on either side of an
  # untimed block is; and a sample without a query says nothing.
  def test_details_of_what_it_doesnt_count
    config, = use
    measured = measure(config, n: 2) do |sample|
      Post.connection.execute("SELECT 1")
      sample.untimed { Post.count }
      Post.transaction { Post.cache { 2.times { Post.where(title: "x").to_a } } }
    end

    assert_match(/\Aan iteration: 0.5× SELECT "posts"\.\* FROM "posts" WHERE "posts"\."title" = \?; 0.5× SELECT 1\z/,
      measured.details.fetch("active_record_queries"))
    assert_empty measure(config) {}.details
  end
end

# Whole comparisons, in real worker processes. (Not for mutant: each
# takes seconds, and the tests above cover the same code.)
class ActiveRecordComparisonTest < PluginTest
  # Whole comparisons: the same code passes; code with an N+1 query fails
  # on its queries, and says which, on each version.
  def test_comparisons
    base = project("base")
    same = compare(base, project("same"))
    queries = same["blog: comment counts"].counted.fetch("active_record_queries")

    assert_predicate same, :passed?, same.output
    assert_equal 2, queries.fetch("candidate") / queries.fetch("n"), same.output
    n_plus_one = compare(base, project("n_plus_one", n_plus_one: true))
    result = n_plus_one["blog: comment counts"]
    queries = result.counted.fetch("active_record_queries")

    assert_includes result.regressed, "active_record_queries", n_plus_one.output
    assert_equal 6, queries.fetch("candidate") / queries.fetch("n"), n_plus_one.output
    assert_match(/^  active_record_queries: 2 queries → 6 queries an iteration$/, n_plus_one.output)
    assert_match(/^  active_record_queries \(candidate\): an iteration: 5× SELECT COUNT\(\*\) FROM "comments" WHERE "comments"\."post_id" = \?; 1× SELECT "posts"\.\* FROM "posts"$/,
      n_plus_one.output)
    assert_match(/^  active_record_queries \(baseline\): an iteration: 1× SELECT "comments"\.\* FROM "comments" WHERE "comments"\."post_id" IN \(\?(, \?)*\); 1× SELECT "posts"\.\* FROM "posts"$/,
      n_plus_one.output)
  end

  private

  def compare(base, candidate) = Duel::Testing.compare(base, candidate, timeout: 300.0) # (a loaded machine)
end
