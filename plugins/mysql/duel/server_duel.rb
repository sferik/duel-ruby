# frozen_string_literal: true

require_relative "duel_helper"

# The plugin's connection to the worker's own server (see .duel.rb).
setup { @connection = Duel::MySQL::Connection.new(Duel::MySQL.socket) }
teardown { @connection.close }

# A reading of the server, over its connection: its queries, and
# Trilogy's results of them. Judged on its allocations alone: the
# server's time to answer isn't the plugin's, and varies with what else
# the machine does. (No other connection runs a statement: it doesn't
# wait for the server to settle.)
duel "read: a reading of a server's 50 statements, none ran since", only: :count do
  once do
    # (Each a statement of its own: its column's name isn't a constant.)
    @connection.execute(Array.new(50) { |i| "SELECT #{i} AS c#{i}" }.join("; "))
    @statements = Duel::MySQL::Statements.new(Canned::Worker.new(@connection))
    @statements.read
    # (A reading reads the statements run a little before the one before
    # it too: these were run long enough before.)
    sleep 2.1
    @statements.read
  end
  @statements.read
end
