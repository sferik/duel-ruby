# frozen_string_literal: true

module Duel
  # Where a regression's time went: StackProf profiles of each version,
  # over the same iterations (Lane#profile), so a frame's samples compare
  # directly: the frames that gained the most CPU, in themselves, are the
  # place to start looking.
  # @api private
  class Profile
    UNAVAILABLE = "install the stackprof gem (CRuby) for a profile of each version"
    TOP = 8
    # Frames kept in the report, per version.
    KEPT = 200

    def initialize(profiles)
      @baseline = profiles.fetch("baseline")
      @candidate = profiles.fetch("candidate")
    end

    # [frame, own, total] for the TOP frames that gained the most samples
    # of their own: what each gained, in itself and with what it called,
    # as a share of all the baseline's samples (+0.05: 5% more CPU there).
    def grew
      base = counts(@baseline)
      samples = [@baseline.fetch("samples"), 1].max.to_f
      # (Only frames the candidate has can have gained.)
      counts(@candidate).map do |frame, (own_now, total_now)|
        # @type block: growth
        # (Steep takes the default for an Array of any length.)
        own_was, total_was = base.fetch(frame, [0, 0]) #: [Integer, Integer]
        [frame, (own_now - own_was) / samples, (total_now - total_was) / samples]
      end.select { |_, own, _| own.positive? }.sort_by { |_, own, _| -own }.first(TOP)
    end

    def to_h = {"grew" => grew, "baseline" => trimmed(@baseline), "candidate" => trimmed(@candidate)}

    private

    def counts(profile) = profile.fetch("frames").to_h { |frame, own, total| [frame, [own, total]] }

    def trimmed(profile) = {"samples" => profile.fetch("samples"), "frames" => profile.fetch("frames").first(KEPT)}
  end
end
