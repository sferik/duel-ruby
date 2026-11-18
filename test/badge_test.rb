# frozen_string_literal: true

require_relative "test_helper"

# `duel badge`, with GitHub's API faked.
class BadgeTest < DuelTest
  cover "Duel::Badge*"
  cover "Duel::Forge*"

  GITHUB = {"GITHUB_REPOSITORY" => "me/mine", "GITHUB_SHA" => "abc"}.freeze

  def command(*argv) = Duel::Badge.new(argv, env: GITHUB, out: (@out = StringIO.new), err: (@err = StringIO.new))

  # Runs it for +branch+, whose commit says +message+ (nil: there's no
  # branch), where comparing the push with that commit's push says
  # +compared+, and the calls in +failing+ fail. Returns its exit status,
  # and the calls to gh.
  def badge(*argv, message: nil, compared: "behind", failing: [], blocker: nil)
    calls = []
    run = command("duel/badge", *argv)
    run.define_singleton_method(:gh) do |*args, quiet: false|
      calls << [*args, *(:quiet if quiet)]
      said = args.join(" ")
      next if failing.any? { |part| said.include?(part) }

      case args.first
      when "repos/me/mine/commits/duel/badge" then message
      when %r{/compare/} then "#{compared}\n"
      when "repos/me/mine/git/trees" then "tree1\n"
      when "repos/me/mine/git/commits" then "commit1\n"
      when "repos/me/mine/git/ref/heads/duel" then ("x\n" if blocker)
      when %r{/git/ref/heads/} then nil
      else "{}"
      end
    end
    [run.run, calls]
  end

  # Green where the push passed, red where Duel failed it or found a
  # regression (even one that passed), and grey where the Duel job failed
  # before Duel said either.
  def test_its_state
    assert_equal %w[guarded guarded regressed regressed unmeasured guarded guarded guarded],
      [%w[passed success], ["passed", "failure"], ["failed", "success"], ["failed", "failure"], [nil, "failure"], ["neutral", "success"],
        [nil, nil], [nil, "cancelled"]].map { |status, result| Duel::Badge.state(status, result) }
    assert_equal "unmeasured", Duel::Badge.state("neutral", "failure")
    svg = Duel::Badge.svg("regressed")

    assert_includes svg, %(<svg xmlns="http://www.w3.org/2000/svg" width="142" height="20">\n  <title>Duel - perf regressed</title>\n)
    assert_includes svg, %(<stop stop-color="#EA4A5A" offset="0%"></stop>\n      <stop stop-color="#D73A49" offset="100%"></stop>)
    assert_includes svg, %(<path d="M0 0h85.939C87.629 0 89 1.343 89 3v14c0 1.657)
    assert_equal 2, svg.scan(%(<tspan x="4" y="1)).size
    assert_equal ["perf guarded", "not measured"], [Duel::Badge.svg("guarded")[/Duel - ([^<]*)</, 1], Duel::Badge.svg("unmeasured")[/Duel - ([^<]*)</, 1]]
  end

  # Its image, alone, in a commit that names the push, the branch moved
  # there (or made).
  def test_writing_it
    status, calls = badge("--status", "failed", "--result", "success")

    assert_equal 0, status
    assert_equal [["repos/me/mine/commits/duel/badge", "--jq", ".commit.message", :quiet],
      ["repos/me/mine/git/trees", "--method", "POST", "-f", "tree[][path]=badge.svg", "-f", "tree[][mode]=100644", "-f", "tree[][type]=blob",
        "-f", "tree[][content]=#{Duel::Badge.svg("regressed")}", "--jq", ".sha"],
      ["repos/me/mine/git/commits", "--method", "POST", "-f", "message=Duel's badge, for abc", "-f", "tree=tree1", "--jq", ".sha"],
      ["repos/me/mine/git/refs/heads/duel/badge", "--method", "PATCH", "-f", "sha=commit1", "-F", "force=true", :quiet]], calls
    assert_equal "duel badge: duel/badge shows the badge of abc\n", @out.string
    status, calls = badge(failing: ["PATCH"])

    assert_equal [0, ["repos/me/mine/git/refs", "--method", "POST", "-f", "ref=refs/heads/duel/badge", "-f", "sha=commit1"]], [status, calls.last], "made"
  end

  # What it says is the Duel job's status and result's, as Badge.state
  # has it.
  def test_what_it_writes
    written = ->(*argv) { badge(*argv).last[1].grep(/\Atree\[\]\[content\]=/).first[/Duel - ([^<]*)</, 1] }

    assert_equal ["not measured", "perf guarded", "perf regressed", "perf guarded"],
      [%w[--result failure], %w[--status passed --result failure], %w[--status failed], []].map { |argv| written.call(*argv) }
  end

  # Where the badge is a newer push's, that push's run has the say.
  def test_a_newer_pushs
    assert_equal [0, 2], badge(message: "Duel's badge, for def123\n", compared: "ahead").then { |status, calls| [status, calls.size] }
    assert_equal "duel badge: duel/badge shows a newer push's badge, which it's left at\n", @out.string
    assert_equal ["repos/me/mine/compare/abc...def123", "--jq", ".status", :quiet], badge(message: "Duel's badge, for def123", compared: "ahead").last.last
    assert_equal 5, badge(message: "Duel's badge, for def123\n", compared: "behind").last.size, "an older push's"
    assert_equal 5, badge(message: "Duel's badge, for def123\n", failing: ["compare"]).last.size, "no comparison"
    assert_equal 4, badge(message: "Someone's commit\n", compared: "ahead").last.size, "not Duel's"
    assert_equal 4, badge(message: "Duel's badge, for def123\nand more", compared: "ahead").last.size
  end

  # Where GitHub won't take the image, or its commit, or the branch, it
  # fails, naming a branch that keeps Git from making it.
  def test_github_failing
    assert_equal [1, 2], badge(failing: ["trees"]).then { |status, calls| [status, calls.size] }
    assert_equal [1, 3], badge(failing: ["commits", "PATCH"]).then { |status, calls| [status, calls.size] }
    status, calls = badge(failing: ["PATCH", "POST -f ref"], blocker: "duel")

    assert_equal [1, ["repos/me/mine/git/ref/heads/duel", :quiet]], [status, calls.last]
    assert_equal "::error::The branch duel keeps Duel from making duel/badge, as Git can't have both. " \
      "Delete it (git push origin --delete duel), or rename it.\n", @out.string
  end

  def test_options
    assert_equal 0, command("--help").run
  rescue SystemExit
    flunk "OptionParser's own --help exits"
  else
    assert_equal Duel::Badge::USAGE + "        --status STATUS              The Duel job's status (its output: passed, failed or neutral)\n" \
      "        --result RESULT              The Duel job's result (success or failure, say)\n" \
      "    -h, --help                       Print this help\n", @out.string
    assert_equal 0, command("-h").run
    assert_equal [2, "duel badge: missing argument: BRANCH\n"], [command.run, @err.string]
    assert_equal [2, "duel badge: needless argument: b\n"], [command("a", "b", "c").run, @err.string]
    assert_equal 2, command("a", "b").run
    assert_equal ["duel badge", "DUEL_TOKEN"], [command.send(:command), command.send(:gitlab_token)]
  end
end
