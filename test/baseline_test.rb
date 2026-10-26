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
    # (Git looks no higher than the tests' directory: it's inside Duel's
    # checkout. And they run in a directory of their own, so a mutation
    # that works on the current directory works there, not on Duel's.)
    ENV["GIT_CEILING_DIRECTORIES"] = File.realpath(tmpdir)
    @pwd = Dir.pwd
    Dir.chdir(FileUtils.mkdir_p(File.join(tmpdir, "cwd")).fetch(0))
  end

  def teardown
    Dir.chdir(@pwd)
    ENV.delete("GIT_CEILING_DIRECTORIES")
    super
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

  # Without a remote: main, or else master.
  def test_a_main_branch_without_a_remote
    @config.main_branch = nil

    assert_equal @second, baseline.ref, "main"
    git("branch", "-q", "-m", "main", "master")

    assert_equal "master", baseline.send(:main_branch)
    assert_equal %w[origin/main origin/master main master], Duel::Baseline::BRANCHES
  end

  def test_no_main_branch
    @config.main_branch = nil
    git("branch", "-q", "-m", "main", "trunk")
    error = assert_raises(Duel::Error) { baseline.ref }

    assert_equal "no main branch to compare with (set c.main_branch in .duel.rb, or --base)", error.message
  end

  # A repository without a commit has nothing to compare with, whatever
  # its main branch.
  def test_no_commits_yet
    empty = project(File.join(tmpdir, "empty"))
    system("git", "-C", empty, "init", "-q", "-b", "main", exception: true)
    error = assert_raises(Duel::Error) { Duel::Baseline.new(Duel::Config.new(empty), settings).ref }

    assert_equal "this repository has no commits yet, so there's nothing to compare with: commit, or compare with a " \
      "directory (--base DIR)", error.message
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

  # A push's baseline: the commit before it, or where c.push_base says,
  # the last commit Duel passed (origin/duel/passed), if HEAD has it.
  def test_a_pushs_baseline
    pushed = ->(base) { baseline(base: base, pushed: true).ref }

    assert_equal @first, pushed.call(@first), "the commit before the push"
    assert_nil pushed.call("0" * 40), "none here: a branch's first push"
    assert_equal "v1.0", baseline(base: "v1.0").ref, "not a push's: as given"
    git("update-ref", "refs/remotes/origin/duel/passed", @second)

    assert_equal @first, pushed.call(@first), "by default, not the last passed"
    @config.push_base = :last_passed

    assert_equal "origin/duel/passed", pushed.call(@first)
    assert_equal "origin/duel/passed", pushed.call("0" * 40), "whatever the commit before"
    assert_equal "v1.0", baseline(base: "v1.0").ref, "not a push's"
    git("update-ref", "refs/remotes/origin/duel/passed", @third)
    git("checkout", "-q", "main")

    assert_equal @first, pushed.call(@first), "HEAD doesn't have it: on another branch"
    git("checkout", "-q", "--orphan", "rewritten")
    commit("rewritten")

    assert_equal @first, pushed.call(@first), "HEAD doesn't have it"
    git("update-ref", "-d", "refs/remotes/origin/duel/passed")
    git("checkout", "-q", "feature")

    assert_equal @first, pushed.call(@first), "no branch"
  end

  # The branch that marks the last commit Duel passed: a project's own in
  # a subdirectory.
  def test_the_passed_branch
    assert_equal ["duel/passed", "origin/duel/passed"], [baseline.passed_branch, baseline.passed]
    app = project(File.join(@repo, "gems", "my_app"))

    assert_equal "duel/passed-gems-my_app", Duel::Baseline.new(Duel::Config.new(app), settings).passed_branch
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

  # Each version runs the candidate's benchmarks and configuration, so a
  # change to only those is compared too (the code with itself), as is a
  # change to the Ruby a version file names, for each version on its own.
  def test_unchanged_unless_what_decides_the_measuring_changed
    # (Staged: a file git doesn't track isn't compared.)
    write = lambda do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.write(File.join(@repo, path), content)
      git("add", "-A")
    end
    write.call("duel/fixtures/input.txt", "x")

    refute_predicate baseline, :unchanged?, "the benchmarks' fixtures"
    commit("fixtures")
    git("checkout", "-q", "main")
    git("merge", "-q", "feature")
    git("checkout", "-q", "feature")

    assert_predicate baseline, :unchanged?
    write.call(".duel.rb", "")

    refute_predicate baseline, :unchanged?, "the configuration"
    assert_predicate baseline(config_path: File.join(@repo, "other.rb")), :unchanged?, "another configuration"
    git("rm", "-qf", ".duel.rb")
    write.call(".ruby-version", "3.4.1\n")
    commit("Ruby 3.4.1")
    git("checkout", "-q", "main")
    git("merge", "-q", "feature")
    git("checkout", "-q", "feature")
    write.call(".ruby-version", "3.5.0\n")

    assert_predicate baseline, :unchanged?, "each version on the runner's Ruby"
    refute_predicate baseline(ruby: :version_file), :unchanged?, "each version on its own"
    @config.ruby = :version_file

    refute_predicate baseline, :unchanged?
    assert_predicate baseline(ruby: "/usr/bin/ruby"), :unchanged?, "--ruby over c.ruby"
  end

  # What a change must touch to be compared: the code, the benchmarks'
  # directory, the configuration's file, and with each version on its
  # own Ruby, the version files there are.
  def test_watched
    assert_equal %w[lib ext duel .duel.rb], baseline.watched
    @config.watch = %w[app duel]

    assert_equal %w[app duel .duel.rb], baseline.watched, "each once"
    @config.benchmarks = "perf/bench/**/*_duel.rb"

    assert_equal %w[app duel perf/bench my.rb], baseline(config_path: File.join(@repo, "my.rb")).watched
    {"perf/x?/a.rb" => "perf", "perf/[ab]/a.rb" => "perf", "perf/{a,b}/a.rb" => "perf", "perf/a_duel.rb" => "perf/a_duel.rb",
     "*_duel.rb" => ":(glob)*_duel.rb"}.each do |glob, watched|
      @config.benchmarks = glob

      assert_equal watched, baseline.watched[2], glob
    end
    File.write(File.join(@repo, "mise.toml"), "")
    File.write(File.join(@repo, ".ruby-version"), "")

    assert_equal %w[app duel :(glob)*_duel.rb .duel.rb .ruby-version mise.toml], baseline(ruby: :version_file).watched
  end

  def test_root_checks_out_and_builds_the_commit_once
    builds = File.join(tmpdir, "builds.log")
    @config.build = "pwd >> #{builds}"
    root = baseline(base: "v1.0").root

    assert_equal baseline.checkout, root
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

  # Its checkout of another commit is checked out afresh: what was left
  # in it goes.
  def test_root_over_whatever_was_there
    dir = baseline(base: @second).root
    File.write(File.join(dir, "junk"), "")

    assert_equal dir, baseline(base: "v1.0").root
    assert_path_exists File.join(dir, "lib", "sample.rb")
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
    # (From another directory: a build run anywhere else writes there, not
    # in Duel's checkout.)
    elsewhere = FileUtils.mkdir_p(File.join(tmpdir, "elsewhere")).first
    Dir.chdir(elsewhere) { Duel::Baseline.new(@config, settings).build(tmpdir, "the candidate") }

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

  # A git baseline is checked out next to the project, under a hidden
  # name as long as its own, from its path's hash: the two versions'
  # paths are as long and as deep (what a version does with its own paths
  # takes longer on a longer or a deeper one).
  def test_checked_out_next_to_the_project
    root = File.realpath(@repo)

    assert_equal File.join(File.dirname(root), ".#{Digest::SHA256.hexdigest(root)[0, 3]}"), baseline.checkout, "repo: 4 letters"
    assert_equal baseline.checkout, baseline(base: "v1.0").checkout, "the same for every run"
    long = File.realpath(project(File.join(tmpdir, "o" * 70)))

    assert_equal File.join(File.dirname(long), ".#{Digest::SHA256.hexdigest(long)}00000"),
      Duel::Baseline.new(Duel::Config.new(long), settings).checkout, "past the hash, padded"
  end

  # Where it can't be (something else of that name there, a directory it
  # can't write in), it's tmp/duel/base. A checkout of this repository
  # there is its own. A project named with one letter has a name of two.
  def test_where_it_cant_be_next_to_the_project
    fallback = File.join(@repo, "tmp", "duel", "base")
    sibling = baseline.checkout
    FileUtils.mkdir_p(sibling)
    # (Git looks no higher than the tests' directory: it's inside Duel's
    # checkout.)
    ENV["GIT_CEILING_DIRECTORIES"] = File.realpath(tmpdir)

    assert_equal fallback, baseline.checkout, "something else there"
    system("git", "-C", sibling, "init", "-q", exception: true)

    assert_equal fallback, baseline.checkout, "another repository there"
    FileUtils.rm_rf(sibling)
    baseline(base: "v1.0").root

    assert_equal sibling, baseline.checkout, "its own checkout"
    one = File.realpath(project(File.join(tmpdir, "a")))

    assert_equal File.join(File.dirname(one), ".#{Digest::SHA256.hexdigest(one)[0]}"), Duel::Baseline.new(Duel::Config.new(one), settings).checkout
  ensure
    ENV.delete("GIT_CEILING_DIRECTORIES")
  end

  def test_not_next_to_a_project_in_a_directory_it_cant_write_in
    skip "root writes anywhere" if Process.uid.zero?

    locked = FileUtils.mkdir_p(File.join(tmpdir, "locked")).first
    inner = project(File.join(locked, "repo"))
    File.chmod(0o555, locked)
    checkout = Duel::Baseline.new(Duel::Config.new(inner), settings).checkout
    File.chmod(0o755, locked)

    assert_equal File.join(inner, "tmp", "duel", "base"), checkout
  end

  # Without a merge base, git fails saying nothing: unrelated histories,
  # or a shallow clone.
  def test_no_merge_base
    git("checkout", "-q", "--orphan", "unrelated")
    commit("unrelated")
    error = assert_raises(Duel::Error) { baseline.ref }

    assert_equal "HEAD and main have no commit in common: their histories are unrelated. Set c.main_branch in .duel.rb, " \
      "or compare with --base REF", error.message
    @config.main_branch = "nope"
    error = assert_raises(Duel::Error) { baseline.ref }

    assert_match(/\Agit merge-base HEAD nope failed: fatal: .*[^\n]\z/m, error.message, "any other failure, as git says")
  end

  def test_no_merge_base_in_a_shallow_clone
    shallow = File.join(tmpdir, "shallow")
    system("git", "clone", "-q", "--depth", "1", "--no-single-branch", "file://#{@repo}", shallow, out: File::NULL,
      err: File::NULL, exception: true)
    config = Duel::Config.new(shallow)
    config.main_branch = "origin/main"
    Dir.chdir(shallow) { system("git", "checkout", "-q", "feature", exception: true) }
    error = assert_raises(Duel::Error) { Duel::Baseline.new(config, settings).ref }

    assert_equal "HEAD and origin/main have no commit in common: this is a shallow clone. Fetch the whole history (on " \
      "GitHub Actions, fetch-depth: 0 for actions/checkout), or compare with --base REF", error.message
  end

  # A project in a subdirectory of its repository (a monorepo's): the
  # whole repository is checked out, next to its top level, and the
  # baseline is the project's directory in it, as long and as deep a
  # path as the project's.
  def test_a_project_in_a_subdirectory
    app = project(File.join(@repo, "packages", "app"))
    builds = File.join(tmpdir, "builds.log")
    commit("the app")
    # (The app, on main too.)
    git("checkout", "-q", "main")
    git("merge", "-q", "feature")
    git("checkout", "-q", "feature")
    File.write(File.join(app, "lib", "sample.rb"), "module Sample; def self.work = 3; end\n")
    config = Duel::Config.new(app)
    config.main_branch = "main"
    config.build = "pwd >> #{builds}"
    of_app = ->(**overrides) { Duel::Baseline.new(config, settings(**overrides)) }
    root = of_app.call(base: "main").root
    checkout = of_app.call.checkout

    assert_equal File.join(checkout, "packages", "app"), root
    assert_equal File.join(File.dirname(File.realpath(@repo)), ".#{Digest::SHA256.hexdigest(File.realpath(app))[0, 3]}"), checkout,
      "next to the repository, named for the project"
    assert_equal [File.realpath(app).length, File.realpath(app).count("/")], [root.length, root.count("/")], "as long, and as deep"
    assert_equal "module Sample\n", File.read(File.join(root, "lib", "sample.rb")).lines.first, "the baseline's"
    assert_path_exists File.join(checkout, "README"), "the whole repository"
    assert File.identical?(root, File.readlines(builds, chomp: true).last), "built there"
    refute_predicate of_app.call(base: "main"), :unchanged?, "lib/ is the app's"
    config.watch = %w[duel]

    assert_predicate of_app.call(base: "main"), :unchanged?, "duel/ is too"
    FileUtils.mkdir_p(File.join(app, "tmp", "duel"))
    of_app.call.clean

    refute_path_exists checkout, "the whole checkout"
    refute_path_exists File.join(app, "tmp", "duel")
    assert_equal File.join(app, "tmp", "duel", "base", "packages", "app"),
      of_app.call.send(:within, File.join(app, "tmp", "duel", "base")), "where it can't be next to it"
  end

  def test_a_baseline_without_the_project
    app = project(File.join(@repo, "packages", "app"))
    config = Duel::Config.new(app)
    config.build = "echo built > #{File.join(tmpdir, "built")}"
    error = assert_raises(Duel::Error) { Duel::Baseline.new(config, settings(base: "v1.0")).root }

    assert_equal "the baseline (v1.0) has no packages/app: compare with --base REF, a commit that has it", error.message
    error = assert_raises(Duel::Error) { Duel::Baseline.new(config, settings(base: "v1.0")).root }

    assert_includes error.message, "has no packages/app", "checked out already, and still not there"
    refute_path_exists File.join(tmpdir, "built"), "nothing to build"
  end

  # Removes tmp/duel and the checkout, and git's record of it, wherever
  # it's run from (and outside a git repository too).
  def test_clean
    checkout = baseline(base: "v1.0").root
    FileUtils.mkdir_p(File.join(@repo, "tmp", "duel"))
    File.write(File.join(@repo, "tmp", "duel", "report.json"), "{}")
    File.write(File.join(@repo, "tmp", "other"), "")
    Dir.chdir(tmpdir) { baseline.clean }

    refute_path_exists File.join(@repo, "tmp", "duel")
    refute_path_exists checkout
    assert_path_exists File.join(@repo, "tmp", "other"), "only Duel's"
    assert_equal 1, `git -C #{@repo} worktree list`.lines.size, "only the main one"
    plain = FileUtils.mkdir_p(File.join(tmpdir, "plain")).first
    # (Git looks no higher than it: the tests' directories are inside Duel's checkout.)
    ENV["GIT_CEILING_DIRECTORIES"] = File.dirname(plain)
    Duel::Baseline.new(Duel::Config.new(plain), settings).clean
  ensure
    ENV.delete("GIT_CEILING_DIRECTORIES")
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
    checkout = Duel::Baseline.new(config, settings(base: "HEAD")).root
    FileUtils.mkdir_p(File.join(repo, "tmp", "duel"))
    File.write(File.join(repo, "tmp", "duel", "report.json"), "{}")
    out = StringIO.new
    status = Dir.chdir(repo) { Duel::CLI.new(["--clean"], env: {}, out: out, err: StringIO.new).run }

    assert_equal 0, status
    assert_equal "duel: removed tmp/duel and its baseline's worktree\n", out.string
    refute Dir.exist?(File.join(repo, "tmp", "duel"))
    refute_path_exists checkout
    assert_equal 1, `git -C #{repo} worktree list`.lines.size, "only the main one"
  end
end
