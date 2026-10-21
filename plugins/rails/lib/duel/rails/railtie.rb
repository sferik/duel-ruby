# frozen_string_literal: true

module Duel
  module Rails
    # In the app (Bundler requires the gem as it boots): `rake duel`, as
    # Duel::RakeTask makes it, unless the app's Rakefile made one.
    # `rails generate duel:install` is found by its path
    # (lib/generators).
    class Railtie < ::Rails::Railtie
      rake_tasks { Railtie.define_task }

      # Defines `rake duel`, unless there's one (Rake would run both).
      def self.define_task
        require "duel/rake_task"
        RakeTask.new unless Rake::Task.task_defined?("duel")
      end
    end
  end
end
