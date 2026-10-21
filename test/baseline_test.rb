# frozen_string_literal: true

require_relative "test_helper"

# Baselines from git: a repository with a release, a main branch and a
# feature branch.
class BaselineTest < DuelTest
  cover "Duel::Baseline*"

  def git(*args) = system("git", "-C", @repo, "-c", "user.email=t@example.com", "-c", "user.name=t", *args,
    out: File::NULL, err: File::NULL) || flunk("git #{args.join(" ")}")

  def commit(message)
    git("add", "-A")
    git("commit", "-qm", message)
    `git -C #{@repo} rev-parse HEAD`.strip
  end

  def setup
    super
    @repo = project(File.join(tmpdir, "repo"))
    git("init", "-q", "-b", "main")
    @first = commit("first")
    git("tag", "v1.0")
    File.write(File.join(@repo, "lib", "sample.rb"), "module Sample; def self.work = 2; end\n")
    @second = commit("second")
    git("checkout", "-qb", "feature")
    File.write(File.join(@repo, "README"), "docs\n")
    @third = commit("docs only")
    @config = Duel::Config.new(@repo)
    @config.main_branch = "main"
  end

  def baseline(**overrides) = Duel::Baseline.new(@config, settings(**overrides))

  def test_by_default_where_head_left_the_main_branch
    git("checkout", "-q", "main")
    File.write(File.join(@repo, "lib", "other.rb"), "")
    commit("main moves on")
    git("checkout", "-q", "feature")

    assert_equal @second, baseline.ref
  end

  # The main branch, without configuring it: what origin/HEAD names, or
  # origin/main, or origin/master.
  def test_finds_the_main_branch
    @config.main_branch = nil
    origin = File.join(tmpdir, "origin.git")
    system("git", "clone", "-q", "--bare", @repo, origin, out: File::NULL, err: File::NULL)
    git("remote", "add", "origin", origin)
    git("fetch", "-q", "origin")
    git("remote", "set-head", "origin", "feature")

    assert_equal "origin/feature", baseline.send(:main_branch), "origin/HEAD names it"
    git("remote", "set-head", "origin", "-d")

    assert_equal "origin/main", baseline.send(:main_branch), "origin/main exists"
    git("branch", "-q", "-r", "-D", "origin/main")
    git("branch", "-q", "-m", "feature", "master")
    git("push", "-q", "origin", "master")

    assert_equal "origin/master", baseline.send(:main_branch)
  end

  def test_no_main_branch
    @config.main_branch = nil
    error = assert_raises(Duel::Error) { baseline.ref }

    assert_equal "no main branch to compare with (set c.main_branch in .duel.rb, or --base)", error.message
  end

  def test_a_named_ref
    assert_equal "v1.0", baseline(base: "v1.0").ref
  end

  def test_the_last_release_before_head
    assert_equal "v1.0", baseline(base: "last-release").ref
    git("tag", "v2.0")

    assert_equal "v1.0", baseline(base: "last-release").ref, "HEAD's own tag is the release being compared"
    @config.release_tags = "release-*"

    assert_nil baseline(base: "last-release").ref, "none"
  end

  # The ref is found once (none, too).
  def test_the_ref_is_found_once
    found = baseline(base: "last-release")
    found.ref
    git("tag", "v1.5", "HEAD^")

    assert_equal "v1.0", found.ref
    @config.release_tags = "release-*"
    none = baseline(base: "last-release")
    none.ref
    git("tag", "release-1", "HEAD^")

    assert_nil none.ref
  end

  def test_unchanged_when_only_unwatched_files_changed
    assert_predicate baseline, :unchanged?, "only the README since main"
    refute_predicate baseline(base: "v1.0"), :unchanged?, "lib/ changed since the release"
    refute_predicate baseline(base_dir: @repo), :unchanged?, "a directory is always compared"
    refute_predicate baseline(candidate_dir: @repo), :unchanged?
  end

  def test_root_checks_out_and_builds_the_commit_once
    builds = File.join(tmpdir, "builds.log")
    @config.build = "pwd >> #{builds}"
    root = baseline(base: "v1.0").root

    assert_equal File.join(@repo, "tmp", "duel", "base"), root
    assert_equal "module Sample\n", File.read(File.join(root, "lib", "sample.rb")).lines.first
    built = File.readlines(builds, chomp: true)

    assert_equal 1, built.size
    assert File.identical?(root, built.first), "built there"
    baseline(base: "v1.0").root

    assert_equal 1, File.readlines(builds).size, "the same commit isn't checked out or built again"
    baseline(base: @second).root

    assert_equal "module Sample; def self.work = 2; end\n", File.read(File.join(root, "lib", "sample.rb"))
    assert_equal 2, File.readlines(builds).size
    assert_equal 2, `git -C #{@repo} worktree list`.lines.size, "the one checkout"
  end

  def test_root_over_whatever_was_there
    dir = File.join(@repo, "tmp", "duel", "base")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "junk"), "")

    assert_path_exists File.join(baseline(base: "v1.0").root, "lib", "sample.rb")
    refute_path_exists File.join(dir, "junk")
  end

  def test_root_without_a_build
    assert_path_exists File.join(baseline(base: "v1.0").root, "lib", "sample.rb")
  end

  def test_building_the_candidate
    @config.build = "echo nope; exit 3"
    error = assert_raises(Duel::Error) { Duel::Baseline.new(@config, settings).build(tmpdir, "the candidate") }

    assert_equal "building the candidate (echo nope; exit 3) failed:\nnope\n", error.message
    @config.build = "pwd > built"
    Duel::Baseline.new(@config, settings).build(tmpdir, "the candidate")

    assert_equal File.realpath(tmpdir), File.realpath(File.read(File.join(tmpdir, "built")).chomp), "built where it is"
  end

  def test_a_failing_build
    @config.build = "echo nope; exit 3"
    error = assert_raises(Duel::Error) { baseline(base: "v1.0").root }

    assert_equal "building the baseline (echo nope; exit 3) failed:\nnope\n", error.message
  end

  def test_a_base_directory_as_is
    assert_equal File.join(tmpdir, "x"), baseline(base_dir: File.join(tmpdir, "y", "..", "x")).root
  end

  def test_git_failures
    error = assert_raises(Duel::Error) { baseline(base: "nope").root }

    assert_match(/\Agit rev-parse nope\^\{commit\} failed: fatal: .*[^\n]\z/m, error.message)
  end

  # Removes tmp/duel, and git's record of the checkout, wherever it's
  # run from (and outside a git repository too).
  def test_clean
    baseline(base: "v1.0").root
    File.write(File.join(@repo, "tmp", "duel", "report.json"), "{}")
    File.write(File.join(@repo, "tmp", "other"), "")
    Dir.chdir(tmpdir) { baseline.clean }

    refute_path_exists File.join(@repo, "tmp", "duel")
    assert_path_exists File.join(@repo, "tmp", "other"), "only Duel's"
    assert_equal 1, `git -C #{@repo} worktree list`.lines.size, "only the main one"
    elsewhere = Duel::Config.new(FileUtils.mkdir_p(File.join(tmpdir, "plain")).first)
    Duel::Baseline.new(elsewhere, settings).clean
  end
end

class CleanTest < DuelTest
  cover "Duel::Baseline*"
  cover "Duel::CLI*"

  def test_clean_removes_the_worktree_and_reports
    repo = project(File.join(tmpdir, "repo"))
    run = ->(*args) { system("git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t", *args, out: File::NULL) }
    run.call("init", "-q", "-b", "main")
    run.call("add", "-A")
    run.call("commit", "-qm", "one")
    config = Duel::Config.new(repo)
    Duel::Baseline.new(config, settings(base: "HEAD")).root
    File.write(File.join(repo, "tmp", "duel", "report.json"), "{}")
    out = StringIO.new
    status = Dir.chdir(repo) { Duel::CLI.new(["--clean"], env: {}, out: out, err: StringIO.new).run }

    assert_equal 0, status
    assert_equal "duel: removed tmp/duel and its baseline's worktree\n", out.string
    refute Dir.exist?(File.join(repo, "tmp", "duel"))
    assert_equal 1, `git -C #{repo} worktree list`.lines.size, "only the main one"
  end
end
