# frozen_string_literal: true

require "json"

module Duel
  module Rails
    # A request a benchmark sends the app, through its whole Rack stack
    # (middleware, routing, the controller, its views), without a
    # server; made from a description like "GET /posts".
    class Request
      METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

      # The statuses a request is expected to answer with, unless told:
      # one that fails (a 404, or a 500) is benchmarking an error page.
      OK = (200..399)

      attr_reader :verb, :path

      # +request+: the method and the path ("GET /posts?page=2").
      # +params+: form parameters (in the query, for a GET), or +json+: a
      # body, sent as JSON. +headers+: by name ("Accept"). +status+: what
      # the response's must be (an Integer, or a Range of them).
      # +rollback+: whether what the request writes to the database is
      # rolled back after it (see #around_iteration), so every request
      # finds the same data.
      def initialize(request, params: nil, json: nil, headers: {}, status: OK, rollback: true)
        verb, path = request.split(" ", 2)
        unless METHODS.include?(verb) && path&.start_with?("/")
          raise ArgumentError, "a request is a method and a path (\"GET /posts\"), not #{request.inspect}"
        end
        @verb = verb #: String
        @path = path #: String
        raise ArgumentError, "#{request}: params: or json:, not both" if params && json

        @options = {method: @verb, params: params}
        if json
          @options[:input] = JSON.generate(json)
          @options["CONTENT_TYPE"] = "application/json"
        end
        headers.each { |name, value| @options[header(name)] = value }
        @status = status
        @rollback = rollback
      end

      # A fresh Rack environment for the request (the app may change the
      # one it's given).
      def env = Rack::MockRequest.env_for(@path, @options)

      # Sends the request (+rack_env+); fails unless the response's status
      # is as expected. Returns the status.
      def call(rack_env = env)
        status = respond(rack_env)
        raise Error, "#{@verb} #{@path}: status #{status}, not #{@status}" unless @status === status

        status
      end

      # Its benchmark's own hooks (Duel::DSL#duel's options): ROLLBACK
      # around each iteration (only the request is measured: pinning the
      # connection, and rolling back, aren't), unless it isn't rolled back.
      def hooks = @rollback ? {around_iteration: ROLLBACK} : {}

      # Defines a benchmark (on +dsl+, a file of benchmarks' main object) of
      # the request: see DSL#duel_request. +hooks+ are its own (as
      # Duel::DSL#duel takes them): an around_iteration one, only for a request not
      # rolled back (it would replace the rollback).
      def self.duel(dsl, name, request, only: nil, peak_memory: false, **options, &prepare)
        hooks = options.slice(*HOOKS)
        sent = new(request, **options.except(*HOOKS))
        if sent.hooks.key?(:around_iteration) && hooks.key?(:around_iteration)
          raise ArgumentError, "duel_request #{name.inspect}: around_iteration: would replace its rollback: give rollback: false too, " \
            "or give the hook to the file (around_iteration { |iteration| ... })"
        end

        dsl.duel(name, only:, peak_memory:, **sent.hooks, **hooks) do
          env = sent.env
          instance_exec(env, &prepare) if prepare
          sent.call(env)
        end
      end

      private

      # The app's response's status, its body read through and closed (as
      # a server's is: a streamed body does its work as it's read).
      def respond(env)
        response = ::Rails.application.call(env) #: [Integer, untyped, untyped]
        status, _headers, body = response
        begin
          body.each do |_|
            # (Read, and let go.)
          end
        ensure
          body.close if body.respond_to?(:close)
        end
        status
      end

      # A header's name in a Rack environment: CONTENT_TYPE, HTTP_ACCEPT.
      def header(name)
        key = name.to_s.upcase.tr("-", "_")
        %w[CONTENT_TYPE CONTENT_LENGTH].include?(key) ? key : "HTTP_#{key}"
      end
    end

    # What files of benchmarks get, as .duel.rb uses the plugin (see
    # Duel.plugin).
    module DSL
      # Defines a benchmark of a request to the app (see Request):
      #
      #   duel_request "posts: index", "GET /posts"
      #   duel_request "posts: create", "POST /posts", params: {post: {title: "Hi"}}
      #   duel_request "api: search", "POST /api/search", json: {q: "duel"}, headers: {"Accept" => "application/json"}
      #
      # Each iteration sends the request once, through the whole Rack
      # stack, and (unless rollback: false) what it wrote is rolled back
      # after it, unmeasured (see Rails::ROLLBACK). With a block, the block
      # is given the request's Rack environment first, in the benchmark's
      # context (to sign in, say, from an instance variable a setup hook
      # set). +only+, +peak_memory+ and the hooks (setup:, say) are
      # #duel's.
      def duel_request(name, request = name, **options, &prepare) = Request.duel(self, name, request, **options, &prepare)
    end
  end
end
