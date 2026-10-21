# frozen_string_literal: true

module Duel
  module Rails
    # What the app's views and its cache did for each benchmark, from
    # Rails's notifications:
    #
    # - rails_views: the templates, partials and layouts it rendered (each
    #   of a collection's partials too)
    # - rails_cache_reads: the keys it read from the cache
    # - rails_cache_misses: the keys it read that weren't there
    # - rails_cache_writes: the keys it wrote
    #
    # Where the views regressed, it says which a sample rendered most.
    class Counter
      # Counts. (Reading them renders nothing and touches no cache, so
      # Duel finds that it costs nothing, and takes nothing away.)
      MEASURES = {
        "rails_views" => {kind: :counted, unit: %w[view views]},
        "rails_cache_reads" => {kind: :counted, unit: %w[read reads]},
        "rails_cache_misses" => {kind: :counted, unit: %w[miss misses]},
        "rails_cache_writes" => {kind: :counted, unit: %w[write writes]}
      }

      # What each event it subscribes to is.
      EVENTS = {
        "render_template.action_view" => :view, "render_partial.action_view" => :view,
        "render_layout.action_view" => :view, "render_collection.action_view" => :collection,
        "cache_read.active_support" => :read, "cache_read_multi.active_support" => :read_multi,
        "cache_write.active_support" => :write, "cache_write_multi.active_support" => :write_multi
      }.freeze

      # The most views shown, explaining a regression.
      SHOWN = 3

      # Adds the metrics, counted from when each worker opens them (once
      # the app has booted) until it ends. Returns the Counter.
      def self.configure(config)
        counter = new
        config.metric(MEASURES) { [counter.totals, counter.views] }
          .open { counter.subscribe }
          .close { counter.unsubscribe }
          .details { |stretches, sample| counter.details(stretches, sample.n) }
        counter
      end

      def initialize
        @views = @reads = @misses = @writes = 0
        # Each view rendered, by its template's path (as given: making
        # another would allocate).
        @rendered = Hash.new(0)
        @subscriptions = [] #: Array[untyped]
        @root = ""
      end

      # Subscribes to its EVENTS, in the booted app.
      def subscribe
        @root = File.join(::Rails.root, "app", "views", "")
        @subscriptions = EVENTS.keys.map { |event| ActiveSupport::Notifications.subscribe(event, self) }
      end

      # Stops counting.
      def unsubscribe = @subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }

      # The totals so far, by name.
      def totals
        {"rails_views" => @views, "rails_cache_reads" => @reads, "rails_cache_misses" => @misses,
         "rails_cache_writes" => @writes}
      end

      # Each view rendered so far, how many times, by its template's
      # path.
      def views = @rendered.dup

      # What explains the views a sample rendered, in its stretches (pairs
      # of readings: see Snapshot#details) of +n+ iterations: the SHOWN
      # rendered most, and how many times an iteration ("an iteration:
      # 20× posts/_post.html.erb; 1× posts/index.html.erb"). Nothing
      # where none were.
      def details(stretches, n)
        rendered = Hash.new(0)
        stretches.each do |started, stopped|
          stopped.context.each { |path, count| rendered[path] += count - started.context.fetch(path, 0) }
        end
        shown = rendered.select { |_, count| count.positive? }.sort_by { |path, count| [-count, path.to_s] }.first(SHOWN)
        return if shown.empty?

        said = shown.map { |path, count| "#{format("%.4g", count.fdiv(n))}× #{path.to_s.delete_prefix(@root)}" }
        {"rails_views" => "an iteration: #{said.join("; ")}"}
      end

      # (Active Support's, for every event subscribed to. Nothing they do
      # allocates: what a benchmark allocates is measured.)
      def start(_name, _id, _payload)
      end

      def finish(name, _id, payload)
        case EVENTS.fetch(name)
        when :view then view(payload, 1)
        when :collection then view(payload, payload[:count] || 0)
        when :read then read(1, payload[:hit] ? 1 : 0)
        when :read_multi then read(payload.fetch(:key).size, payload.fetch(:hits).size)
        when :write then @writes += 1
        else @writes += payload.fetch(:key).size
        end
      end

      private

      # +count+ views of the template at the payload's identifier.
      def view(payload, count)
        @views += count
        @rendered[payload[:identifier]] += count
      end

      def read(keys, hits)
        @reads += keys
        @misses += keys - hits
      end
    end
  end
end
