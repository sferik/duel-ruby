# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

# `rake release` builds the gem, tags the release and pushes the tag; the
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

task default: :test
