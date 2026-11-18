# frozen_string_literal: true

require "optparse"
require "uri"
require_relative "forge"

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
  # earlier ones that aren't hidden yet as outdated, which GitHub
  # collapses, so the newest is the one in view. It talks to GitHub with
  # gh, which GH_TOKEN signs in, in GITHUB_REPOSITORY.
  #
  # On GitLab CI (GITLAB_CI), it's what the GitLab CI jobs' comment job
  # runs, on a merge request: what Duel said is the Duel job's dotenv
  # report's (DUEL_COMMENT and DUEL_STATUS), it talks to GitLab's API
  # (CI_API_V4_URL) with DUEL_COMMENT_TOKEN, and it hides nothing, as only
  # a Developer can resolve a thread, and a merge request's token is a
  # Reporter's. With --commit, it signs in with DUEL_TOKEN.
  # @api private
  class Comment
    include Forge

    USAGE = "Usage: duel comment --report DIR --head SHA [--marker TEXT]\n" \
      "       duel comment --report DIR --commit SHA [--marker TEXT]\n\n" \
      "Comments on a pull request with the report a Perf run kept in DIR, when Duel said to, and only if the pull\n" \
      "request's head is still SHA: what the Perf comment workflow runs (or on GitLab CI, where GITLAB_CI is set,\n" \
      "on a merge request, with DUEL_COMMENT_TOKEN: the comment job). With --commit, on the pushed commit SHA, as\n" \
      "DUEL_COMMENT and DUEL_STATUS say: what the Comment on the commit job runs.\n\n"

    # The first release of Duel whose `duel comment`, `duel mark-passed`
    # and `duel badge` the workflows that this one writes can run (0.2.1's
    # comments on a pushed commit, and has the other two): they install
    # the newest release of the same minor version (~>), so a fix comes
    # with one.
    SINCE = "0.2.1"

    # Where GitLab CI has what Duel said (comment.env's, on GitHub): the
    # merge request's, and the Duel job's dotenv report's.
    GITLAB = {"pr" => "CI_MERGE_REQUEST_IID", "comment" => "DUEL_COMMENT", "status" => "DUEL_STATUS"}.freeze

    # What Duel says in comment.env, as each line must have it.
    SAID = {"pr" => /\A[0-9]+\z/, "comment" => /\A(?:post|change)\z/, "status" => /\A(?:passed|failed|neutral)\z/}.freeze

    # The characters a comment of reports has room for (GitHub takes
    # 65,536, the marker and the names' headings among them), which each
    # report's cut to its share of.
    ROOM = 65_000

    # A report's, in a comment of them, where its Duel job failed before
    # it compared.
    NONE = "No report: its Duel job failed before it compared.\n"

    # The comments on a pull request, a page at a time (gh api graphql
    # --paginate follows endCursor): GraphQL's, which say whether each is
    # hidden, as REST's don't.
    COMMENTS = <<~GRAPHQL
      query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $pr) {
            comments(first: 100, after: $endCursor) {
              nodes { id isMinimized author { login } body }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    GRAPHQL

    # The jq that picks, of COMMENTS, the ones GitHub Actions' token
    # posted, each with its id, whether it's hidden, and its marker (its
    # body's first line).
    LISTED = '.data.repository.pullRequest.comments.nodes[] | select(.author.login == "github-actions") | ' \
      '{id, hidden: .isMinimized, marked: (.body | split("\n")[0] | rtrimstr("\r"))}'

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
      # (--gitlab is taken, and unlisted: the comment jobs that duel init
      # wrote before, which install the newest Duel of their release,
      # pass it. GITLAB_CI says it's GitLab's now.)
      rest = catch(:help) { parser.parse(@argv - ["--gitlab"]) } or return 0
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?
      report = @report
      commit = @commit
      return commit_comment(report, commit) if report && commit
      raise OptionParser::MissingArgument, "--report, and --head or --commit, are required" unless report && @head

      comment(report)
    rescue OptionParser::ParseError => e
      @err.puts "duel comment: #{e}"
      2
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--report DIR", "The directory of the Perf run's report (duel.md and comment.env), or of its reports (duel-report*/)") { |v| @report = v }
        o.on("--head SHA", "The commit the run compared, the pull request's head") { |v| @head = v }
        o.on("--commit SHA", "Comment on this pushed commit instead") { |v| @commit = v }
        o.on("--marker TEXT", "What marks Duel's comments (default: duel)") { |v| @marker = v }
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          throw :help
        end
      end
    end

    # Comments with the report in +dir+ (or the reports: see reports), if
    # Duel said to, and the pull request's head is still the run's.
    def comment(dir)
      reports = reports(dir)
      pr, mode, status = SAID.keys.map { |name| merged(name, reports.map { |report| said(name, report) }) }
      return quiet("Duel said not to") unless pr && mode && status

      head = (gitlab? ? merge_request(pr)&.fetch("sha") : gh("repos/#{repository}/pulls/#{pr}", "--jq", ".head.sha")&.chomp) or return 1
      return quiet("the #{gitlab? ? "merge" : "pull"} request has moved on since the run") unless head == @head

      ours = (gitlab? ? notes(pr) : earlier(pr)) or return 1
      ours = ours.select { |c| c.fetch("marked").start_with?("#{marker} status=") || c.fetch("marked") == "#{marker} -->" }
      last = ours.last&.fetch("marked")
      stale = last && !last.eql?("#{marker} status=#{status} -->")
      return quiet("the last comment says #{status} already") unless mode == "post" || stale

      post(pr, "#{marker} status=#{status} -->\n#{body(reports)}") or return 1
      @out.puts "duel comment: commented on #{gitlab? ? "merge request !" : "pull request "}#{pr}"
      ours.reject { |earlier| earlier.fetch("hidden") }.each { |earlier| hide(earlier.fetch("id")) } unless gitlab?
      0
    end

    # Comments on the pushed commit +sha+ with the report in +dir+, where
    # Duel said to (DUEL_COMMENT and DUEL_STATUS, the Duel job's outputs):
    # a new comment, which notifies its author, where it says to post, and
    # otherwise only where the last comment's status isn't this run's.
    # Its last comment is the last one on any commit (on GitLab, on the
    # commit before, CI_COMMIT_BEFORE_SHA).
    def commit_comment(dir, sha)
      mode, status = %w[comment status].map { |name| @env[GITLAB.fetch(name)].to_s[SAID.fetch(name)] }
      return quiet("Duel said not to") unless mode && status

      report = File.join(dir, "duel.md")
      return quiet("no report: the Duel job failed before it compared") unless File.file?(report)

      marked = (gitlab? ? commit_notes : commit_comments) or return 1
      last = marked.reverse.find { |first| first.start_with?("#{marker} status=") }
      stale = last && !last.eql?("#{marker} status=#{status} -->")
      return quiet("the last comment says #{status} already") unless mode == "post" || stale

      body = "#{marker} status=#{status} -->\n#{File.read(report)}"
      posted = gitlab? ? gitlab(:Post, "#{project}/repository/commits/#{sha}/comments", {"note" => body}) :
        gh("repos/#{repository}/commits/#{sha}/comments", "--method", "POST", "-f", "body=#{body}")
      return 1 unless posted

      @out.puts "duel comment: commented on commit #{sha}"
      0
    end

    # The markers (first lines) of GitHub Actions' comments on the
    # repository's commits, oldest first, or nil where GitHub wouldn't
    # list them.
    def commit_comments
      listed = gh("--paginate", "repos/#{repository}/comments", "--jq",
        '.[] | select(.user.login == "github-actions[bot]") | .body | split("\n")[0] | rtrimstr("\r")') or return
      listed.lines(chomp: true)
    end

    # The markers of the token's comments on the commit before the push
    # (CI_COMMIT_BEFORE_SHA), oldest first, or nil where GitLab wouldn't
    # list them.
    def commit_notes
      me = gitlab(:Get, "/user") or return
      before = @env.fetch("CI_COMMIT_BEFORE_SHA")
      comments = gitlab(:Get, "#{project}/repository/commits/#{before}/comments?per_page=100") or return
      comments.select { |comment| comment.dig("author", "id") == me.fetch("id") }.map { |comment| comment.fetch("note").lines.first.to_s.chomp }
    end

    # Posts +body+ as a new comment on the pull request (or merge request)
    # +pr+: what GitHub (or GitLab) said, or nil.
    def post(pr, body)
      return gh("repos/#{repository}/issues/#{pr}/comments", "--method", "POST", "-f", "body=#{body}") unless gitlab?

      gitlab(:Post, "#{project}/merge_requests/#{pr}/notes", {"body" => body})
    end

    # The reports' directories in +dir+: +dir+, or where there's no
    # report there (no comment.env), each of the Perf run's in a directory
    # of its own, as the reusable Perf comment workflow gets them,
    # duel-report and duel-report-NAME (where a call of the Perf workflow
    # named its report), in order (Dir.glob's).
    def reports(dir)
      return [dir] if gitlab? || File.file?(File.join(dir, "comment.env"))

      Dir.glob("duel-report{,-*}", base: dir).map { |name| File.join(dir, name) }
    end

    # What +values+, each report's, say together for +name+: the pull
    # request, where every one that names one names the same; a post, if
    # any says to (or else a change); and a status, failed if any failed,
    # passed if every one passed, and otherwise neutral. Nil where none
    # says it.
    def merged(name, values)
      said = values.compact
      return if said.empty?

      case name
      when "pr" then said.first if said.uniq.one?
      when "comment" then said.max # (post, where any says to)
      else
        return "failed" if said.include?("failed")

        values.all?("passed") ? "passed" : "neutral"
      end
    end

    # The comment's Markdown: the report's, or for more than one, each
    # under its name (its directory's, after duel-report-, or Duel, for
    # the one not named), cut to its share of ROOM, or where it has none,
    # NONE.
    def body(reports)
      case reports
      in [report] then File.read(File.join(report, "duel.md"))
      else
        share = ROOM / reports.size
        reports.map do |each|
          name = File.basename(each).delete_prefix("duel-report").delete_prefix("-")
          path = File.join(each, "duel.md")
          text = File.file?(path) ? File.read(path) : NONE
          "## #{name.empty? ? "Duel" : name}\n\n#{text[0, share].chomp}\n"
        end.join("\n")
      end
    end

    # What Duel said, as SAID has it, or nil: in +report+'s comment.env
    # (the last line that says it), or on GitLab CI, as GITLAB has it.
    def said(name, report)
      return @env[GITLAB.fetch(name)].to_s[SAID.fetch(name)] if gitlab?

      path = File.join(report, "comment.env")
      lines = File.file?(path) ? File.readlines(path, chomp: true) : [] #: Array[String]
      lines.map { |line| line[/\A#{name}=(.*)\z/, 1] }.grep(SAID.fetch(name)).last
    end

    # Duel's comments on the pull request, oldest first, each with its id,
    # whether it's hidden, and its marker (its first line), or nil where
    # GitHub wouldn't list them.
    def earlier(pr)
      owner, name = repository.split("/")
      listed = gh("graphql", "--paginate", "-f", "query=#{COMMENTS}", "-F", "pr=#{pr}", "-f", "owner=#{owner}", "-f", "name=#{name}",
        "--jq", LISTED) or return
      listed.lines.map { |line| JSON.parse(line) }
    end

    # The merge request +pr+, as GitLab's API has it, or nil.
    def merge_request(pr) = gitlab(:Get, "#{project}/merge_requests/#{pr}")

    # The token's notes on the merge request, oldest first, each with its
    # marker (its first line), or nil where GitLab wouldn't list them.
    def notes(pr)
      me = gitlab(:Get, "/user") or return
      notes = [] #: Array[Hash[String, untyped]]
      page = "1"
      while page
        listed, page = gitlab(:Get, "#{project}/merge_requests/#{pr}/notes?sort=asc&order_by=created_at&per_page=100&page=#{page}", pages: true)
        return unless listed

        notes.concat(listed)
      end
      notes.select { |note| note.dig("author", "id") == me.fetch("id") }.map { |note| {"marked" => note.fetch("body").lines.first.to_s.chomp} }
    end

    # Hides an earlier comment as outdated, which GitHub collapses, or
    # says it couldn't (it's still there, and that's all).
    def hide(id)
      query = "mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { clientMutationId } }"
      gh("graphql", "-f", "query=#{query}", "-f", "id=#{id}") || @err.puts("duel comment: couldn't hide an earlier comment")
    end

    # Says why it doesn't comment, and returns 0.
    def quiet(why)
      @out.puts "duel comment: no comment (#{why})"
      0
    end

    def marker = "<!-- #{@marker}"

    # (For Forge.)
    def command = "duel comment"

    # (A merge request's comment signs in with a token of its own, which
    # an unprotected pipeline has: a Reporter's. A push's, with the
    # Developer's that moves the branches.)
    def gitlab_token = @commit ? "DUEL_TOKEN" : "DUEL_COMMENT_TOKEN"
  end
end
