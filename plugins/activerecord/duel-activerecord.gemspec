# frozen_string_literal: true

require_relative "lib/duel/activerecord/version"

Gem::Specification.new do |spec|
  spec.name = "duel-activerecord"
  spec.version = Duel::ActiveRecord::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "What Active Record did for each Duel benchmark: queries, transactions and records"
  spec.description = "A Duel plugin: every benchmark is judged on the SQL queries, cached queries, " \
    "transactions and record instantiations Active Record did for it too, whatever the database."
  spec.homepage = "https://github.com/sferik/duel-ruby/tree/main/plugins/activerecord"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/sferik/duel-ruby/blob/main/plugins/activerecord/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sferik/duel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "duel", "~> 0.1"
  spec.add_dependency "activerecord", ">= 7.2"
end
