# frozen_string_literal: true

module Duel
  # What the runner and a worker say to each other, over the worker's
  # socket: plain Hashes, Arrays, Strings, numbers, true, false and nil,
  # marshaled. Not JSON: the worker would load json before it loads the
  # version it measures, and in json's own repository, every baseline
  # worker would load the candidate's json first, and the baseline's
  # over it. Marshal is Ruby's own, with nothing to load (so a version's
  # code is the first of it the worker loads), and it keeps a String's
  # encoding. (Both ends are Duel's own processes, and the socket is in
  # the run's own directory.)
  # @api private
  module Message
    # Sends +message+ over +io+.
    def self.write(io, message) = io.write(Marshal.dump(message))

    # The next message over +io+, or nil once the other end has closed it.
    def self.read(io)
      Marshal.load(io)
    rescue EOFError
      nil
    end
  end
end
