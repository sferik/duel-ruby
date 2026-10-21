# frozen_string_literal: true

require "socket"

# The plugin guards its own speed: what it does around every sample. Its
# benchmarks read a memcached server's statistics as the plugin does, so
# each worker gets a server of its own, started here, not by the plugin:
# using it (c.use :memcached) would load the candidate's plugin into Duel
# (and the baseline's workers would then load the baseline's over it). The plugin
# itself is loaded as any gem is, from each version's lib/.
Duel.configure do |c|
  # The repository holds Duel and its plugins, so `--base last-release`
  # compares against this plugin's newest release tag (duel-memcached-v0.1.0,
  # say), not Duel's.
  c.release_tags = "duel-memcached-v*"

  c.prepare(:worker) do |w|
    socket = w.path("memcached.sock")
    w.spawn("memcached", "-s", socket, "-m", "32", "-t", "1")
    w.wait_until do
      UNIXSocket.open(socket) { |s| s.write("version\r\n") && s.gets.to_s.start_with?("VERSION ") }
    rescue SystemCallError, IOError
      false
    end
    {"DUEL_MEMCACHED_BENCHMARK_SERVER" => socket}
  end
end
