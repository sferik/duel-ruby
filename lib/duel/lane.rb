# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../duel"
require_relative "platform"
require_relative "process_sample"
require_relative "resource"
require_relative "result"
require_relative "stats"
require_relative "worker_process"

module Duel
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
      @warm = settings.warm || (started.any?(&:jit) ? CRUBY_JIT_WARM : JIT_WARM)
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
    def self.short_tmp(tmpdir = Dir.tmpdir, windows: Platform::WINDOWS) = (windows || tmpdir.size <= SHORT) ? tmpdir : "/tmp"

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
    def rubies = firsts.transform_values(&:description)

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
      if process_of(name)
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
      sides = firsts
      sides.each_value { |worker| worker.request("setup", name) }
      sides.transform_values { |worker| worker.request("profile", name, n: n, runs: PROFILE_SAMPLES) }
    ensure
      sides&.each_value { |worker| worker.request("teardown", name) }
    end

    private

    # How a benchmark runs as a process of its own, or nil where it's no
    # process benchmark.
    def process_of(name) = benchmarks.fetch(name).fetch("process")

    # Each version's first worker, by version.
    def firsts = {"baseline" => @bases.first, "candidate" => @candidates.first}

    # A worker of +side+, with its own resources, and its version's Ruby
    # and environment.
    def spawn(side, index)
      version = @sides.fetch(side)
      label = "#{version.label}-#{index + 1}"
      env = Resource.prepare(@config.prepares.fetch(:worker), File.join(@dir, label), label, version.root, env: version.env,
        ruby: version.ruby, timeout: @settings.timeout, cache: @config.cache) { |resource| keep(@resources, resource) }
      worker = WorkerProcess.new(label, version.root, @sides.fetch("candidate").root, @dir,
        config_path: @settings.config_path, env: env, timeout: @settings.timeout, ruby: version.ruby, engine: version.engine)
      keep(@workers, worker)
      check_jit(side, worker, env, version.engine)
      worker
    end

    # Fails where +env+, +worker+'s (over the runner's own), turns one of
    # CRuby's JITs on (see JIT_VARIABLES) and +worker+ doesn't run it: its
    # benchmarks would be measured without it, and nothing would say so.
    # A CRuby without the JIT ignores its variable, as one before 4.0, or
    # built without ZJIT, does RUBY_ZJIT_ENABLE, and so do JRuby and
    # TruffleRuby, whose JIT is their own.
    def check_jit(side, worker, env, engine)
      jit, variable = JIT_VARIABLES.find { |_, name| JIT_ON.include?(env.fetch(name) { ENV[name] }) }
      return if jit.nil? || worker.jit == jit

      asked = jit.upcase
      why = if engine == "ruby"
        (jit == "zjit") ? "a Ruby before 4.0, or one built without ZJIT, ignores RUBY_ZJIT_ENABLE" : "a Ruby built without YJIT ignores RUBY_YJIT_ENABLE"
      else
        "#{asked} is CRuby's, and #{engine} has a JIT of its own: unset #{variable} for it"
      end
      raise Failed, "the #{side}'s workers run #{worker.jit&.upcase || "no JIT"}, not #{asked} as #{variable} asks, on " \
        "#{worker.description}: #{why}"
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
      workers = firsts
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
      peak_memory(name, n, result) if benchmark.fetch("peak_memory")
      judge(name, n, floors, result)
      # (Counted once it's timed: on JRuby, the bytes a benchmark allocates
      # can fall as its JIT compiles it, so a count right after a short
      # warm-up could find one version's workers further along than the
      # other's.)
      count(name, n, result) unless timings_only
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
      process = process_of(name) #: Definition::process
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
    # #steady), for JIT_WARM's or CRUBY_JIT_WARM's seconds at most.
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
          above_floors?(floors, spec)
      end
      return judge_processes(name, n, judged, result) if by_process?(name)

      # @type var raw: Hash[String, Array[[Metric::value, Metric::value]]]
      raw = judged.to_h { |spec| [spec.fetch("name"), []] }
      pending = judged.dup
      every = process_of(name)
      (0...MAX_PAIRS).each do |i|
        break if pending.empty?

        base, candidate = pair(name, n, i)
        result.note(base, candidate)
        raw.each { |metric, pairs| pairs << [base.fetch("timed").fetch(metric), candidate.fetch("timed").fetch(metric)] }
        round = ((i + 1) % STEP).zero?
        next unless round || every

        pending.reject! { |spec| decided?(verdict(ratios(raw.fetch(spec.fetch("name"))), spec), round) }
      end
      judged.each do |spec|
        list = ratios(raw.fetch(spec.fetch("name")))
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
    # them (see #enough_workers?).
    def by_process?(name) = !process_of(name) && enough_workers?

    # Whether there are workers enough of each version for an interval
    # over them (Lane.by_process?): then timings and counts alike are
    # judged by process.
    def enough_workers? = Lane.by_process?(@bases.size, @settings.confidence)

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

        in_round(name, n, round) do |i, j, base, candidate|
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
      !above_floors?(floors, cpu)
    end

    # Whether either version's samples in +floors+ (its timed measures)
    # are above +spec+'s floors (the median): its own, and its share of
    # CPU time.
    def above_floors?(floors, spec)
      floors.transpose.any? do |side|
        samples = side.map { |sample| sample.fetch("timed") }
        values = samples.map { |sample| sample.fetch(spec.fetch("name")) }
        cpu = samples.map { |sample| sample.fetch("cpu") }
        median = Stats.median(values)
        median >= spec.fetch("floor") && median * spec.fetch("unit_ns") >= spec.fetch("cpu_floor") * Stats.median(cpu)
      end
    end

    # Each of +pairs+' ratio: the candidate's value over the baseline's
    # (at least 1).
    def ratios(pairs) = pairs.map { |base, candidate| candidate.fdiv([base, 1].max) }

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

    # Round +round+ of pairs taken by process (see #judge_processes and
    # #count_by_process): a sample from every baseline worker, the +i+th,
    # paired with the candidate's +j+th in turn (each round pairs each with
    # another), baseline first alternating by worker and by round. Yields
    # each pair's workers' indexes and samples.
    def in_round(name, n, round, runs: RUNS, count: false)
      k = @bases.size
      k.times do |i|
        j = (i + round) % k
        base, candidate = sampled(name, n, @bases.fetch(i), @candidates.fetch(j), base_first: i.even? == round.even?, runs:, count:)
        yield i, j, base, candidate
      end
    end

    # A sample (of +n+ iterations) from +base+, a baseline worker, and
    # from +candidate+, a candidate worker, the baseline's first if
    # +base_first+ (see #pair).
    def sampled(name, n, base, candidate, base_first:, runs:, count:)
      order = base_first ? [base, candidate] : [candidate, base]
      process = process_of(name)
      replies = if process
        # (Each run of one version's next to one of the other's.)
        each_run = Array.new(n) { order.map { |worker| worker.run(process) } }
        fastest = order.zip(each_run.transpose).to_h do |worker, samples|
          # (Never nil: each worker in order has its runs.)
          ran = samples #: Array[ProcessSample::sampled]
          [worker, ProcessSample.fastest(ran)]
        end
        @peaks.fetch("baseline") << fastest.fetch(base).fetch("peak")
        @peaks.fetch("candidate") << fastest.fetch(candidate).fetch("peak")
        fastest
      else
        order.to_h { |worker| [worker, worker.sample(name, n, runs: runs, count: count)] }
      end
      [replies.fetch(base), replies.fetch(candidate)]
    end

    # Each counted measure's fewest, on each version, over COUNTS pairs of
    # samples, and what its metric said of those samples.
    def count(name, n, result)
      return count_by_process(name, n, result) if enough_workers?

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
      # @type var fewest: Hash[String, Hash[String, Hash[Integer, Metric::value]]]
      fewest = Hash.new do |h, metric|
        none = {} #: Hash[Integer, Metric::value]
        h[metric] = {"baseline" => none, "candidate" => none.dup}
      end
      COUNT_ROUNDS.times do |round|
        in_round(name, n, round, runs: 1, count: true) do |i, j, base, candidate|
          fewest!(fewest, "baseline", i, base)
          fewest!(fewest, "candidate", j, candidate)
          # (What metrics said of its counts alone: a timing's is the timed
          # pairs'.)
          base.fetch("counted").each_key { |metric| result.note(base, candidate, metric) }
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
end
