# frozen_string_literal: true

require "json"
require "tmpdir"

# Compares a project's code with itself (`duel --force --base HEAD`)
# RUNS times over (default 5), and summarizes every benchmark's ratios
# across the runs (from each run's JSON report: see docs/json.md), so a lean (one side faster every time, which no one
# run is enough to call) shows. Identical code must compare even: it
# fails if any run found a regression (or couldn't compare), and warns
# if a metric's ratios lean one way more than chance would have them.
#
#   ruby tasks/bias_check.rb [RUNS]                       # Duel's own benchmarks
#   cd plugins/redis && ruby ../../tasks/bias_check.rb 3  # a plugin's
#
# The nightly bias check (.github/workflows/bias.yml) runs it. It
# compares HEAD, so commit what you want compared first.
module BiasCheck
  extend self

  COMMAND = %w[bundle exec duel --force --base HEAD --json].freeze
  # The JSON report's schema it reads.
  SCHEMA = 1
  # Every benchmark's median ratio across the board (where there were
  # enough to tell): shown, but not counted again in the lean.
  ACROSS_NAME = "(across the board)"
  # A two-sided sign test's p-value below which a lean is called.
  LEAN_P = 0.01

  def run(runs)
    statuses = []
    # {metric => {benchmark => [ratio of each run, or nil]}}
    ratios = Hash.new { |hash, metric| hash[metric] = Hash.new { |by_name, name| by_name[name] = Array.new(runs) } }
    Dir.mktmpdir("bias") do |dir|
      runs.times do |run|
        json = File.join(dir, "run#{run + 1}.json")
        puts "== Run #{run + 1} of #{runs}: #{[*COMMAND, json].join(" ")}"
        $stdout.flush
        system(*COMMAND, json)
        statuses << $?.exitstatus
        parse(read(json)).each { |metric, name, median| ratios[metric][name][run] = median }
      end
    end
    summarize(ratios, runs)
    failed = statuses.each_index.reject { |run| statuses[run].zero? }
    return 0 if failed.empty?

    puts "::error::Identical code didn't compare even: run #{failed.map { |run| run + 1 }.join(", ")} of #{runs} failed (exit #{failed.map { |run| statuses[run] }.join(", ")})"
    1
  end

  # The JSON report at +path+, or nil where the run wrote none (it
  # crashed, say: its exit status fails the check).
  def read(path)
    return unless File.exist?(path)

    report = JSON.parse(File.read(path))
    schema = report.fetch("schema")
    raise "#{path}: schema #{schema}, not #{SCHEMA}: update tasks/bias_check.rb" unless schema == SCHEMA

    report
  end

  # [metric, benchmark, median ratio] for each timed measure in +report+,
  # and each metric's across the board.
  def parse(report)
    return [] unless report

    timed = report.fetch("benchmarks").flat_map do |benchmark|
      benchmark.fetch("timed").map { |metric, t| [metric, benchmark.fetch("name"), t.fetch("ratio")] }
    end
    across = report.fetch("across").filter_map { |metric, v| [metric, ACROSS_NAME, v.fetch("ratio")] if v.fetch("interval") }
    timed + across
  end

  def summarize(ratios, runs)
    puts
    puts "== The candidate's ratio to the baseline (identical code), by run: above 1 is the candidate slower"
    width = ratios.values.flat_map(&:keys).map(&:size).max.to_i
    ratios.each do |metric, by_name|
      puts
      puts format("%-*s  %s  %7s", width, metric, (1..runs).map { |run| format("%6s", "run#{run}") }.join(" "), "geomean")
      by_name.sort.each do |name, values|
        shown = values.map { |value| value ? format("%6.3f", value) : "-".rjust(6) }.join(" ")
        puts format("%-*s  %s  %7.3f", width, name, shown, geomean(values.compact))
      end
      lean(metric, by_name.except(ACROSS_NAME).values.flatten.compact)
    end
  end

  # How +values+ (a metric's every ratio) lean, and a warning if more one
  # way than a fair coin would put them (ties, 1.000, left out).
  def lean(metric, values)
    above = values.count { |value| value > 1 }
    below = values.count { |value| value < 1 }
    p = sign_test(above, below)
    puts format("%s: %d above 1, %d below, %d even, geometric mean %.4f, sign test p=%.3g",
      metric, above, below, values.size - above - below, geomean(values), p)
    return unless p < LEAN_P

    side = (above > below) ? "baseline" : "candidate"
    puts "::warning title=Bias (#{metric})::The #{side} was faster at #{metric} in #{[above, below].max} of #{above + below} " \
      "ratios (p=#{format("%.3g", p)}): identical code leans one way"
  end

  def geomean(values) = values.empty? ? Float::NAN : Math.exp(values.sum { |value| Math.log(value) } / values.size)

  # The two-sided p-value of +above+ against +below+, were each side as
  # likely as the other.
  def sign_test(above, below)
    n = above + below
    return 1.0 if n.zero?

    tail = (0..[above, below].min).sum { |k| binomial(n, k) } / (2.0**n)
    [2 * tail, 1.0].min
  end

  def binomial(n, k) = (1..k).reduce(1) { |product, i| product * (n - k + i) / i }
end

exit BiasCheck.run(Integer(ARGV.fetch(0, "5"))) if $PROGRAM_NAME == __FILE__
