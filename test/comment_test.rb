# frozen_string_literal: true

require_relative "test_helper"
require "duel/comment"

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
    bin = FileUtils.mkdir_p(File.join(tmpdir, "bin")).first
    File.write(File.join(bin, "gh"), "#!/bin/sh\n[ \"$3\" = fail ] && { echo ' no ' >&2; exit 1; }\necho \"$*\"\n")
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    command = Duel::Comment.new([], env: {}, out: StringIO.new, err: (err = StringIO.new))

    with_path("#{bin}:#{ENV.fetch("PATH")}") do
      assert_equal "api a b\n", command.send(:gh, "a", "b")
      assert_nil command.send(:gh, "a", "fail")
      assert_equal "duel comment: gh api a: no\n", err.string
    end
    with_path(File.join(tmpdir, "nothing")) { assert_nil command.send(:gh, "a") }
    assert_match(/\Aduel comment: gh: No such file or directory/, err.string.lines.last)
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
      Usage: duel comment --report DIR --head SHA [--marker TEXT]

      Comments on a pull request with the report a Perf run kept in DIR, when Duel said to, and only if the pull
      request's head is still SHA: what the Perf comment workflow runs.

              --report DIR                 The directory of the Perf run's report (duel.md and comment.env)
              --head SHA                   The commit the run compared, the pull request's head
              --marker TEXT                What marks Duel's comments (default: duel)
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
