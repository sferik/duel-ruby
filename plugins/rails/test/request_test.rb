# frozen_string_literal: true

require_relative "test_helper"

# Requests a benchmark sends the app, through its whole Rack stack.
class RequestTest < PluginTest
  cover "Duel::Rails::Request*"
  cover "Duel::Rails.rolled_back"
  cover "Duel::Rails::DSL#duel_request"

  def request(...) = Duel::Rails::Request.new(...)

  # The DSL, as a file of benchmarks has it once .duel.rb uses the
  # plugin.
  def dsl
    Duel::Config.new(@dir).use(:rails, bundle: false)
    Object.new.extend(Duel::DSL)
  end

  def test_a_get
    sent = request("GET /plain?say=hi")

    assert_equal ["GET", "/plain?say=hi"], [sent.verb, sent.path]
    assert_equal 200, sent.call
    env = sent.env

    assert_equal ["GET", "/plain", "say=hi"], env.values_at("REQUEST_METHOD", "PATH_INFO", "QUERY_STRING")
    refute_same env, sent.env, "a fresh one each time"
  end

  # Form parameters (a GET's in its query), or a body of JSON, and
  # headers by name.
  def test_what_it_sends
    env = request("GET /plain", params: {say: "hi"}).env

    assert_equal "say=hi", env.fetch("QUERY_STRING")
    env = request("POST /posts", params: {post: {title: "Hi"}}).env

    assert_equal ["POST", "post%5Btitle%5D=Hi"], [env.fetch("REQUEST_METHOD"), env.fetch("rack.input").read]
    env = request("POST /posts", json: {post: {title: "Hi"}}).env

    assert_equal ["application/json", %({"post":{"title":"Hi"}})], [env.fetch("CONTENT_TYPE"), env.fetch("rack.input").read]
    env = request("GET /plain", headers: {"Accept" => "text/plain", "X-Request-Id" => "7", "Content-Length" => "0"}).env

    assert_equal ["text/plain", "7", "0"], env.values_at("HTTP_ACCEPT", "HTTP_X_REQUEST_ID", "CONTENT_LENGTH")
    assert_equal "1", request("GET /plain", headers: {content_type: "1"}).env.fetch("CONTENT_TYPE"), "any name"
  end

  # What a request writes is rolled back after each iteration, by its
  # benchmark's around_iteration hook (Rails::ROLLBACK, unless asked not
  # to): every request finds the same data.
  def test_rolled_back
    sent = request("POST /posts", params: {post: {title: "Hi"}})

    assert_equal({around_iteration: Duel::Rails::ROLLBACK}, sent.hooks)
    assert_equal 302, Duel::Rails::ROLLBACK.call(-> { sent.call }), "what the iteration returns"
    assert_equal 0, Post.count
    kept = request("POST /posts", params: {post: {title: "Hi"}}, rollback: false)

    assert_empty kept.hooks
    kept.call

    assert_equal ["Hi"], Post.pluck(:title)
    request("POST /posts", params: {post: {title: "Again"}}).call

    assert_equal 2, Post.count, "only around it"
  end

  # Each pool Active Record writes through is pinned to the thread (as
  # transactional tests do).
  def test_rolled_back_pins_the_writing_pools
    handler = ActiveRecord::Base.connection_handler
    pool = ActiveRecord::Base.connection_pool
    list = handler.method(:connection_pool_list)
    pin = pool.method(:pin_connection!)
    asked = []
    stub(handler, :connection_pool_list, ->(*role) { (asked << role) && list.call(*role) }) do
      stub(pool, :pin_connection!, ->(lock_thread) { (asked << lock_thread) && pin.call(lock_thread) }) do
        Duel::Rails.rolled_back { nil }
      end
    end

    assert_equal [[:writing], true], asked
  end

  def test_rolled_back_runs_the_block_and_returns_what_it_does
    assert_equal :ran, Duel::Rails.rolled_back { :ran }
    assert_raises(ZeroDivisionError) { Duel::Rails.rolled_back { 1 / 0 } }
    assert_equal 0, ActiveRecord::Base.connection.open_transactions, "nothing left open, however it ends"
  end

  # Without Active Record, there's nothing to roll back.
  def test_rolled_back_without_active_record
    saved = Object.send(:remove_const, :ActiveRecord)

    assert_equal :ran, Duel::Rails.rolled_back { :ran }
  ensure
    Object.const_set(:ActiveRecord, saved)
  end

  # A response whose status isn't as expected fails: by default, a 2xx or
  # a 3xx.
  def test_the_status
    error = assert_raises(Duel::Error) { request("GET /boom").call }

    assert_equal "GET /boom: status 500, not 200..399", error.message
    assert_raises(Duel::Error) { request("GET /nowhere").call }
    assert_equal 500, request("GET /boom", status: 500).call
    assert_equal 404, request("GET /nowhere", status: 400..499).call
  end

  # The response's body is read through, and closed.
  def test_the_body
    read = []
    body = Object.new
    body.define_singleton_method(:each) { |&block| %w[a b].each { |part| block.call(read << part) } }
    body.define_singleton_method(:close) { read << :close }
    stub(Rails.application, :call, ->(_env) { [200, {}, body] }) { request("GET /plain").call }

    assert_equal ["a", "b", :close], read
    stub(Rails.application, :call, ->(_env) { [200, {}, []] }) { assert_equal 200, request("GET /plain").call }
  end

  # The method, then the path: everything after the spaces after it
  # (split as awk does, whatever $; is).
  def test_the_method_and_the_path
    assert_equal ["GET", "/a b"], [request("GET  /a b").verb, request("GET  /a b").path]
    deprecated = Warning[:deprecated]
    Warning[:deprecated] = false
    $; = "/"

    assert_equal "/posts", request("GET /posts").path
  ensure
    $; = nil
    Warning[:deprecated] = deprecated
  end

  def test_requests_there_arent
    ["GET", "FETCH /posts", "GET posts", "", "get /posts"].each do |bad|
      error = assert_raises(ArgumentError) { request(bad) }

      assert_equal "a request is a method and a path (\"GET /posts\"), not #{bad.inspect}", error.message
    end
    error = assert_raises(ArgumentError) { request("POST /posts", params: {a: 1}, json: {a: 1}) }

    assert_equal "POST /posts: params: or json:, not both", error.message
    assert_equal Duel::Rails::Request::METHODS.size, Duel::Rails::Request::METHODS.count { |m| request("#{m} /x").verb == m }
  end

  # duel_request defines a benchmark of the request (#duel's options
  # too), rolled back around each iteration. Its block is given the
  # request's environment first, in the benchmark's context.
  def test_duel_request
    dsl = self.dsl
    dsl.duel_request("posts: index", "GET /posts")
    dsl.duel_request("GET /plain", only: :count, peak_memory: true, rollback: false)
    dsl.duel_request("hello", "GET /plain", params: {say: "x"}) { |env| env["QUERY_STRING"] = "say=#{@say}" }
    dsl.duel_request("boom", "GET /boom", status: 500)
    index, plain, hello, boom = Duel.benchmarks.values

    assert_equal 500, Object.new.instance_exec(&boom.body), "the request's options"
    assert_equal [["posts: index", nil, false], ["GET /plain", :count, true], ["hello", nil, false], ["boom", nil, false]],
      Duel.benchmarks.values.map { |b| [b.name, b.only, b.peak_memory] }
    assert_equal [{around_iteration: Duel::Rails::ROLLBACK}, {}], [index.hooks, plain.hooks]
    assert_equal 200, Object.new.instance_exec(&index.body)
    assert_equal 200, Object.new.instance_exec(&plain.body)
    context = Object.new.tap { |o| o.instance_variable_set(:@say, "context") }
    said = []
    stub(Rails.application, :call, ->(env) { (said << env["QUERY_STRING"]) && [200, {}, []] }) { context.instance_exec(&hello.body) }

    assert_equal ["say=context"], said
    assert_raises(ArgumentError) { dsl.duel_request("bad", "nope") }
  end

  # duel_request takes #duel's hooks: an around_iteration one only for a
  # request not rolled back, which it would replace.
  def test_duel_request_with_hooks
    dsl = self.dsl
    setup = -> { @ready = true }
    around = ->(iteration) { iteration.call }
    dsl.duel_request("ready", "GET /plain", setup: setup)
    dsl.duel_request("around", "GET /plain", rollback: false, around_iteration: around)

    assert_equal [{around_iteration: Duel::Rails::ROLLBACK, setup: setup}, {around_iteration: around}], Duel.benchmarks.values.map(&:hooks)
    error = assert_raises(ArgumentError) { dsl.duel_request("both", "GET /plain", around_iteration: around) }

    assert_equal 'duel_request "both": around_iteration: would replace its rollback: give rollback: false too, ' \
      "or give the hook to the file (around_iteration { |iteration| ... })", error.message
    refute Duel.benchmarks.key?("both")
  end

  # Its benchmarks belong to the file that called duel_request, not this
  # gem's: they get that file's hooks.
  def test_duel_request_belongs_to_its_file
    dsl.duel_request("posts: index", "GET /posts")

    assert_equal __FILE__, Duel.benchmarks.fetch("posts: index").file
  end
end
