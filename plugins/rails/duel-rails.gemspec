# frozen_string_literal: true

require_relative "lib/duel/rails/version"

Gem::Specification.new do |spec|
  spec.name = "duel-rails"
  spec.version = Duel::Rails::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "Performance regression guards for Rails apps, with Duel"
  spec.description = "A Duel plugin for Rails apps: each version of the app booted like production, with its own " \
    "bundle and database, and benchmarks of its requests, judged on time, allocations, queries, views and cache use."
  spec.homepage = "https://github.com/sferik/duel-ruby/tree/main/plugins/rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/sferik/duel-ruby/blob/main/plugins/rails/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sferik/duel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "lib/**/*.tt", "sig/**/*.rbs", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "duel", "~> 0.1"
  spec.add_dependency "duel-activerecord", "~> 0.1"
  spec.add_dependency "railties", ">= 7.2"
end
