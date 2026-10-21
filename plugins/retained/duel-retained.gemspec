# frozen_string_literal: true

require_relative "lib/duel/retained/version"

Gem::Specification.new do |spec|
  spec.name = "duel-retained"
  spec.version = Duel::Retained::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "What each Duel benchmark leaves alive: objects that outlive the garbage collector"
  spec.description = "A Duel plugin: every benchmark is judged on the Ruby objects its iterations leave " \
    "alive after a full garbage collection, so a leak, or a cache that grows with every call, fails."
  spec.homepage = "https://github.com/sferik/duel-ruby/tree/main/plugins/retained"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/sferik/duel-ruby/blob/main/plugins/retained/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sferik/duel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "duel", "~> 0.1"
end
