# frozen_string_literal: true

require_relative "test_helper"
require "rake"

# In an app: `rake duel`.
class RailtieTest < PluginTest
  cover "Duel::Rails::Railtie*"

  # (Descriptions are kept as `rake -T` keeps them.)
  def tasks
    Rake::TaskManager.record_task_metadata = true
    Rake.with_application do |rake|
      yield
      return rake.tasks.select { |task| task.name == "duel" }
    end
  end

  def test_rake_duel
    duel = tasks { Rails.application.load_tasks }

    assert_equal ["Fail if this tree is slower than its baseline at any benchmark (duel)"], duel.map(&:comment)
  end

  # Unless the app's Rakefile made one: Rake would run both.
  def test_not_twice
    duel = tasks do
      Rake::Task.define_task(:duel) { nil }
      Duel::Rails::Railtie.define_task
    end

    assert_equal 1, duel.first.actions.size
    assert_equal 1, tasks { Duel::Rails::Railtie.define_task }.first.actions.size
  end
end
