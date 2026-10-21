# frozen_string_literal: true

require "duel"
require_relative "rails/version"
require_relative "rails/bundle"
require_relative "rails/database"
require_relative "rails/request"
require_relative "rails/counter"
require_relative "rails/jobs"
# (In an app, where Bundler requires the gem as Rails boots: `rake duel`.
# A worker requires it from .duel.rb before the app boots, and needs no
# Railtie.)
defined?(::Rails::Railtie) && require_relative("rails/railtie")

module Duel
  # Duel for a Rails app: each version of the app booted in the benchmark
  # environment, with a bundle and a database of its own, and benchmarks
  # of requests (see DSL#duel_request), with the jobs they enqueue.
  #
  #   # .duel.rb
  #   Duel.configure { |c| c.use :rails, database: :postgresql }
  #
  # Inside module Duel, ::Rails is Rails itself: Rails is this module.
  module Rails
    Duel.plugin(:rails, self)

    # What a change must touch to be compared: the app's code, its
    # configuration, its schema, its gems, and its Ruby. (From the app's
    # own directory, in a monorepo's subdirectory too.)
    WATCH = %w[app config db lib Gemfile Gemfile.lock .ruby-version].freeze

    # The environment each version boots in (see the generator's
    # config/environments/benchmark.rb).
    ENVIRONMENT = "benchmark"

    # What Ruby's random numbers, and Faker's, are seeded with in each
    # worker, before its data is loaded.
    SEED = 42

    # An around_iteration hook (for .duel.rb, a file of benchmarks, or one
    # benchmark): each iteration in a transaction, rolled back after it,
    # unmeasured (see .rolled_back). Each request benchmark (see
    # DSL#duel_request) has it, unless told not to.
    #
    #   c.around_iteration(&Duel::Rails::ROLLBACK)
    ROLLBACK = ->(iteration) { Rails.rolled_back { iteration.call } }

    # Configures Duel for the app (c.use :rails):
    #
    # - +database+: the worker's own database (see Database.configure), or
    #   nil for none. +database_options+ go to its plugin.
    # - +environment+: what each version boots in (its workers, and its
    #   process benchmarks: RAILS_ENV).
    # - +bundle+: whether each version runs its own bundle (see Bundle).
    # - +fixtures+: the fixtures (test/fixtures) loaded into each worker's
    #   database, by name, or :all. +seeds+: whether db/seeds.rb runs
    #   too, after them. Both run once Ruby's random numbers are seeded
    #   with +seed+.
    # - +reset+: whether every table is emptied, and the fixtures and
    #   seeds loaded again, before every sample (see .reset_data).
    # - +jobs+: whether the jobs a benchmark enqueues are performed, and
    #   measured with it (see Jobs).
    # - +active_record+: whether Active Record's queries are counted too
    #   (c.use :activerecord), and +query_time+ timed.
    #
    # Each version's schema is loaded into its workers' databases.
    def self.configure(config, database: :sqlite, environment: ENVIRONMENT, bundle: true, fixtures: [], seeds: false,
      seed: SEED, reset: false, jobs: true, active_record: true, query_time: false, **database_options)
      raise ArgumentError, "reset: needs a database to reset" if reset && !database

      config.watch = WATCH
      config.load { |root| boot(root, environment) }
      Bundle.configure(config) if bundle
      config.prepare(:version) { |_version| {"RAILS_ENV" => environment} }
      # (What .reset_data loads again.)
      @data = ({fixtures:, seeds:, seed:} if database)
      if database
        Database.configure(config, database, **database_options)
        config.in_worker { load_worker_data(fixtures:, seeds:, seed:) }
        config.before_sample { reset_data } if reset
      end
      Jobs.configure(config) if jobs
      # (Its options only where they aren't its own defaults: an app's own
      # c.use :activerecord may have given others.)
      if active_record
        query_time ? config.use(:activerecord, query_time: true) : config.use(:activerecord)
      end
      Counter.configure(config)
    end

    # Boots the version at +root+ in +environment+, from its own tree (a
    # relative path the app reads is the version's own).
    def self.boot(root, environment)
      ENV["RAILS_ENV"] = environment
      Dir.chdir(root)
      require File.join(root, "config", "environment")
    end

    # Loads the worker's data: the version's schema, then its data (see
    # .load_data).
    def self.load_worker_data(fixtures:, seeds:, seed:)
      Database.load_schema
      load_data(fixtures:, seeds:, seed:)
    end

    # Loads +fixtures+ and (if +seeds+) db/seeds.rb, with random numbers
    # seeded with +seed+.
    def self.load_data(fixtures:, seeds:, seed:)
      seed_random(seed)
      Database.load_fixtures(fixtures)
      ::Rails.application.load_seed if seeds
    end

    # Puts the worker's data back as it was loaded: empties every table,
    # then loads the fixtures and seeds it was given (c.use :rails's)
    # again. For benchmarks that write what isn't rolled back, before each
    # sample: reset: true does it for every benchmark, and a file's
    # +before_sample { Duel::Rails.reset_data }+ for that file's.
    def self.reset_data
      data = @data or raise Error, "reset_data: c.use :rails gave the app no database to reset"
      Database.clear
      load_data(**data)
    end

    # Runs the block with each database connection Active Record writes
    # through pinned, in a transaction rolled back after it (as Rails's
    # own transactional tests do: the block's own transactions become
    # savepoints, and ending a request doesn't release the connection).
    # Without Active Record, it just runs the block. Returns what it does.
    def self.rolled_back
      return yield unless defined?(::ActiveRecord::Base)

      pinned = [] #: Array[untyped]
      begin
        ::ActiveRecord::Base.connection_handler.connection_pool_list(:writing).each do |pool|
          pool.pin_connection!(true)
          pinned << pool
        end
        yield
      ensure
        pinned.each(&:unpin_connection!)
      end
    end

    # Seeds Ruby's random numbers with +seed+, and Faker's, if it's
    # loaded: the same data on both versions.
    def self.seed_random(seed)
      srand(seed)
      Faker::Config.random = Random.new(seed) if defined?(Faker::Config)
    end
  end
end
