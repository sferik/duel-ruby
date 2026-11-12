# frozen_string_literal: true

require_relative "test_helper"
require "duel/comment"
require "socket"

# `duel comment`, which the Perf comment workflow runs: what it trusts in
# a Perf run's report, and what it asks GitHub for.
class CommentTest < DuelTest
  cover "Duel::Comment*"

  ENV_TEXT = "pr=12\ncomment=post\nstatus=failed\n"

  # A comment of Duel's, as the listing has it.
  def ours(id, marked = "<!-- duel status=failed -->", hidden: false) = JSON.generate({"id" => id, "hidden" => hidden, "marked" => marked})

  def report
    FileUtils.mkdir_p(File.join(tmpdir, "report")).first
  end

  # Runs `duel comment` on a report that says +said+ (comment.env), with
  # gh faked: the pull request's head is +head+, Duel's comments on it are
  # +listed+, and the calls in +failing+ fail. Returns its exit status,
  # and the calls it made to gh.
  def comment(said = ENV_TEXT, *argv, head: "abc", listed: [], failing: [], markdown: "**Slower**, says @someone\n")
    File.write(File.join(report, "comment.env"), said) if said
    File.write(File.join(report, "duel.md"), markdown)
    calls = []
    command = Duel::Comment.new(["--report", report, "--head", "abc", *argv], env: {"GITHUB_REPOSITORY" => "me/my_gem"},
      out: (@out = StringIO.new), err: (@err = StringIO.new))
    command.define_singleton_method(:gh) do |*args|
      calls << args
      next if failing.include?(args.first) || failing.any? { |arg| args.include?(arg) }

      if args.first == "repos/me/my_gem/pulls/12" then "#{head}\n"
      elsif args.include?("--paginate") then listed.map { |line| "#{line}\n" }.join
      else "{}"
      end
    end
    [command.run, calls]
  end

  # The comments it posted: their bodies.
  def posted(calls) = calls.select { |call| call.include?("POST") }.map { |call| call.last.delete_prefix("body=") }

  # The comments it hid: their ids.
  def hidden(calls) = calls.select { |call| call.first == "graphql" && !call.include?("--paginate") }.map { |call| call.last.delete_prefix("id=") }

  # With nothing before it, it posts the report, with its marker and
  # status on the first line: a new comment, as Markdown.
  def test_a_comment
    status, calls = comment

    assert_equal 0, status
    assert_equal ["<!-- duel status=failed -->\n**Slower**, says @someone\n"], posted(calls)
    assert_equal [["repos/me/my_gem/pulls/12", "--jq", ".head.sha"],
      ["graphql", "--paginate", "-f", "query=#{Duel::Comment::COMMENTS}", "-F", "pr=12", "-f", "owner=me", "-f", "name=my_gem", "--jq",
        Duel::Comment::LISTED],
      ["repos/me/my_gem/issues/12/comments", "--method", "POST", "-f", "body=#{posted(calls).first}"]], calls
    assert_equal "duel comment: commented on pull request 12\n", @out.string
    assert_empty @err.string
  end

  # Once it has posted, it hides each of Duel's earlier comments as
  # outdated (but those hidden already), and says so where GitHub wouldn't
  # (which doesn't fail it).
  def test_hiding_earlier_comments
    status, calls = comment(listed: [ours("A"), ours("B", "<!-- duel status=passed -->")])

    assert_equal [0, %w[A B]], [status, hidden(calls)]
    query = "query=mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { clientMutationId } }"

    assert_equal ["graphql", "-f", query, "-f", "id=A"], calls.find { |call| call.first == "graphql" && !call.include?("--paginate") }
    _, calls = comment(listed: [ours("A", hidden: true), ours("B")])

    assert_equal %w[B], hidden(calls), "not one hidden already"
    status, calls = comment(listed: [ours("A")], failing: ["id=A"])

    assert_equal [0, %w[A]], [status, hidden(calls)]
    assert_equal "duel comment: couldn't hide an earlier comment\n", @err.string
  end

  # It trusts only what Duel could have said, on a line of its own: a
  # number, post or change, and a status. Of any it says twice, the last.
  def test_what_duel_said
    assert_equal [[0, []]] * 7, ["pr=12; rm -rf /\ncomment=post\nstatus=failed\n", "pr=12\ncomment=post\nstatus=failed -->\n",
      "pr=\ncomment=post\nstatus=failed\n", "pr=12\ncomment=none\nstatus=failed\n", "pr=12\nstatus=failed\n", "pr=12\ncomment=post\n",
      "comment=post\nstatus=failed\n"].map { |said| comment(said) }
    assert_equal "duel comment: no comment (Duel said not to)\n", @out.string
    assert_equal 1, posted(comment("pr=7\npr=12\ncomment=change\ncomment=post\nstatus=passed\nstatus=failed\n").last).size
    assert_equal 1, posted(comment(" pr=12\npr=12\ncomment=post\nstatus=failed\n").last).size, "from the line's start"
    assert_equal [], comment("xpr=12\ncomment=post\nstatus=failed\n").last
    assert_equal [], comment("12\ncomment=post\nstatus=failed\n").last, "named"
    FileUtils.rm(File.join(report, "comment.env"))

    assert_equal [0, []], comment(nil), "none said"
    FileUtils.rm(File.join(report, "comment.env"), force: true)
    FileUtils.mkdir(File.join(report, "comment.env"))

    assert_equal [0, []], comment(nil), "not a file"
  end

  # A pull request whose head has moved on since the run gets nothing.
  def test_a_pull_request_that_moved_on
    status, calls = comment(head: "def")

    assert_equal [0, 1], [status, calls.size]
    assert_equal "duel comment: no comment (the pull request has moved on since the run)\n", @out.string
  end

  # change: a comment only where the last of Duel's had another status
  # (Duel 0.1.0's had none), so the last is never stale.
  def test_a_change
    change = "pr=12\ncomment=change\nstatus=failed\n"

    assert_empty posted(comment(change).last), "none before it"
    assert_empty posted(comment(change, listed: [ours("A", "<!-- duel status=passed -->"), ours("B")]).last)
    assert_equal "duel comment: no comment (the last comment says failed already)\n", @out.string
    assert_equal 1, posted(comment(change, listed: [ours("A"), ours("B", "<!-- duel status=passed -->")]).last).size
    assert_equal 1, posted(comment(change, listed: [ours("A", "<!-- duel -->")]).last).size
    assert_empty posted(comment(change, listed: [ours("A"), ours("B", "<!-- duel gems/parser status=passed -->")]).last), "another project's"
  end

  # --marker names the project, in a monorepo.
  def test_a_marker
    _, calls = comment(ENV_TEXT, "--marker", "duel gems/parser", listed: [ours("A"), ours("B", "<!-- duel gems/parser -->")])

    assert_equal [["<!-- duel gems/parser status=failed -->\n**Slower**, says @someone\n"], %w[B]], [posted(calls), hidden(calls)]
  end

  # Where GitHub won't say what it needs, or take the comment, it fails.
  def test_github_failing
    assert_equal [1, 1], comment(failing: ["repos/me/my_gem/pulls/12"]).then { |status, calls| [status, calls.size] }
    assert_equal [1, 2], comment(failing: ["--paginate"]).then { |status, calls| [status, calls.size] }
    status, calls = comment(listed: [ours("A")], failing: ["POST"])

    assert_equal [1, 3], [status, calls.size], "nothing hidden"
    assert_empty @out.string
  end

  # The jq that lists Duel's comments: github-actions', each with its id,
  # whether it's hidden, and the first line of its body.
  def test_the_listing
    skip "no jq" unless system("jq", "--version", out: File::NULL, err: File::NULL)
    nodes = [{"id" => "A", "isMinimized" => false, "author" => {"login" => "github-actions"}, "body" => "<!-- duel status=failed -->\r\n### Duel"},
      {"id" => "B", "isMinimized" => false, "author" => {"login" => "someone"}, "body" => "<!-- duel status=failed -->"},
      {"id" => "C", "isMinimized" => true, "author" => {"login" => "github-actions"}, "body" => "plain"},
      {"id" => "D", "isMinimized" => false, "author" => nil, "body" => "ghost"}]
    page = {"data" => {"repository" => {"pullRequest" => {"comments" => {"nodes" => nodes}}}}}
    listed = IO.popen(["jq", "-c", Duel::Comment::LISTED], "r+") do |io|
      io.write(JSON.generate(page))
      io.close_write
      io.read
    end

    assert_equal [{"id" => "A", "hidden" => false, "marked" => "<!-- duel status=failed -->"}, {"id" => "C", "hidden" => true, "marked" => "plain"}],
      listed.lines.map { |line| JSON.parse(line) }
  end

  # The query pages through the comments as gh api graphql --paginate does.
  def test_the_query
    assert_includes Duel::Comment::COMMENTS, "$endCursor: String"
    assert_includes Duel::Comment::COMMENTS, "comments(first: 100, after: $endCursor)"
    assert_includes Duel::Comment::COMMENTS, "pageInfo { hasNextPage endCursor }"
  end

  # gh api: what it prints, or nil
  # where it fails or isn't there, which it says.
  def test_gh
    bin = File.join(tmpdir, "bin")
    fake_command(File.join(bin, "gh"), %([ "$3" = fail ] && { echo ' no ' >&2; exit 1; }\necho "$*"))
    command = Duel::Comment.new([], env: {}, out: StringIO.new, err: (err = StringIO.new))

    with_path(path_with(bin)) do
      assert_equal "api a b\n", command.send(:gh, "a", "b")
      assert_nil command.send(:gh, "a", "fail")
      assert_equal "duel comment: gh api a: no\n", err.string
    end
    with_path(File.join(tmpdir, "nothing")) { assert_nil command.send(:gh, "a") }
    assert_match(/\Aduel comment: gh: No such file or directory/, err.string.lines.last)
  end

  GITLAB_ENV = {"CI_API_V4_URL" => "https://gitlab.example/api/v4", "CI_PROJECT_ID" => "7", "DUEL_COMMENT_TOKEN" => "t",
                "CI_MERGE_REQUEST_IID" => "12", "DUEL_COMMENT" => "post", "DUEL_STATUS" => "failed"}.freeze

  # A note of GitLab's API, by +author+ (an id).
  def note(id, body, author: 5) = {"id" => id, "author" => {"id" => author}, "body" => body}

  # Runs `duel comment --gitlab` in an environment of GITLAB_ENV and
  # +env+, with GitLab's API faked: the merge request's head is +head+,
  # its notes' pages are +notes+, and the calls in +failing+ fail.
  # Returns its exit status, and the calls it made.
  def gitlab_comment(*argv, env: {}, head: "abc", notes: [[]], failing: [])
    File.write(File.join(report, "duel.md"), "**Slower**\n")
    calls = []
    paging = method(:page_of)
    command = Duel::Comment.new(["--gitlab", "--report", report, "--head", "abc", *argv], env: GITLAB_ENV.merge(env),
      out: (@out = StringIO.new), err: (@err = StringIO.new))
    command.define_singleton_method(:gitlab) do |verb, path, body = nil, pages: false|
      calls << [verb, path, body, pages].compact.reject { |arg| arg == false }
      next if failing.any? { |part| path.include?(part) || verb.to_s == part }

      case path
      when "/user" then {"id" => 5}
      when "/projects/7/merge_requests/12" then {"sha" => head}
      when %r{notes\?.*page=(\d+)\z} then paging.call(notes, Integer($1))
      else {}
      end
    end
    command.define_singleton_method(:hide) { |id| calls << [:hide, id] }
    [command.run, calls]
  end

  # The page +number+ of +pages+, and the next one's number, if there's one.
  def page_of(pages, number) = [pages.fetch(number - 1), ((number + 1).to_s if number < pages.size)]

  # On GitLab CI, what Duel said is the Duel job's dotenv report's, and the
  # merge request's, and it posts the report as a new note, after checking
  # the merge request's head.
  def test_a_gitlab_comment
    status, calls = gitlab_comment

    assert_equal 0, status
    assert_equal [[:Get, "/projects/7/merge_requests/12"], [:Get, "/user"],
      [:Get, "/projects/7/merge_requests/12/notes?sort=asc&order_by=created_at&per_page=100&page=1", true],
      [:Post, "/projects/7/merge_requests/12/notes", {"body" => "<!-- duel status=failed -->\n**Slower**\n"}]], calls
    assert_equal "duel comment: commented on merge request !12\n", @out.string
    assert_equal [0, 1], gitlab_comment(head: "def").then { |done, made| [done, made.size] }
    assert_equal "duel comment: no comment (the merge request has moved on since the run)\n", @out.string
  end

  # It trusts only what Duel could have said, as on GitHub.
  def test_what_duel_said_on_gitlab
    [{"DUEL_COMMENT" => "none"}, {"DUEL_STATUS" => "failed -->"}, {"CI_MERGE_REQUEST_IID" => "12; x"}, {"DUEL_COMMENT" => ""}].each do |env|
      assert_equal [0, []], gitlab_comment(env: env), env.inspect
    end
    command = Duel::Comment.new(["--gitlab", "--report", report, "--head", "abc"], env: GITLAB_ENV.except("DUEL_STATUS"), out: StringIO.new,
      err: StringIO.new)

    assert_equal 0, command.run, "none said"
  end

  # change: a note only where the last of the token's own had another
  # status, through every page of the notes, and others' don't count.
  def test_a_gitlab_change
    change = {"DUEL_COMMENT" => "change"}

    assert_equal 3, gitlab_comment(env: change).last.size, "none before it: nothing posted"
    _, calls = gitlab_comment(env: change, notes: [[note(1, "<!-- duel status=passed -->\n### Duel")], [note(2, "<!-- duel status=failed -->\r\n### Duel")]])

    refute(calls.any? { |call| call.first == :Post }, "the last says failed")
    assert_equal 2, calls.count { |call| call[1].include?("notes?") }, "both pages"
    _, calls = gitlab_comment(env: change, notes: [[note(1, "<!-- duel status=failed -->")], [note(2, "<!-- duel status=passed -->\r\nx")]])

    assert(calls.any? { |call| call.first == :Post }, "the last says passed")
    _, calls = gitlab_comment(env: change, notes: [[note(1, "<!-- duel status=failed -->"), note(2, "<!-- duel status=passed -->", author: 6)]])

    refute(calls.any? { |call| call.first == :Post }, "another's doesn't count")
    _, calls = gitlab_comment(env: change, notes: [[note(1, "<!-- duel status=failed -->"), note(2, ""), {"id" => 3, "body" => "<!-- duel -->"}]])

    refute(calls.any? { |call| call.first == :Post }, "an empty note, or one of no one's, doesn't count")
  end

  # It hides nothing on GitLab: only a Developer can resolve a thread.
  def test_nothing_hidden_on_gitlab
    _, calls = gitlab_comment(notes: [[note(1, "<!-- duel status=passed -->")]])

    assert(calls.any? { |call| call.first == :Post })
    refute(calls.any? { |call| call.first == :hide })
  end

  # Where GitLab won't say what it needs, or take the note, it fails.
  def test_gitlab_failing
    assert_equal [1, 1], gitlab_comment(failing: ["merge_requests/12"]).then { |status, calls| [status, calls.size] }
    assert_equal [1, 2], gitlab_comment(failing: ["/user"]).then { |status, calls| [status, calls.size] }
    assert_equal [1, 3], gitlab_comment(failing: ["notes?"]).then { |status, calls| [status, calls.size] }
    assert_equal 1, gitlab_comment(failing: ["Post"]).first
    assert_empty @out.string
  end

  # A local HTTP server that answers each request with the next of
  # +answers+ ([status, headers, body]), for GitLab's API: its URL, and
  # the requests it got (each its request line, headers and body).
  def http_server(answers)
    server = TCPServer.new("127.0.0.1", 0)
    got = []
    thread = Thread.new do
      answers.each do |status, headers, body|
        client = server.accept
        head = +""
        head << client.gets until head.end_with?("\r\n\r\n")
        length = head[/^content-length: (\d+)/i, 1].to_i
        got << [head, client.read(length)]
        client.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n" \
          "#{headers.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n#{body}")
        client.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}/api/v4", got
  ensure
    thread&.join(5)
    server&.close
  end

  # GitLab's API, as the comment job has it: JSON, signed in with
  # DUEL_COMMENT_TOKEN, and with +pages+, the next page's number. Where it
  # fails (an error status, JSON that isn't, or no server), nil, which it
  # says why.
  def test_gitlabs_api
    answers = [["200 OK", {"X-Next-Page" => "12"}, %([{"id": 1}])], ["200 OK", {"X-Next-Page" => ""}, "[]"], ["201 Created", {}, %({"id": 3})],
      ["404 Not Found", {}, %( {"message": "404 Not found"}  \n)], ["404 Not Found", {}, ""], ["200 OK", {}, "{"], ["200 OK", {}, "[]"],
      ["304 Not Modified", {}, ""]]
    http_server(answers) do |url, got|
      command = Duel::Comment.new([], env: GITLAB_ENV.merge("CI_API_V4_URL" => url), out: StringIO.new, err: (err = StringIO.new))

      assert_equal [[{"id" => 1}], "12"], command.send(:gitlab, :Get, "/projects/7/x?page=1", pages: true)
      assert_equal [[], nil], command.send(:gitlab, :Get, "/projects/7/x?page=2", pages: true), "the last page"
      assert_equal({"id" => 3}, command.send(:gitlab, :Post, "/projects/7/notes", {"body" => "hi"}))
      assert_nil command.send(:gitlab, :Get, "/user")
      assert_nil command.send(:gitlab, :Get, "/user", pages: true)
      assert_nil command.send(:gitlab, :Get, "/user")
      assert_equal [[], nil], command.send(:gitlab, :Get, "/projects/7/x?page=3", pages: true), "no X-Next-Page"
      assert_nil command.send(:gitlab, :Get, "/user"), "no body"
      said = err.string.lines(chomp: true)

      assert_equal ["duel comment: GitLab: GET /user: 404 {\"message\": \"404 Not found\"}", "duel comment: GitLab: GET /user: 404"], said.first(2)
      assert_match(/\Aduel comment: GitLab: GET \/user: \S/, said[2], "JSON that isn't")
      assert_equal ["duel comment: GitLab: GET /user: 304"], said.last(1)
      assert_equal 4, said.size
    end
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    command = Duel::Comment.new([], env: GITLAB_ENV.merge("CI_API_V4_URL" => "http://127.0.0.1:#{port}"), out: StringIO.new,
      err: (err = StringIO.new))

    assert_nil command.send(:gitlab, :Get, "/user", pages: true)
    assert_match(/\Aduel comment: GitLab: GET \/user: \S/, err.string)
  end

  # What it sends: the path under CI_API_V4_URL, the token, and a body (as
  # JSON) only where it's given one.
  def test_what_it_sends_gitlabs_api
    http_server([["200 OK", {}, "{}"], ["201 Created", {}, "{}"]]) do |url, got|
      command = Duel::Comment.new([], env: GITLAB_ENV.merge("CI_API_V4_URL" => url), out: StringIO.new, err: StringIO.new)
      command.send(:gitlab, :Get, "/projects/7/x?page=1")
      command.send(:gitlab, :Post, "/projects/7/notes", {"body" => "hi"})
      (get, nothing), (post, body) = got

      assert_match %r{\AGET /api/v4/projects/7/x\?page=1 HTTP/1.1\r\n}, get
      assert_equal "", nothing, "a GET has no body"
      assert_match %r{\APOST /api/v4/projects/7/notes HTTP/1.1\r\n}, post
      assert_match(/^private-token: t\r$/i, post)
      assert_match(%r{^content-type: application/json\r$}i, post)
      assert_equal %({"body":"hi"}), body
    end
  end

  # An https URL is TLS's: a server that answers in plain HTTP fails it.
  def test_gitlabs_api_over_tls
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
      client.close
    end
    command = Duel::Comment.new([], env: GITLAB_ENV.merge("CI_API_V4_URL" => "https://127.0.0.1:#{server.addr[1]}"), out: StringIO.new,
      err: (err = StringIO.new))

    assert_nil command.send(:gitlab, :Get, "/user")
    assert_match(/\Aduel comment: GitLab: GET \/user: \S/, err.string)
  ensure
    thread&.join(5)
    server&.close
  end

  def with_path(path)
    original = ENV.fetch("PATH")
    ENV["PATH"] = path
    yield
  ensure
    ENV["PATH"] = original
  end

  def test_options
    assert_equal 0, Duel::Comment.new(["--help"], env: {}, out: (out = StringIO.new), err: StringIO.new).run
    assert_equal <<~HELP, out.string
      Usage: duel comment --report DIR --head SHA [--marker TEXT] [--gitlab]

      Comments on a pull request with the report a Perf run kept in DIR, when Duel said to, and only if the pull
      request's head is still SHA: what the Perf comment workflow runs (or with --gitlab, the comment job).

              --report DIR                 The directory of the Perf run's report (duel.md and comment.env)
              --head SHA                   The commit the run compared, the pull request's head
              --marker TEXT                What marks Duel's comments (default: duel)
              --gitlab                     Comment on a GitLab merge request, from GitLab CI (with DUEL_COMMENT_TOKEN)
          -h, --help                       Print this help
    HELP
    assert_equal 0, Duel::Comment.new(["-h"], env: {}, out: StringIO.new, err: StringIO.new).run
    {[] => "missing argument: --report and --head are required", %w[--report x] => "missing argument: --report and --head are required",
     %w[--head x] => "missing argument: --report and --head are required", %w[--report x --head y z w] => "needless argument: z",
     ["--nope"] => "invalid option: --nope"}.each do |argv, said|
      assert_equal 2, Duel::Comment.new(argv, env: {}, out: StringIO.new, err: (err = StringIO.new)).run
      assert_equal "duel comment: #{said}\n", err.string
    end
    assert_equal 0, Duel::CLI.new(%w[comment --help], out: StringIO.new, err: StringIO.new).run, "from duel"
  rescue SystemExit
    flunk "OptionParser's own --help exits"
  end
end
