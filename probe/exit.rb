# Probe for https://github.com/sferik/duel-ruby/issues/5: which spawns of
# the shell's `exit 3` end on Windows, and which hang.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "duel/process_sample"
require "tmpdir"

WAIT = 15

def env(*names) = {"PATH" => ENV.fetch("PATH")}.merge(names.to_h { |name| [name, ENV.fetch(name)] })

LOG = File.join(Dir.tmpdir, "probe.log")
ONCE = {in: File::NULL, out: [LOG, "w"], err: [:child, :out], close_others: true}

# [name, env, command, spawn options, whether to open a handle as ProcessSample does]
CASES = [
  ["bare: PATH only", env, ["exit 3"], {unsetenv_others: true}, false],
  ["bare: + SystemRoot", env("SystemRoot"), ["exit 3"], {unsetenv_others: true}, false],
  ["bare: + COMSPEC", env("COMSPEC"), ["exit 3"], {unsetenv_others: true}, false],
  ["bare: + both", env("SystemRoot", "COMSPEC"), ["exit 3"], {unsetenv_others: true}, false],
  ["bare: whole environment", {}, ["exit 3"], {}, false],
  ["cmd /c: PATH only", env, ["cmd.exe", "/c", "exit 3"], {unsetenv_others: true}, false],
  ["once's options: PATH only", env, ["exit 3"], ONCE.merge(unsetenv_others: true), false],
  ["once's options: + SystemRoot", env("SystemRoot"), ["exit 3"], ONCE.merge(unsetenv_others: true), false],
  ["once's options + handle: PATH only", env, ["exit 3"], ONCE.merge(unsetenv_others: true), true],
  ["once's options + handle: + SystemRoot", env("SystemRoot"), ["exit 3"], ONCE.merge(unsetenv_others: true), true],
  ["once's options + handle: + both", env("SystemRoot", "COMSPEC"), ["exit 3"], ONCE.merge(unsetenv_others: true), true],
  ["once's options + handle: Ruby's exit 3", env, [RbConfig.ruby, "-e", "exit 3"], ONCE.merge(unsetenv_others: true), true]
]

puts RUBY_DESCRIPTION
results = CASES.map do |name, environment, command, options, handle|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pid = Process.spawn(environment, *command, **options)
  spawned = Duel::Native::Windows::Spawned.open(pid) if handle
  waiter = Thread.new { Duel::Native::Child.wait(pid) }
  outcome =
    if waiter.join(WAIT)
      code, = waiter.value
      extra = spawned ? " cycles=#{spawned.cycles} peak=#{spawned.peak.inspect}" : ""
      "exit #{code.inspect} in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)}s#{extra}"
    else
      tasks = `tasklist /FI "PID eq #{pid}"`.lines.last.to_s.strip
      system("taskkill", "/T", "/F", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
      waiter.join(5)
      "HUNG #{WAIT}s (tasklist: #{tasks})"
    end
  spawned&.close
  log = File.exist?(LOG) ? File.read(LOG).strip : ""
  File.delete(LOG) if File.exist?(LOG)
  line = format("%-42s %s%s", name, outcome, log.empty? ? "" : " log=#{log.inspect}")
  puts line
  line
end

# And the way the test hung: ProcessSample.once itself.
thread = Thread.new { Duel::ProcessSample.once(["exit 3"], env, Dir.tmpdir, LOG) }
once = thread.join(WAIT) ? thread.value.inspect : "HUNG #{WAIT}s"
puts format("%-42s %s", "ProcessSample.once: PATH only", once)

File.open(ENV.fetch("GITHUB_STEP_SUMMARY", File::NULL), "a") do |summary|
  summary.puts "### #{RUBY_DESCRIPTION}", "", "```", *results, "ProcessSample.once: PATH only  #{once}", "```"
end
