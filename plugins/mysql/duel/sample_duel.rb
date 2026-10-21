# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's work for a sample, after every one (Sample#stop): a
# reading at its start and its stop, and what explains it: what each
# statement did in its stretches, those that did the most of each
# measure, and their texts (read once, in setup).
[[20, 3], [200, 10], [2000, 20]].each do |size, ran|
  duel "sample: #{ran} of #{size} statements ran" do
    once do
      table = digest_table(size)
      @statements = canned(table, ran_again(table, ran))
    end
    sample(@statements)
  end
end

# A benchmark that sends the server nothing (most, in a suite that has
# some that do): its samples are read and explained too.
[200, 2000].each do |size|
  duel "sample: none of #{size} statements ran" do
    once { @statements = canned(digest_table(size)) }
    sample(@statements)
  end
end

# A sample whose untimed blocks split it in stretches: one per block,
# and one more.
duel "sample: 10 of 200 statements ran, in 10 stretches" do
  once do
    tables = (1..10).reduce([digest_table(200)]) { |so_far, seed| so_far << ran_again(so_far.last, 10, seed:) }
    # (Each stretch's start, then its stop: nothing ran in between.)
    @statements = canned(*tables.each_cons(2).to_a.flatten(1), stretches: 10)
  end
  sample(@statements, 10)
end
