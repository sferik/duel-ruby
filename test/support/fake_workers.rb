# frozen_string_literal: true

# Worker processes faked, in this process (see DuelTest#with_fake_workers):
# each answers a sample with measures worked out from its version and the
# iterations, so every ratio is exact, and every request is logged.
class FakeWorkers
  CPU = {"name" => "cpu", "kind" => "ratio", "unit" => "ns", "plural" => "ns", "floor" => 300_000, "unit_ns" => 1, "limit" => nil, "tolerance" => 0,
         "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}.freeze
  ALLOCATIONS = {"name" => "allocations", "kind" => "counted", "unit" => nil, "plural" => nil, "floor" => 0, "unit_ns" => 1, "limit" => nil,
                 "tolerance" => 0.5, "sizes_samples" => true, "allowance" => 0, "cpu_floor" => 0, "across" => true}.freeze

  # Every request, as [label, op, name, args]; and each worker's
  # arguments when it was made, as [label, root, candidate_root, dir,
  # options].
  attr_reader :log, :made

  # What every worker says it has.
  attr_accessor :metrics, :memory, :profiler

  # Each version's CPU time per iteration, in nanoseconds (by default).
  attr_reader :per_iteration

  def initialize
    @log = []
    @made = []
    @lock = Mutex.new
    @metrics = [CPU, ALLOCATIONS]
    @memory = true
    @profiler = true
    @benchmarks = {}
    @measures = {}
    @failures = {}
    @per_iteration = {"baseline" => 100_000, "candidate" => 100_000}
    @peaks = {"baseline" => [], "candidate" => []}
    @profiles = {}
  end

  # A benchmark (as a worker's hello has it); its measures are the
  # block's, given the version, the iterations and the worker's label,
  # or by default CPU time per_iteration, two allocations and 1 KB per
  # iteration.
  def benchmark(name, only: nil, peak_memory: false, &measures)
    @benchmarks[name] = {"name" => name, "only" => only, "peak_memory" => peak_memory}
    @measures[name] = measures || lambda do |side, iterations, _label|
      {"timed" => {"cpu" => iterations * per_iteration.fetch(side)}, "counted" => {"allocations" => iterations * 2},
       "heap" => iterations * 1024}
    end
  end

  def benchmarks = @benchmarks.dup

  # Makes +label+'s +op+ of +name+ (nil: any) raise +error+.
  def fail(label, op, name = nil, error: Duel::Failed.new("#{label}: RuntimeError: oops")) = @failures[[label, op, name]] = error

  # Each fresh worker's peak memory, in turn, by version.
  def peaks(side, *bytes) = @peaks.fetch(side).concat(bytes)

  def profile(side, profile) = @profiles[side] = profile

  def record(entry) = @lock.synchronize { @log << entry }

  # The requests logged of +op+, as [label, name, args].
  def requests(op) = @lock.synchronize { @log.select { |entry| entry[1] == op }.map { |label, _, name, args| [label, name, args] } }

  def make(label, root, candidate_root, dir, **options)
    error = @failures[[label, "new", nil]]
    raise error if error

    @lock.synchronize { @made << [label, root, candidate_root, dir, options] }
    Worker.new(self, label)
  end

  def answer(worker, op, name, args)
    error = @failures[[worker.label, op, name]] || @failures[[worker.label, op, nil]]
    raise error if error

    @benchmarks.fetch(name)
    case op
    when "sample"
      measured = @measures.fetch(name).call(worker.side, args.fetch(:n), worker.label)
      {"timed" => measured.fetch("timed"), "counted" => args.fetch(:count) ? measured.fetch("counted") : {},
       "heap" => measured.fetch("heap"), "details" => measured.fetch("details", {})}
    when "memory" then {"peak" => @lock.synchronize { @peaks.fetch(worker.side).shift }}
    when "profile" then @profiles.fetch(worker.side)
    else {"ok" => true}
    end
  end

  # A worker process, faked.
  class Worker
    attr_reader :label

    def initialize(workers, label)
      @workers = workers
      @label = label
    end

    def side = label.split("-").first

    def benchmarks = @workers.benchmarks

    def metrics = @workers.metrics

    def memory = @workers.memory

    def profiler = @workers.profiler

    def request(op, name, **args)
      raise IOError, "closed stream" if @stopped

      @workers.record([label, op, name, args])
      @workers.answer(self, op, name, args)
    end

    def sample(name, n, runs: 1, count: false) = request("sample", name, n: n, runs: runs, count: count)

    def stop
      @stopped = true
      @workers.record([label, "stop"])
    end
  end
end

class DuelTest
  # Yields FakeWorkers that every WorkerProcess.new makes during the
  # block.
  def with_fake_workers
    workers = FakeWorkers.new
    stub(Duel::WorkerProcess, :new, ->(*args, **options) { workers.make(*args, **options) }) { yield workers }
  end
end
