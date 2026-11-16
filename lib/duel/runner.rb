# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "../duel"
require_relative "across"
require_relative "lane"
require_relative "memory"
require_relative "profile"
require_relative "resource"
require_relative "result"
require_relative "rubies"

module Duel
  # The most seconds each benchmark runs before it's measured, unless
  # --warm says: until each worker is steady (see Lane#steady), as long
  # as that takes. JRuby's and TruffleRuby's JITs keep compiling for
  # seconds, and some code is still several times faster at 5 than it
  # was, so they get up to a minute.
  # @api private
  JIT_WARM = {"jruby" => 60.0, "truffleruby" => 60.0}.fetch(RUBY_ENGINE, 0.0)

  # The most seconds each benchmark runs before it's measured where a
  # worker has one of CRuby's JITs on, YJIT or ZJIT (an app may turn one
  # on as it boots, as Rails does YJIT), unless --warm says. A small
  # library's methods are compiled within the warm-up samples, but a big
  # app's only after YJIT's 120 calls each, more than a slow benchmark's
  # warm-up samples make.
  # @api private
  CRUBY_JIT_WARM = 10.0

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
  # @api private
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

    # Bytes of memory, in megabytes to a tenth ("41.5MB").
    def self.mb(bytes) = format("%.1fMB", bytes / 1_048_576.0)

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
        Resource.evict(@config.cache)
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
        side.env = Resource.prepare(@config.prepares.fetch(:version), File.join(@dir, side.label), side.label, side.root,
          env: side.env, ruby: side.ruby, timeout: @settings.timeout, cache: @config.cache, so_far: true) { |resource| @prepared << resource }
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
      memory = result.memory&.then { |m| ["peak_memory #{Runner.mb(m.fetch("baseline"))}→#{Runner.mb(m.fetch("candidate"))}"] }
      format("%s %-48s %5.1fs n=%-6d %s", result.worse.empty? ? " " : "!", result.name, result.seconds, result.n,
        (timed + counted + memory.to_a).join("  "))
    end

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
