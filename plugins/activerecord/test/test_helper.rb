# frozen_string_literal: true

# SimpleCov's strict profile: line, branch and method coverage, each held
# to 100% (COVERAGE=false to run some of the tests; mutant runs its own).
if ENV["COVERAGE"] != "false" && RUBY_ENGINE == "ruby" && !defined?(Mutant)
  require "simplecov"
  SimpleCov.start("strict") do
    root File.expand_path("..", __dir__)
    skip %r{\A/?test/}
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/activerecord"
require "duel/testing"
require "active_record"
# Mutant runs the tests itself (and autorun, at exit, would run them all
# again in every one of its processes).
require defined?(Mutant) ? "minitest" : "minitest/autorun"
require "minitest/strict"

# Where the tests' files go: each test's directory, and each process's
# database (each of mutant's has its own: they'd lock one another out of
# a shared one). The process that made it removes it when the tests are
# done (under mutant, a test may be killed before its teardown, and
# minitest's hooks don't run). (Before mutant's coverage declarations,
# which define Mutant themselves.)
module TestFiles
  ROOT = Dir.mktmpdir("dar", "/tmp")
  OWNER = Process.pid
  cleanup = -> { FileUtils.rm_rf(ROOT) if Process.pid == OWNER }
  defined?(Mutant) ? at_exit(&cleanup) : Minitest.after_run(&cleanup)

  # Connects this process to its database, made the first time (each
  # thread has a connection of its own).
  def self.connect_database
    return if @connected == Process.pid

    @connected = Process.pid
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(ROOT, "test-#{Process.pid}.sqlite3"))
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:posts) { |t| t.string :title }
      create_table(:comments) { |t| t.references :post }
    end
  end
end

begin
  # `cover "Duel::ActiveRecord*"` tells mutant which tests exercise which
  # code.
  require "mutant/minitest/coverage"
rescue LoadError
  # mutant is CRuby's; elsewhere coverage declarations do nothing.
  module Minitest
    class Test
      def self.cover(_expression) = nil
    end
  end
end

class Post < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class PluginTest < Minitest::Test
  def setup
    TestFiles.connect_database
    @dir = Dir.mktmpdir("test", TestFiles::ROOT)
    @counters = []
    Post.create!(title: "first").comments.create!([{}, {}])
  end

  def teardown
    @counters.each(&:unsubscribe)
    Comment.delete_all
    Post.delete_all
    FileUtils.rm_rf(@dir) if @dir
  end

  # The plugin used, with +options+, and its Counter (unsubscribed after
  # the test).
  def use(**options)
    config = Duel::Config.new(@dir)
    @counters << config.use(:activerecord, **options)
    [config, @counters.last]
  end

  # What the block did, as the metrics measure a sample of +n+ iterations
  # (in a worker). The block gets the benchmark's context (#untimed).
  def measure(config, n: 1, &) = Duel::Testing.measure(config, n:, &)

  # A project of one benchmark, which counts every post's comments,
  # loading them all at once (or, +n_plus_one+, each post's on its own),
  # with .duel.rb using the plugin.
  def project(name, n_plus_one: false)
    Duel::Testing.project(File.join(@dir, name),
      "lib/blog.rb" => <<~RUBY,
        require "active_record"

        class Post < ActiveRecord::Base
          has_many :comments
        end

        class Comment < ActiveRecord::Base
          belongs_to :post
        end

        module Blog
          def self.comment_counts = Post.#{n_plus_one ? "all" : "includes(:comments)"}.map { |post| post.comments.size }
        end
      RUBY
      "duel/duel_helper.rb" => <<~RUBY,
        require "blog"

        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        ActiveRecord::Schema.verbose = false
        ActiveRecord::Schema.define do
          create_table(:posts) { |t| t.string :title }
          create_table(:comments) { |t| t.references :post }
        end
        5.times { |i| Post.create!(title: "post \#{i}").comments.create!([{}, {}]) }
      RUBY
      "duel/blog_duel.rb" => <<~RUBY,
        require_relative "duel_helper"

        duel("blog: comment counts") { Blog.comment_counts }
      RUBY
      ".duel.rb" => <<~RUBY)
        Duel.configure do |c|
          c.load { |root| $LOAD_PATH.unshift(File.join(root, "lib")) }
          c.use :activerecord
        end
      RUBY
  end
end
