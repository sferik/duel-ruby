# frozen_string_literal: true

require "duel"
require_relative "activerecord/version"

module Duel
  # What Active Record did for each benchmark, from its notifications,
  # whatever the database:
  #
  # - active_record_queries: the queries it sent the database (counted),
  #   but schema queries, transactions' own statements (BEGIN, COMMIT...)
  #   and those the query cache answered
  # - active_record_cached_queries: the queries the query cache answered
  #   (counted)
  # - active_record_transactions: the transactions, and savepoints, it
  #   opened (counted)
  # - active_record_instantiations: the records it instantiated (counted)
  # - active_record_query_time, when asked for: how long the queries
  #   took, in elapsed time (a ratio metric, in nanoseconds, like CPU
  #   time)
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :activerecord }
  #
  # It subscribes to the notifications in workers only, as its metric is
  # opened, once the benchmarks have loaded (so the runner never loads
  # Active Support for it), and unsubscribes when the worker ends. Where the queries
  # regressed, it says which statements a sample sent most, on each
  # version (Counter#details).
  module ActiveRecord
    Duel.plugin(:activerecord, self)

    # Counts. Reading them queries nothing, so there's nothing to take
    # away.
    MEASURES = {
      "active_record_queries" => {kind: :counted, unit: %w[query queries], calibrate: false},
      "active_record_cached_queries" => {kind: :counted, unit: %w[query queries], calibrate: false},
      "active_record_transactions" => {kind: :counted, unit: %w[transaction transactions], calibrate: false},
      "active_record_instantiations" => {kind: :counted, unit: %w[record records], calibrate: false}
    }

    # Elapsed time, measured when asked for (see the README).
    QUERY_TIME = {"active_record_query_time" => {kind: :ratio, unit: "ns", floor: 300_000, limit: 1.05}}

    # Configures Duel for the plugin (c.use :activerecord): its metrics,
    # and +query_time+ too if true. +ignore+, if given, is called with
    # each query's notification payload, and a query it's true for isn't
    # counted, nor timed. Returns the Counter.
    def self.configure(config, query_time: false, ignore: nil)
      counter = Counter.new(query_time:, ignore:)
      measures = query_time ? MEASURES.merge(QUERY_TIME) : MEASURES
      config.metric(measures) { counter.totals }
        .open { counter.subscribe(measures.keys.reject { |name| config.skip?(name) }) }
        .close { counter.unsubscribe }
        .details { |stretches, sample| counter.details(stretches, sample.n) }
      counter
    end

    # Running totals, from the notifications it subscribes to. One object
    # (Active Support calls its #start and #finish, the cheapest kind of
    # subscriber) for every event.
    class Counter
      SQL = "sql.active_record"
      TRANSACTION = "transaction.active_record"
      INSTANTIATION = "instantiation.active_record"

      # The events each measure needs.
      EVENTS = {
        "active_record_queries" => SQL, "active_record_cached_queries" => SQL, "active_record_query_time" => SQL,
        "active_record_transactions" => TRANSACTION, "active_record_instantiations" => INSTANTIATION
      }.freeze

      # Where a query's start is kept until it finishes (queries in
      # several threads or fibers at once each have their own).
      STARTED = :duel_activerecord_started

      # The queries counted last that it keeps track of (which statement
      # each was), for #details.
      KEPT = 1000

      # The most statements whose SQL it keeps between two #details
      # (the first sent: the rest are told as others).
      STATEMENTS = 8

      # The most statements shown, and the most shown of each one's SQL.
      SHOWN = 3
      LENGTH = 100

      def initialize(query_time:, ignore:)
        @query_time = query_time
        @ignore = ignore
        @queries = @cached = @transactions = @instantiations = @time = 0
        @subscriptions = [] #: Array[untyped]
        # Each query's SQL's hash, round (the first KEPT make it).
        @recent = [] #: Array[Integer]
        @sql = {} #: Hash[Integer, String]
      end

      # Subscribes to the events +measures+ need (see EVENTS).
      def subscribe(measures)
        @timing = measures.include?("active_record_query_time")
        @subscriptions = measures.map { |measure| EVENTS.fetch(measure) }.uniq.map do |event|
          notifications.subscribe(event, self)
        end
      end

      # The totals so far, by name.
      def totals
        totals = {"active_record_queries" => @queries, "active_record_cached_queries" => @cached,
                  "active_record_transactions" => @transactions, "active_record_instantiations" => @instantiations}
        @query_time ? totals.merge("active_record_query_time" => @time) : totals
      end

      # What explains the queries a sample sent, in its stretches (pairs
      # of readings of the totals: see Snapshot#details) of +n+
      # iterations: the statements sent most (of the last KEPT), and how
      # many times an iteration, the SHOWN most and others: "an
      # iteration: 3× SELECT ...; 1× others". Nothing where none were. It
      # forgets their SQL.
      def details(stretches, n)
        oldest = @queries - KEPT
        keys = stretches.flat_map do |started, stopped|
          ([queries(started), oldest].max...queries(stopped)).map { |i| @recent.fetch(i % KEPT) }
        end
        return if keys.empty?

        sent = keys.tally.filter_map { |key, count| [count, @sql.fetch(key)] if @sql.key?(key) } #: Array[[Integer, String]]
        shown = sent.sort_by { |count, sql| [-count, sql] }.first(SHOWN)
        others = keys.size - shown.sum { |count, _| count }
        shown << [others, "others"] if others.positive?
        {"active_record_queries" => "an iteration: #{shown.map { |count, sql| "#{format("%.4g", count.fdiv(n))}× #{shorten(sql)}" }.join("; ")}"}
      ensure
        @sql.clear
      end

      # Stops counting.
      def unsubscribe = @subscriptions.each { |subscription| notifications.unsubscribe(subscription) }

      # (Active Support's, for every event subscribed to.)
      def start(name, _id, _payload)
        (Thread.current[STARTED] ||= []) << monotonic if @timing && name == SQL
      end

      def finish(name, _id, payload)
        case name
        when SQL then query(payload)
        when TRANSACTION then @transactions += 1
        else @instantiations += payload.fetch(:record_count)
        end
      end

      private

      def query(payload)
        took = monotonic - Thread.current.fetch(STARTED).pop if @timing
        name = payload[:name]
        return if name == "SCHEMA" || @ignore&.call(payload)

        @time += took if took
        return if name == "TRANSACTION"
        return @cached += 1 if payload[:cached]

        sent(payload.fetch(:sql))
        @queries += 1
      end

      # Keeps track of the statement a query sent, by its SQL's hash (no
      # copy of it, and nothing allocated: what a benchmark allocates is
      # measured), and its SQL, for the first STATEMENTS.
      def sent(sql)
        key = sql.hash
        @recent[@queries % KEPT] = key
        @sql[key] = sql if @sql.size < STATEMENTS
      end

      # The queries counted by a reading of the totals.
      def queries(reading) = reading.total("active_record_queries")

      # +sql+ on one line, and at most LENGTH long.
      def shorten(sql)
        line = sql.gsub(/\s+/, " ").strip
        (line.length > LENGTH) ? "#{line[0, LENGTH - 3]}..." : line
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

      # Active Support's notifications, loaded when it first subscribes
      # (in a worker: never in the runner).
      # mutant:disable -- the tests have loaded Active Support, so leaving
      # out the require can't fail them in their process
      # (test_subscribes_in_the_worker checks it, in a process of its own)
      def notifications
        require "active_support/notifications"
        ::ActiveSupport::Notifications
      end
    end
  end
end
