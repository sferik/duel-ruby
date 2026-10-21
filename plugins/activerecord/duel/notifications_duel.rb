# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's subscriber as Active Support calls it, through its
# notifications: the kind of subscriber it is decides what Active Support
# does for every event, besides what the plugin does itself.
teardown { @counter.unsubscribe }

[["notifications: 100 queries", {}], ["notifications: 100 queries, timed", {query_time: true}]].each do |name, options|
  duel name do
    once do
      @counter = subscribed(**options)
      @payloads = replayed(QUERIES + SKIPPED)
      warm(@counter, QUERIES)
    end
    @payloads.each { |payload| ActiveSupport::Notifications.instrument(SQL, payload) }
  end
end
