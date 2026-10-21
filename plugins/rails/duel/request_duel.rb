# frozen_string_literal: true

require "rack"

# Each iteration of a request benchmark builds the request's Rack
# environment afresh, in the benchmark's timed code.
duel "request: a GET's environment" do
  once { @request = Duel::Rails::Request.new("GET /posts?page=2", headers: {"Accept" => "text/html"}) }
  @request.env
end

duel "request: a POST's environment, with JSON" do
  once { @request = Duel::Rails::Request.new("POST /api/posts", json: {post: {title: "Hi", tags: %w[a b]}}) }
  @request.env
end
