# frozen_string_literal: true

require_relative "test_helper"

# The runner's connection to a worker: over a Unix socket, or a port of
# 127.0.0.1's where there are none.
class ControlTest < DuelTest
  cover "Duel::Control*"

  def connected(server, address)
    client = Thread.new { Duel::Control.connect(address).tap { |socket| socket.write("hi") } }
    accepted = server.accept
    [accepted.read(2), client.value]
  ensure
    accepted&.close
    client&.value&.close
    server.close
  end

  def test_a_unix_socket
    skip "no Unix sockets here" unless Duel::Control::UNIX

    path = File.join(short_tmpdir, "c.sock")
    server, address = Duel::Control.listen(path, unix: true)

    assert_equal path, address
    assert_kind_of UNIXServer, server
    got, socket = connected(server, address)

    assert_equal "hi", got
    assert_kind_of UNIXSocket, socket
    Duel::Control.remove(address)

    refute_path_exists path
  end

  def test_a_port
    path = File.join(short_tmpdir, "c.sock")
    server, address = Duel::Control.listen(path, unix: false)

    assert_kind_of TCPServer, server
    assert_equal "127.0.0.1", server.addr.fetch(3)
    assert_equal "127.0.0.1:#{server.addr.fetch(1)}", address
    refute_path_exists path
    got, socket = connected(server, address)

    assert_equal "hi", got
    assert_kind_of TCPSocket, socket
    Duel::Control.remove(address)
  end

  def test_unix_where_there_are_unix_sockets
    assert_equal defined?(UNIXServer) ? true : false, Duel::Control::UNIX
  end

  def test_the_tcp_address
    assert_match Duel::Control::TCP, "127.0.0.1:5"
    refute_match Duel::Control::TCP, "x127.0.0.1:5"
    refute_match Duel::Control::TCP, "127.0.0.1:5\n/x"
    refute_match Duel::Control::TCP, "127.0.0.1:"
    refute_match Duel::Control::TCP, "127.0.0.1:x"
    refute_match Duel::Control::TCP, "/tmp/127.0.0.1:5"
  end
end
