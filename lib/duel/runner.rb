# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../duel"
require_relative "stats"
require_relative "profile"
require_relative "across"
require_relative "message"
require_relative "resource"
require_relative "rubies"
require_relative "process_sample"
require_relative "memory"

module Duel
  # The most seconds each benchmark runs before it's measured, unless
  # --warm says: until each worker is steady (see Lane#steady), as long
  # as that takes. JRuby's and TruffleRuby's JITs keep compiling for
  # seconds, and some code is still several times faster at 5 than it
  # was, so they get up to a minute.
  # @api private
  JIT_WARM = {"jruby" => 60.0, "truffleruby" => 60.0}.fetch(RUBY_ENGINE, 0.0)

  # The most seconds each benchmark runs before it's measured where a
  # worker has YJIT on (an app may turn it on as it boots, as Rails
  # does), unless --warm says. A small library's methods are compiled
  # within the warm-up samples, but a big app's only after 120 calls
  # each, more than a slow benchmark's warm-up samples make.
  # @api private
  YJIT_WARM = 10.0

  # Worker processes of each version, by default: enough for an interval
  # over processes (see Lane#judge_processes), which takes 5 at 99%, and
  # more, as it narrows with each. JRuby's and TruffleRuby's are JVMs,
  # slow to start and big (some 500 MB), so they get fewer.
  # @api private
  PROCESSES = {"jruby" => 8, "truffleruby" => 8}.fetch(RUBY_ENGINE, 12)

  # The CPUs for each lane of workers, by default (see CLI#parse): half
  # the CPUs make lanes, so that each lane's pair of workers has a CPU of
  # its own. JRuby's and TruffleRuby's JIT compilers keep other CPUs busy,
  # and each of their workers is a big JVM, so they get a lane for every
  # four: more lanes are no faster there, and take more memory.
  # @api private
  CPUS_PER_LANE = {"jruby" => 4, "truffleruby" => 4}.fetch(RUBY_ENGINE, 2)

  # The seconds a worker may take to load, or to answer a request, by
  # default (see Settings#timeout). JRuby's and TruffleRuby's JVMs take a
  # while to start, and with -Xbatch (see Rubies::JRUBY_WORKER), they
  # compile as they load too: 16 at once can take over a minute.
  # @api private
  TIMEOUT = {"jruby" => 300.0, "truffleruby" => 300.0}.fetch(RUBY_ENGINE, 60.0)

  # The seconds a run measures for, at most, by default (see
  # Settings#time_limit and Runner#out_of_time?): two hours, as on JRuby,
  # a benchmark can take half a minute to warm up.
  TIME_LIMIT = 7200.0

  # How a run is set up (see Duel::CLI for where each comes from).
  # @api private
  # Of +jobs+ and +processes+, +fit+ names those Duel may lower to fit
  # the memory available (see Runner#fit): the defaults, but not what
  # an option set.
  Settings = Struct.new(:base, :base_dir, :candidate_dir, :filter, :jobs, :processes, :limit, :confidence, :warm, :force,
    :config_path, :timeout, :ruby, :comment, :fail_on, :pushed, :target, :time_limit, :accepted, :fit) do
    # @type self: singleton(Settings)
    def self.defaults = new(filter: //, jobs: 1, processes: PROCESSES, limit: 1.02, confidence: 0.99, warm: nil, force: false,
      timeout: TIMEOUT, time_limit: TIME_LIMIT, fit: [])
  end

  # One version as a run has it (see Runner#prepare), +name+d "baseline"
  # or "candidate": its tree (+root+), the Ruby its processes run on
  # (Config#ruby), and what they get in their environment (that Ruby's,
  # and what its Config#prepare(:version) blocks gave it).
  # @api private
  Side = Struct.new(:name, :root, :ruby, :env, :engine) do
    # @type self: singleton(Side)

    # Each version with nothing prepared: its tree, on the runner's Ruby.
    def self.unprepared(config, settings, base_root)
      {"baseline" => new("baseline", File.expand_path(base_root), RbConfig.ruby, {}, RUBY_ENGINE),
       "candidate" => new("candidate", File.expand_path(settings.candidate_dir || config.root), RbConfig.ruby, {}, RUBY_ENGINE)}
    end
  end

  class Side
    # What each version's workers, their directories and their sockets
    # are named for (see #label): "base" and "head", as long as each
    # other, so that the two versions' workers get arguments and
    # environments of the same length. Where a process's stack starts
    # depends on how long they are, and at some lengths, the same code
    # runs the same instructions in more cycles: a version whose workers'
    # were a byte longer could measure slower in every one.
    LABELS = {"baseline" => "base", "candidate" => "head"}.freeze

    # What its workers, and its version's resources, are named for: "base"
    # or "head".
    def label = LABELS.fetch(name)
  end

  # A worker process (Duel::Worker) running one version of the code.
  # @api private
  class WorkerProcess
    LIB = File.expand_path("..", __dir__)
    # Seconds between looks at a worker that's loading, or ending.
    POLL = 0.01
    # Seconds a worker may take to end, once its connection is closed,
    # before it's killed.
    STOP_WAIT = 10
    # The gems that are Duel's: Duel, and its plugins (duel-redis, say).
    DUEL_GEM = /\Aduel(-|\z)/

    attr_reader :label, :benchmarks, :metrics, :memory, :profiler, :yjit

    # The Ruby it runs on (RUBY_DESCRIPTION), the native extensions it
    # loaded (see Worker.extensions), those it loaded twice (see
    # Worker.twice), and the directories gems are installed in (see
    # Worker.gem_dirs).
    attr_reader :description, :extensions, :twice, :gem_dirs

    # Where a worker on +ruby+ loads Duel from, ahead of anything else
    # (a version's own bundle, which may not have Duel, or an older one):
    # the runner's Duel, and every Duel gem (+specs+) the runner loaded
    # (its plugins), so both versions are measured with the same. On the
    # runner's own Ruby, Duel's dependencies (Fiddle) too: on another,
    # their builds wouldn't load.
    def self.load_path(ruby, specs: Gem.loaded_specs)
      duel = specs.select { |name, _| name.match?(DUEL_GEM) }.values
      none = [] #: Array[Gem::BasicSpecification]
      dependencies = Rubies.runner?(ruby) ? specs["duel"]&.runtime_dependencies.to_a.filter_map { |d| specs[d.name] } : none
      [LIB, *(duel + dependencies).flat_map(&:full_require_paths)].uniq
    end

    # +timeout+: the seconds it may take to load, or to answer a request,
    # before it's taken for hung (and killed). It runs on +ruby+ (whose
    # engine is +engine+), with +env+, and on JRuby, the JVM's options for
    # a worker (see Rubies.worker_environment), not given to the processes
    # it starts for a process benchmark (see #run): their boot is measured
    # as it is.
    def initialize(label, root, candidate_root, dir, config_path:, env:, timeout:, ruby:, engine:)
      @label = label
      @timeout = timeout
      @root = root
      @dir = dir
      @env = env
      @ruby = ruby
      control = File.join(dir, "#{label}.sock")
      server = UNIXServer.new(control)
      # (A nil config_path is left out. And the worker gets no other
      # worker's connection: TruffleRuby's sockets aren't close-on-exec,
      # and one left open in another worker would keep it from ending.)
      @pid = Process.spawn(Rubies.worker_environment(env, engine), ruby, *WorkerProcess.load_path(ruby).flat_map { |lib| ["-I", lib] }, "-r", "duel/worker",
        "-e", "Duel::Worker.main(*ARGV)", root, candidate_root, control, *[config_path].compact, in: File::NULL, close_others: true)
      @socket = accept(server, control)
      hello = read
      @benchmarks = hello.fetch("benchmarks").to_h { |b| [b.fetch("name"), b] }
      @metrics = hello.fetch("metrics")
      @memory = hello.fetch("memory")
      @profiler = hello.fetch("profiler")
      @yjit = hello.fetch("yjit")
      @description = hello.fetch("ruby")
      @extensions = hello.fetch("extensions")
      @twice = hello.fetch("twice")
      @gem_dirs = hello.fetch("gem_dirs")
    end

    # Sends a request, and returns the reply, or raises Failed with its
    # error.
    def request(op, name, **args)
      # (By name: +args+ come by keyword, as Symbols.)
      Message.write(@socket, {"op" => op, "name" => name, **args.transform_keys(&:to_s)})
      reply = read
      raise Failed, "#{@label}: #{reply.fetch("error")}\n  #{reply.fetch("backtrace").join("\n  ")}" if reply.key?("error")

      reply
    end

    def sample(name, n, runs: 1, count: false) = request("sample", name, n: n, runs: runs, count: count)

    # A run of a process benchmark (see DSL#duel_process): +process+, a
    # fresh process, started as this worker was (on its Ruby, in its
    # version's tree, with its environment), and measured (see
    # ProcessSample#run).
    def run(process)
      # (Code, without a command.)
      code = process.fetch("ruby") #: String
      command = process.fetch("command") || [@ruby, "-I", File.join(@root, "lib"), "-e", code]
      runs = @runs ||= ProcessSample.new(@label, env: @env, chdir: @root, log: File.join(@dir, "#{@label}.log"), timeout: @timeout)
      runs.run(command)
    end

    # Closing the connection ends the worker. One still running +wait+
    # seconds later is killed.
    def stop(wait: STOP_WAIT)
      @runs&.stop
      @socket.close
      deadline = monotonic + wait
      sleep POLL until (gone = Process.wait(@pid, Process::WNOHANG)) || monotonic > deadline
      kill unless gone
    rescue Errno::ECHILD # gone already
      nil
    end

    private

    # The worker's connection, once it has loaded (or Failed if it died,
    # or took too long, first).
    def accept(server, path)
      deadline = monotonic + @timeout
      until server.wait_readable(POLL)
        raise Failed, "#{@label} worker exited while loading" if Process.wait(@pid, Process::WNOHANG)
        hung("load") if monotonic > deadline
      end
      server.accept
    ensure
      server.close
      File.delete(path)
    end

    def read
      hung("answer") unless @socket.wait_readable(@timeout)
      Message.read(@socket) or raise Failed, "#{@label} worker exited"
    end

    # Kills a worker that didn't +what+ within the timeout, and fails.
    def hung(what)
      kill
      raise Failed, "#{@label} worker didn't #{what} within #{@timeout}s (killed: a benchmark that hangs?)"
    end

    def kill
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # What Duel raises when something a run needs fails: a resource that
  # didn't start (Resource#failed), two that set a variable differently,
  # a worker that died or hung.
  class Failed < Error; end

  # Workers of both versions, taking turns: Settings#processes of each
  # (PROCESSES, by default). Where things landed in one process's memory
  # can make the very same code a few percent faster or slower for that
  # process's whole life, so the interval is over the workers, where
  # they're enough for one (see #judge_processes), and not over the
  # pairs, which share them. Each worker has its own resources
  # (Config#prepare(:worker)).
  # @api private
  class Lane
    # CPU time (or a plugin's ratio metric's equivalent) a run aims for:
    # long enough that a clock's resolution is lost in it. A sample is the
    # fastest of RUNS runs.
    TARGET_NS = 1_000_000
    RUNS = 5
    WARMUP = 5
    # A process benchmark's pairs before any are measured (of one run
    # each), and the most runs a sample of it takes (unless it says: see
    # DSL#duel_process): as many as take PROCESS_SAMPLE_NS of CPU time,
    # each sample the fastest of them.
    PROCESS_WARMUP = 1
    PROCESS_RUNS = 3
    PROCESS_SAMPLE_NS = 1_000_000_000
    # The most a run may allocate, in bytes (see Sample#heap): it all stays
    # until the run is over, as the garbage collector is held off.
    HEAP_CAP = 64 << 20
    # Pairs are taken in rounds of STEP until the verdict is clear (a
    # process benchmark's: see #judge).
    STEP = 10
    MAX_PAIRS = 60
    # A benchmark judged by process (see #judge_processes) is decided from
    # its MIN_ROUNDS-th round of a sample from every worker, a sample
    # each takes, and up to PROCESS_PAIRS pairs.
    MIN_ROUNDS = 4
    PROCESS_PAIRS = 120
    # Counts are each version's fewest in COUNTS samples, or where a
    # version is on JRuby, JRUBY_COUNTS: its count of bytes allocated
    # takes one of two values, some 31 bytes an iteration apart, sample by
    # sample, and the fewest of more are the lower one.
    COUNTS = 3
    JRUBY_COUNTS = 10
    # A count by process (see #count_by_process) is each worker's fewest
    # in COUNT_ROUNDS rounds of a sample from every worker.
    COUNT_ROUNDS = 3
    # Peak memory is each version's least in MEMORY_SAMPLES fresh workers.
    MEMORY_SAMPLES = 3
    # A profile: PROFILE_SAMPLES samples of the benchmark (some 5,000 of
    # StackProf's a version: enough to tell a few percent apart).
    PROFILE_SAMPLES = 500

    attr_reader :profiler

    # Its workers start at once, each with its resources (a database
    # server takes seconds), and stop at once. +sides+ are the versions as
    # the run prepared them (Runner#prepare), by name.
    def initialize(config, settings, sides, processes: settings.processes)
      @id = Lane.next_id
      @dir = Lane.tmpdir
      @resources = []
      @workers = []
      @lock = Mutex.new
      @config = config
      @settings = settings
      @sides = sides
      workers = %w[baseline candidate].product(Array.new(processes) { |i| i }) #: Array[[String, Integer]]
      started = in_parallel(workers) { |side, index| spawn(side, index) }
      @bases = started.first(processes)
      @candidates = started.drop(processes)
      @profiler = @candidates.first.profiler
      @warm = settings.warm || (started.any?(&:yjit) ? YJIT_WARM : JIT_WARM)
      check_builds
    rescue Exception # rubocop:disable Lint/RescueException
      stop
      raise
    end

    @ids = 0
    @ids_lock = Mutex.new

    # A number of its own for each lane, from 1: what tells one lane's
    # workers from another's (see Result#processes).
    # mutant:disable -- CRuby doesn't switch threads in the middle of += on an Integer, and JRuby can
    def self.next_id = @ids_lock.synchronize { @ids += 1 }

    # Whether +processes+ workers of each version are enough for a
    # +confidence+ interval over them (see Stats.shift_rank): 5 at 99%.
    def self.by_process?(processes, confidence) = !Stats.shift_rank(processes, processes, confidence).nil?

    # A directory for a lane's sockets, short as a Unix socket's path must
    # be (see .short_tmp).
    def self.tmpdir = Dir.mktmpdir("duel", short_tmp)

    # The longest +tmpdir+ a lane's directory goes in: a resource's socket
    # there (Resource#path) must stay within a Unix socket path's 104 bytes.
    SHORT = 40

    # Where lanes' directories go: +tmpdir+ (TMPDIR) if it's that short,
    # else /tmp (macOS's TMPDIR is long). Windows has no /tmp, so its own
    # TMP, however long.
    def self.short_tmp(tmpdir = Dir.tmpdir, windows: Native::WINDOWS) = (windows || tmpdir.size <= SHORT) ? tmpdir : "/tmp"

    # Opens a lane, yields it and always closes it.
    def self.open(config, settings, sides, processes: settings.processes)
      # @type var lane: Lane
      lane = new(config, settings, sides, processes:)
      yield lane
    ensure
      lane&.stop
    end

    def benchmarks = @candidates.first.benchmarks

    # The Ruby each version runs on (RUBY_DESCRIPTION), by version.
    def rubies = {"baseline" => @bases.first.description, "candidate" => @candidates.first.description}

    # Stops its workers, then their resources: each worker's last first
    # (one may need another), the workers' at once.
    def stop
      in_parallel(@workers) { |worker| worker.stop }
      in_parallel(@resources.group_by(&:name).values) { |resources| resources.reverse_each(&:stop) }
      FileUtils.rm_rf(@dir)
    end

    # Measures one benchmark on both versions, and returns its Result. (A
    # process benchmark's workers have nothing to set up: its samples are
    # processes of their own.)
    def compare(name)
      result = Result.new(name)
      started = monotonic
      if benchmarks.fetch(name).fetch("process")
        measure_process(name, result)
      else
        set_up(name, result)
        return result if result.skipped

        begin
          measure(name, result)
        ensure
          each_worker { |worker| worker.request("teardown", name) }
        end
      end
      result.seconds = monotonic - started
      result
    end

    # Profiles of the benchmark on each version (+n+ iterations a
    # sample): {"baseline" =>, "candidate" =>}, or nil without StackProf.
    def profile(name, n)
      return unless @profiler

      # @type var sides: Hash[String, WorkerProcess]?
      sides = {"baseline" => @bases.first, "candidate" => @candidates.first}
      sides.each_value { |worker| worker.request("setup", name) }
      sides.transform_values { |worker| worker.request("profile", name, n: n, runs: PROFILE_SAMPLES) }
    ensure
      sides&.each_value { |worker| worker.request("teardown", name) }
    end

    private

    # A worker of +side+, with its own resources, and its version's Ruby
    # and environment.
    def spawn(side, index)
      version = @sides.fetch(side)
      label = "#{version.label}-#{index + 1}"
      env = version.env
      @config.prepares.fetch(:worker).each_with_index do |block, i|
        resource = Resource.new(File.join(@dir, "#{label}-#{i + 1}"), label, version.root, timeout: @settings.timeout,
          cache: File.join(@config.state, "cache"), ruby: version.ruby, env: version.env)
        keep(@resources, resource)
        env = Resource.environment(label, env, block.call(resource))
      end
      worker = WorkerProcess.new(label, version.root, @sides.fetch("candidate").root, @dir,
        config_path: @settings.config_path, env: env, timeout: @settings.timeout, ruby: version.ruby, engine: version.engine)
      keep(@workers, worker)
      worker
    end

    # Fails if a version's workers loaded a native extension that isn't a
    # build of its own: one in the other version's tree, or one where the
    # other version loaded the same from its own tree (an installed gem's,
    # say). A checkout without a build of its own (see Config#build)
    # quietly loads whichever build it finds, and the comparison wouldn't
    # be of its code. An installed gem's extension (in the directories
    # gems are installed in, by the worker that loaded it) is in no
    # version's tree, even in a bundle there (vendor/bundle, say, which
    # both versions may load from). And fails if a version's workers
    # loaded one twice (see Worker.twice): the candidate's, that something
    # required before Duel loaded the version, and then its own over it.
    def check_builds
      workers = {"baseline" => @bases.first, "candidate" => @candidates.first}
      workers.each do |side, worker|
        worker.twice.each do |feature, paths|
          raise Failed, "the #{side} loaded #{feature} twice, from #{paths.join(" and ")}: something required it before " \
            "Duel loaded the #{side}, and both stay loaded. Require what loads it in a block that runs once the version " \
            "has loaded (c.in_worker, in .duel.rb), not as .duel.rb or a plugin loads"
        end
        other = (side == "baseline") ? "candidate" : "baseline"
        theirs = workers.fetch(other).then { |w| w.extensions.select { |_, path| inside?(path, other, w) } }
        worker.extensions.each do |feature, path|
          next if inside?(path, side, worker) || !(inside?(path, other, worker) || theirs.key?(feature))

          raise Failed, "the #{side} loaded #{path}, not a build of its own: #{feature} isn't built in " \
            "#{@sides.fetch(side).root}. Set c.build in .duel.rb to build each version (by default, it's " \
            "`bundle exec rake compile` for a project with ext/ and a Rakefile)"
        end
      end
    end

    # Whether +path+ (a real path, that +worker+ loaded) is in +side+'s
    # tree, and not in an installed gem (in +worker+'s gem directories).
    def inside?(path, side, worker)
      root = @sides.fetch(side).root
      path.start_with?(File.join(File.exist?(root) ? File.realpath(root) : root, "")) &&
        worker.gem_dirs.none? { |dir| path.start_with?(dir) }
    end

    # Adds +item+ to +list+, from a thread of its own (see #in_parallel).
    # mutant:disable -- CRuby's Array#<< is atomic anyway, and JRuby's isn't
    def keep(list, item) = @lock.synchronize { list << item }

    def each_worker(&) = (@bases + @candidates).each(&)

    # Sets the benchmark up in every worker, the first candidate first (a
    # benchmark that fails there is broken) and the first baseline next
    # (one that fails there is new: skipped), then the rest at once.
    def set_up(name, result)
      @candidates.first.request("setup", name)
      begin
        @bases.first.request("setup", name)
      rescue Failed => e
        @candidates.first.request("teardown", name)
        result.skipped = "not on the baseline (#{e.message.lines.first.chomp})"
        return
      end
      in_parallel(@bases.drop(1) + @candidates.drop(1)) { |worker| worker.request("setup", name) }
    end

    # What's measured: ratio metrics' measures are in a sample's "timed",
    # counted ones' in its "counted".
    def metrics = @candidates.first.metrics

    # Whether workers start (and stop) at once: not on TruffleRuby, whose
    # Process.spawn, closing other descriptors (see WorkerProcess), fails
    # when another thread closes one meanwhile.
    PARALLEL = RUBY_ENGINE != "truffleruby"

    # What the block returns for each item, each on a thread of its own
    # (one after another, unless PARALLEL). Every one finishes before the
    # first that failed, if any, raises.
    def in_parallel(items, &)
      return items.map(&) unless PARALLEL

      threads = items.map do |item|
        Thread.new do
          Thread.current.report_on_exception = false
          yield item
        end
      end
      threads.each do |thread|
        thread.join
      rescue
        nil # (raised by #value, once they're all done)
      end
      threads.map(&:value)
    end

    def measure(name, result)
      benchmark = benchmarks.fetch(name)
      only = benchmark.fetch("only")
      if only == "count"
        count(name, result.n = COUNTS_ONLY, result)
        return
      end

      timings_only = !only.nil? # (the only other choice)
      target = timings_only ? TARGET_NS * 10 : TARGET_NS
      n = calibrate(name, target, 1)
      warm(name, n)
      n = calibrate(name, target, n) if @warm.positive? # it may have got faster
      floors = Array.new(WARMUP) { |i| pair(name, n, i) }
      # (It got faster still, a JIT got to it, say: sized again, unless
      # what it allocates holds it there.)
      if below_cpu_floor?(floors) && (sized = calibrate(name, target, n)) > n
        n = sized
        floors = Array.new(WARMUP) { |i| pair(name, n, i) }
      end
      result.n = n
      count(name, n, result) unless timings_only
      peak_memory(name, n, result) if benchmark.fetch("peak_memory")
      judge(name, n, floors, result)
    end

    # A process benchmark's samples (see DSL#duel_process): each the
    # fastest of a few fresh processes (see #pair and #process_runs), as
    # its one iteration, paired as any other's, after PROCESS_WARMUP pairs
    # (the first runs read files the disk's cache hasn't yet), and each
    # version's least peak memory, where it can be told.
    def measure_process(name, result)
      @peaks = {"baseline" => [], "candidate" => []}
      result.n = 1
      floors = Array.new(PROCESS_WARMUP) { |i| pair(name, 1, i) }
      # (A process benchmark's.)
      process = benchmarks.fetch(name).fetch("process") #: Definition::process
      judge(name, process.fetch("runs") || process_runs(floors), floors, result)
      return if @peaks.values.flatten.include?(nil)

      # (Each told, so each least is.)
      least = @peaks.transform_values(&:min) #: Hash[String, Integer]
      result.memory = least
    end

    # The runs a process benchmark's sample takes, by its warm-up's
    # samples (+floors+, of a run each): as many as take
    # PROCESS_SAMPLE_NS of CPU time on the slower version, up to
    # PROCESS_RUNS, and one at least. A short process varies the most, and
    # the fastest of a few is steadier, but a long one's pairs take long
    # enough as they are.
    def process_runs(floors)
      longest = floors.flatten.map { |sample| sample.fetch("timed").fetch("cpu") }.max #: Integer
      # (Any number, for one that took none at all.)
      PROCESS_SAMPLE_NS.fdiv(longest).clamp(1, PROCESS_RUNS).floor
    end

    # Every worker runs the benchmark a few times, and then, all at once
    # (none of it is measured, so they needn't take turns), for the
    # seconds --warm says (Settings#warm), or else until it's steady (see
    # #steady), for JIT_WARM's or YJIT_WARM's seconds at most.
    def warm(name, n)
      warm_until = monotonic + @warm
      in_parallel(@bases + @candidates) do |worker|
        2.times { worker.sample(name, n) }
        if @settings.warm
          worker.sample(name, n) until monotonic > warm_until
        else
          steady(worker, name, n, warm_until)
        end
      end
    end

    # A worker's warm-up ends once STEADY_WINDOWS windows of STEADY
    # seconds in a row each have a median of its samples no faster, by
    # STEADY_GAIN, than the last window that was (so code that creeps
    # faster by less a window isn't steady): a JIT has compiled what it
    # will. (Not once its fastest sample stops getting
    # faster: the more samples, the faster the fastest of them, by
    # chance. And not once one window is no faster: a pause, a collection
    # say, can slow one.) A small library's code is steady in a few
    # seconds, where a big app's JIT keeps compiling, for up to the
    # warm-up's seconds.
    STEADY = 0.5
    STEADY_GAIN = 0.01
    STEADY_WINDOWS = 3

    # Samples +worker+ (+n+ iterations each), STEADY seconds at a time,
    # until it's steady, or it's +warm_until+.
    def steady(worker, name, n, warm_until)
      window, now = window(worker, name, n, warm_until)
      return if now > warm_until

      fastest = Stats.median(window)
      calm = 0
      loop do
        window, now = window(worker, name, n, warm_until)
        return if now > warm_until

        median = Stats.median(window)
        if median > fastest * (1 - STEADY_GAIN)
          calm += 1
          return if calm == STEADY_WINDOWS
        else
          calm = 0
          fastest = median
        end
      end
    end

    # STEADY seconds of +worker+'s samples' CPU time (a sample at least),
    # or until +warm_until+, and when they ended.
    def window(worker, name, n, warm_until)
      window_until = monotonic + STEADY
      samples = [] #: Array[Metric::value]
      loop do
        samples << worker.sample(name, n).fetch("timed").fetch("cpu")
        now = monotonic
        return [samples, now] if now > window_until || now > warm_until
      end
    end

    # Takes pairs until every ratio metric worth judging (measured on
    # both versions in the warm-up, and above its floors on either: one
    # that rises from next to nothing is judged too) is decided, or
    # MAX_PAIRS run out: each decided at the end of a round of STEP pairs,
    # and each interval over the pairs. That's for a process benchmark, or
    # too few workers for an interval over them: otherwise, see
    # #judge_processes. A process benchmark's pairs take a process each,
    # so it's decided not slower (Result::CLEARED) after any pair too.
    # That can only stop it before it would have been found slower, never
    # make it slower: it's found slower only at the end of a round, as any
    # benchmark is.
    def judge(name, n, floors, result)
      judged = metrics.select do |spec|
        floors.flatten.all? { |sample| sample.fetch("timed").key?(spec.fetch("name")) } &&
          floors.transpose.any? { |side| above_floors?(side.map { |sample| sample.fetch("timed") }, spec) }
      end
      return judge_processes(name, n, judged, result) if by_process?(name)

      ratios = judged.to_h { |spec| [spec.fetch("name"), []] }
      # @type var raw: Hash[String, Array[[Metric::value, Metric::value]]]
      raw = judged.to_h { |spec| [spec.fetch("name"), []] }
      pending = judged.dup
      every = benchmarks.fetch(name).fetch("process")
      (0...MAX_PAIRS).each do |i|
        break if pending.empty?

        base, candidate = pair(name, n, i)
        result.note(base, candidate)
        ratios.each do |metric, list|
          values = [base.fetch("timed").fetch(metric), candidate.fetch("timed").fetch(metric)] #: [Metric::value, Metric::value]
          raw.fetch(metric) << values
          list << values.last.fdiv([values.first, 1].max)
        end
        round = ((i + 1) % STEP).zero?
        next unless round || every

        pending.reject! { |spec| decided?(verdict(ratios.fetch(spec.fetch("name")), spec), round) }
      end
      judged.each do |spec|
        list = ratios.fetch(spec.fetch("name"))
        medians = raw.fetch(spec.fetch("name")).transpose.map { |values| Stats.median(values) }
        result.timed[spec.fetch("name")] = {"median" => Stats.median(list), "limit" => limit(spec), "across" => spec.fetch("across"),
                                            "unit" => spec.fetch("unit"), "plural" => spec.fetch("plural"),
                                            "interval" => Stats.median_interval(list, @settings.confidence),
                                            "pairs" => list.size, "verdict" => verdict(list, spec).to_s,
                                            "baseline" => medians.fetch(0), "candidate" => medians.fetch(1)}
      end
    end

    # Whether a benchmark's timings are judged by process (see
    # #judge_processes): unless it's a process benchmark (each of its
    # samples is a fresh process already, so its pairs are independent),
    # or there are too few workers of each version for an interval over
    # them (Lane.by_process?).
    def by_process?(name) = !benchmarks.fetch(name).fetch("process") && Lane.by_process?(@bases.size, @settings.confidence)

    # Takes rounds of pairs, each a sample from every worker of each
    # version (the baseline's in order, paired with the candidate's in
    # turn: each round pairs each with another), until every ratio metric
    # judged (see #judge) is decided, from the second round on, or
    # #rounds run out. Each worker's median is a sample, and the interval
    # is over workers (Stats.shift_interval): where a process's luck
    # makes it faster or slower than another for its whole life (where
    # things landed in its memory, or what a JIT compiled), the interval
    # is as wide as that makes it. An interval over pairs would be as
    # narrow as if every pair had processes of its own. Each worker's
    # medians are kept, by metric, for across the board (Result#processes).
    def judge_processes(name, n, judged, result)
      k = @bases.size
      # @type var values: Hash[String, Hash[String, Array[Array[Metric::value]]]]
      values = judged.to_h { |spec| [spec.fetch("name"), {"baseline" => Array.new(k) { [] }, "candidate" => Array.new(k) { [] }}] }
      pending = judged.dup
      pairs = 0
      rounds(k).times do |round|
        break if pending.empty?

        k.times do |i|
          j = (i + round) % k
          base, candidate = sampled(name, n, @bases.fetch(i), @candidates.fetch(j), base_first: i.even? == round.even?)
          result.note(base, candidate)
          values.each do |metric, sides|
            sides.fetch("baseline").fetch(i) << base.fetch("timed").fetch(metric)
            sides.fetch("candidate").fetch(j) << candidate.fetch("timed").fetch(metric)
          end
          pairs += 1
        end
        next if round + 1 < MIN_ROUNDS

        pending.reject! { |spec| decided?(process_verdict(medians(values.fetch(spec.fetch("name"))), spec), true) }
      end
      judged.each do |spec|
        metric = spec.fetch("name")
        each = medians(values.fetch(metric))
        bases, candidates = clamped(each)
        result.timed[metric] = {"median" => Stats.shift(bases, candidates), "limit" => limit(spec), "across" => spec.fetch("across"),
                                "unit" => spec.fetch("unit"), "plural" => spec.fetch("plural"),
                                "interval" => Stats.shift_interval(bases, candidates, @settings.confidence),
                                "pairs" => pairs, "processes" => k, "verdict" => process_verdict(each, spec).to_s,
                                "baseline" => Stats.median(each.fetch("baseline")), "candidate" => Stats.median(each.fetch("candidate"))}
        result.processes[metric] = {"lane" => @id, "baseline" => each.fetch("baseline"), "candidate" => each.fetch("candidate")}
      end
    end

    # The most rounds of +k+ workers' pairs: as many as make
    # PROCESS_PAIRS pairs, and MIN_ROUNDS at least.
    def rounds(k) = [PROCESS_PAIRS / k, MIN_ROUNDS].max

    # Each worker's median, by version, of +values+ (each worker's
    # measures, by version).
    def medians(values) = values.transform_values { |lists| lists.map { |list| Stats.median(list) } }

    # The baseline's medians (of +each+) at least 1, as the ratio's
    # denominator (so a ratio to nothing is one to 1, as a pair's is),
    # and the candidate's.
    def clamped(each) = [each.fetch("baseline").map { |value| [value, 1].max }, each.fetch("candidate")]

    def process_verdict(each, spec)
      bases, candidates = clamped(each)
      Stats.decide(Stats.shift_interval(bases, candidates, @settings.confidence), limit(spec))
    end

    # Whether both versions' CPU time in +floors+ is below its floor: then
    # it wouldn't be judged at all.
    def below_cpu_floor?(floors)
      cpu = metrics.find { |spec| spec.fetch("name") == "cpu" } #: Metric::spec
      floors.transpose.none? { |side| above_floors?(side.map { |sample| sample.fetch("timed") }, cpu) }
    end

    # Whether +samples+ (one version's timed measures) are above +spec+'s
    # floors (the median): its own, and its share of CPU time.
    def above_floors?(samples, spec)
      values = samples.map { |sample| sample.fetch(spec.fetch("name")) }
      cpu = samples.map { |sample| sample.fetch("cpu") }
      median = Stats.median(values)
      median >= spec.fetch("floor") && median * spec.fetch("unit_ns") >= spec.fetch("cpu_floor") * Stats.median(cpu)
    end

    def limit(spec) = spec.fetch("limit") || @settings.limit

    # The verdicts that decide a measure at the end of a round (see
    # #judge), and after any other pair: only those that clear it.
    DECISIVE = {true => [:slower, :faster, :same], false => [:faster, :same]}.freeze #: Hash[bool, Array[Stats::verdict]]

    # Whether +verdict+ decides a measure, at the end of a +round+ or not.
    def decided?(verdict, round) = DECISIVE.fetch(round).include?(verdict)

    def verdict(ratios, spec) = Stats.verdict(ratios, limit: limit(spec), confidence: @settings.confidence)

    # The iterations per sample (from +n+ up) whose fastest run takes
    # about +target+ on the first candidate, by its largest timed metric
    # that sizes samples (CPU time does), found while warming up (twice in
    # a row: a cold run may look like enough), and that allocate no more
    # than HEAP_CAP a run.
    def calibrate(name, target, n)
      units = metrics.select { |spec| spec.fetch("sizes_samples") }.to_h { |spec| [spec.fetch("name"), spec.fetch("unit_ns")] }
      reached = 0
      until reached == 2
        sample = pair(name, n, 0, runs: 3).last
        # (CPU time sizes samples, and is always measured.)
        timed = sample.fetch("timed")
        work = units.filter_map { |metric, unit| timed[metric]&.*(unit) }.max #: Metric::value
        most = most_iterations(n, sample.fetch("heap"))
        if most <= n
          # (Finite, when it's at most n.)
          return most #: Integer
        end

        reached = (work >= target) ? reached + 1 : 0
        next unless reached.zero?

        # (An Integer: most is finite, or more.)
        n = [(n * (target * 1.2 / work).clamp(2, 100)).ceil, most].min #: Integer
      end
      n
    end

    # The most iterations whose allocations fit HEAP_CAP, by +heap+ bytes
    # over +n+ (at least one, and any number when it allocated nothing).
    def most_iterations(n, heap)
      return Float::INFINITY unless heap.positive?

      [n * HEAP_CAP / heap, 1].max
    end

    # The +index+th pair: a sample (of +n+ iterations) from a baseline
    # worker and from a candidate worker, each pair of workers in turn,
    # baseline first on even pairs. A process benchmark's sample is the
    # fastest of +n+ runs (see #measure_process), the two versions' taking
    # turns: so interference, which only ever adds time, is mostly left
    # out, and weighs on both alike.
    def pair(name, n, index, runs: RUNS, count: false)
      k = @bases.size
      sampled(name, n, @bases.fetch(index % k), @candidates.fetch((index + (index / k)) % k), base_first: index.even?, runs:, count:)
    end

    # A sample (of +n+ iterations) from +base+, a baseline worker, and
    # from +candidate+, a candidate worker, the baseline's first if
    # +base_first+ (see #pair).
    def sampled(name, n, base, candidate, base_first:, runs: RUNS, count: false)
      order = base_first ? [base, candidate] : [candidate, base]
      process = benchmarks.fetch(name).fetch("process")
      replies = if process
        # (Each run of one version's next to one of the other's.)
        each_run = Array.new(n) { order.map { |worker| worker.run(process) } }
        order.zip(each_run.transpose).to_h do |worker, samples|
          # (Never nil: each worker in order has its runs.)
          ran = samples #: Array[ProcessSample::sampled]
          [worker, ProcessSample.fastest(ran)]
        end
      else
        order.to_h { |worker| [worker, worker.sample(name, n, runs: runs, count: count)] }
      end
      if process
        @peaks.fetch("baseline") << replies.fetch(base).fetch("peak")
        @peaks.fetch("candidate") << replies.fetch(candidate).fetch("peak")
      end
      [replies.fetch(base), replies.fetch(candidate)]
    end

    # Each counted measure's fewest, on each version, over COUNTS pairs of
    # samples, and what its metric said of those samples.
    def count(name, n, result)
      return count_by_process(name, n, result) if Lane.by_process?(@bases.size, @settings.confidence)

      samples = Array.new(counts) { |i| pair(name, n, i, runs: 1, count: true) }
      metrics.each do |spec|
        metric = spec.fetch("name")
        base, candidate = samples.transpose.map do |side|
          side.select { |sample| sample.fetch("counted").key?(metric) }.min_by { |sample| sample.fetch("counted").fetch(metric) }
        end
        next unless base && candidate

        result.counted[metric] = {"baseline" => base.fetch("counted").fetch(metric), "candidate" => candidate.fetch("counted").fetch(metric),
                                  "n" => n, "tolerance" => spec.fetch("tolerance"), "allowance" => spec.fetch("allowance"),
                                  "unit" => spec.fetch("unit"), "plural" => spec.fetch("plural")}
        result.note(base, candidate, metric)
      end
    end

    # Each counted measure, with workers enough for an interval over them
    # (see #judge_processes): each worker's fewest in COUNT_ROUNDS rounds
    # of a sample from every worker, and how much more the candidate's
    # are than the baseline's, at least (the low end of an interval for
    # it, Stats.difference_interval), which is what's judged (see
    # Result#worse). Where every worker's is the same, as CRuby's counts
    # of objects are, that's exactly how many more. Where they differ, as
    # JRuby's bytes do where one JVM's JIT does away with an allocation
    # and another's doesn't, it's as little as the workers can tell.
    # Each version's own is the median of its workers'.
    def count_by_process(name, n, result)
      k = @bases.size
      # @type var fewest: Hash[String, Hash[String, Hash[Integer, Metric::value]]]
      fewest = Hash.new do |h, metric|
        none = {} #: Hash[Integer, Metric::value]
        h[metric] = {"baseline" => none, "candidate" => none.dup}
      end
      COUNT_ROUNDS.times do |round|
        k.times do |i|
          j = (i + round) % k
          base, candidate = sampled(name, n, @bases.fetch(i), @candidates.fetch(j), base_first: i.even? == round.even?, runs: 1, count: true)
          fewest!(fewest, "baseline", i, base)
          fewest!(fewest, "candidate", j, candidate)
          result.note(base, candidate)
        end
      end
      metrics.each do |spec|
        metric = spec.fetch("name")
        next unless fewest.key?(metric)

        found = fewest.fetch(metric)
        bases = found.fetch("baseline").values
        candidates = found.fetch("candidate").values
        next if bases.empty? || candidates.empty?

        result.counted[metric] = {"baseline" => Stats.median(bases), "candidate" => Stats.median(candidates),
                                  "more" => Stats.difference_interval(bases, candidates, @settings.confidence)&.first,
                                  "n" => n, "tolerance" => spec.fetch("tolerance"), "allowance" => spec.fetch("allowance"),
                                  "unit" => spec.fetch("unit"), "plural" => spec.fetch("plural")}
      end
    end

    # Keeps each count of +sample+ (from +side+'s +worker+th worker) in
    # +fewest+, where it's that worker's fewest so far.
    def fewest!(fewest, side, worker, sample)
      sample.fetch("counted").each do |metric, value|
        least = fewest[metric].fetch(side)
        least[worker] = [least[worker], value].compact.min
      end
    end

    # The samples a count takes: JRUBY_COUNTS where a version is on JRuby,
    # or else COUNTS.
    def counts = (@sides.each_value.any? { |side| side.engine == "jruby" }) ? JRUBY_COUNTS : COUNTS

    # Each version's least peak memory over MEMORY_SAMPLES fresh workers
    # (a long-lived one has room left over from earlier work), turn about.
    # Fresh means no trial run either: the allocator keeps what that freed,
    # and the measured run would reuse it rather than grow.
    def peak_memory(name, n, result)
      return unless @candidates.first.memory

      # @type var peaks: Hash[String, Array[Integer]]
      peaks = {"baseline" => [], "candidate" => []}
      MEMORY_SAMPLES.times do |i|
        sides = i.even? ? %w[baseline candidate] : %w[candidate baseline]
        sides.each do |side|
          peaks.fetch(side) << fresh(side) do |worker|
            worker.request("setup", name, trial: false)
            worker.request("memory", name, n: n).fetch("peak")
          end
        end
      end
      result.memory = peaks.transform_values(&:min)
    end

    # Yields a worker of +side+ of its own, set up for nothing yet, then
    # stops it and its resources.
    def fresh(side)
      # @type var workers: Integer
      # @type var resources: Integer
      workers = @workers.size
      resources = @resources.size
      worker = spawn(side, @workers.size)
      yield worker
    ensure
      @workers.pop(@workers.size - workers).each(&:stop)
      @resources.pop(@resources.size - resources).reverse_each(&:stop)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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
    attr_reader :undecided

    # @api private
    attr_writer :n, :seconds, :skipped, :error, :memory, :profile

    # @api private
    def initialize(name)
      @name = name
      @timed = {}
      @counted = {}
      @details = {}
      @confirmations = []
      @undecided = []
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
    # a counted one up by more than its tolerance per iteration and its
    # allowance per sample (counted by process, up by that much at least:
    # see Lane#count_by_process).
    # @api private
    def worse
      more = @counted.select do |_, c|
        !Metric.within?(c["more"] || (c.fetch("candidate") - c.fetch("baseline")), c.fetch("n"), tolerance: c.fetch("tolerance"),
          allowance: c.fetch("allowance"))
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
    # undecided there (none slower, none the same or faster), and each
    # measure it regressed on so far is one of them. One that can't tell
    # neither confirms it nor clears it, so it's measured again instead.
    # Returns whether +again+ was set aside.
    # @api private
    def confirm(again)
      timed = again.timed
      close = timed.all? { |_, t| t.fetch("verdict") == "undecided" } && regressed.all? { |metric| timed.key?(metric) } &&
        @undecided.size < Runner::CONFIRM
      (close ? @undecided : @confirmations) << again
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

      agreed = measurements.map(&:worse).reduce(:&)
      return agreed unless agreed.empty? && measurements.all?(&:slower_in_time?)

      measurements.flat_map(&:slower).uniq
    end

    # Whether it regressed in time on one timed metric in some
    # measurements and on another in the rest (CPU time in one,
    # instructions in the next, say), slower in every one with none saying
    # it isn't: that takes one measurement more than one metric does.
    # @api private
    def mixed? = measurements.map(&:worse).reduce(:&).empty? && !regressed.empty?

    # Whether it regressed on nothing, and didn't fail.
    def passed? = regressed.empty? && !@error

    # Whether a timed measure's verdict was too close to the limit to settle.
    # @api private
    def unsettled? = @timed.any? { |_, t| t.fetch("verdict") == "undecided" }

    private

    # The first measurement and its confirmations.
    def measurements = [self, *@confirmations]
  end

  # Measures every benchmark, confirms what looks worse, and reports.
  # @api private
  class Runner
    # Measurements of each suspect, from scratch, before it fails.
    CONFIRM = 3

    # +number+ of +noun+, in its plural for any number but one ("1
    # benchmark", "2 benchmarks").
    def self.count(number, noun, plural = "#{noun}s") = "#{number} #{(number == 1) ? noun : plural}"

    # A count, an iteration's (a Float, often): to four figures, or one of
    # NUMBER or more (where four figures would be 1e+04) as a whole number
    # (25736 bytes, not 2.574e+04).
    def self.number(value) = (value.abs >= NUMBER) ? value.round.to_s : format("%.4g", value)

    # The least count #number shows as a whole number.
    NUMBER = 9_999.5

    # Across the board (see Across): {metric => verdict}, "confirmed" in
    # those slower in a second measurement too. Set by #run.
    attr_reader :across

    # The Ruby each version ran on (RUBY_DESCRIPTION), by version, and the
    # seconds the run took. Set by #run.
    attr_reader :rubies, :seconds

    # What the run left undone when it reached its time limit
    # (Settings#time_limit): {"unmeasured" => the benchmarks it didn't
    # measure, "unconfirmed" => those it judged without every
    # measurement again (see #confirm), "across" => whether it judged
    # across the board without measuring every benchmark again (see
    # #judge_across)}, or nil where it reached none. Set by #run.
    def cut_short
      return if @unmeasured.empty? && @unconfirmed.empty? && !@across_cut

      {"unmeasured" => @unmeasured, "unconfirmed" => @unconfirmed, "across" => @across_cut}
    end

    def initialize(config, settings, base_root, out: $stdout)
      @config = config
      @settings = settings
      @base_root = base_root
      @out = out
      @prepared = []
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @lock = Mutex.new
      @unmeasured = [] #: Array[String]
      @unconfirmed = [] #: Array[String]
      @across_cut = false
    end

    # Returns the Results.
    def run
      CycleClock.prepare
      started = @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @dir = Lane.tmpdir
      begin
        compare_all(started)
      ensure
        @prepared.reverse_each(&:stop)
        FileUtils.rm_rf(@dir)
        Resource.evict(File.join(@config.state, "cache"))
      end
    end

    # Whether nothing got slower: no benchmark, nor all of them together,
    # and none failed.
    def passed?(results) = results.all?(&:passed?) && regressed_across.empty?

    def regressed_across = @across.select { |_, v| v["confirmed"] }.keys

    # What a run cut short at its time limit left undone (see #cut_short),
    # or nil where it wasn't.
    def cut_short_note
      return unless cut_short

      undone = [("#{Runner.count(@unmeasured.size, "benchmark")} not measured" unless @unmeasured.empty?),
        ("#{Runner.count(@unconfirmed.size, "benchmark")} judged without measuring every one again" unless @unconfirmed.empty?),
        ("across the board judged without measuring again" if @across_cut)].compact
      "the run measured for longer than #{limit_text}: #{undone.join(", ")}. Raise --time-limit, or make the slowest " \
        "benchmarks quicker to settle"
    end

    # Whether the run has measured for longer than its time limit
    # (Settings#time_limit). Then it starts nothing more: a benchmark it
    # hasn't measured is an error, unmeasured, and what looked worse is
    # judged on the measurements it has, without measuring it again. It
    # fails what still looks worse in all of them, so a run cut short
    # never passes a regression it would have failed. Each measurement it
    # started runs to its end.
    def out_of_time? = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started > @settings.time_limit

    # The plugins the configuration used (Config#plugins), by name.
    def plugins = @config.plugins

    # What a regression's report says of it, line by line: each worse
    # measure an iteration, what its metric said, and where the extra CPU
    # went (see Profile).
    def explained(result) = explanation(result) + profile_lines(result.profile)

    private

    # What #run does, with its versions prepared in its directory.
    def compare_all(started)
      @sides = prepare
      fit
      names, results = with_lanes do |lanes|
        found = lanes.first.benchmarks.keys.grep(@settings.filter)
        @benchmarks = lanes.first.benchmarks
        @out.puts "Comparing #{Runner.count(found.size, "benchmark")}, #{@settings.jobs} at a time: baseline #{@base_root} " \
          "against candidate #{File.expand_path(@settings.candidate_dir || @config.root)} (slower: a " \
          "#{(@settings.confidence * 100).round(1)}% interval above #{@settings.limit}, #{interval_over})"
        rubies = @rubies = lanes.first.rubies
        rubies.each { |side, ruby| @out.puts "  #{side} on #{ruby}" } if rubies.values.uniq.size > 1
        @out.puts "  with plugins #{plugins.join(", ")}" unless plugins.empty?
        [found, measure_all(lanes, found)]
      end
      confirm(results.select { |r| r.worse.any? })
      @across = judge_across(results, names)
      profile(results.select { |r| (r.regressed & r.timed.keys).any? && !@benchmarks.fetch(r.name).fetch("process") })
      report(results, @seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      results
    end

    # What a benchmark's interval is over (see Lane#judge_processes): the
    # workers, or the pairs, where they're too few (and says how many it
    # takes, of the first PROCESSES_CHECKED).
    # mutant:disable -- fewer than 2 of each never take an interval over them, and the last checked is only a bound
    def interval_over
      processes = @settings.processes
      workers = Runner.count(processes, "worker process", "worker processes")
      return "over #{workers} of each version" if Lane.by_process?(processes, @settings.confidence)

      least = (1..PROCESSES_CHECKED).find { |k| Lane.by_process?(k, @settings.confidence) }
      "over pairs: #{workers} of each version are too few for an interval over them" + (least ? ", which takes #{least}" : "")
    end

    # The most workers of each version #interval_over looks at, for how
    # many it takes (more would take long to check, and longer to run).
    PROCESSES_CHECKED = 20

    # Each version, prepared once for the run, before any of its workers
    # start: its Ruby found (Config#ruby, or --ruby), and its
    # Config#prepare(:version) blocks run, each given a Resource (named for
    # the version) whose processes stop when the run ends.
    def prepare
      choice = @settings.ruby || @config.ruby
      Side.unprepared(@config, @settings, @base_root).transform_values do |side|
        side.ruby = Rubies.find(choice, side.root, side.name)
        side.env = Rubies.environment(side.ruby)
        side.engine = Rubies.engine(side.ruby)
        @config.prepares.fetch(:version).each_with_index do |block, i|
          resource = Resource.new(File.join(@dir, "#{side.label}-#{i + 1}"), side.label, side.root, timeout: @settings.timeout,
            cache: File.join(@config.state, "cache"), ruby: side.ruby, env: side.env)
          @prepared << resource
          side.env = Resource.environment(side.label, side.env, block.call(resource))
        end
        side
      end
    end

    # The memory Runner#fit leaves for everything but the workers and
    # their resources: the runner, the system, and other processes.
    RESERVE = 1 << 30

    # How much more than what it took to start a pair of workers takes
    # while it measures (its heap grows, and so do its resources'), by
    # Runner#fit's reckoning.
    HEADROOM = 1.25

    # How many times what a worker took as it started one on a JIT's
    # engine takes once it's warm, by Runner#fit's reckoning, as the JIT
    # compiles: a TruffleRuby worker that started at some 510 MB grew to
    # some 1.5 GB (and HEADROOM covers the rest).
    JIT_GROWTH = {"truffleruby" => 2.5}.freeze

    # Lowers Settings#jobs, and then Settings#processes, as far as
    # Settings#fit lets it, where their workers (and each one's
    # resources, a database server, say) wouldn't fit in the memory
    # available: more than that and the machine swaps, or a CI runner
    # stops answering and its job is lost. What one worker of each
    # version takes is found by starting them (a lane of them), and every
    # pair is taken to need that, HEADROOM over (and on a JIT's engine,
    # JIT_GROWTH times that, as its workers grow as they warm up), or what
    # the plugins say each worker's resources take at most
    # (Config#worker_memory), if that's more: a database server takes
    # more as it's used.
    def fit
      return if @settings.fit.empty?

      available = Memory.available or return
      taken = Lane.open(@config, @settings, @sides, processes: 1) { available - (Memory.available || available) }
      said = 2 * @config.worker_memory
      growth = @sides.each_value.map { |side| JIT_GROWTH.fetch(side.engine, 1.0) }.max
      pair = [(taken * HEADROOM * growth).ceil, said].max
      return unless pair.positive?

      pairs = [(available - RESERVE) / pair, 1].max
      processes = @settings.fit.include?(:processes) ? [@settings.processes, pairs].min : @settings.processes
      # (More jobs than the settings' are never taken: only fewer are.)
      jobs = @settings.fit.include?(:jobs) ? [pairs / processes, 1].max : @settings.jobs
      fewer = [("#{Runner.count(jobs, "benchmark")} at a time (not #{@settings.jobs})" if jobs < @settings.jobs),
        ("#{Runner.count(processes, "worker")} of each version (not #{@settings.processes})" if processes < @settings.processes)].compact
      return if fewer.empty?

      takes = if said == pair then "#{gigabytes(said)} GB, with its resources, as its plugins say"
      elsif growth > 1 then "#{gigabytes(taken)} GB, with its resources, as it starts, and some #{growth}x that once warm"
      else "#{gigabytes(taken)} GB, with its resources"
      end
      @out.puts "A worker of each version takes #{takes}, of #{gigabytes(available)} GB available, so to fit: #{fewer.join(", and ")}"
      @settings.jobs = jobs
      @settings.processes = processes
    end

    # +bytes+ in gigabytes, to a tenth.
    def gigabytes(bytes) = format("%.1f", bytes.fdiv(1 << 30))

    def with_lanes
      # @type var lanes: Array[Lane]
      lanes = []
      @settings.jobs.times { lanes << open_lane }
      yield lanes
    ensure
      lanes.each(&:stop)
    end

    # The verdicts across the board. Those slower are measured again,
    # every benchmark, in fresh processes, and are confirmed if they're
    # still slower.
    def judge_across(results, names)
      verdicts = across_of(results).verdicts
      slower = verdicts.select { |_, v| v.fetch("verdict") == "slower" }.keys
      return verdicts if slower.empty?

      if out_of_time?
        # (Judged on the one measurement: slower in it, so slower.)
        @across_cut = true
        @out.puts "\nSlower across the board in #{slower.join(", ")}, not measured again: the run reached its time limit (#{limit_text})"
        slower.each { |metric| verdicts.fetch(metric)["confirmed"] = true }
        return verdicts
      end

      @out.puts "\nMeasuring every benchmark again, in fresh processes: slower across the board in #{slower.join(", ")}?"
      again = across_of(with_lanes { |lanes| measure_all(lanes, names) }).verdicts
      slower.each { |metric| verdicts.fetch(metric)["confirmed"] = again.dig(metric, "verdict") == "slower" }
      verdicts
    end

    # Across the board, of +results+, judged over workers where the run
    # judged benchmarks over them (see Lane.by_process?).
    # mutant:disable -- whether it's over workers is only how fast: results judged over pairs have no workers' medians to find
    def across_of(results) = Across.new(results, confidence: @settings.confidence, by_process: Lane.by_process?(@settings.processes, @settings.confidence))

    def open_lane = Lane.new(@config, @settings, @sides)

    def measure_all(lanes, names)
      queue = Queue.new(names.each_with_index)
      queue.close
      # @type var results: Array[Result]
      results = []
      lanes.each_index.map do |i|
        Thread.new do
          while (name, index = queue.deq)
            if out_of_time?
              results[index] = unmeasured(name)
              next
            end

            result = results[index] = attempt(lanes.fetch(i), name)
            @out.print "#{line(result)}\n" # (in one write: other threads write too)
            next unless result.error

            # Its workers may be gone: the next benchmark gets new ones.
            lanes.fetch(i).stop
            lanes[i] = open_lane
          end
        end
      end.each(&:join)
      results
    end

    def attempt(lane, name)
      lane.compare(name)
    rescue Failed, SystemCallError, IOError => e
      Result.new(name).tap { |r| r.error = "#{e.class}: #{e}" }
    end

    # A benchmark the run reached its time limit before it measured: an
    # error, so the run fails. (Each lane's thread adds to the list.)
    # mutant:disable -- CRuby's Array#<< is atomic anyway, and JRuby's isn't
    def unmeasured(name)
      @lock.synchronize { @unmeasured << name }
      Result.new(name).tap { |r| r.error = "not measured: the run reached its time limit (#{limit_text})" }
    end

    def limit_text = "#{@settings.time_limit.round}s, --time-limit"

    # Measures each suspect again, from scratch, in fresh processes, until
    # one measurement clears it or CONFIRM agree (and once more for each
    # too close to call, up to CONFIRM more: see Result#confirm).
    def confirm(suspects)
      return if suspects.empty?

      @out.puts "\nMeasuring #{Runner.count(suspects.size, "benchmark")} that looked worse again, in fresh processes, up to " \
        "#{CONFIRM} times each (#{CONFIRM + 1} if what's slower differs, and once more for each too close to call):"
      suspects.each do |result|
        while result.confirming?
          if out_of_time?
            @unconfirmed << result.name
            @out.puts format("  %-48s judged on %s: the run reached its time limit (%s)", result.name,
              Runner.count(result.confirmations.size + 1, "measurement"), limit_text)
            break
          end
          again = Lane.open(@config, @settings, @sides) { |lane| attempt(lane, result.name) }
          @out.puts line(again) + (result.confirm(again) ? "  (too close to call: once more)" : "")
        end
      end
    end

    # Profiles each version on every benchmark slower in time, and keeps
    # the frames whose share of the CPU grew the most (see Profile).
    def profile(regressed)
      regressed.each do |result|
        # (Measured, so with an n, since it regressed.)
        n = result.n #: Integer
        profiles = Lane.open(@config, @settings, @sides, processes: 1) { |lane| lane.profile(result.name, n) }
        result.profile = profiles ? Profile.new(profiles).to_h : {"unavailable" => Profile::UNAVAILABLE}
      rescue Failed, SystemCallError, IOError => e
        result.profile = {"unavailable" => "#{e.class}: #{e}"}
      end
    end

    def report(results, seconds)
      regressed = results.reject { |r| r.regressed.empty? }
      errors = results.select(&:error)
      @out.puts
      @across.each do |metric, v|
        low, high = v.fetch("interval")
        next unless low # (too few benchmarks to say)

        @out.puts format("across the board: %s %.3f [%.3f, %.3f] %s (limit %.4f, %d benchmarks)", metric, v.fetch("median"),
          low, high, v.fetch("verdict"), v.fetch("limit"), v.fetch("benchmarks"))
      end
      both = @across_cut ? "slower, not measured again (the run reached its time limit)" : "slower in both measurements"
      regressed_across.each { |metric| @out.puts "REGRESSION across the board: #{metric} #{both}" }
      errors.each { |r| @out.puts "ERROR #{r.name}: #{r.error}" }
      cut_short_note&.then { |note| @out.puts "TIME LIMIT: #{note}" }
      regressed.each do |r|
        @out.puts "REGRESSION #{r.name}: " +
          (r.mixed? ? "slower in every measurement, by one of #{r.regressed.join(", ")}" : "worse #{r.regressed.join(", ")} in every measurement")
        explained(r).each { |line| @out.puts "  #{line}" }
      end
      # (Each benchmark once: a regression's timing may have been unsettled too.)
      unsettled = (results - regressed).count(&:unsettled?)
      @out.puts format("%s in %.0fs: %d regressed, %s, %d with a timing too close to the limit to settle",
        Runner.count(results.size, "benchmark"), seconds, regressed.size, Runner.count(errors.size, "error"), unsettled)
    end

    def line(result)
      return format("  %-48s skipped: %s", result.name, result.skipped) if result.skipped
      return format("  %-48s error", result.name) if result.error

      timed = result.timed.map do |metric, t|
        low, high = t.fetch("interval")
        format("%s %.3f [%.3f, %.3f] %s", metric, t.fetch("median"), low, high, t.fetch("verdict"))
      end
      # (An iteration's, as the explanation's are.)
      counted = result.counted.map do |metric, c|
        n = c.fetch("n") # (at least one)
        base = c.fetch("baseline").fdiv(n)
        candidate = c.fetch("candidate").fdiv(n)
        # (No unit its name ends in: "retained_objects 2", not "2 objects".)
        named = c.fetch("plural")&.then { |plural| metric.end_with?(plural.tr(" ", "_")) }
        [format("%s %s%s", metric, Runner.number(base), ("→#{Runner.number(candidate)}" unless base == candidate)),
          (unit(candidate, c) unless named)].compact.join(" ")
      end
      memory = result.memory&.then { |m| ["peak_memory #{mb(m.fetch("baseline"))}→#{mb(m.fetch("candidate"))}"] }
      format("%s %-48s %5.1fs n=%-6d %s", result.worse.empty? ? " " : "!", result.name, result.seconds, result.n,
        (timed + counted + memory.to_a).join("  "))
    end

    def mb(bytes) = format("%.1fMB", bytes / 1_048_576.0)

    # The unit of +measured+ (a result's measure), for +number+ of it: the
    # singular for one, the plural for any other.
    def unit(number, measured) = (number == 1) ? measured.fetch("unit") : measured.fetch("plural")

    # What each measure that's worse measured, an iteration, on each
    # version, and what its metric said of it (Metric#details).
    def explanation(result)
      # (Measured, so with an n, since it regressed.)
      n = result.n #: Integer
      result.regressed.flat_map do |metric|
        timed = result.timed[metric]
        counted = result.counted[metric]
        measured = if timed
          [format("%s: %s → %s an iteration (%.2fx)", metric, amount(timed.fetch("baseline"), n, timed),
            amount(timed.fetch("candidate"), n, timed), timed.fetch("median"))]
        elsif counted
          ["#{metric}: #{amount(counted.fetch("baseline"), n, counted)} → #{amount(counted.fetch("candidate"), n, counted)} an iteration"]
        else
          # (Peak memory: on its line already.)
          [] #: Array[String]
        end
        said = result.details[metric] || Result::NOTHING_SAID
        # (The candidate's first.)
        measured + said.sort.reverse.map { |side, text| "#{metric} (#{side}): #{text}" }
      end
    end

    # +value+ (a sample's, of +n+ iterations) an iteration, in the unit of
    # +measured+ (a result's timed or counted measure): a time unit as
    # time, in the largest unit it makes at least one of, and any other after
    # the number.
    def amount(value, n, measured)
      each = value.fdiv([n, 1].max)
      ns = Metric::TIME_UNITS[measured.fetch("unit")]
      return [Runner.number(each), unit(each, measured)].compact.join(" ") unless ns

      time = each * ns
      shown, size = Metric::TIME_UNITS.reverse_each.find { |_, unit_ns| time >= unit_ns } || ["ns", 1]
      format("%.4g%s", time / size, shown)
    end

    def profile_lines(profile)
      return [] unless profile
      return ["profile: #{profile.fetch("unavailable")}"] if profile.key?("unavailable")

      # (A Profile's: Steep doesn't narrow on key?.)
      grew = profile.fetch("grew") #: Array[Profile::growth]
      gc = profile.fetch("gc") #: Float
      lines = ["where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
        *grew.map { |frame, own, total| format("  %+6.1f%% %+6.1f%%  %s", own * 100, total * 100, frame) }]
      lines << format("  %+6.1f%%          in garbage collection, apart from the code", gc * 100) unless gc.zero?
      lines
    end
  end
end
