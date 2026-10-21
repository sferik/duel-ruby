# frozen_string_literal: true

require "socket"

# Duel guards the plugin's own speed: what its metrics cost around every
# sample. The plugin is each version's library, loaded by convention
# (duel/redis), so it isn't used here (c.use :redis): that would load the
# candidate's into every worker, the baseline's too. Each worker gets a
# Redis server of its own, as the plugin would give it, for benchmarks to
# read (Duel::Redis.url).
Duel.configure do |c|
  # The repository holds Duel and its plugins, so `--base last-release`
  # compares against this plugin's newest release tag (duel-redis-v0.1.0,
  # say), not Duel's.
  c.release_tags = "duel-redis-v*"

  c.prepare(:worker) do |w|
    socket = w.path("redis.sock")
    w.spawn("redis-server", "--unixsocket", socket, "--port", "0", "--save", "", "--appendonly", "no")
    w.wait_until do
      UNIXSocket.open(socket) { |s| s.write("PING\r\n") && s.gets == "+PONG\r\n" }
    rescue SystemCallError
      false
    end
    {"DUEL_REDIS_URL" => "unix://#{socket}"}
  end
end
