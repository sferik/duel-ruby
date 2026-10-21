# frozen_string_literal: true

require_relative "lib/duel/gvl/version"

Gem::Specification.new do |spec|
  spec.name = "duel-gvl"
  spec.version = Duel::GVL::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "How long threads waited for the GVL, for every Duel benchmark with threads of its own"
  spec.description = "A Duel plugin: benchmarks with threads of their own are judged on how long their " \
    "threads waited for the GVL too, so a change that adds contention fails even when its CPU time doesn't."
  spec.homepage = "https://github.com/sferik/duel-ruby/tree/main/plugins/gvl"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/sferik/duel-ruby/blob/main/plugins/gvl/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sferik/duel-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "ext/duel_gvl/*.{c,rb}", "sig/**/*.rbs", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  # Built where it can be, and elsewhere a Makefile that does nothing (see
  # extconf.rb), and no metric.
  spec.extensions = ["ext/duel_gvl/extconf.rb"]

  spec.add_dependency "duel", "~> 0.1"
end
