# frozen_string_literal: true

require_relative "test_helper"

# Each worker's own database, and its version's schema and fixtures.
class DatabaseTest < PluginTest
  cover "Duel::Rails::Database*"

  def config = Duel::Config.new(@dir)

  def resource = Duel::Resource.new(@dir, "candidate-1", @dir, timeout: 1.0, cache: File.join(@dir, "cache"))

  def test_sqlite_a_file_of_the_workers_own
    c = config
    Duel::Rails::Database.configure(c, :sqlite)

    assert_equal [{"DATABASE_URL" => "sqlite3:#{File.join(@dir, "db.sqlite3")}"}], c.prepares.fetch(:worker).map { |block| block.call(resource) }
    assert_empty c.plugins
  end

  # A server, from its plugin (used with the URL's scheme, where it isn't
  # the plugin's own, and the options given).
  def test_a_server_from_its_plugin
    {postgresql: [:postgresql, {}, {}], mysql2: [:mysql, {}, {}],
     trilogy: [:mysql, {args: ["--x"]}, {scheme: "trilogy", args: ["--x"]}]}.each do |database, (plugin, options, used)|
      c = config
      given = []
      c.define_singleton_method(:use) { |name, **opts| (given << [name, opts]) && :used }

      assert_equal :used, Duel::Rails::Database.configure(c, database, **options)
      assert_equal [[plugin, used]], given, database
    end
  end

  def test_a_database_there_isnt
    error = assert_raises(ArgumentError) { Duel::Rails::Database.configure(config, :oracle) }

    assert_equal "database: must be :sqlite, :postgresql, :mysql2 or :trilogy, not :oracle", error.message
  end

  # Its plugin, not in the app's bundle (as duel-mysql isn't in the
  # tests'), fails, saying which gem to add.
  def test_a_plugin_not_in_the_bundle
    error = assert_raises(Duel::Error) { Duel::Rails::Database.configure(config, :mysql2) }

    assert_equal "c.use :mysql: no duel/mysql to require: add the duel-mysql gem to the Gemfile", error.message
  end

  def test_load_schema
    ActiveRecord::Base.connection.drop_table(:posts)
    ActiveRecord::Schema.verbose = true
    out = capture_io { Duel::Rails::Database.load_schema }.first

    assert_includes ActiveRecord::Base.connection.tables, "posts"
    assert_empty out, "quietly"
  end

  # Every table emptied, but Active Record's own.
  def test_clear
    Post.create!(title: "a")
    Duel::Rails::Database.clear

    assert_equal 0, Post.count
    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM schema_migrations"), "the schema's version"
  end

  def test_load_fixtures
    Duel::Rails::Database.load_fixtures([])

    assert_equal 0, Post.count
    Duel::Rails::Database.load_fixtures([:posts])

    assert_equal %w[First Second], Post.order(:title).pluck(:title)
    Post.delete_all
    Duel::Rails::Database.load_fixtures(:all)

    assert_equal 2, Post.count, "every one"
    other = File.join(@dir, "fixtures")
    FileUtils.mkdir_p(File.join(other, "posts"))
    File.write(File.join(other, "posts.yml"), "only:\n  title: Only\n")
    File.write(File.join(other, "posts", "ignored.txt"), "")
    Post.delete_all
    Duel::Rails::Database.load_fixtures(:all, path: other)

    assert_equal %w[Only], Post.pluck(:title)
  end

  # Every one, by name, in order: nothing (not even a reset) for none, or
  # without test/fixtures.
  def test_load_fixtures_by_name
    FileUtils.mkdir_p(File.join(@dir, "a"))
    %w[z.yml a.yml a/b.yml].each { |file| File.write(File.join(@dir, file), "") }
    loaded = []
    stub(ActiveRecord::FixtureSet, :reset_cache, -> { loaded << :reset }) do
      stub(ActiveRecord::FixtureSet, :create_fixtures, ->(path, names) { loaded << [path, names] }) do
        Duel::Rails::Database.load_fixtures(:all, path: @dir)
        Duel::Rails::Database.load_fixtures([])
        Duel::Rails::Database.load_fixtures(:all, path: File.join(@dir, "none"))
      end
    end

    assert_equal [:reset, [@dir, %w[a a/b z]]], loaded
  end
end
