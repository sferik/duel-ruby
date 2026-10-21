# frozen_string_literal: true

module Duel
  # Where a regression's time went: StackProf profiles of each version,
  # over the same iterations (Lane#profile), so a frame's samples compare
  # directly: the frames that gained the most CPU, in themselves, are the
  # place to start looking.
  # @api private
  class Profile
    # Why there's no profile: StackProf runs on CRuby only, so the hint
    # reads right on JRuby and TruffleRuby too.
    UNAVAILABLE = "a profile of each version needs CRuby, with the stackprof gem in the bundle"
    TOP = 8
    # Frames kept in the report, per version.
    KEPT = 200

    # StackProf's frames for garbage collection, which isn't the
    # benchmark's code: what it gained is reported apart (see #gc).
    GC = "(garbage collection)"
    GC_FRAMES = [GC, "(marking)", "(sweeping)"].freeze

    # The frames that mark a benchmark's measured work (see Harness and
    # ProfileSample): its iterations, and what they left to do, are inside
    # Harness#iterate, an untimed block and around_iteration hooks' own
    # work are inside ProfileSample#pause, and an iteration inside its
    # hooks is inside Harness#iteration, inside that pause.
    ITERATE = "Duel::Harness#iterate"
    PAUSE = "Duel::ProfileSample#pause"
    ITERATION = "Duel::Harness#iteration"

    # A version's profile, from StackProf's +results+ (raw, so with each
    # sample's stack): every frame's samples [name, own, total], most total
    # first, and how many samples there were. Only the benchmark's work is
    # kept, and garbage collection (reported apart: see #gc). Frames of
    # one name, from different places, are one.
    def self.of(results)
      names = results.fetch(:frames).transform_values { |frame| frame.fetch(:name) }
      # @type var frames: Hash[String, [Integer, Integer]]
      frames = Hash.new do |h, k|
        h[k] = [0, 0] #: [Integer, Integer]
      end
      samples = 0
      # (Each stack: its depth, its frames, outermost first, and how many
      # samples in a row had it. None at all without samples.)
      raw = results.fetch(:raw, []) #: Array[Integer]
      i = 0
      while i < raw.size
        depth = raw.fetch(i)
        stack = Array.new(depth) { |j| names.fetch(raw.fetch(i + 1 + j)) }
        count = raw.fetch(i + 1 + depth)
        i += depth + 2
        next unless kept?(stack)

        samples += count
        frames[stack.last][0] += count
        stack.uniq.each { |name| frames[name][1] += count }
      end
      {"samples" => samples, "frames" => frames.sort_by { |_, (_, total)| -total }.map { |frame, (own, total)| [frame, own, total] }}
    end

    # Whether a sample, by its stack's frames' names (outermost first), is
    # of garbage collection or the benchmark's measured work: inside its
    # iterations and not paused, or, if paused, in an iteration inside the
    # innermost pause. So the work of pausing and resuming around each
    # iteration, which a Sample takes away (see Harness#leak), is left
    # out too.
    def self.kept?(stack)
      return true if GC_FRAMES.include?(stack.first)

      paused = stack.rindex(PAUSE)
      return stack.include?(ITERATE) unless paused

      iteration = stack.rindex(ITERATION)
      !iteration.nil? && iteration > paused
    end

    def initialize(profiles)
      @baseline = profiles.fetch("baseline")
      @candidate = profiles.fetch("candidate")
    end

    # [frame, own, total] for the TOP frames that gained the most samples
    # of their own: what each gained, in itself and with what it called,
    # as a share of all the baseline's samples (+0.05: 5% more CPU there).
    def grew
      base = counts(@baseline)
      whole = samples
      # (Only frames the candidate has can have gained.)
      @candidate.fetch("frames").filter_map do |frame, own_now, total_now|
        # (Steep takes the default for an Array of any length.)
        own_was, total_was = base.fetch(frame, [0, 0]) #: [Integer, Integer]
        next if own_now <= own_was || GC_FRAMES.include?(frame)

        [frame, (own_now - own_was) / whole, (total_now - total_was) / whole] #: growth
      end.sort_by { |_, own, _| -own }.first(TOP)
    end

    # What garbage collection gained, as a share of all the baseline's
    # samples: collecting the garbage of each sample before the next (a
    # profile's samples hold the collector off, as measured ones do).
    def gc = (collecting(@candidate) - collecting(@baseline)) / samples

    def to_h = {"grew" => grew, "gc" => gc, "baseline" => trimmed(@baseline), "candidate" => trimmed(@candidate)}

    private

    def samples = [@baseline.fetch("samples"), 1].max.to_f

    def counts(profile) = profile.fetch("frames").to_h { |frame, own, total| [frame, [own, total]] }

    # A profile's samples in garbage collection.
    def collecting(profile) = profile.fetch("frames").find { |frame, _, _| frame == GC }&.last || 0

    def trimmed(profile) = {"samples" => profile.fetch("samples"), "frames" => profile.fetch("frames").first(KEPT)}
  end
end
