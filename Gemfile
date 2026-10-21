# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake"
gem "minitest"
gem "minitest-strict"
gem "standard", ">= 1.57"
gem "standard-performance"
gem "rubocop"
gem "rubocop-performance"
gem "rubocop-minitest"
gem "simplecov", ">= 1.3"

# Profiles of regressions (CRuby): optional for Duel's users.
gem "stackprof", platforms: :mri

platforms :mri do
  gem "mutant-minitest"
  # Type checking (sig/): Steep doesn't run on JRuby.
  gem "rbs"
  gem "steep"
end
