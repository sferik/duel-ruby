# frozen_string_literal: true

require_relative "test_helper"

# Active Job's queue while benchmarking: the jobs a benchmark enqueues are
# performed after its iterations (an after_iterations hook), and measured
# with them.
class JobsTest < PluginTest
  cover "Duel::Rails::Jobs*"

  def setup
    super
    @adapter = ActiveJob::Base.queue_adapter
    @config = Duel::Config.new(@dir)
    @jobs = Duel::Rails::Jobs.configure(@config)
  end

  def teardown
    ActiveJob::Base.queue_adapter = @adapter
    super
  end

  def later(title) = Duel::Rails::Request.new("POST /later", params: {title:}).call

  # In a worker, it's the queue: what a sample enqueued is performed after
  # it, those jobs' own jobs too, in order.
  def test_performed_after_the_iterations
    Duel::Testing.in_worker(@config) do
      assert_same @jobs, ActiveJob::Base.queue_adapter
      Duel::Testing.measure(@config) do
        assert_equal 202, later("a")
        PostJob.perform_later("b", "c", "d")

        assert_equal [0, 2], [Post.count, @jobs.size], "not yet"
      end

      assert_equal %w[a b c d], Post.order(:id).pluck(:title)
      assert_equal 0, @jobs.size
    end
  end

  # What was enqueued before a sample (by loading the worker's data, say)
  # isn't the sample's.
  def test_cleared_before_each_sample
    Duel::Testing.in_worker(@config) do
      PostJob.perform_later("before")
      Duel::Testing.measure(@config) { nil }

      assert_equal 0, Post.count
    end
  end

  # A job that waits for its transaction to commit is enqueued when the
  # request's own commits: the transaction a request is rolled back in
  # doesn't hold it.
  def test_enqueued_after_the_requests_transaction
    @jobs.use
    waits = PostJob.enqueue_after_transaction_commit
    PostJob.enqueue_after_transaction_commit = true
    Duel::Rails.rolled_back do
      Post.transaction do
        PostJob.perform_later("waited")

        assert_equal 0, @jobs.size, "not while it's open"
      end

      assert_equal 1, @jobs.size
    end
  ensure
    PostJob.enqueue_after_transaction_commit = waits
  end

  # A job scheduled for later is performed too.
  def test_scheduled
    @jobs.use
    PostJob.set(wait: 3600).perform_later("later")

    assert_equal 1, @jobs.size
    @jobs.perform

    assert_equal %w[later], Post.pluck(:title)
  end

  def test_kept_serialized
    job = PostJob.new("a")
    @jobs.enqueue(job)

    assert_equal [job.serialize.except("enqueued_at")], @jobs.instance_variable_get(:@queue).map { |data| data.except("enqueued_at") }
    @jobs.clear

    assert_equal 0, @jobs.size
  end

  # What Active Job asks of an adapter, by Rails version.
  def test_as_an_adapter
    assert_predicate @jobs, :enqueue_after_transaction_commit?
    refute_predicate @jobs, :stopping?
    assert_kind_of Duel::Rails::Jobs, Duel::Rails::Jobs.new
  end

  # Active Job's, whatever's named ActiveJob in Duel (a plugin's
  # module).
  def test_not_a_plugins_active_job
    Duel.const_set(:ActiveJob, Module.new)
    @jobs.use
    PostJob.perform_later("mine")
    @jobs.perform

    assert_same @jobs, ::ActiveJob::Base.queue_adapter
    assert_equal %w[mine], Post.pluck(:title)
  ensure
    Duel.send(:remove_const, :ActiveJob)
  end

  # The app without Active Job: nothing to use.
  def test_without_active_job
    saved = Object.send(:remove_const, :ActiveJob)

    assert_nil @jobs.use
  ensure
    Object.const_set(:ActiveJob, saved)
  end

  def test_configure
    assert_equal [1, 1, 1], [@config.in_workers, @config.hooks.fetch(:before_sample), @config.hooks.fetch(:after_iterations)].map(&:size)
  end
end
