# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "duel/rake_task"

# `rake release` builds the gem, tags the release and pushes the tag. The
# push workflow (.github/workflows/push.yml) then signs the gem and pushes
# it to RubyGems.org, with an attestation, from CI.
ENV["gem_push"] = "no"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

desc "Check the RBS signatures (sig/), and lib/ against them with Steep (CRuby)"
task :typecheck do
  sh "rbs", "-I", "sig", "-I", "steep", "-r", "open3", "-r", "optparse", "-r", "socket", "validate"
  sh "steep", "check"
end

desc "Mutation-test every subject with mutant (slow: CI shards it)"
task :mutant do
  sh "bundle exec mutant run"
end

namespace :mutant do
  desc "List the subjects touched since REF (every one, without a REF), one per line"
  task :subjects, [:ref] do |_task, args|
    require_relative "tasks/mutant_shard"
    puts MutantShard.subjects(args[:ref])
  end

  desc "Mutation-test shard INDEX of TOTAL of the subjects touched since REF (every one, without a REF)"
  task :shard, [:ref, :index, :total] do |_task, args|
    require "shellwords"
    require_relative "tasks/mutant_shard"
    index = Integer(args.fetch(:index))
    total = Integer(args.fetch(:total))
    subjects = MutantShard.subjects(args[:ref])
    mine = MutantShard.shard(subjects, index, total)

    if mine.empty?
      puts "Shard #{index} of #{total}: no subjects"
    else
      puts "Shard #{index} of #{total}: #{mine.size} of #{subjects.size} subjects"
      sh "bundle exec mutant run #{mine.map { |subject| Shellwords.escape(subject) }.join(" ")}"
    end
  end
end

# `rake duel` compares the benchmarks in duel/ with the main branch's,
# and fails if this tree is slower at any of them.
Duel::RakeTask.new

# The plugins (plugins/*) are gems of their own, each with its own bundle
# and tasks: `rake plugins` runs every one's default task (its tests),
# and `rake plugins:redis` one's.
PLUGINS = Dir["plugins/*/Rakefile"].map { |rakefile| File.basename(File.dirname(rakefile)) }.sort

namespace :plugins do
  PLUGINS.each do |plugin|
    desc "Install plugins/#{plugin}'s bundle and run its default task"
    task plugin do
      Bundler.with_unbundled_env do
        sh "bundle", "install", "--quiet", chdir: "plugins/#{plugin}"
        sh "bundle", "exec", "rake", chdir: "plugins/#{plugin}"
      end
    end
  end
end

desc "Install every plugin's bundle and run its default task"
task plugins: PLUGINS.map { |plugin| "plugins:#{plugin}" }

# Duel and its plugins released together, at one version (see
# tasks/release.rb, and CONTRIBUTING.md's Releasing section).
namespace :release do
  desc "Check every gem, then tag HEAD for each and push the tags (RELEASE_DATE, DRY_RUN=1, FORCE=1)"
  task :all do
    require_relative "tasks/release"
    options = Release.options(ENV)
    released = Bundler.with_unbundled_env do
      Release.release(__dir__, date: options[:date], dry_run: options[:dry_run], force: options[:force])
    end
    abort unless released
  end

  namespace :all do
    desc "Run every check of release:all, but tag and push nothing"
    task :dry_run do
      ENV["DRY_RUN"] = "1"
      Rake::Task["release:all"].invoke
    end
  end

  desc "Set every gem's version to VERSION and date each changelog's Unreleased entries (RELEASE_DATE)"
  task :bump, [:version] do |_task, args|
    require_relative "tasks/release"
    version = args.fetch(:version) { abort "Usage: rake release:bump[VERSION]" }
    changed = Release.bump(__dir__, version, date: Release.options(ENV)[:date])
    puts "Changed:", *changed.map { |path| "  #{path}" }
    puts "Review, commit and push the changes, then run rake release:all."
  end
end

task default: :test
