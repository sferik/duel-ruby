# frozen_string_literal: true

require_relative "../duel"

module Duel
  # What one comparison of a benchmark found (Testing::Comparison#results
  # has them): its #name, whether it #passed?, the measures it #regressed
  # on, each #timed measure's verdict and each #counted one's counts,
  # what metrics said of it (#details), its peak #memory, its iterations
  # a sample (#n), the #seconds it took, why it was #skipped or its
  # #error, and its #confirmations (the measurements that confirmed it
  # was worse, not those too close to call: see #confirm). Its writers,
  # and the rest, are @api private.
  class Result
    # Peak memory grows by more than MEMORY_RATIO, and by MEMORY_FLOOR
    # bytes at least, before it's worse (it's measured as a whole, with the
    # garbage collector working, so it isn't exact).
    # @api private
    MEMORY_RATIO = 1.1

    # @api private
    MEMORY_FLOOR = 1 << 20

    # What a sample says when no metric said anything (and what a measure
    # it said nothing of did).
    # @api private
    NOTHING_SAID = {} #: Hash[String, String]

    # The verdicts that say a timing isn't slower.
    # @api private
    CLEARED = %w[same faster].freeze

    attr_reader :name, :timed, :counted, :details, :confirmations, :n, :seconds, :skipped, :error, :memory

    # Where a regression's time went (see Profile).
    # @api private
    attr_reader :profile

    # Each worker's median of each measure judged by process (see
    # Lane#judge_processes): {metric => {"lane" => its lane's number,
    # "baseline" => [each baseline worker's], "candidate" => [...]}},
    # for across the board.
    # @api private
    attr_reader :processes

    # The measurements again that were too close to call (see #confirm).
    # @api private
    attr_reader :close_calls

    # @api private
    attr_writer :n, :seconds, :skipped, :error, :memory, :profile

    # A counted measure's (+c+'s) count an iteration (of its "n", one at
    # least): [baseline's, candidate's].
    # @api private
    def self.per_iteration(c) = [c.fetch("baseline").fdiv(c.fetch("n")), c.fetch("candidate").fdiv(c.fetch("n"))]

    # @api private
    def initialize(name)
      @name = name
      @timed = {}
      @counted = {}
      @details = {}
      @confirmations = []
      @close_calls = []
      @processes = {}
    end

    # Keeps what metrics said of a pair of samples (Metric#details): each
    # measure's latest, by version (only +measure+'s, if given).
    # @api private
    def note(base, candidate, measure = nil)
      {"baseline" => base, "candidate" => candidate}.each do |side, sample|
        said = sample["details"] || NOTHING_SAID
        said = said.slice(measure) if measure
        said.each { |name, text| (@details[name] ||= {}).store(side, text) }
      end
    end

    # The metrics on which the candidate did worse: a timed one slower, or
    # a counted one up by more than its per_iteration an iteration and its
    # per_sample a sample (counted by process, up by that much at least:
    # see Lane#count_by_process).
    # @api private
    def worse
      more = @counted.select do |_, c|
        !Metric.within?(c["more"] || (c.fetch("candidate") - c.fetch("baseline")), c.fetch("n"), per_iteration: c.fetch("per_iteration"),
          per_sample: c.fetch("per_sample"))
      end
      slower + more.keys + (more_memory? ? ["peak_memory"] : [])
    end

    # The timed metrics on which the candidate was slower.
    # @api private
    def slower = @timed.filter_map { |metric, t| metric if t.fetch("verdict") == "slower" }

    # Whether its timings say slower: one is, and none says it isn't
    # (same, or faster).
    # @api private
    def slower_in_time? = slower.any? && @timed.none? { |_, t| CLEARED.include?(t.fetch("verdict")) }

    # Whether it's to be measured again (see Runner#confirm): it looks
    # worse in every measurement so far, and there are fewer confirmations
    # than it takes to fail (Runner::CONFIRM, or one more where it's
    # #mixed?).
    # @api private
    def confirming?
      return false if regressed.empty?

      @confirmations.size < (mixed? ? Runner::CONFIRM + 1 : Runner::CONFIRM)
    end

    # Keeps +again+, a measurement of it again from scratch (see
    # Runner#confirm), as a confirmation, or sets it aside where it's too
    # close to call, up to Runner::CONFIRM times: every timing is still
    # unsettled there (none slower, none the same or faster), and each
    # measure it regressed on so far is one of them. One that can't tell
    # neither confirms it nor clears it, so it's measured again instead.
    # Returns whether +again+ was set aside.
    # @api private
    def confirm(again)
      timed = again.timed
      close = timed.all? { |_, t| t.fetch("verdict") == "unsettled" } && regressed.all? { |metric| timed.key?(metric) } &&
        @close_calls.size < Runner::CONFIRM
      (close ? @close_calls : @confirmations) << again
      close
    end

    # Whether its peak memory grew by too much (see MEMORY_RATIO).
    # @api private
    def more_memory?
      memory = @memory
      return false unless memory

      base = memory.fetch("baseline")
      memory.fetch("candidate") - base > [MEMORY_FLOOR, base * (MEMORY_RATIO - 1)].max
    end

    # Worse on a metric in the first measurement and in every confirmation.
    # Or, where no one metric is, slower in time in all of them (see
    # #mixed?): the timed metrics slower in any.
    def regressed
      return [] if @error || @skipped

      worse = agreed
      return worse unless worse.empty? && measurements.all?(&:slower_in_time?)

      measurements.flat_map(&:slower).uniq
    end

    # Whether it regressed in time on one timed metric in some
    # measurements and on another in the rest (CPU time in one,
    # instructions in the next, say), slower in every one with none saying
    # it isn't: that takes one measurement more than one metric does.
    # @api private
    def mixed? = agreed.empty? && !regressed.empty?

    # Whether it regressed on nothing, and didn't fail.
    def passed? = regressed.empty? && !@error

    # Whether a timed measure's verdict was too close to the limit to settle.
    # @api private
    def unsettled? = @timed.any? { |_, t| t.fetch("verdict") == "unsettled" }

    private

    # The first measurement and its confirmations.
    def measurements = [self, *@confirmations]

    # The metrics it was worse on in every measurement.
    def agreed = measurements.map(&:worse).reduce(:&)
  end
end
