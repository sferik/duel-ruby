# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require_relative "../duel"
require_relative "rubies"

module Duel
  # The version to compare against: a directory (Settings#base_dir), or a
  # git commit checked out (and built, see Config#build) where #checkout
  # says. Settings#base names the commit:
  #
  # - nil: where HEAD left the main branch (their merge base): for a
  #   pull request, the branch it targets (Settings#target), or else
  #   Config#main_branch, or the one origin/HEAD names, or origin/main, or
  #   origin/master, or (a repository without a remote) main, or master
  # - "last-release": the newest release tag (Config#release_tags) before
  #   HEAD, to catch slowdowns too small for any one change to fail but
  #   that add up between releases
  # - a push's (Settings#pushed, the branch pushed): the commit before it, or where
  #   Config#push_base says, the last commit Duel passed (#passed)
  # - anything else: a git ref
  # @api private
  class Baseline
    LAST_RELEASE = "last-release"
    # The main branch's usual names, origin's first (see #main_branch).
    BRANCHES = %w[origin/main origin/master main master].freeze

    def initialize(config, settings)
      @config = config
      @settings = settings
    end

    # The commit, or nil for "last-release" with no release yet, and for
    # a push with no commit before it here (see #pushed).
    def ref
      return @ref if instance_variable_defined?(:@ref)

      @ref = case @settings.base
      when nil then merge_base
      when LAST_RELEASE then git("describe", "--tags", "--abbrev=0", "--match", @config.release_tags, "HEAD^", allow_failure: true)
      else @settings.pushed ? pushed : @settings.base
      end
    end

    # The branch that marks the last commit Duel passed in a push to the
    # branch pushed (Settings#pushed), for Config#push_base:
    # duel/passed/main, or for a project in a subdirectory of its
    # repository, with its path (duel/passed-gems-parser/main), so each
    # branch, and each of a monorepo's projects, has its own.
    def passed_branch = "#{prefix.empty? ? "duel/passed" : "duel/passed-#{prefix.tr("/", "-")}"}/#{@settings.pushed}"

    # The last commit Duel passed in a push, as checked out from GitHub
    # (#passed_branch, on origin).
    def passed = "origin/#{passed_branch}"

    # Whether nothing #watched changed since the baseline (only for a git
    # baseline compared with the working tree).
    def unchanged?
      return false if @settings.base_dir || @settings.candidate_dir

      # (There's a ref: CLI#run checks first.)
      commit = ref #: String
      _, status = Open3.capture2e("git", "-C", @config.root, "diff", "--quiet", commit, "--", *watched)
      status.success?
    end

    # What a change must touch to be compared, from the root: the code
    # (Config#watch), and what decides how it's measured. Each version
    # runs the candidate's benchmarks and configuration, so a change to
    # only those compares the code with itself, which checks them. They
    # are the benchmarks' directory (the glob's, up to its first
    # wildcard), the configuration's file, and with each version on its
    # own Ruby, the version files at the root.
    def watched
      measured = [benchmarks, config_file]
      measured.concat(version_files) if (@settings.ruby || @config.ruby) == :version_file
      (@config.watch + measured).uniq
    end

    # The baseline's tree, checked out and built if it's a commit.
    def root
      base_dir = @settings.base_dir
      return File.expand_path(base_dir) if base_dir

      sha = git("rev-parse", "#{ref}^{commit}")
      dir = checkout
      unless git("-C", dir, "rev-parse", "HEAD", allow_failure: true) == sha
        FileUtils.rm_rf(dir)
        git("worktree", "prune") # (git's record of it)
        git("worktree", "add", dir, sha)
        build(within(dir), "the baseline") if Dir.exist?(within(dir))
      end
      raise Error, "the baseline (#{ref}) has no #{prefix}: compare with --base REF, a commit that has it" unless Dir.exist?(within(dir))

      within(dir)
    end

    # Where the project is in a checkout of its repository at +dir+: as far
    # from the top as it is in its own (a project in a subdirectory of a
    # monorepo, say).
    def within(dir) = prefix.empty? ? dir : File.join(dir, prefix)

    # The project's path from its repository's top level ("" at the top,
    # and outside a repository).
    def prefix = @prefix ||= git("rev-parse", "--show-prefix", allow_failure: true).to_s.chomp("/")

    # Where a git baseline is checked out (the whole repository, whose
    # #within is the project): next to the repository's top level, under a
    # hidden name as long as its own, from the project's path's hash
    # (".3f9c2a1b7", next to duel-rails), so the two versions' paths (with
    # symlinks resolved, as Rails resolves its root) are alike: as long,
    # and as deep. What a version does with its own paths (looking for a
    # file a request might be for, say) takes longer on a longer or a
    # deeper one, and a baseline that measured slower would hide a
    # regression that small. (A repository named with one letter has a
    # name of two.) Where that can't be (a directory Duel can't write in,
    # or something else of that name there), tmp/duel/base.
    def checkout
      root = File.realpath(@config.root)
      top = root.delete_suffix("/#{prefix}")
      length = [File.basename(top).length - 1, 1].max
      sibling = File.join(File.dirname(top), ".#{Digest::SHA256.hexdigest(root).ljust(length, "0")[0, length]}")
      return sibling if File.writable?(File.dirname(top)) && (!File.exist?(sibling) || ours?(sibling))

      File.join(@config.root, "tmp", "duel", "base")
    end

    # Removes what Duel keeps: tmp/duel, and the baseline's checkout (and
    # git's record of it as a worktree).
    def clean
      FileUtils.rm_rf(File.join(@config.root, "tmp", "duel"))
      FileUtils.rm_rf(checkout)
      git("worktree", "prune", allow_failure: true) # (not a git repository, say)
    end

    # The main branch (see #ref).
    def main_branch
      @settings.target || @config.main_branch ||
        git("symbolic-ref", "--short", "refs/remotes/origin/HEAD", allow_failure: true) ||
        BRANCHES.find { |branch| git("rev-parse", branch, allow_failure: true) } ||
        raise(Error, "no main branch to compare with (set c.main_branch in .duel.rb, or --base)")
    end

    # Builds the tree in +dir+ (Config#build), if there's a build: the
    # baseline's when it's checked out, and the candidate's before every
    # run, so a stale or missing build (a C extension the code quietly
    # does without, say) never decides a comparison. Builds are
    # incremental, so one already done costs little.
    def build(dir, what)
      command = @config.build
      return unless command

      output, status = Open3.capture2e(command, chdir: dir)
      raise Error, "building #{what} (#{command}) failed:\n#{output}" unless status.success?
    end

    private

    # The benchmarks' directory (see #watched), or for benchmarks at the
    # root, their glob, as git matches one.
    def benchmarks
      glob = @config.benchmarks
      dir = glob.split("/").take_while { |part| !part.match?(/[*?\[{]/) }.join("/")
      dir.empty? ? ":(glob)#{glob}" : dir
    end

    # The configuration's file, from the root (which is its directory).
    def config_file = File.basename(@settings.config_path || ".duel.rb")

    # The version files at the root (see Rubies).
    def version_files = Rubies::VERSION_FILES.select { |name| File.exist?(File.join(@config.root, name)) }

    # Where HEAD left the main branch: their merge base, which there isn't
    # when their histories are unrelated, or in a shallow clone (CI's,
    # fetched without the history), where git fails saying nothing.
    def merge_base
      unless git("rev-parse", "HEAD", allow_failure: true)
        raise Error, "this repository has no commits yet, so there's nothing to compare with: commit, " \
          "or compare with a directory (--base DIR)"
      end
      branch = main_branch
      out, err, status = Open3.capture3("git", "-C", @config.root, "merge-base", "HEAD", branch)
      return out.chomp if status.success?
      raise Error, "git merge-base HEAD #{branch} failed: #{err.chomp}" unless err.empty?

      why = if git("rev-parse", "--is-shallow-repository") == "true"
        "this is a shallow clone. Fetch the whole history (on GitHub Actions, fetch-depth: 0 for actions/checkout)"
      else
        "their histories are unrelated. Set c.main_branch in .duel.rb"
      end
      raise Error, "HEAD and #{branch} have no commit in common: #{why}, or compare with --base REF"
    end

    # A push's baseline: the last commit Duel passed (#passed), where
    # Config#push_base says and HEAD has it, or else the commit before the
    # push, or nil where that isn't here (a branch's first push, or one
    # that rewrote history).
    def pushed
      return passed if @config.push_base == :last_passed && git("merge-base", "--is-ancestor", passed, "HEAD", allow_failure: true)

      before = @settings.base #: String
      before if git("cat-file", "-e", "#{before}^{commit}", allow_failure: true)
    end

    # Whether +dir+ is a checkout of this repository (a worktree of it).
    def ours?(dir) = common_dir(dir) == common_dir(@config.root)

    # The repository a directory is a checkout of (its git directory), or
    # nil for none.
    def common_dir(dir) = git("-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir", allow_failure: true)

    def git(*args, allow_failure: false)
      out, err, status = Open3.capture3("git", "-C", @config.root, *args)
      return out.chomp if status.success?
      raise Error, "git #{args.join(" ")} failed: #{err.chomp}" unless allow_failure
    end
  end
end
