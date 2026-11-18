# frozen_string_literal: true

require "optparse"
require_relative "forge"

module Duel
  # `duel badge BRANCH --status STATUS --result RESULT`: what the Update
  # the badge job runs, on GitHub Actions, after a push to the default
  # branch: Duel's badge, for the README, as that push left it, written
  # alone to BRANCH (in GITHUB_REPOSITORY, through gh), which the README
  # shows. Green (perf guarded), red (perf regressed) where Duel failed
  # the push or found a regression (STATUS failed, even one that passed,
  # where Config#fail_on says only a pull request fails), or grey (not
  # measured) where the Duel job failed (RESULT failure) before Duel said
  # either. A run for an older push than the badge's leaves it as it is.
  # It checks nothing out, runs none of the code, and fetches nothing.
  # @api private
  class Badge
    include Forge

    USAGE = "Usage: duel badge BRANCH --status STATUS --result RESULT\n\n" \
      "Writes Duel's badge, as the push (GITHUB_SHA) left it, to BRANCH: what the Update the badge job runs, with the\n" \
      "Duel job's status and result.\n\n"

    # Each state's words, and the badge's width, its colors (top and
    # bottom), and its right edge's path, by what's to say.
    STATES = {
      "guarded" => ["perf guarded", 133, "#34D058", "#28A745", "76.939C78.629 0 80 1.343 80"],
      "regressed" => ["perf regressed", 142, "#EA4A5A", "#D73A49", "85.939C87.629 0 89 1.343 89"],
      "unmeasured" => ["not measured", 138, "#959DA5", "#6A737D", "81.939C83.629 0 85 1.343 85"]
    }.freeze #: Hash[String, [String, Integer, String, String, String]]

    # The badge's image, with %<state>s, %<width>s, %<top>s, %<bottom>s and
    # %<right>s, written here rather than fetched from anywhere.
    SVG = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="%<width>s" height="20">
        <title>Duel - %<state>s</title>
        <defs>
          <linearGradient id="duel-fill" x1="50%%" y1="0%%" x2="50%%" y2="100%%">
            <stop stop-color="#444D56" offset="0%%"></stop>
            <stop stop-color="#24292E" offset="100%%"></stop>
          </linearGradient>
          <linearGradient id="state-fill" x1="50%%" y1="0%%" x2="50%%" y2="100%%">
            <stop stop-color="%<top>s" offset="0%%"></stop>
            <stop stop-color="%<bottom>s" offset="100%%"></stop>
          </linearGradient>
        </defs>
        <g fill="none" fill-rule="evenodd">
          <g font-family="'DejaVu Sans',Verdana,Geneva,sans-serif" font-size="11">
            <path d="M0,3 C0,1.3431 1.3552,0 3.02702703,0 L53,0 L53,20 L3.02702703,20 C1.3552,20 0,18.6569 0,17 L0,3 Z" fill="url(#duel-fill)" fill-rule="nonzero"></path>
            <text fill="#010101" fill-opacity=".3">
              <tspan x="22.1981982" y="15" aria-hidden="true">Duel</tspan>
            </text>
            <text fill="#FFFFFF">
              <tspan x="22.1981982" y="14">Duel</tspan>
            </text>
          </g>
          <g transform="translate(53)" font-family="'DejaVu Sans',Verdana,Geneva,sans-serif" font-size="11">
            <path d="M0 0h%<right>s 3v14c0 1.657-1.37 3-3.061 3H0V0z" fill="url(#state-fill)" fill-rule="nonzero"></path>
            <text fill="#010101" fill-opacity=".3" aria-hidden="true">
              <tspan x="4" y="15">%<state>s</tspan>
            </text>
            <text fill="#FFFFFF">
              <tspan x="4" y="14">%<state>s</tspan>
            </text>
          </g>
          <g fill="#959DA5">
            <path d="M4.6 3.6L6.9 4.5L14.3 11.9L12.9 13.3L5.5 5.9Z M17.4 3.6L15.1 4.5L7.7 11.9L9.1 13.3L16.5 5.9Z"></path>
            <circle cx="16.6" cy="15.6" r="1.1"></circle>
            <circle cx="5.4" cy="15.6" r="1.1"></circle>
          </g>
          <g stroke="#959DA5" stroke-linecap="round">
            <path d="M12.1 14.5L15.5 11.1 M9.9 14.5L6.5 11.1" stroke-width="1.6"></path>
            <path d="M13.8 12.8L16 15 M8.2 12.8L6 15" stroke-width="1.8"></path>
          </g>
        </g>
      </svg>
    SVG

    # What its commit says, which names the push: "Duel's badge, for SHA".
    MESSAGE = "Duel's badge, for "

    def initialize(argv, env:, out:, err:)
      @argv = argv
      @env = env
      @out = out
      @err = err
    end

    # Returns the exit status: 0 written (or left, for an older push), 1
    # GitHub wouldn't take it, 2 a bad option.
    def run
      branches = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::MissingArgument, "BRANCH" if branches.empty?
      raise OptionParser::NeedlessArgument, branches.drop(1).first if branches.size > 1

      branch = branches.first #: String
      sha = @env.fetch("GITHUB_SHA")
      return left(branch) if newer?(branch, sha)

      write(branch, Badge.svg(Badge.state(@status, @result)), sha)
    rescue OptionParser::ParseError => e
      @err.puts "#{command}: #{e}"
      2
    end

    # What the badge says, given the Duel job's +status+ (its output:
    # passed, failed or neutral) and +result+ (success or failure, say):
    # one of STATES.
    def self.state(status, result)
      case status
      when "failed" then "regressed"
      when "passed" then "guarded"
      else (result == "failure") ? "unmeasured" : "guarded"
      end
    end

    # The badge's image, saying +state+ (one of STATES).
    def self.svg(state)
      words, width, top, bottom, right = STATES.fetch(state)
      format(SVG, state: words, width: width, top: top, bottom: bottom, right: right)
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--status STATUS", "The Duel job's status (its output: passed, failed or neutral)") { |v| @status = v }
        o.on("--result RESULT", "The Duel job's result (success or failure, say)") { |v| @result = v }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Whether the badge on +branch+ is a newer push's than +sha+ (its
    # commit names the push): that push's run has the say.
    def newer?(branch, sha)
      message = gh("repos/#{repository}/commits/#{branch}", "--jq", ".commit.message", quiet: true).to_s
      last = message[/\A#{MESSAGE}(\h+)\n?\z/o, 1] or return false

      gh("repos/#{repository}/compare/#{sha}...#{last}", "--jq", ".status", quiet: true)&.chomp == "ahead"
    end

    # Writes +svg+, alone, to +branch+ (moved there, or made), in a commit
    # that names the push, +sha+.
    def write(branch, svg, sha)
      # (gh makes the fields' JSON: {"tree": [{"path": "badge.svg", ...}]}.)
      tree = gh("repos/#{repository}/git/trees", "--method", "POST", "-f", "tree[][path]=badge.svg", "-f", "tree[][mode]=100644",
        "-f", "tree[][type]=blob", "-f", "tree[][content]=#{svg}", "--jq", ".sha")&.chomp or return 1
      commit = gh("repos/#{repository}/git/commits", "--method", "POST", "-f", "message=#{MESSAGE}#{sha}", "-f", "tree=#{tree}",
        "--jq", ".sha")&.chomp or return 1
      ref = "repos/#{repository}/git/refs"
      if gh("#{ref}/heads/#{branch}", "--method", "PATCH", "-f", "sha=#{commit}", "-F", "force=true", quiet: true) ||
          gh(ref, "--method", "POST", "-f", "ref=refs/heads/#{branch}", "-f", "sha=#{commit}")
        @out.puts "#{command}: #{branch} shows the badge of #{sha}"
        return 0
      end
      blocked(branch) { |prefix| gh("repos/#{repository}/git/ref/heads/#{prefix}", quiet: true) }
    end

    def left(branch)
      @out.puts "#{command}: #{branch} shows a newer push's badge, which it's left at"
      0
    end

    # (For Forge.)
    def command = "duel badge"

    def gitlab_token = "DUEL_TOKEN"
  end
end
