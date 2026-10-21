# frozen_string_literal: true

require_relative "test_helper"

# Setting Duel up for an app, booting a version, and each worker's data.
class RailsTest < PluginTest
  cover "Duel::Rails.configure"
  cover "Duel::Rails.boot"
  cover "Duel::Rails.load_worker_data"
  cover "Duel::Rails.load_data"
  cover "Duel::Rails.reset_data"
  cover "Duel::Rails.seed_random"

  def config = Duel::Config.new(@dir)

  def measures(config) = config.metrics.flat_map { |m| m.measures.keys }

  # By default: the app's code is watched, each version boots in the
  # benchmark environment (its processes too), with a bundle and a SQLite
  # database of its own, the jobs its benchmarks enqueue are performed,
  # and its queries (duel-activerecord's), views and cache are counted.
  def test_use
    c = config

    assert_instance_of Duel::Rails::Counter, c.use(:rails)
    assert_equal %w[app config db lib Gemfile Gemfile.lock .ruby-version], c.watch
    booted = stub(Duel::Rails, :boot, ->(root, environment) { [root, environment] }) { c.load_into("/v1") }

    assert_equal ["/v1", "benchmark"], booted
    assert_equal 2, c.prepares.fetch(:version).size, "a bundle, and the environment"
    assert_equal({"RAILS_ENV" => "benchmark"}, c.prepares.fetch(:version).last.call(nil))
    assert_equal 1, c.prepares.fetch(:worker).size, "a database"
    assert_equal 2, c.in_workers.size, "data, then the jobs' queue"
    assert_equal [1, 1], [c.hooks.fetch(:before_sample).size, c.hooks.fetch(:after_iterations).size], "the jobs': none to reset"
    assert_equal [*Duel::ActiveRecord::MEASURES.keys, *Duel::Rails::Counter::MEASURES.keys], measures(c)
  end

  # The plugin, by name, and the one it uses for Active Record.
  def test_registered
    c = config
    c.use(:rails, bundle: false)

    assert_same Duel::Rails, Duel.plugins.fetch(:rails)
    assert_equal %i[rails activerecord], c.plugins
  end

  def test_use_with_options
    c = config
    c.use(:rails, database: nil, environment: "staging", bundle: false, jobs: false, active_record: false)
    booted = stub(Duel::Rails, :boot, ->(root, environment) { [root, environment] }) { c.load_into("/v1") }

    assert_equal ["/v1", "staging"], booted
    assert_equal [{"RAILS_ENV" => "staging"}], c.prepares.fetch(:version).map { |block| block.call(nil) }
    assert_empty c.prepares.fetch(:worker)
    assert_empty c.in_workers
    assert_empty c.hooks.fetch(:before_sample)
    assert_empty c.hooks.fetch(:after_iterations)
    assert_equal Duel::Rails::Counter::MEASURES.keys, measures(c)
    assert_equal [:rails], c.plugins
  end

  # query_time: for duel-activerecord, and the options it doesn't take
  # for the database's plugin.
  def test_use_with_options_for_other_plugins
    c = config
    c.use(:rails, bundle: false, query_time: true)

    assert_includes measures(c), "active_record_query_time"
    assert_equal 1, c.prepares.fetch(:worker).size
    configured = []
    stub(Duel::Rails::Database, :configure, ->(_config, database, **options) { configured << [database, options] }) do
      config.use(:rails, database: :postgresql, bundle: false, active_record: false, version: "16")
    end

    assert_equal [[:postgresql, {version: "16"}]], configured, "the rest, for the database's plugin"
  end

  # An app's own c.use :activerecord, before, with its options: duel-rails
  # uses it again, without any (or with query_time: true, if it was
  # given).
  def test_an_apps_own_active_record_options
    c = config
    counter = c.use(:activerecord, query_time: true)
    c.use(:rails, bundle: false)

    assert_includes measures(c), "active_record_query_time"
    assert_equal %i[activerecord rails], c.plugins
    c = config
    c.use(:activerecord, query_time: true)
    c.use(:rails, bundle: false, query_time: true)

    assert_equal 1, measures(c).count("active_record_query_time")
    assert_instance_of Duel::ActiveRecord::Counter, counter
  end

  # reset: true puts the data back before every sample: every
  # benchmark's.
  def test_use_reset
    c = config
    c.use(:rails, bundle: false, jobs: false, reset: true)
    reset = []
    stub(Duel::Rails, :reset_data, -> { reset << :reset }) { c.hooks.fetch(:before_sample).each(&:call) }

    assert_equal [:reset], reset
    error = assert_raises(ArgumentError) { config.use(:rails, database: nil, reset: true) }

    assert_equal "reset: needs a database to reset", error.message
  end

  # The data a worker gets: what it was used with, once Duel has loaded
  # the version (here, it's booted). By default, no fixtures, no seeds,
  # and random numbers seeded with SEED.
  def test_a_workers_data
    prepared = []
    [{fixtures: [:posts], seeds: true, seed: 7}, {}].each do |options|
      c = config
      c.use(:rails, bundle: false, active_record: false, **options)
      stub(Duel::Rails, :load_worker_data, ->(**given) { prepared << given }) { c.in_workers.first.call(Duel::Stops.new) }
    end

    assert_equal [{fixtures: [:posts], seeds: true, seed: 7}, {fixtures: [], seeds: false, seed: 42}], prepared
  end

  # Boots the version from its own directory, in the environment given.
  def test_boot
    required = []
    here = Dir.pwd
    stub(Duel::Rails, :require, ->(path) { required << [path, Dir.pwd, ENV.fetch("RAILS_ENV")] }) do
      Duel::Rails.boot(@dir, "staging")
    end

    assert_equal [[File.join(@dir, "config", "environment"), File.realpath(@dir), "staging"]],
      required.map { |path, dir, env| [path, File.realpath(dir), env] }
  ensure
    Dir.chdir(here)
    ENV["RAILS_ENV"] = "benchmark"
  end

  # The schema, then fixtures, then seeds, with random numbers seeded.
  def test_load_worker_data
    ActiveRecord::Base.connection.drop_table(:posts)
    Duel::Rails.load_worker_data(fixtures: [:posts], seeds: true, seed: 7)
    seeded = Post.order(:id).pluck(:title)
    srand(7)

    assert_equal ["First", "Second", "seeded #{rand(1000)}"].sort, seeded.sort
    Post.delete_all
    Duel::Rails.load_worker_data(fixtures: [], seeds: false, seed: 7)

    assert_equal 0, Post.count
  end

  # The data again, as it was loaded: what was written since is gone,
  # from tables the fixtures don't load too.
  def test_reset_data
    config.use(:rails, bundle: false, fixtures: [:posts], seeds: true, seed: 7)
    Post.create!(title: "written")
    Duel::Rails.reset_data
    srand(7)

    assert_equal ["First", "Second", "seeded #{rand(1000)}"].sort, Post.pluck(:title).sort
    config.use(:rails, bundle: false, seeds: true, seed: 7)
    Post.create!(title: "written")
    Duel::Rails.reset_data
    srand(7)

    assert_equal ["seeded #{rand(1000)}"], Post.pluck(:title), "emptied, then seeded"
    config.use(:rails, database: nil)
    error = assert_raises(Duel::Error) { Duel::Rails.reset_data }

    assert_equal "reset_data: c.use :rails gave the app no database to reset", error.message
  end

  def test_seed_random
    Duel::Rails.seed_random(3)
    first = Array.new(3) { rand }
    Duel::Rails.seed_random(3)

    assert_equal first, Array.new(3) { rand }
    faker = Module.new
    config = Module.new { class << self; attr_accessor :random; end }
    faker.const_set(:Config, config)
    Object.const_set(:Faker, faker)
    Duel::Rails.seed_random(3)

    assert_kind_of Random, config.random, "a generator of Faker's own"
    assert_equal Random.new(3).rand, config.random.rand, "Faker's too"
  ensure
    Object.send(:remove_const, :Faker) if defined?(Faker)
  end
end
