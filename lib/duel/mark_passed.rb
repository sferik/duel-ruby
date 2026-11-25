# frozen_string_literal: true

require "optparse"
require_relative "forge"

module Duel
  # `duel mark-passed BRANCH`: what the Mark the commit passed job runs,
  # where Duel said a push passed, with the branch that marks it (see
  # Baseline#passed_branch: the Duel job's passed output), where
  # Config#push_base compares a push with the last commit Duel passed.
  # It moves the branch forward to mark the push's commit (or makes it),
  # but never back: where a newer push's run marked it first, it stays.
  # On GitHub Actions, through gh (GITHUB_SHA, in GITHUB_REPOSITORY), to
  # a commit of its own that names the push's (see #on_github), and on
  # GitLab CI, through its API, signed in with DUEL_TOKEN, to the push's
  # commit (CI_COMMIT_SHA). It checks nothing out, and runs none of the
  # code.
  # @api private
  class MarkPassed
    include Forge

    USAGE = "Usage: duel mark-passed BRANCH\n\n" \
      "Moves BRANCH, which marks the last commit Duel passed, forward to mark the pushed commit, or makes it: what the\n" \
      "Mark the commit passed job runs.\n\n"

    # What begins a mark's message (see #mark), before the commit it
    # marks, which Baseline#passed reads.
    MESSAGE = "Duel passed "

    # A mark's message, and the commit it marks.
    MARKED = /\A#{MESSAGE}(\h{40}|\h{64})\n?\z/

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

    # Marks +sha+ on GitHub: moves +branch+ forward to a commit of its
    # own that names it (#mark), or makes it there. The branch never has
    # the project's files, so moving it changes no workflow, which GitHub
    # lets GITHUB_TOKEN do only with the workflows permission, which it
    # can't have. Each mark's parent is the mark before, so GitHub moves
    # the branch only where nothing moved it since: where something did,
    # or where making it fails (something else made it), it looks once
    # more, and then says why it failed.
    def on_github(branch, sha)
      ref = "repos/#{repository}/git/refs/heads/#{branch}"
      at = nil #: String?
      2.times do |again|
        quiet = again.zero?
        at = gh("repos/#{repository}/git/ref/heads/#{branch}", "--jq", ".object.sha", quiet: true)&.chomp
        unless at
          return moved(branch, sha) if (mark = mark(sha)) && made(branch, mark, quiet)

          next
        end
        message = gh("repos/#{repository}/git/commits/#{at}", "--jq", ".message") or return 1
        # (Or where it's at the commit itself: moved there by hand, say, or
        # by Duel 0.3.)
        marked = message[MARKED, 1]
        case (compared = compared(sha, marked || at))
        # (A newer push's run marked it, or this one's did, run again.)
        when "ahead", "identical" then return left(branch)
        # (History rewritten, a force push's, say, or replaced: marked
        # anyway.)
        when "diverged", "behind", "unrelated"
          mark = mark(sha, (at if marked)) or return 1
          return moved(branch, sha) if marked ? gh(ref, "--method", "PATCH", "-f", "sha=#{mark}", quiet:) : remade(branch, mark, quiet)
        else
          @out.puts "::error::Couldn't compare #{branch} with this push: #{compared}"
          return 1
        end
      end
      at ? 1 : blocked(branch) { |prefix| gh("repos/#{repository}/git/ref/heads/#{prefix}", quiet: true) }
    end

    # A commit that marks +sha+, for the branch: its message names it
    # (MESSAGE), and its one file, passed, has it. Its parent is +parent+,
    # the mark before, or it has none. Or nil, where GitHub won't make it.
    def mark(sha, parent = nil)
      # (gh makes the fields' JSON: {"tree": [{"path": "passed", ...}]}.)
      tree = gh("repos/#{repository}/git/trees", "--method", "POST", "-f", "tree[][path]=passed", "-f", "tree[][mode]=100644",
        "-f", "tree[][type]=blob", "-f", "tree[][content]=#{sha}\n", "--jq", ".sha")&.chomp or return
      gh("repos/#{repository}/git/commits", "--method", "POST", "-f", "message=#{MESSAGE}#{sha}", "-f", "tree=#{tree}",
        *[parent].compact.flat_map { |mark| ["-f", "parents[]=#{mark}"] }, "--jq", ".sha")&.chomp
    end

    # Makes +branch+ at +mark+, saying why it fails, unless +quiet+.
    def made(branch, mark, quiet)
      gh("repos/#{repository}/git/refs", "--method", "POST", "-f", "ref=refs/heads/#{branch}", "-f", "sha=#{mark}", quiet:)
    end

    # Moves +branch+, at one of the project's commits, to +mark+: where it
    # has a workflow, moving it would take that away, which GitHub lets
    # GITHUB_TOKEN do no more than change one, so it's deleted and made
    # again.
    def remade(branch, mark, quiet)
      gh("repos/#{repository}/git/refs/heads/#{branch}", "--method", "DELETE", quiet: true)
      made(branch, mark, quiet)
    end

    # How +at+ (the branch's commit) compares with the push's commit
    # +sha+, as GitHub says: ahead, identical, behind or diverged, or
    # unrelated, which GitHub can't compare (commits with no history in
    # common, or one of them not there), or what went wrong.
    def compared(sha, at)
      out, err, status = Spawn.open3(:capture3, "gh", "api", "repos/#{repository}/compare/#{sha}...#{at}", "--jq", ".status")
      return out.chomp if status.success?

      # (GitHub says Not Found for both: no history in common, or a commit
      # that's gone, after a force push, as a mark may name.)
      err.include?("(HTTP 404)") ? "unrelated" : err.strip
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
      @out.puts "#{command}: #{branch} marks #{sha}"
      0
    end

    def left(branch)
      @out.puts "#{command}: #{branch} marks a newer push's commit, which it's left at"
      0
    end

    # (For Forge.)
    def command = "duel mark-passed"

    def gitlab_token = "DUEL_TOKEN"
  end
end
