# frozen_string_literal: true

require "json"
require "open3"
require "optparse"

module Duel
  # `duel comment`: what the Perf comment workflow runs, once the Perf
  # workflow has, to comment on a pull request with Duel's report. It runs
  # with the repository's own workflow and a token that can write, and the
  # pull request's code ran in the Duel job, which could have written
  # anything in what it kept (the report's directory), so it trusts only
  # what Duel could have said there: the pull request's number, if it
  # names the pull request whose head the run compared, and a comment
  # (post or change: see CLI.comment) and a status (see CLI::MARKED) that
  # Duel says. The report itself is the comment, as Markdown. It never
  # edits or deletes a comment: once it has posted one, it hides Duel's
  # earlier ones as outdated, which GitHub collapses, so the newest is the
  # one in view. It talks to GitHub with gh, which GH_TOKEN signs in, in
  # GITHUB_REPOSITORY.
  # @api private
  class Comment
    USAGE = "Usage: duel comment --report DIR --head SHA [--marker TEXT]\n\n" \
      "Comments on a pull request with the report a Perf run kept in DIR, when Duel said to, and only if the pull\n" \
      "request's head is still SHA: what the Perf comment workflow runs.\n\n"

    # The first release of Duel whose `duel comment` the Perf comment
    # workflow that this one writes can run: it installs the newest
    # release of the same minor version (~>), so a fix comes with one.
    SINCE = "0.1.8"

    # What Duel says in comment.env, as each line must have it.
    SAID = {"pr" => /\A[0-9]+\z/, "comment" => /\A(?:post|change)\z/, "status" => /\A(?:passed|failed|neutral)\z/}.freeze

    # The jq that lists the comments GitHub Actions' token posted, each
    # with its node_id and its marker (its body's first line).
    LISTED = '.[] | select(.user.login == "github-actions[bot]") | {node_id, marked: (.body | split("\n")[0] | rtrimstr("\r"))}'

    def initialize(argv, env:, out:, err:)
      @argv = argv
      @env = env
      @out = out
      @err = err
      @marker = "duel"
    end

    # Returns the exit status: 0 commented (or had nothing to say), 1 GitHub
    # wouldn't take it, 2 a bad option.
    def run
      rest = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?
      raise OptionParser::MissingArgument, "--report and --head are required" unless @report && @head

      comment
    rescue OptionParser::ParseError => e
      @err.puts "duel comment: #{e}"
      2
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--report DIR", "The directory of the Perf run's report (duel.md and comment.env)") { |v| @report = v }
        o.on("--head SHA", "The commit the run compared, the pull request's head") { |v| @head = v }
        o.on("--marker TEXT", "What marks Duel's comments (default: duel)") { |v| @marker = v }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Comments, if Duel said to, and the pull request's head is still the
    # run's.
    def comment
      pr, mode, status = SAID.keys.map { |name| said(name) }
      return quiet("Duel said not to") unless pr && mode && status

      head = gh("repos/#{repository}/pulls/#{pr}", "--jq", ".head.sha") or return 1
      return quiet("the pull request has moved on since the run") unless head.chomp == @head

      ours = earlier(pr) or return 1
      last = ours.last&.fetch("marked")
      stale = last && !last.eql?("#{marker} status=#{status} -->")
      return quiet("the last comment says #{status} already") unless mode == "post" || stale

      # (Set: see #run.)
      report = @report #: String
      body = "#{marker} status=#{status} -->\n#{File.read(File.join(report, "duel.md"))}"
      gh("repos/#{repository}/issues/#{pr}/comments", "--method", "POST", "-f", "body=#{body}") or return 1
      @out.puts "duel comment: commented on pull request #{pr}"
      ours.each { |earlier| hide(earlier.fetch("node_id")) }
      0
    end

    # What Duel said in comment.env, as SAID has it (the last line that
    # says it), or nil.
    def said(name)
      report = @report #: String
      path = File.join(report, "comment.env")
      lines = File.file?(path) ? File.readlines(path, chomp: true) : [] #: Array[String]
      lines.map { |line| line[/\A#{name}=(.*)\z/, 1] }.grep(SAID.fetch(name)).last
    end

    # Duel's comments on the pull request, oldest first, each with its
    # node_id and its marker (its first line), or nil where GitHub
    # wouldn't list them.
    def earlier(pr)
      listed = gh("repos/#{repository}/issues/#{pr}/comments", "--paginate", "--jq", LISTED) or return
      listed.lines.map { |line| JSON.parse(line) }.select { |c| c.fetch("marked").start_with?("#{marker} status=") || c.fetch("marked") == "#{marker} -->" }
    end

    # Hides an earlier comment as outdated, which GitHub collapses, or
    # says it couldn't (it's still there, and that's all).
    def hide(id)
      query = "mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { clientMutationId } }"
      gh("graphql", "-f", "query=#{query}", "-f", "id=#{id}") || @err.puts("duel comment: couldn't hide an earlier comment")
    end

    # What gh api prints, given +args+, or nil where it fails (or isn't
    # there), which it says why.
    def gh(*args)
      out, err, status = Open3.capture3("gh", "api", *args)
      return out if status.success?

      @err.puts "duel comment: gh api #{args.first}: #{err.strip}"
    rescue SystemCallError => e
      @err.puts "duel comment: gh: #{e}"
    end

    # Says why it doesn't comment, and returns 0.
    def quiet(why)
      @out.puts "duel comment: no comment (#{why})"
      0
    end

    def marker = "<!-- #{@marker}"

    def repository = @env.fetch("GITHUB_REPOSITORY")
  end
end
