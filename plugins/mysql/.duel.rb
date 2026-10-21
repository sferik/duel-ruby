# frozen_string_literal: true

require "digest"
require "fileutils"
require "trilogy"

# The plugin guards its own speed, each version loaded as a gem's is
# (duel/mysql, from its lib/). It isn't used here (c.use): that would
# load the candidate's plugin into the runner and every worker, and the
# baseline's workers would load theirs over it. So each worker's server
# is started here, as the plugin starts one, and benchmarks read it with
# their version's code (Duel::MySQL.socket, from DUEL_MYSQL_SOCKET).
Duel.configure do |c|
  # The repository holds Duel and its plugins, so `--base last-release`
  # compares against this plugin's newest release tag (duel-mysql-v0.1.0,
  # say), not Duel's.
  c.release_tags = "duel-mysql-v*"

  # The plugin's options (Duel::MySQL::OPTIONS): the server its
  # benchmarks read is one it would start.
  options = %w[
    --skip-networking --mysqlx=OFF --skip-log-bin
    --innodb-buffer-pool-size=32M --innodb-redo-log-capacity=8M --innodb-doublewrite=OFF --innodb-use-native-aio=OFF
    --innodb-flush-log-at-trx-commit=0 --innodb-stats-auto-recalc=OFF --event-scheduler=OFF --performance-schema=ON
  ]

  c.prepare(:worker) do |w|
    server = ENV.fetch("DUEL_MYSQL_SERVER", "mysqld")
    files = server.include?(File::SEPARATOR) ? [server] : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, server) }
    program = files.find { |file| File.executable?(file) } || w.failed("no #{server} on the PATH (or DUEL_MYSQL_SERVER)")
    # (Its options come first: mysqld takes --no-defaults only there.)
    run = ->(data) { [program, "--no-defaults", "--datadir=#{data}", *options] }

    # A data directory initialized once, for this server and these
    # options, and copied for each worker.
    real = File.realpath(program)
    template = w.cached("duel-mysql-perf-#{Digest::SHA256.hexdigest([real, File.mtime(real).to_f, *options].join("\0"))[0, 16]}") do |dir|
      File.write(w.path("init.sql"), "CREATE DATABASE duel;\n")
      w.run(*run.call(dir), "--initialize-insecure", "--init-file=#{w.path("init.sql")}", log: "mysqld-initialize")
    end
    FileUtils.cp_r(template, w.path("data"))

    socket = w.path("mysqld.sock")
    w.spawn(*run.call(w.path("data")), "--socket=#{socket}", "--pid-file=#{w.path("mysqld.pid")}", "--tmpdir=#{w.dir}",
      "--innodb-fast-shutdown=2")
    w.wait_until do
      Trilogy.new(socket:, database: "duel").discard!
    rescue Trilogy::Error
      false
    end
    {"DUEL_MYSQL_SOCKET" => socket}
  end
end
