# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "optparse"
require "uri"

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
  # With --gitlab, it's what the GitLab CI jobs' comment job runs, on a
  # merge request: what Duel said is the Duel job's dotenv report's
  # (DUEL_COMMENT and DUEL_STATUS), it talks to GitLab's API
  # (CI_API_V4_URL) with DUEL_COMMENT_TOKEN, and it hides nothing, as only
  # a Developer can resolve a thread, and a merge request's token is a
  # Reporter's.
  # @api private
  class Comment
    USAGE = "Usage: duel comment --report DIR --head SHA [--marker TEXT] [--gitlab]\n\n" \
      "Comments on a pull request with the report a Perf run kept in DIR, when Duel said to, and only if the pull\n" \
      "request's head is still SHA: what the Perf comment workflow runs (or with --gitlab, the comment job).\n\n"

    # The first release of Duel whose `duel comment` the Perf comment
    # workflow that this one writes can run: it installs the newest
    # release of the same minor version (~>), so a fix comes with one.
    SINCE = "0.1.8"

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
      rest = catch(:help) { parser.parse(@argv) } or return 0
      raise OptionParser::NeedlessArgument, rest.first unless rest.empty?
      report = @report
      raise OptionParser::MissingArgument, "--report and --head are required" unless report && @head

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
        o.on("--marker TEXT", "What marks Duel's comments (default: duel)") { |v| @marker = v }
        o.on("--gitlab", "Comment on a GitLab merge request, from GitLab CI (with DUEL_COMMENT_TOKEN)") { @gitlab = true }
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

      head = (@gitlab ? merge_request(pr)&.fetch("sha") : gh("repos/#{repository}/pulls/#{pr}", "--jq", ".head.sha")&.chomp) or return 1
      return quiet("the #{@gitlab ? "merge" : "pull"} request has moved on since the run") unless head == @head

      ours = (@gitlab ? notes(pr) : earlier(pr)) or return 1
      ours = ours.select { |c| c.fetch("marked").start_with?("#{marker} status=") || c.fetch("marked") == "#{marker} -->" }
      last = ours.last&.fetch("marked")
      stale = last && !last.eql?("#{marker} status=#{status} -->")
      return quiet("the last comment says #{status} already") unless mode == "post" || stale

      post(pr, "#{marker} status=#{status} -->\n#{body(reports)}") or return 1
      @out.puts "duel comment: commented on #{@gitlab ? "merge request !" : "pull request "}#{pr}"
      ours.reject { |earlier| earlier.fetch("hidden") }.each { |earlier| hide(earlier.fetch("id")) } unless @gitlab
      0
    end

    # Posts +body+ as a new comment on the pull request (or merge request)
    # +pr+: what GitHub (or GitLab) said, or nil.
    def post(pr, body)
      return gh("repos/#{repository}/issues/#{pr}/comments", "--method", "POST", "-f", "body=#{body}") unless @gitlab

      gitlab(:Post, "#{project}/merge_requests/#{pr}/notes", {"body" => body})
    end

    # The reports' directories in +dir+: +dir+, or where there's no
    # report there (no comment.env), each of the Perf run's in a directory
    # of its own, as the reusable Perf comment workflow gets them,
    # duel-report and duel-report-NAME (where a call of the Perf workflow
    # named its report), in order (Dir.glob's).
    def reports(dir)
      return [dir] if @gitlab || File.file?(File.join(dir, "comment.env"))

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
      return @env[GITLAB.fetch(name)].to_s[SAID.fetch(name)] if @gitlab

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

    # What gh api prints, given +args+, or nil where it fails (or isn't
    # there), which it says why.
    def gh(*args)
      out, err, status = Open3.capture3("gh", "api", *args)
      return out if status.success?

      @err.puts "duel comment: gh api #{args.first}: #{err.strip}"
    rescue SystemCallError => e
      @err.puts "duel comment: gh: #{e}"
    end

    # What GitLab's API says to +verb+ (:Get or :Post) +path+ (under
    # CI_API_V4_URL), given +body+ (as JSON), signed in with
    # DUEL_COMMENT_TOKEN, or nil where it fails, which it says why. With
    # +pages+, that and the next page's number (X-Next-Page), if there's
    # one.
    def gitlab(verb, path, body = nil, pages: false)
      uri = URI("#{@env.fetch("CI_API_V4_URL")}#{path}")
      request = Net::HTTP.const_get(verb).new(uri)
      request["PRIVATE-TOKEN"] = @env.fetch("DUEL_COMMENT_TOKEN")
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      http = connection(uri)
      http.use_ssl = uri.scheme == "https"
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        return @err.puts("duel comment: GitLab: #{verb.upcase} #{path}: #{[response.code, response.body.to_s.strip].reject(&:empty?).join(" ")}")
      end

      parsed = JSON.parse(response.body)
      pages ? [parsed, response["X-Next-Page"].to_s[/\A[0-9]+\z/]] : parsed
    rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError => e
      @err.puts "duel comment: GitLab: #{verb.upcase} #{path}: #{e}"
    end

    # A connection to +uri+'s host, not yet started.
    # mutant:disable -- a nil host is Net::HTTP's localhost, where the
    # tests' server is, so only another host could tell them apart
    def connection(uri) = Net::HTTP.new(uri.host.to_s, uri.port)

    # Says why it doesn't comment, and returns 0.
    def quiet(why)
      @out.puts "duel comment: no comment (#{why})"
      0
    end

    def marker = "<!-- #{@marker}"

    def repository = @env.fetch("GITHUB_REPOSITORY")

    # The project's path in GitLab's API.
    def project = "/projects/#{@env.fetch("CI_PROJECT_ID")}"
  end
end
