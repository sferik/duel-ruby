# frozen_string_literal: true

require_relative "lib/duel/version"

Gem::Specification.new do |spec|
  spec.name = "duel"
  spec.version = Duel::VERSION
  spec.authors = ["Erik Berlin"]
  spec.email = ["sferik@gmail.com"]
  spec.summary = "Performance regression guards: fail when a change makes your code slower"
  spec.description = "Duel runs your benchmarks on two versions of your code side by side, the baseline " \
    "(where your branch left main, say) and the candidate, and fails if the candidate is slower at any of " \
    "them. Timings are judged by a distribution-free confidence interval for paired CPU-time ratios and " \
    "confirmed in fresh processes, so it fails on real regressions, not noise; allocations are counted."
  spec.homepage = "https://github.com/sferik/duel-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "sig/manifest.yaml", "exe/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["duel"]
  spec.require_paths = ["lib"]

  # Instruction counts and memory, from the operating system (Ruby's own
  # gem; no longer one of its default gems).
  spec.add_dependency "fiddle", "~> 1.1"
end
