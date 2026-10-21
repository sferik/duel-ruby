# frozen_string_literal: true

require "active_job"
require "logger"

# A job that does nothing: what's measured is the queue's own work.
class NoopJob < ActiveJob::Base
  def perform(_id) = nil
end

# What the plugin does inside a benchmark's measured code when the app
# enqueues jobs, and after its iterations: keep each job, serialized, and
# perform them (with Active Job's own work, the same on both versions).
setup do
  ActiveJob::Base.logger = Logger.new(nil)
  @jobs = Duel::Rails::Jobs.new
  @job = NoopJob.new(1)
end

duel "jobs: 10 enqueued and performed" do
  10.times { @jobs.enqueue(@job) }
  @jobs.perform
end
