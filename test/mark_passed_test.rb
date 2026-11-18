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

  # Runs it on GitHub, where the branch is +at+ (nil for none), the calls
  # in +failing+ fail, and comparing the push with the branch says
  # +compared+. Returns its exit status, and the calls to gh.
  def on_github(branch = "duel/passed/main", at: nil, failing: [], compared: "ahead", blocker: nil)
    calls = []
    run = command(branch, env: GITHUB)
    run.define_singleton_method(:gh) do |*args, quiet: false|
      calls << [*args, *(:quiet if quiet)]
      said = args.join(" ")
      next if failing.any? { |part| part.is_a?(Regexp) ? said.match?(part) : said.include?(part) }

      case args.first
      when %r{/git/ref/heads/(.*)\z} then ($1 == branch) ? (at && "#{at}\n") : (("x\n" if $1 == blocker))
      else "{}"
      end
    end
    run.define_singleton_method(:compared) { |sha, ref| (calls << [:compared, sha, ref]) && compared }
    [run.run, calls]
  end

  # Moved forward, where GitHub moves it only where it's behind.
  def test_moving_it_forward
    status, calls = on_github

    assert_equal 0, status
    assert_equal [["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=abc", :quiet]], calls
    assert_equal "duel mark-passed: duel/passed/main is at abc\n", @out.string
  end

  # Made where there's none, or where making it fails, looked for once
  # more, as something else may have made it.
  def test_making_it
    patch = /PATCH -f sha=abc\z/
    status, calls = on_github(failing: [patch])

    assert_equal 0, status
    assert_equal [["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=abc", :quiet],
      ["repos/me/mine/git/ref/heads/duel/passed/main", "--jq", ".object.sha", :quiet],
      ["repos/me/mine/git/refs", "--method", "POST", "-f", "ref=refs/heads/duel/passed/main", "-f", "sha=abc"]], calls
    assert_equal "duel mark-passed: duel/passed/main is at abc\n", @out.string
    status, calls = on_github(failing: [patch, "POST"])

    assert_equal [1, 8], [status, calls.size], "twice, then blocked (the branches in its way, looked for)"
  end

  # Where it's ahead of the push (a newer push's run moved it), it's left
  # there. Where history was rewritten, it's moved anyway.
  def test_where_the_branch_is_already
    patch = /PATCH -f sha=abc\z/

    assert_equal 0, on_github(at: "def", failing: [patch], compared: "ahead").first
    assert_equal "duel mark-passed: duel/passed/main is at a newer push's commit, which it's left at\n", @out.string
    assert_equal [0, [:compared, "abc", "def"]], on_github(at: "def", failing: [patch], compared: "identical").then { |s, c| [s, c.last] }
    %w[diverged behind unrelated].each do |compared|
      status, calls = on_github(at: "def", failing: [patch], compared:)

      assert_equal [0, ["repos/me/mine/git/refs/heads/duel/passed/main", "--method", "PATCH", "-f", "sha=abc", "-F", "force=true"]],
        [status, calls.last], compared
      assert_equal "duel mark-passed: duel/passed/main is at abc\n", @out.string
    end
    assert_equal 1, on_github(at: "def", failing: [patch, "force=true"], compared: "behind").first
    assert_equal [1, "::error::Couldn't compare duel/passed/main with this push: Not Found\n"],
      [on_github(at: "def", failing: [patch], compared: "Not Found").first, @out.string]
  end

  # A branch whose name is a folder of the branch's keeps Git from making
  # it: it's named.
  def test_a_branch_in_the_way
    status, calls = on_github(failing: ["PATCH", "POST"], blocker: "duel")

    assert_equal 1, status
    assert_equal [["repos/me/mine/git/ref/heads/duel/passed", :quiet], ["repos/me/mine/git/ref/heads/duel", :quiet]], calls.last(2)
    assert_equal "::error::The branch duel keeps Duel from making duel/passed/main, as Git can't have both. " \
      "Delete it (git push origin --delete duel), or rename it.\n", @out.string
  end

  # How GitHub compares: its status, or unrelated, where the commits have
  # no history in common, or what went wrong.
  def test_compared
    run = command("duel/passed/main", env: GITHUB)
    asked = []
    said = lambda do |out, err, success|
      stub(Duel::Spawn, :open3, ->(*args, **) { (asked << args) && [out, err, Struct.new(:success?).new(success)] }) { run.send(:compared, "abc", "def") }
    end

    assert_equal "ahead", said.call("ahead\n", "", true)
    assert_equal [:capture3, "gh", "api", "repos/me/mine/compare/abc...def", "--jq", ".status"], asked.first
    assert_equal "unrelated", said.call("", "gh: No common ancestor between abc and def (HTTP 404)\n", false)
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
    assert_equal "duel mark-passed: duel/passed/main is at abc\n", @out.string
    assert_equal made, on_gitlab(at: "old", base: "old").last.last(2), "moved forward"
    assert_equal made, on_gitlab(at: "def", base: "123").last.last(2), "moved anyway, after a rewrite"
    assert_equal [0, [:Get, "/projects/7/repository/merge_base?refs%5B%5D=abc&refs%5B%5D=def"]], on_gitlab(at: "def", base: "abc").then { |s, c| [s, c.last] },
      "left where a newer push's job moved it"
    assert_equal "duel mark-passed: duel/passed/main is at a newer push's commit, which it's left at\n", @out.string
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
