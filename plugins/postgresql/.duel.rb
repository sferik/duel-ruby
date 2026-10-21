# frozen_string_literal: true

Duel.configure do |c|
  # The repository holds Duel and its plugins, so `--base last-release`
  # compares against this plugin's newest release tag (duel-postgresql-v0.1.0,
  # say), not Duel's.
  c.release_tags = "duel-postgresql-v*"
end
