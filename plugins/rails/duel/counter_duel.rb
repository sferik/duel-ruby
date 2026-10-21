# frozen_string_literal: true

require_relative "duel_helper"

# What the plugin does inside a benchmark's own timed code: Active
# Support calls the counter for every view rendered and every key read
# or written. It must cost little, and allocate nothing.
setup { @counter = Duel::Rails::Counter.new }

duel "counter: 100 views rendered" do
  once { @payload = {identifier: view("posts/_post")} }
  100.times { @counter.finish("render_partial.action_view", "1", @payload) }
end

duel "counter: a collection of 100 rendered" do
  once { @payload = {identifier: view("posts/_post"), count: 100} }
  @counter.finish("render_collection.action_view", "1", @payload)
end

duel "counter: 100 cache reads" do
  once { @payload = {key: "posts", hit: true} }
  100.times { @counter.finish("cache_read.active_support", "1", @payload) }
end

duel "counter: 100 cache reads of 10 keys" do
  once { @payload = {key: Array.new(10) { |i| "k#{i}" }, hits: %w[k0 k1]} }
  100.times { @counter.finish("cache_read_multi.active_support", "1", @payload) }
end

# What it does around every sample: read its totals (twice), and explain
# the sample.
duel "counter: the totals" do
  once { @counter.finish("render_partial.action_view", "1", {identifier: view("posts/_post")}) }
  @counter.totals
  @counter.views
end

duel "counter: what explains 20 views" do
  once do
    names = Array.new(20) { |i| view("posts/_p#{i}") }
    @stretches = [[Reading.new({}, names.to_h { |name| [name, 1] }), Reading.new({}, names.to_h { |name| [name, 4] })]]
  end
  @counter.details(@stretches, 1)
end
