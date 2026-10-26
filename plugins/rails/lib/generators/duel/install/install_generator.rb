# frozen_string_literal: true

require "open3"
require "pathname"
require "rails/generators"

module Duel
  module Generators
    # `rails generate duel:install`: sets Duel up for the app, with
    # .duel.rb, the benchmark environment, benchmarks of its requests and
    # of its boot, and a GitHub Actions workflow, and adds StackProf (and
    # the plugin for its database's server) to the Gemfile. An app in a
    # subdirectory of its repository (a monorepo's) gets a workflow at the
    # repository's root, run in the app's directory.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.join(File.dirname(__FILE__), "templates")

      desc "Sets Duel up for this app: .duel.rb, config/environments/benchmark.rb, " \
        "benchmarks of its requests (duel/requests_duel.rb) and its boot (duel/boot_duel.rb), and a GitHub Actions workflow."

      class_option :database, type: :string, enum: %w[sqlite postgresql mysql2 trilogy],
        desc: "Each worker's database (default: as the app's own)"

      # The adapters each worker's database can stand in for, by the
      # database duel-rails calls it.
      ADAPTERS = {"sqlite3" => "sqlite", "postgresql" => "postgresql", "postgis" => "postgresql",
                  "mysql2" => "mysql2", "trilogy" => "trilogy"}.freeze

      # The plugin each database's server comes from.
      PLUGINS = {"postgresql" => "duel-postgresql", "mysql2" => "duel-mysql", "trilogy" => "duel-mysql"}.freeze

      # The most requests benchmarked at first.
      ROUTES = 10

      # Controllers of Rails's own (its health check, Active Storage...).
      FRAMEWORK = %r{\A(rails|active_storage|action_mailbox|turbo)/}

      def create_config = template("duel.rb.tt", ".duel.rb")

      def create_environment = template("benchmark.rb.tt", "config/environments/benchmark.rb")

      def create_benchmarks = template("requests_duel.rb.tt", "duel/requests_duel.rb")

      def create_boot_benchmark = template("boot_duel.rb.tt", "duel/boot_duel.rb")

      # The workflows, at the repository's root: perf.yml, and
      # perf-comment.yml, which comments on a pull request with the
      # report, or, for an app in a subdirectory, perf-<its path>.yml
      # (perf-apps-blog.yml) and perf-<its path>-comment.yml, so that each
      # of a monorepo's apps can have its own.
      def create_workflow
        dir = working_directory
        name = dir ? "perf-#{dir.tr("/", "-")}" : "perf"
        template("perf.yml.tt", File.join(repository, ".github", "workflows", "#{name}.yml"))
        template("perf-comment.yml.tt", File.join(repository, ".github", "workflows", "#{name}-comment.yml"))
      end

      # The plugin that gives each worker its database's server.
      def add_plugin
        plugin = PLUGINS[database]
        gem(plugin, group: :development) if plugin && !gemfile.include?(plugin)
      end

      # StackProf, for profiles of regressions: it runs on CRuby only, so
      # it's left out of JRuby's and TruffleRuby's bundles.
      def add_stackprof
        gem("stackprof", platforms: :mri, group: :development) unless gemfile.include?("stackprof")
      end

      private

      def gemfile = File.read(File.join(destination_root, "Gemfile"))

      # The database each worker gets: as asked, or as the app's own
      # primary database is, or nil for one Duel can't give it.
      def database = options[:database] || ADAPTERS[adapter]

      # The app's primary database's adapter (nil without Active Record).
      def adapter
        return unless defined?(::ActiveRecord::Base)

        configs = ::ActiveRecord::Base.configurations.configs_for(env_name: ::Rails.env)
        (configs.find { |config| config.name == "primary" } || configs.first)&.adapter
      end

      # The app's first ROUTES routes a GET without parameters reaches, as
      # [name, request]: "posts: index", "GET /posts". Each path once, and
      # each action once (a benchmark's name is its own): the root, say,
      # that reaches what /posts does is benchmarked once.
      def routes
        found = ::Rails.application.routes.routes.filter_map do |route|
          controller, action = route.requirements.values_at(:controller, :action)
          path = route.path.spec.to_s.delete_suffix("(.:format)")
          next unless route.verb == "GET" && controller && !controller.match?(FRAMEWORK) && !path.match?(/[:*(]/)

          ["#{controller}: #{action}", "GET #{path}"]
        end
        found.uniq(&:last).uniq(&:first).first(ROUTES)
      end

      # Whether the app has fixtures (test/fixtures), for each worker's data.
      def fixtures? = Dir.glob("test/fixtures/**/*.yml", base: destination_root).any?

      # Whether the app names its Ruby in a .ruby-version: then each version
      # runs on the Ruby its own names (c.ruby = :version_file), and the
      # workflow installs the app's.
      def version_file? = File.exist?(File.join(destination_root, ".ruby-version"))

      # The Ruby the workflow runs: none, where .ruby-version says.
      def ruby_version = (RUBY_VERSION.rpartition(".").first unless version_file?)

      # The root of the app's git repository: the app's own directory,
      # outside one (or without git).
      def repository
        top, _, status = Open3.capture3("git", "-C", destination_root, "rev-parse", "--show-toplevel")
        status.success? ? top.chomp : destination_root
      rescue SystemCallError
        destination_root
      end

      # The app's directory, from its repository's root ("apps/blog"), or
      # nil for an app at the root.
      def working_directory
        path = Pathname(File.realpath(destination_root)).relative_path_from(File.realpath(repository)).to_s
        path unless path == "."
      end
    end
  end
end
