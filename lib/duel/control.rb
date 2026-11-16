# frozen_string_literal: true

require "socket"

module Duel
  # The runner's connection to a worker: a Unix socket at a path, or
  # where there are no Unix sockets (JRuby on Windows has none), a port of
  # 127.0.0.1's, its address "127.0.0.1:PORT". (As open to the machine's
  # other processes as the plugins' servers are there.)
  # @api private
  module Control
    HOST = "127.0.0.1"
    UNIX = !defined?(UNIXServer).nil?
    TCP = /\A127\.0\.0\.1:(\d+)\z/

    # Whether a worker can reach a server on a Unix socket (see
    # Duel.unix_sockets?): not on Windows (+windows+), whose builds of
    # servers (Cygwin's, MSYS2's) have Unix sockets of their own, which
    # Windows's Ruby can't reach, nor where Ruby has none (+unix+: JRuby's,
    # on Windows).
    def self.unix_sockets?(windows:, unix: UNIX) = !windows && unix

    # A server for a worker to connect to, at +path+ (or a port, unless
    # +unix+), and its address.
    def self.listen(path, unix:)
      return [UNIXServer.new(path), path] if unix

      server = tcp_server
      [server, "#{HOST}:#{server.addr.fetch(1)}"]
    end

    # A server on a port of 127.0.0.1's that the system chose.
    # mutant:disable -- a port of nil is 0's alike: any that's free
    def self.tcp_server
      # (RBS's TCPServer.new takes a port alone, but Ruby's takes the host
      # before it.)
      TCPServer.new(HOST, 0) # steep:ignore UnexpectedPositionalArgument
    end

    # A connection to the server at +address+.
    # mutant:disable -- a host of nil is localhost, which is 127.0.0.1
    # where the tests run
    def self.connect(address)
      port = address[TCP, 1]
      port ? TCPSocket.new(HOST, Integer(port)) : UNIXSocket.new(address)
    end

    # Removes the server's socket file, once it's done with: a Unix
    # socket's.
    def self.remove(address) = (File.delete(address) unless address.match?(TCP))
  end
end
