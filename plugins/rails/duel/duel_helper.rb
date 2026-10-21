# frozen_string_literal: true

# A reading of the counter's totals, as Duel gives a details block one:
# its totals, and the views rendered so far (its context).
Reading = Struct.new(:totals, :context)

# A template's path, as Action View gives it.
def view(name) = "/app/views/#{name}.html.erb"
