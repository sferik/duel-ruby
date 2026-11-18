# frozen_string_literal: true

require "rake"

module Duel
  # A rake task running `duel` with +args+, which exits as `duel` does:
  # with its status, where it isn't 0 (see CLI).
  #
  #   require "duel/rake_task"
  #   Duel::RakeTask.new(:perf)
  #   Duel::RakeTask.new(:perf_since_release, "--base", "last-release")
  #
  # Duel itself loads only as the task runs: a Rakefile that defines the
  # task loads nothing more for its other tasks (rake test, say).
  class RakeTask
    include Rake::DSL

    # Loads Duel's command, as the task runs.
    # mutant:disable -- the tests' process has Duel loaded from the start, so
    # a require changes nothing there: RakeTaskTest's
    # test_the_task_loads_duel_as_it_runs checks it, in a process of its own
    def self.load_duel = require_relative("cli")

    def initialize(name = :duel, *args)
      desc "Fail if this tree is slower than its baseline at any benchmark (duel)"
      task(name) do
        RakeTask.load_duel
        status = CLI.new(args).run
        exit(status) unless status.zero?
      end
    end
  end
end
