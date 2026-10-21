# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../duel"
require_relative "stats"
require_relative "profile"
require_relative "across"
require_relative "resource"

module Duel
  # Seconds each benchmark runs before it's measured: JRuby's and
  # TruffleRuby's JITs keep compiling for seconds (YJIT's is done within
  # the warm-up samples).
  # @api private
  JIT_WARM = {"jruby" => 5.0, "truffleruby" => 5.0}.fetch(RUBY_ENGINE, 0.0)

  # How a run is set up (see Duel::CLI for where each comes from).
  # @api private
  Settings = Struct.new(:base, :base_dir, :candidate_dir, :filter, :jobs, :processes, :limit, :confidence, :warm, :force,
    :config_path, :timeout) do
    # @type self: singleton(Settings)
    def self.defaults = new(filter: //, jobs: 1, processes: 3, limit: 1.02, confidence: 0.99, warm: JIT_WARM, force: false,
      timeout: 60.0)
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

    attr_reader :label, :benchmarks, :metrics, :memory, :profiler

    # +timeout+: the seconds it may take to load, or to answer a request,
    # before it's taken for hung (and killed).
    def initialize(label, root, candidate_root, dir, config_path:, env:, timeout:)
      @label = label
      @timeout = timeout
      control = File.join(dir, "#{label}.sock")
      server = UNIXServer.new(control)
      # (A nil config_path is left out. And the worker gets no other
      # worker's connection: TruffleRuby's sockets aren't close-on-exec,
      # and one left open in another worker would keep it from ending.)
      @pid = Process.spawn(env, RbConfig.ruby, "-I", LIB, "-r", "duel/worker", "-e", "Duel::Worker.main(*ARGV)",
        root, candidate_root, control, *[config_path].compact, in: File::NULL, close_others: true)
      @socket = accept(server, control)
      hello = read
      @benchmarks = hello.fetch("benchmarks").to_h { |b| [b.fetch("name"), b] }
      @metrics = hello.fetch("metrics")
      @memory = hello.fetch("memory")
      @profiler = hello.fetch("profiler")
    end

    # Sends a request; returns the reply, or raises Failed with its error.
    def request(op, name, **args)
      @socket.puts JSON.generate({"op" => op, "name" => name, **args})
      reply = read
      raise Failed, "#{@label}: #{reply.fetch("error")}\n  #{reply.fetch("backtrace").join("\n  ")}" if reply.key?("error")

      reply
    end

    def sample(name, n, runs: 1, count: false) = request("sample", name, n: n, runs: runs, count: count)

    # Closing the connection ends the worker; one still running +wait+
    # seconds later is killed.
    def stop(wait: STOP_WAIT)
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
      line = @socket.gets or raise Failed, "#{@label} worker exited"
      JSON.parse(line)
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

  # Workers of both versions, taking turns: PROCESSES of each (Settings),
  # so that where things landed in one process's memory (which can make
  # the very same code a few percent faster or slower for that process's
  # whole life) is spread over many pairs as noise the confidence
  # interval accounts for, not a bias every pair shares. Each worker has
  # its own resources (Config#resource).
  # @api private
  class Lane
    # CPU time (or a plugin's ratio metric's equivalent) a run aims for:
    # long enough that a clock's resolution is lost in it. A sample is the
    # fastest of RUNS runs.
    TARGET_NS = 1_000_000
    RUNS = 5
    WARMUP = 5
    # The most a run may allocate, in bytes (see Sample#heap): it all stays
    # until the run is over, as the garbage collector is held off.
    HEAP_CAP = 64 << 20
    # Pairs are taken in rounds of STEP until the verdict is clear.
    STEP = 10
    MAX_PAIRS = 60
    # Counts are each version's fewest in COUNTS samples.
    COUNTS = 3
    # Peak memory is each version's least in MEMORY_SAMPLES fresh workers.
    MEMORY_SAMPLES = 3
    # A profile: PROFILE_RUNS runs of PROFILE_SCALE samples' iterations
    # (some 5,000 samples a version: enough to tell a few percent apart).
    PROFILE_RUNS = 5
    PROFILE_SCALE = 100

    attr_reader :profiler

    # Its workers start at once, each with its resources (a database
    # server takes seconds), and stop at once.
    def initialize(config, settings, base_root, processes: settings.processes)
      @dir = Lane.tmpdir
      @resources = []
      @workers = []
      @lock = Mutex.new
      @config = config
      @settings = settings
      @roots = {"baseline" => File.expand_path(base_root),
                "candidate" => File.expand_path(settings.candidate_dir || config.root)}
      workers = %w[baseline candidate].product(Array.new(processes) { |i| i }) #: Array[[String, Integer]]
      started = in_parallel(workers) { |side, index| spawn(side, index) }
      @bases = started.first(processes)
      @candidates = started.drop(processes)
      @profiler = @candidates.first.profiler
    rescue Exception # rubocop:disable Lint/RescueException
      stop
      raise
    end

    # A directory for a lane's sockets, short as a Unix socket's path must
    # be (see .short_tmp).
    def self.tmpdir = Dir.mktmpdir("duel", short_tmp)

    # The longest +tmpdir+ a lane's directory goes in: a resource's socket
    # there (Resource#path) must stay within a Unix socket path's 104 bytes.
    SHORT = 40

    # Where lanes' directories go: +tmpdir+ (TMPDIR) if it's that short,
    # else /tmp (macOS's TMPDIR is long).
    def self.short_tmp(tmpdir = Dir.tmpdir) = (tmpdir.size <= SHORT) ? tmpdir : "/tmp"

    # Opens a lane, yields it and always closes it.
    def self.open(config, settings, base_root, processes: settings.processes)
      # @type var lane: Lane
      lane = new(config, settings, base_root, processes:)
      yield lane
    ensure
      lane&.stop
    end

    def benchmarks = @candidates.first.benchmarks

    # Stops its workers, then their resources: each worker's last first
    # (one may need another), the workers' at once.
    def stop
      in_parallel(@workers) { |worker| worker.stop }
      in_parallel(@resources.group_by(&:name).values) { |resources| resources.reverse_each(&:stop) }
      FileUtils.rm_rf(@dir)
    end

    # Measures one benchmark on both versions; returns its Result.
    def compare(name)
      result = Result.new(name)
      started = monotonic
      set_up(name, result)
      return result if result.skipped

      begin
        measure(name, result)
      ensure
        each_worker { |worker| worker.request("teardown", name) }
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
      sides.transform_values { |worker| worker.request("profile", name, n: n * PROFILE_SCALE, runs: PROFILE_RUNS) }
    ensure
      sides&.each_value { |worker| worker.request("teardown", name) }
    end

    private

    # A worker of +side+, with its own resources.
    def spawn(side, index)
      label = "#{side}-#{index + 1}"
      env = {} #: Hash[String, String?]
      @config.resources.each_with_index do |block, i|
        resource = Resource.new(File.join(@dir, "#{label}-#{i + 1}"), label, @roots.fetch(side), timeout: @settings.timeout,
          cache: File.join(@config.root, "tmp", "duel", "cache"))
        keep(@resources, resource)
        env = Resource.environment(label, env, block.call(resource))
      end
      worker = WorkerProcess.new(label, @roots.fetch(side), @roots.fetch("candidate"), @dir,
        config_path: @settings.config_path, env: env, timeout: @settings.timeout)
      keep(@workers, worker)
      worker
    end

    # Adds +item+ to +list+, from a thread of its own (see #in_parallel).
    # mutant:disable -- CRuby's Array#<< is atomic anyway; JRuby's isn't
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
    # (one after another, unless PARALLEL); every one finishes before the
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
      n = calibrate(name, target, n) if @settings.warm.positive? # it may have got faster
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

    # Every worker runs the benchmark a few times, and for Settings#warm
    # seconds, all at once: none of it is measured, so they needn't take
    # turns.
    def warm(name, n)
      warm_until = monotonic + @settings.warm
      in_parallel(@bases + @candidates) do |worker|
        2.times { worker.sample(name, n) }
        worker.sample(name, n) until monotonic > warm_until
      end
    end

    # Takes pairs until every ratio metric worth judging (measured on
    # both versions in the warm-up, and above its floors on either: one
    # that rises from next to nothing is judged too) is decided, or
    # MAX_PAIRS run out.
    def judge(name, n, floors, result)
      judged = metrics.select do |spec|
        floors.flatten.all? { |sample| sample.fetch("timed").key?(spec.fetch("name")) } &&
          floors.transpose.any? { |side| above_floors?(side.map { |sample| sample.fetch("timed") }, spec) }
      end
      ratios = judged.to_h { |spec| [spec.fetch("name"), []] }
      # @type var raw: Hash[String, Array[[Metric::value, Metric::value]]]
      raw = judged.to_h { |spec| [spec.fetch("name"), []] }
      pending = judged.dup
      (0...MAX_PAIRS).step(STEP) do |pairs|
        break if pending.empty?

        STEP.times do |i|
          base, candidate = pair(name, n, pairs + i)
          result.note(base, candidate)
          ratios.each do |metric, list|
            values = [base.fetch("timed").fetch(metric), candidate.fetch("timed").fetch(metric)] #: [Metric::value, Metric::value]
            raw.fetch(metric) << values
            list << values.last.fdiv([values.first, 1].max)
          end
        end
        pending.select! { |spec| verdict(ratios.fetch(spec.fetch("name")), spec) == :undecided }
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
    # over +n+ (at least one; any number when it allocated nothing).
    def most_iterations(n, heap)
      return Float::INFINITY unless heap.positive?

      [n * HEAP_CAP / heap, 1].max
    end

    # The +index+th pair: a sample from a baseline worker and from a
    # candidate worker, each pair of workers in turn, baseline first on
    # even pairs.
    def pair(name, n, index, runs: RUNS, count: false)
      k = @bases.size
      base = @bases.fetch(index % k)
      candidate = @candidates.fetch((index + (index / k)) % k)
      order = index.even? ? [base, candidate] : [candidate, base]
      replies = order.to_h { |worker| [worker, worker.sample(name, n, runs: runs, count: count)] }
      [replies.fetch(base), replies.fetch(candidate)]
    end

    # Each counted measure's fewest, on each version, over COUNTS pairs of
    # samples, and what its metric said of those samples.
    def count(name, n, result)
      samples = Array.new(COUNTS) { |i| pair(name, n, i, runs: 1, count: true) }
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
  # was worse). Its writers, and the rest, are @api private.
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

    attr_reader :name, :timed, :counted, :details, :confirmations, :n, :seconds, :skipped, :error, :memory

    # Where a regression's time went (see Profile).
    # @api private
    attr_reader :profile

    # @api private
    attr_writer :n, :seconds, :skipped, :error, :memory, :profile

    # @api private
    def initialize(name)
      @name = name
      @timed = {}
      @counted = {}
      @details = {}
      @confirmations = []
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
    # allowance per sample.
    # @api private
    def worse
      slower = @timed.select { |_, t| t.fetch("verdict") == "slower" }.keys
      more = @counted.select do |_, c|
        !Metric.within?(c.fetch("candidate") - c.fetch("baseline"), c.fetch("n"), tolerance: c.fetch("tolerance"),
          allowance: c.fetch("allowance"))
      end
      slower + more.keys + (more_memory? ? ["peak_memory"] : [])
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
    def regressed
      return [] if @error || @skipped

      [self, *@confirmations].map(&:worse).reduce(:&)
    end

    # Whether it regressed on nothing, and didn't fail.
    def passed? = regressed.empty? && !@error

    # Whether a timed measure's verdict was too close to the limit to settle.
    # @api private
    def unsettled? = @timed.any? { |_, t| t.fetch("verdict") == "undecided" }
  end

  # Measures every benchmark, confirms what looks worse, and reports.
  # @api private
  class Runner
    # Measurements of each suspect, from scratch, before it fails.
    CONFIRM = 3

    # Across the board (see Across): {metric => verdict}, "confirmed" in
    # those slower in a second measurement too. Set by #run.
    attr_reader :across

    def initialize(config, settings, base_root, out: $stdout)
      @config = config
      @settings = settings
      @base_root = base_root
      @out = out
    end

    # Returns the Results.
    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      names, results = with_lanes do |lanes|
        found = lanes.first.benchmarks.keys.grep(@settings.filter)
        @out.puts "Comparing #{found.size} benchmarks: baseline #{@base_root} against candidate " \
          "#{File.expand_path(@settings.candidate_dir || @config.root)} (#{@settings.jobs} at a time; slower means a " \
          "#{(@settings.confidence * 100).round(1)}% interval above #{@settings.limit})"
        [found, measure_all(lanes, found)]
      end
      confirm(results.select { |r| r.worse.any? })
      @across = judge_across(results, names)
      profile(results.select { |r| (r.regressed & r.timed.keys).any? })
      report(results, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      results
    end

    # Whether nothing got slower: no benchmark, nor all of them together,
    # and none failed.
    def passed?(results) = results.all?(&:passed?) && regressed_across.empty?

    def regressed_across = @across.select { |_, v| v["confirmed"] }.keys

    private

    def with_lanes
      # @type var lanes: Array[Lane]
      lanes = []
      @settings.jobs.times { lanes << open_lane }
      yield lanes
    ensure
      lanes.each(&:stop)
    end

    # The verdicts across the board; those slower are measured again,
    # every benchmark, in fresh processes, and are confirmed if they're
    # still slower.
    def judge_across(results, names)
      verdicts = Across.new(results, confidence: @settings.confidence).verdicts
      slower = verdicts.select { |_, v| v.fetch("verdict") == "slower" }.keys
      return verdicts if slower.empty?

      @out.puts "\nMeasuring every benchmark again, in fresh processes: slower across the board in #{slower.join(", ")}?"
      again = Across.new(with_lanes { |lanes| measure_all(lanes, names) }, confidence: @settings.confidence).verdicts
      slower.each { |metric| verdicts.fetch(metric)["confirmed"] = again.dig(metric, "verdict") == "slower" }
      verdicts
    end

    def open_lane = Lane.new(@config, @settings, @base_root)

    def measure_all(lanes, names)
      queue = Queue.new(names.each_with_index)
      queue.close
      # @type var results: Array[Result]
      results = []
      lanes.each_index.map do |i|
        Thread.new do
          while (name, index = queue.deq)
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

    # Measures each suspect again, from scratch, in fresh processes, until
    # one measurement clears it or CONFIRM agree.
    def confirm(suspects)
      return if suspects.empty?

      @out.puts "\nMeasuring #{suspects.size} that looked worse again, up to #{CONFIRM} times each, in fresh processes:"
      suspects.each do |result|
        CONFIRM.times do
          again = Lane.open(@config, @settings, @base_root) { |lane| attempt(lane, result.name) }
          result.confirmations << again
          @out.puts line(again)
          break if result.regressed.empty?
        end
      end
    end

    # Profiles each version on every benchmark slower in time, and keeps
    # the frames whose share of the CPU grew the most (see Profile).
    def profile(regressed)
      regressed.each do |result|
        # (Measured, so with an n, since it regressed.)
        n = result.n #: Integer
        profiles = Lane.open(@config, @settings, @base_root, processes: 1) { |lane| lane.profile(result.name, n) }
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
        range = (format(" [%.3f, %.3f]", low, high) if low)
        @out.puts format("across the board: %s %.3f%s %s (limit %.4f, %d benchmarks)", metric, v.fetch("median"), range,
          v.fetch("verdict"), v.fetch("limit"), v.fetch("benchmarks"))
      end
      regressed_across.each { |metric| @out.puts "REGRESSION across the board: #{metric} slower in both measurements" }
      errors.each { |r| @out.puts "ERROR #{r.name}: #{r.error}" }
      regressed.each do |r|
        @out.puts "REGRESSION #{r.name}: worse #{r.regressed.join(", ")} in every measurement"
        (explanation(r) + profile_lines(r.profile)).each { |explained| @out.puts "  #{explained}" }
      end
      @out.puts format("%d benchmarks in %.0fs: %d regressed, %d errors, %d with a timing too close to the limit to settle",
        results.size, seconds, regressed.size, errors.size, results.count(&:unsettled?))
    end

    def line(result)
      return format("  %-48s skipped: %s", result.name, result.skipped) if result.skipped
      return format("  %-48s error", result.name) if result.error

      timed = result.timed.map do |metric, t|
        low, high = t.fetch("interval")
        format("%s %.3f [%.3f, %.3f] %s", metric, t.fetch("median"), low, high, t.fetch("verdict"))
      end
      counted = result.counted.map do |metric, c|
        base = c.fetch("baseline")
        candidate = c.fetch("candidate")
        # (No unit its name ends in: "retained_objects 2", not "2 objects".)
        named = c.fetch("plural")&.then { |plural| metric.end_with?(plural.tr(" ", "_")) }
        ["#{metric} #{base}#{"→#{candidate}" unless base == candidate}", (unit(candidate, c) unless named)].compact.join(" ")
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
    # time, in the largest unit it makes at least one of; any other after
    # the number.
    def amount(value, n, measured)
      each = value.fdiv([n, 1].max)
      ns = Metric::TIME_UNITS[measured.fetch("unit")]
      return [format("%.4g", each), unit(each, measured)].compact.join(" ") unless ns

      time = each * ns
      shown, size = Metric::TIME_UNITS.reverse_each.find { |_, unit_ns| time >= unit_ns } || ["ns", 1]
      format("%.4g%s", time / size, shown)
    end

    def profile_lines(profile)
      return [] unless profile
      return ["profile: #{profile.fetch("unavailable")}"] if profile.key?("unavailable")

      # (A Profile's: Steep doesn't narrow on key?.)
      grew = profile.fetch("grew") #: Array[Profile::growth]
      ["where the extra CPU went (as a share of the baseline's: in each frame itself, and with what it called):",
        *grew.map { |frame, own, total| format("  %+6.1f%% %+6.1f%%  %s", own * 100, total * 100, frame) }]
    end
  end
end
