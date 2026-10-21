# frozen_string_literal: true

require_relative "duel/subject"

# Duel guards its own speed, with each version's code loaded apart from
# the Duel that measures it (see Subject).
Duel.configure do |c|
  c.load { |root| Subject.load(root, "duel", "duel/context", "duel/runner", "duel/profile") }
end
