# frozen_string_literal: true

require_relative "test_helper"

# `duel mark-passed BRANCH`, with GitHub's and GitLab's APIs faked.
class MarkPassedTest < DuelTest
  cover "Duel::MarkPassed*"
  cover "Duel::Forge*"

  GITHUB = {"GITHUB_REPOSITORY" => "me/mine", "GITHUB_SHA" => "abc"}.freeze
  GITLAB = {"GITLAB_CI" => "true", "CI_API_V4_URL" => "https://gitlab/api/v4", "CI_PROJECT_ID" => "7", "DUEL_TOKEN" => "t",
            "CI_COMMIT_SHA" => "abc"}.freeze

  def command(*argv, env:) = Duel::MarkPassed.new(argv, env: env, out: (@out = StringIO.new), err: (@err = StringIO.new))

  # The push's commit, and others.
  PUSHED = "a" * 40
  OLDER = "b" * 40
  MARK = "c" * 40

  # What gh's asked to make a mark of PUSHED (as a tree, then a commit,
  # after +parent+), and to make the branch at it.
  def marked(parent = nil)
    [["repos/me/mine/git/trees", "--method", "POST", "-f", "tree[][path]=passed", "-f", "tree[][mode]=100644", "-f", "tree[][type]=blob",
      "-f", "tree[][content]=#{PUSHED}\n", "--jq", ".sha"],
      ["repos/me/mine/git/commits", "--method", "POST", "-f", "message=Duel passed #{PUSHED}", "-f", "tree=tree", *(["-f", "parents[]=#{parent}"] if parent),
        "--jq", ".sha"]]
  end

  def made(*quiet) = ["repos/me/mine/git/refs", "--method", "POST", "-f", "ref=refs/heads/duel/passed/main", "-f", "sha=mark", *quiet]

  def looked = ["repos/me/mine/git/ref/heads/duel/passed/main", "--jq", ".object.sha", :quiet]

  # Runs it on GitHub, where the branch is at +at+ (nil for none: each
  # look, the next of them, given a list), whose message is +message+,
  # the calls in +failing+ fail, and comparing the push with the commit
  # it marks says +compared+. Returns its exit status, and the calls to
  # gh.
  def on_github(at: nil, message: "Duel passed #{OLDER}\n", failing: [], compared: "behind", blocker: nil)
    calls = []
    run = command("duel/passed/main", env: GITHUB.merge("GITHUB_SHA" => PUSHED))
    ats = Array(at)
    next_at = -> { (ats.size > 1) ? ats.shift : ats.first }
    run.define_singleton_method(:gh) do |*args, quiet: false|
      calls << [*args, *(:quiet if quiet)]
      said = args.join(" ")
      next if failing.any? { |part| part.is_a?(Regexp) ? said.match?(part) : said.include?(part) }

      case args.first
      when %r{/git/ref/heads/(.*)\z} then ($1 == "duel/passed/main") ? next_at.call&.then { |sha| "#{sha}\n" } : ("x\n" if $1 == blocker)
      when %r{/git/commits/} then message
      when %r{/git/trees\z} then "tree\n"
      when %r{/git/commits\z} then "mark\n"
      else "{}"
      end
    end
    run.define_singleton_method(:compared) { |sha, ref| (calls << [:compared, sha, ref]) && compared }
    [run.run, calls]
  end

  # Made, at a mark with no parent, where there's none.
  def test_making_it
    status, calls = on_github

    assert_equal [0, [looked, *marked, made(:quiet)]], [status, calls]
    assert_equal "duel mark-passed: duel/passed/main marks #{PUSHED}\n", @out.string
    assert_empty @err.string
  end

  # Moved forward, to a mark whose parent is the mark before, where GitHub
  # moves it only where nothing moved it since. Where history was
  # rewritten, it's moved anyway.
  def test_moving_it_forward
    %w[behind diverged unrelated].each do |compared|
      status, calls = on_github(at: MARK, compared:)

      assert_equal [0, [looked, ["repos/me/mine/git/commits/#{MARK}", "--jq", ".message"], [:compared, PUSHED, OLDER], *marked(MARK),
        ["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=mark", :quiet]]], [status, calls], compared
      assert_equal "duel mark-passed: duel/passed/main marks #{PUSHED}\n", @out.string
    end
  end

  # Where it's at one of the project's commits (moved there by hand, or by
  # Duel 0.3), that's the commit it marks, and it's deleted and made again
  # at a mark, as moving it would take its workflows away.
  def test_where_it_is_at_a_commit
    status, calls = on_github(at: OLDER, message: "Add a benchmark\n")

    assert_equal [0, [looked, ["repos/me/mine/git/commits/#{OLDER}", "--jq", ".message"], [:compared, PUSHED, OLDER], *marked,
      ["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "DELETE", :quiet], made(:quiet)]], [status, calls]
    assert_equal "duel mark-passed: duel/passed/main marks #{PUSHED}\n", @out.string
    assert_equal [OLDER, "Duel passed #{PUSHED}x"].map { |sha| on_github(at: OLDER, message: "Duel passed #{sha}\n").last[2].last },
      [OLDER, OLDER], "not a mark: not quite a commit"
    assert_equal OLDER, on_github(at: MARK, message: "Duel passed #{OLDER}").last[2].last, "a mark, without the newline"
    assert_equal "f" * 64, on_github(at: MARK, message: "Duel passed #{"f" * 64}\n").last[2].last, "SHA-256"
    assert_equal MARK, on_github(at: MARK, message: "Duel passed #{"f" * 50}\n").last[2].last
    assert_equal MARK, on_github(at: MARK, message: "Duel passed #{"f" * 39}\n").last[2].last
    assert_equal MARK, on_github(at: MARK, message: "Duel passed #{"f" * 40}\nmore\n").last[2].last
  end

  # Where it marks a commit ahead of the push's (a newer push's run marked
  # it), or the push's own, it's left there.
  def test_where_it_marks_a_newer_push
    %w[ahead identical].each do |compared|
      status, calls = on_github(at: MARK, compared:)

      assert_equal [0, [:compared, PUSHED, OLDER]], [status, calls.last], compared
      assert_equal "duel mark-passed: duel/passed/main marks a newer push's commit, which it's left at\n", @out.string
    end
    assert_equal [1, "::error::Couldn't compare duel/passed/main with this push: Not Found\n"],
      [on_github(at: MARK, compared: "Not Found").first, @out.string]
  end

  # Where something moved it, or made it, first, it looks once more, and
  # says why it fails the second time.
  def test_where_something_moved_it_first
    status, calls = on_github(at: [MARK, MARK, MARK], failing: ["PATCH"])

    assert_equal [1, 12], [status, calls.size]
    assert_equal [["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=mark", :quiet],
      ["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=mark"]], [calls[5], calls.last]
    status, calls = on_github(at: [nil, MARK], failing: ["POST -f ref="])

    assert_equal [0, made(:quiet)], [status, calls[3]], "made by something else"
    assert_equal ["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=mark"], calls.last
    status, calls = on_github(at: OLDER, message: "Add a benchmark\n", failing: ["POST -f ref="])

    assert_equal [1, made], [status, calls.last], "deleted, and made again"
    assert_equal 1, on_github(at: OLDER, failing: ["PATCH"]).first
  end

  # Where GitHub won't say what the commit there is, or make a mark, it
  # fails.
  def test_where_github_fails
    assert_equal [1, ["repos/me/mine/git/commits/#{MARK}", "--jq", ".message"]], on_github(at: MARK, failing: [%r{commits/c}]).then { |s, c| [s, c.last] }
    assert_equal [1, 4], on_github(at: MARK, failing: ["trees"]).then { |s, c| [s, c.size] }
    assert_equal [1, 5], on_github(at: MARK, failing: [%r{commits --method}]).then { |s, c| [s, c.size] }
    assert_equal [1, 6], on_github(failing: ["trees"]).then { |s, c| [s, c.size] }, "looked at twice, then blocked"
  end

  # A branch whose name is a folder of the branch's keeps Git from making
  # it: it's named.
  def test_a_branch_in_the_way
    status, calls = on_github(failing: ["POST -f ref="], blocker: "duel")

    assert_equal [1, made], [status, calls[-3]], "said why, the second time"
    assert_equal [["repos/me/mine/git/ref/heads/duel/passed", :quiet], ["repos/me/mine/git/ref/heads/duel", :quiet]], calls.last(2)
    assert_equal "::error::The branch duel keeps Duel from making duel/passed/main, as Git can't have both. " \
      "Delete it (git push origin --delete duel), or rename it.\n", @out.string
  end

  # How GitHub compares: its status, or unrelated, where the commits have
  # no history in common or one isn't there, or what went wrong.
  def test_compared
    run = command("duel/passed/main", env: GITHUB)
    asked = []
    said = lambda do |out, err, success|
      stub(Duel::Spawn, :open3, ->(*args, **) { (asked << args) && [out, err, Struct.new(:success?).new(success)] }) { run.send(:compared, "abc", "def") }
    end

    assert_equal "ahead", said.call("ahead\n", "", true)
    assert_equal [:capture3, "gh", "api", "repos/me/mine/compare/abc...def", "--jq", ".status"], asked.first
    assert_equal "unrelated", said.call("", "gh: No common ancestor between abc and def (HTTP 404)\n", false)
    assert_equal "unrelated", said.call("", "gh: No commit found for SHA: def (HTTP 404)\n", false), "gone, after a force push"
    assert_equal "Not Found", said.call("", "  Not Found\n", false)
  end

  # Runs it on GitLab, where the branch is at +at+ (nil for none), their
  # merge base is +base+, and the calls in +failing+ fail. Returns its exit
  # status, and the calls to GitLab's API.
  def on_gitlab(at: nil, base: nil, failing: [], blocker: nil)
    calls = []
    run = command("duel/passed/main", env: GITLAB)
    run.define_singleton_method(:gitlab) do |verb, path, body = nil, quiet: false|
      calls << [verb, path, body, *(:quiet if quiet)].compact
      next if failing.any? { |part| "#{verb} #{path}".include?(part) }

      case path
      when "/projects/7/repository/branches/duel%2Fpassed%2Fmain" then (verb == :Get) ? (at && {"commit" => {"id" => at}}) : {}
      when "/projects/7/repository/branches/duel" then ({} if blocker)
      when %r{/branches/} then nil
      when /merge_base/ then base && ((base == :none) ? {} : {"id" => base})
      else {}
      end
    end
    [run.run, calls]
  end

  def test_on_gitlab
    made = [[:Delete, "/projects/7/repository/branches/duel%2Fpassed%2Fmain", :quiet],
      [:Post, "/projects/7/repository/branches", {"branch" => "duel/passed/main", "ref" => "abc"}, :quiet]]

    assert_equal [0, [[:Get, "/projects/7/repository/branches/duel%2Fpassed%2Fmain", :quiet], *made]], on_gitlab, "made"
    assert_equal "duel mark-passed: duel/passed/main marks abc\n", @out.string
    assert_equal made, on_gitlab(at: "old", base: "old").last.last(2), "moved forward"
    assert_equal made, on_gitlab(at: "def", base: "123").last.last(2), "moved anyway, after a rewrite"
    assert_equal [0, [:Get, "/projects/7/repository/merge_base?refs%5B%5D=abc&refs%5B%5D=def"]], on_gitlab(at: "def", base: "abc").then { |s, c| [s, c.last] },
      "left where a newer push's job moved it"
    assert_equal "duel mark-passed: duel/passed/main marks a newer push's commit, which it's left at\n", @out.string
    assert_equal [1, "Couldn't compare duel/passed/main with this push\n"], [on_gitlab(at: "def").first, @out.string], "no comparison"
    assert_equal 1, on_gitlab(at: "def", base: :none).first, "nothing in common"
    status, calls = on_gitlab(failing: ["Post"], blocker: "duel")

    assert_equal [1, [[:Get, "/projects/7/repository/branches/duel%2Fpassed", :quiet], [:Get, "/projects/7/repository/branches/duel", :quiet]]],
      [status, calls.last(2)]
    assert_equal "The branch duel keeps Duel from making duel/passed/main, as Git can't have both. " \
      "Delete it (git push origin --delete duel), or rename it.\n", @out.string
  end

  def test_options
    assert_equal 0, command("--help", env: {}).run
  rescue SystemExit
    flunk "OptionParser's own --help exits"
  else
    assert_equal "#{Duel::MarkPassed::USAGE}    -h, --help                       Print this help\n", @out.string
    assert_equal 0, command("-h", env: {}).run
    assert_equal [2, "duel mark-passed: missing argument: BRANCH\n"], [command(env: {}).run, @err.string]
    assert_equal [2, "duel mark-passed: needless argument: b\n"], [command("a", "b", "c", env: {}).run, @err.string]
    assert_equal 2, command("a", "b", env: {}).run
    assert_equal 2, command("--branch", env: {}).run
    assert_equal ["duel mark-passed", "DUEL_TOKEN"], %i[command gitlab_token].map { |name| command(env: {}).send(name) }
  end
end
