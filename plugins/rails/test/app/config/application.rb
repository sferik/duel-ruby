# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# The tests' app: a blog, booted as each version of an app is (see
# Duel::Rails.boot), on SQLite.
module Blog
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = true
    config.secret_key_base = "duel-test" * 8
    config.logger = Logger.new(nil)
    config.log_level = :fatal
    config.hosts.clear
    config.action_controller.allow_forgery_protection = false
    config.cache_store = :memory_store
  end
end
