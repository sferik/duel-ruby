# frozen_string_literal: true

require_relative "test_helper"

# Whole comparisons of two versions of the tests' app, in worker processes
# that boot it, each with a database of its own: the same app passes, and
# one that queries more and renders more fails.
#
# (Too slow for mutation testing: the code they run is covered there by
# faster tests.)
class EndToEndTest < PluginTest
  # A copy of the tests' app, set up for Duel, at +dir+; with +changes+
  # (path => content) on top.
  def app(dir, changes = {})
    FileUtils.cp_r(TestApp::ROOT, dir)
    files = {
      ".duel.rb" => <<~RUBY,
        Duel.configure { |c| c.use :rails, bundle: false, fixtures: :all }
      RUBY
      "duel/requests_duel.rb" => %(duel_request "posts: index", "GET /posts"\n)
    }
    files.merge(changes).each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), content)
    end
    dir
  end

  def compare(base, candidate) = Duel::Testing.compare(base, candidate, timeout: 120.0)

  # Every benchmark of the same app passes. A request finds the data as
  # it was (what the last one wrote, rolled back), the file's setup
  # reaches a request's block, and a job a request enqueues is performed
  # and measured with it. A plain benchmark is rolled back too, by a
  # file's around_iteration hook (Rails::ROLLBACK).
  def test_the_same_app_passes
    requests = <<~RUBY
      setup { @title = "from setup" }

      duel_request "posts: index", "GET /posts"

      duel_request "posts: create, from setup", "POST /posts" do |env|
        raise "the file's setup didn't reach the request" unless @title

        env["QUERY_STRING"] = "post[title]=\#{@title}"
      end

      duel_request "posts: later", "POST /later", params: {title: "queued"}
    RUBY
    models = <<~RUBY
      around_iteration(&Duel::Rails::ROLLBACK)

      duel("posts: create a model") { Post.create!(title: "Hi") && Post.all.to_a }
    RUBY
    changes = {"duel/requests_duel.rb" => requests, "duel/models_duel.rb" => models}
    comparison = compare(app(File.join(@dir, "base"), changes), app(File.join(@dir, "candidate"), changes))
    names = ["posts: create a model", "posts: index", "posts: create, from setup", "posts: later"]
    model, index, created, later = names.map { |name| comparison[name] }
    per = ->(result, name) { result.counted.fetch(name).fetch("candidate") / result.n }

    assert_predicate comparison, :passed?, comparison.output
    assert_equal names, [model, index, created, later].map(&:name)
    assert_equal 3, per.call(model, "active_record_instantiations"), "the fixtures' two posts, and the one it made, every time"
    assert_equal 2, per.call(index, "active_record_instantiations"), "the fixtures' two posts, every time"
    assert_operator index.counted.fetch("rails_views").fetch("candidate"), :>=, 2 * index.n
    assert_equal 1, per.call(created, "active_record_queries"), "the insert (not pinning, or rolling back)"
    assert_equal 1, per.call(later, "active_record_queries"), "the job's insert"
  end

  def test_more_queries_and_views_fail
    slower = {
      "app/controllers/posts_controller.rb" => File.read(File.join(TestApp::ROOT, "app/controllers/posts_controller.rb"))
        .sub("def index = @posts = Post.order(:id).to_a", "def index = (@posts = Post.order(:id).to_a) && Post.count"),
      "app/views/posts/index.html.erb" => <<~ERB
        <h1>Posts</h1>
        <% 2.times do %><%= render partial: "posts/post", collection: @posts %><% end %>
      ERB
    }
    comparison = compare(app(File.join(@dir, "base")), app(File.join(@dir, "candidate"), slower))
    result = comparison["posts: index"]

    refute_predicate comparison, :passed?
    assert_equal %w[active_record_queries rails_views], (result.regressed & %w[active_record_queries rails_views]).sort, comparison.output
    assert_match(/rails_views \(candidate\): an iteration: 4× posts\/_post\.html\.erb/, comparison.output)
  end

  # A metric that's costly to read (Metric.costly?) isn't paused around
  # each request, but what rolling it back adds (pinning the connection,
  # and its BEGIN and ROLLBACK) is learned in each worker and taken away:
  # it counts what the same metric paused around each request does, every
  # statement a request sent, its own transaction's (savepoints, here)
  # too.
  def test_a_costly_metric_counts_only_the_request
    duel = <<~RUBY
      Duel.configure do |c|
        c.use :rails, bundle: false, fixtures: :all
        statements = 0
        counted = ->(*, payload) { statements += 1 unless payload[:name] == "SCHEMA" }
        c.in_worker { ActiveSupport::Notifications.subscribe("sql.active_record", &counted) }
        c.metric("sql_statements") { statements }.costly
        c.metric("sql_statements_paused") { statements }
      end
    RUBY
    requests = <<~RUBY
      duel_request "posts: index", "GET /posts"
      duel_request "posts: create", "POST /posts", params: {post: {title: "Hi"}}
    RUBY
    changes = {".duel.rb" => duel, "duel/requests_duel.rb" => requests}
    comparison = compare(app(File.join(@dir, "base"), changes), app(File.join(@dir, "candidate"), changes))
    per = lambda do |name|
      result = comparison[name]
      %w[sql_statements sql_statements_paused].map { |metric| result.counted.fetch(metric).fetch("candidate").fdiv(result.n) }
    end

    assert_predicate comparison, :passed?, comparison.output
    assert_equal [1.0, 1.0], per.call("posts: index"), "the select"
    assert_equal [3.0, 3.0], per.call("posts: create"), "a savepoint, the insert, and its release"
  end
end
