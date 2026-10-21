# frozen_string_literal: true

Rails.application.routes.draw do
  resources :posts, only: %i[index show create]
  get "cached", to: "posts#cached"
  get "plain", to: "posts#plain"
  get "boom", to: "posts#boom"
  post "later", to: "posts#later"
end
