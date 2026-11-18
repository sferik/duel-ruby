# frozen_string_literal: true

require "optparse"
require_relative "forge"

module Duel
  # `duel mark-passed BRANCH`: what the Mark the commit passed job runs,
  # where Duel said a push passed, with the branch that marks it (see
  # Baseline#passed_branch: the Duel job's passed output), where
  # Config#push_base compares a push with the last commit Duel passed.
  # It moves the branch to the push's commit (or makes it), but never
  # back: where a newer push's run moved it first, it stays. On GitHub
  # Actions, through gh (to GITHUB_SHA, in GITHUB_REPOSITORY), and on
  # GitLab CI, through its API, signed in with DUEL_TOKEN (to
  # CI_COMMIT_SHA). It checks nothing out, and runs none of the code.
  # @api private
  class MarkPassed
    include Forge

    USAGE = "Usage: duel mark-passed BRANCH\n\n" \
      "Moves BRANCH, which marks the last commit Duel passed, forward to the pushed commit, or makes it: what the Mark\n" \
      "the commit passed job runs.\n\n"

    def initialize(argv, env:, out:, err:)
      @argv = argv
      @env = env
      @out = out
      @err = err
    end

    # Returns the exit status: 0 moved (or left where a newer push's run
    # moved it), 1 it couldn't, 2 a bad option.
    def run
      branches = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::MissingArgument, "BRANCH" if branches.empty?
      raise OptionParser::NeedlessArgument, branches.drop(1).first if branches.size > 1

      branch = branches.first #: String
      gitlab? ? on_gitlab(branch, @env.fetch("CI_COMMIT_SHA")) : on_github(branch, @env.fetch("GITHUB_SHA"))
    rescue OptionParser::ParseError => e
      @err.puts "#{command}: #{e}"
      2
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Moves +branch+ to +sha+ on GitHub: forward, where GitHub moves it
    # only where it's behind the push. Where there's no branch, and making
    # it fails, it looks once more, as something else may have made it (a
    # push of it, say).
    def on_github(branch, sha)
      ref = "repos/#{repository}/git/refs/heads/#{branch}"
      at = nil #: String?
      2.times do
        return moved(branch, sha) if gh(ref, "--method", "PATCH", "-f", "sha=#{sha}", quiet: true)

        at = gh("repos/#{repository}/git/ref/heads/#{branch}", "--jq", ".object.sha", quiet: true)&.chomp
        break if at
        return moved(branch, sha) if gh("repos/#{repository}/git/refs", "--method", "POST", "-f", "ref=refs/heads/#{branch}", "-f", "sha=#{sha}")
      end
      found = at or return blocked(branch) { |prefix| gh("repos/#{repository}/git/ref/heads/#{prefix}", quiet: true) }

      case (compared = compared(sha, found))
      # (A newer push's run moved it, or this one's did, run again.)
      when "ahead", "identical" then left(branch)
      # (History rewritten, a force push's, say, or replaced: moved anyway.)
      when "diverged", "behind", "unrelated"
        gh(ref, "--method", "PATCH", "-f", "sha=#{sha}", "-F", "force=true") ? moved(branch, sha) : 1
      else
        @out.puts "::error::Couldn't compare #{branch} with this push: #{compared}"
        1
      end
    end

    # How +at+ (the branch's commit) compares with the push's commit
    # +sha+, as GitHub says: ahead, identical, behind or diverged, or
    # unrelated, which GitHub can't compare (commits with no history in
    # common), or what went wrong.
    def compared(sha, at)
      out, err, status = Spawn.open3(:capture3, "gh", "api", "repos/#{repository}/compare/#{sha}...#{at}", "--jq", ".status")
      return out.chomp if status.success?

      err.include?("No common ancestor") ? "unrelated" : err.strip
    end

    # Moves +branch+ to +sha+ on GitLab, which moves no branch, so it's
    # deleted, and made again where it is: unless it's at a newer push's
    # commit (one that has +sha+).
    def on_gitlab(branch, sha)
      path = "#{project}/repository/branches/#{encoded(branch)}"
      at = gitlab(:Get, path, quiet: true)&.dig("commit", "id")
      if at
        base = gitlab(:Get, "#{project}/repository/merge_base?refs%5B%5D=#{sha}&refs%5B%5D=#{at}")&.fetch("id", nil)
        unless base
          @out.puts "Couldn't compare #{branch} with this push"
          return 1
        end
        # (A newer push's job moved it, or this one's did, run again.)
        return left(branch) if base == sha
      end
      gitlab(:Delete, path, quiet: true)
      return moved(branch, sha) if gitlab(:Post, "#{project}/repository/branches", {"branch" => branch, "ref" => sha}, quiet: true)

      blocked(branch) { |prefix| gitlab(:Get, "#{project}/repository/branches/#{encoded(prefix)}", quiet: true) }
    end

    def moved(branch, sha)
      @out.puts "#{command}: #{branch} is at #{sha}"
      0
    end

    def left(branch)
      @out.puts "#{command}: #{branch} is at a newer push's commit, which it's left at"
      0
    end

    # (For Forge.)
    def command = "duel mark-passed"

    def gitlab_token = "DUEL_TOKEN"
  end
end
