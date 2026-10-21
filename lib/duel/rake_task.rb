# frozen_string_literal: true

require "rake"
require_relative "cli"

module Duel
  # A rake task running `duel` with +args+:
  #
  #   require "duel/rake_task"
  #   Duel::RakeTask.new(:perf)
  #   Duel::RakeTask.new(:perf_since_release, "--base", "last-release")
  class RakeTask
    include Rake::DSL

    def initialize(name = :duel, *args)
      desc "Fail if this tree is slower than its baseline at any benchmark (duel)"
      task(name) do
        case CLI.new(args).run
        when 1 then abort "duel: slower than the baseline"
        when 2 then abort "duel: couldn't compare"
        end
      end
    end
  end
end
