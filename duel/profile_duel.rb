# frozen_string_literal: true

require_relative "duel_helper"

duel "profile: where the time went, over 200 frames" do
  once { @profile = Subject::Duel::Profile.new("baseline" => stackprof(200, seed: 1), "candidate" => stackprof(200, seed: 2)) }
  @profile.to_h
end
