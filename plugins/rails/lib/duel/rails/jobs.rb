# frozen_string_literal: true

module Duel
  module Rails
    # Active Job's queue while benchmarking: the jobs a benchmark enqueues
    # are performed in an after_iterations hook (Config#after_iterations),
    # after its iterations (or inside each, for a request rolled back:
    # before what it wrote is rolled back), and measured with them. A request that enqueues a job
    # is judged on the job's work too, as a server and its queue would do
    # it.
    #
    # It's the queue adapter of ActiveJob::Base, in each worker: a job
    # class with an adapter of its own keeps that one.
    class Jobs
      # Performs each version's jobs after its benchmarks' iterations.
      # Returns the Jobs.
      def self.configure(config)
        jobs = new
        config.in_worker { jobs.use }
        config.before_sample { jobs.clear }
        config.after_iterations { jobs.perform }
        jobs
      end

      def initialize
        # Each job enqueued, serialized (as a queue keeps it), in order.
        @queue = [] #: Array[Hash[String, untyped]]
      end

      # Makes it Active Job's queue adapter, in the booted app, if it has
      # Active Job.
      def use
        ::ActiveJob::Base.queue_adapter = self if defined?(::ActiveJob::Base)
      end

      # (An adapter's: the job is kept, serialized, until it's performed,
      # whenever it's scheduled for.)
      def enqueue(job) = @queue << job.serialize

      def enqueue_at(job, _timestamp) = enqueue(job)

      # (Rails 7.2 asks an adapter whether jobs enqueued in a transaction
      # wait for it to commit, as Active Job's own adapters do. Rails 8.0
      # and later ask the job.)
      def enqueue_after_transaction_commit? = true

      # (Rails 8.1 asks whether a continuable job should stop: never.)
      def stopping? = false

      # The jobs waiting to be performed.
      def size = @queue.size

      # Performs the jobs waiting, in order, and those they enqueue.
      def perform
        ::ActiveJob::Base.execute(@queue.shift) until @queue.empty?
      end

      # Forgets the jobs waiting (enqueued before a sample: by loading the
      # worker's data, say).
      def clear = @queue.clear
    end
  end
end
