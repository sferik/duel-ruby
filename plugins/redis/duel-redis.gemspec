# frozen_string_literal: true

require_relative "lib/duel/redis/version"

Gem::Specification.new do |spec|
  spec.name = "duel-redis"
  spec.version = Duel::Redis::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "A Redis server for each Duel worker, and what it did for each benchmark"
  spec.description = "A Duel plugin: each worker gets a Redis server of its own, and every benchmark is " \
    "judged on the Redis CPU time, commands and round trips it took too."
  spec.homepage = "https://github.com/sferik/duel-ruby/tree/main/plugins/redis"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/sferik/duel-ruby/blob/main/plugins/redis/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sferik/duel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "duel", "~> 0.1"
end
