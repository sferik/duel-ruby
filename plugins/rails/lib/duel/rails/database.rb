# frozen_string_literal: true

module Duel
  module Rails
    # Each worker's own database, in DATABASE_URL (which Rails prefers to
    # config/database.yml), with its version's schema and data loaded
    # into it (see Rails.load_worker_data).
    module Database
      # The plugin that gives each worker a server, by database.
      SERVERS = {postgresql: :postgresql, mysql2: :mysql, trilogy: :mysql}.freeze

      # The URL's scheme (which Rails takes for the adapter), by database,
      # where the plugin's own isn't it.
      SCHEMES = {trilogy: "trilogy"}.freeze

      # Gives each worker its own +database+: a file for :sqlite, or a
      # server for :postgresql, :mysql2 or :trilogy, from its Duel plugin
      # (used with +options+).
      def self.configure(config, database, **options)
        return config.prepare(:worker) { |w| {"DATABASE_URL" => "sqlite3:#{w.path("db.sqlite3")}"} } if database == :sqlite

        plugin = SERVERS.fetch(database) do
          raise ArgumentError, "database: must be :sqlite, :postgresql, :mysql2 or :trilogy, not #{database.inspect}"
        end
        config.use(plugin, **{scheme: SCHEMES[database]}.compact, **options)
      end

      # Loads the version's schema (db/schema.rb, or db/structure.sql)
      # into the worker's database.
      def self.load_schema
        ::ActiveRecord::Tasks::DatabaseTasks.load_schema(::ActiveRecord::Base.connection_db_config)
      end

      # Empties every table of the worker's database (but Active Record's
      # own: its schema's version, say).
      def self.clear
        ::ActiveRecord::Base.with_connection { |connection| connection.truncate_tables(*connection.tables) }
      end

      # Loads +names+ from the version's test/fixtures (every one, for
      # :all): nothing for none. (Again, if they were loaded before: Active
      # Record would take them for still there.)
      def self.load_fixtures(names, path: ::Rails.root.join("test", "fixtures"))
        case names
        when :all then names = Dir.glob("**/*.yml", base: path).map { |file| file.delete_suffix(".yml") }.sort
        end
        return if names.empty?

        ::ActiveRecord::FixtureSet.reset_cache
        ::ActiveRecord::FixtureSet.create_fixtures(path, names)
      end
    end
  end
end
