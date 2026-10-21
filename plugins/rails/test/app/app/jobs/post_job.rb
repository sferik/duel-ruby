# frozen_string_literal: true

# Creates a post (and, given more, another job for the rest).
class PostJob < ActiveJob::Base
  def perform(title, *more)
    Post.create!(title:)
    PostJob.perform_later(*more) if more.any?
  end
end
