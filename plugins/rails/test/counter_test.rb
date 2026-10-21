# frozen_string_literal: true

require_relative "test_helper"

# What the app's views and its cache did for each benchmark.
class CounterTest < PluginTest
  cover "Duel::Rails::Counter*"

  def setup
    super
    @config = Duel::Config.new(@dir)
    @counter = Duel::Rails::Counter.configure(@config)
  end

  def measure(&) = Duel::Testing.measure(@config, &)

  def sent(path) = proc { Duel::Rails::Request.new("GET #{path}").call }

  # Every view rendered: a collection's partials each count.
  def test_views
    Post.create!([{title: "a"}])
    one = measure(&sent("/posts")).fetch("rails_views")
    Post.create!([{title: "b"}, {title: "c"}])

    assert_equal one + 2, measure(&sent("/posts")).fetch("rails_views"), "two more posts, two more partials"
    assert_equal 1, measure(&sent("/plain")).fetch("rails_views"), "render plain: (a text template)"
    assert_equal 0, measure { nil }.fetch("rails_views")
  end

  # Keys read (a miss: one that wasn't there), and written.
  def test_the_cache
    measured = measure(&sent("/cached"))

    assert_equal [3, 3, 3], measured.values_at("rails_cache_reads", "rails_cache_misses", "rails_cache_writes"),
      "fetch: a miss and a write, then two keys missed, and two written"
    measured = measure(&sent("/cached"))

    assert_equal [3, 0, 2], measured.values_at("rails_cache_reads", "rails_cache_misses", "rails_cache_writes"),
      "all there: two keys written again"
  end

  # Where views were rendered, the most rendered, and how many times an
  # iteration, by their path in app/views.
  def test_details
    Post.create!([{title: "a"}, {title: "b"}])
    details = Duel::Testing.measure(@config, n: 2) { 2.times(&sent("/posts")) }.details.fetch("rails_views")

    assert_match(%r{\Aan iteration: 2× posts/_post\.html\.erb; 1× (layouts/application|posts/index)\.html\.erb; 1× }, details)
    assert_nil measure { nil }.details["rails_views"], "nothing, where none were"
  end

  # A sample's views over its stretches (around untimed blocks): those
  # rendered in an untimed block aren't counted.
  def test_details_over_stretches
    started = Duel::Snapshot::Reading.new({}, {"/app/views/a.erb" => 1, "/x/b.erb" => 5})
    paused = Duel::Snapshot::Reading.new({}, {"/app/views/a.erb" => 3, "/x/b.erb" => 5})
    resumed = Duel::Snapshot::Reading.new({}, {"/app/views/a.erb" => 9, "/x/b.erb" => 5})
    stopped = Duel::Snapshot::Reading.new({}, {"/app/views/a.erb" => 10, "/x/b.erb" => 5, nil => 4})
    @counter.instance_variable_set(:@root, "/app/views/")

    assert_equal({"rails_views" => "an iteration: 2× ; 1.5× a.erb"}, @counter.details([[started, paused], [resumed, stopped]], 2),
      "a view without a path (an inline one) too")
    assert_nil @counter.details([[started, started]], 1)
  end

  # The SHOWN rendered most and, of those rendered as often, by path (a
  # view without one first).
  def test_details_shows_the_most_rendered
    stopped = Duel::Snapshot::Reading.new({}, {"d" => 1, "b" => 1, nil => 1, "c" => 1, "a" => 1, "e" => 2})

    assert_equal({"rails_views" => "an iteration: 2× e; 1× ; 1× a"}, @counter.details([[Duel::Snapshot::Reading.new({}, {}), stopped]], 1))
  end

  # What a payload may leave out: a collection's count (nothing
  # rendered), whether a read hit (a miss), a view's path (an inline
  # one).
  def test_payloads_without
    @counter.finish("render_collection.action_view", "1", {identifier: "a"})
    @counter.finish("cache_read.active_support", "1", {key: "k"})
    @counter.finish("render_template.action_view", "1", {})

    assert_equal({"rails_views" => 1, "rails_cache_reads" => 1, "rails_cache_misses" => 1, "rails_cache_writes" => 0}, @counter.totals)
    assert_equal({"a" => 0, nil => 1}, @counter.views)
  end

  # A read that hit (one key, or some of several) isn't a miss, and a
  # write of several keys is a write of each.
  def test_hits
    @counter.finish("cache_read.active_support", "1", {key: "k", hit: true})
    @counter.finish("cache_read_multi.active_support", "1", {key: %w[a b c], hits: %w[a]})
    @counter.finish("cache_write_multi.active_support", "1", {key: {"a" => 1, "b" => 2}})

    assert_equal({"rails_views" => 0, "rails_cache_reads" => 4, "rails_cache_misses" => 2, "rails_cache_writes" => 2}, @counter.totals)
  end

  # Before it subscribes: nothing counted, nothing to stop, and views'
  # paths in full.
  def test_before_subscribing
    counter = Duel::Rails::Counter.new

    assert_equal({"rails_views" => 0, "rails_cache_reads" => 0, "rails_cache_misses" => 0, "rails_cache_writes" => 0}, counter.totals)
    assert_empty counter.views
    counter.unsubscribe
    stopped = Duel::Snapshot::Reading.new({}, {"/x/a.erb" => 1})

    assert_equal({"rails_views" => "an iteration: 1× /x/a.erb"}, counter.details([[Duel::Snapshot::Reading.new({}, {}), stopped]], 1))
  end

  # It counts from when the worker makes its metrics (opened, in the
  # booted app), and stops when the worker ends (closed: its own
  # subscriptions, no one else's).
  def test_subscribes_in_the_worker
    theirs = 0
    subscriber = ActiveSupport::Notifications.subscribe("render_template.action_view") { theirs += 1 }
    Duel::Testing.in_worker(@config) do
      before = @counter.totals.fetch("rails_views")
      sent("/posts").call

      assert_operator @counter.totals.fetch("rails_views"), :>, before
    end
    before = [@counter.totals, theirs]
    sent("/posts").call

    assert_equal before.first, @counter.totals, "unsubscribed"
    assert_operator theirs, :>, before.last, "another's subscription still there"
    assert_equal File.join(Rails.root.to_s, "app", "views", ""), @counter.instance_variable_get(:@root)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Reading the totals counts nothing: calibration finds it costs
  # nothing, and a sample's counts are what the block did.
  def test_reading_costs_nothing
    measured = measure { 3.times { @counter.finish("render_template.action_view", "1", {identifier: "a"}) } }

    assert_equal 3, measured.fetch("rails_views")
  end

  def test_measures
    assert_equal %w[rails_views rails_cache_reads rails_cache_misses rails_cache_writes], Duel::Rails::Counter::MEASURES.keys
    assert(Duel::Rails::Counter::MEASURES.values.all? { |s| s[:kind] == :counted && !s.key?(:calibrate) }, "calibrated, to nothing")
    assert_equal [%w[view views], %w[read reads], %w[miss misses], %w[write writes]], Duel::Rails::Counter::MEASURES.values.map { |s| s[:unit] }
    assert_kind_of Duel::Rails::Counter, @counter
  end
end
