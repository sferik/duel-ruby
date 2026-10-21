# frozen_string_literal: true

class PostsController < ApplicationController
  def index = @posts = Post.order(:id).to_a

  def show = render(plain: Post.find(params[:id]).title)

  def create
    post = Post.create!(params.require(:post).permit(:title))
    redirect_to post_path(post)
  end

  # Reads and writes the cache: a miss, then a hit (and two keys at once).
  def cached
    Rails.cache.fetch("posts") { Post.count }
    Rails.cache.read_multi("a", "b")
    Rails.cache.write_multi("a" => 1, "b" => 2)
    render plain: "ok"
  end

  def plain = render(plain: params.fetch(:say, "ok"))

  # Leaves the post to a job.
  def later
    PostJob.perform_later(params.fetch(:title))
    head :accepted
  end

  def boom = raise("boom")
end
