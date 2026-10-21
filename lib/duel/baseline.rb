# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../duel"

module Duel
  # The version to compare against: a directory (Settings#base_dir), or a
  # git commit checked out (and built, see Config#build) in
  # tmp/duel/base. Settings#base names the commit:
  #
  # - nil: where HEAD left the main branch (their merge base):
  #   Config#main_branch, or the one origin/HEAD names, or origin/main, or
  #   origin/master
  # - "last-release": the newest release tag (Config#release_tags) before
  #   HEAD, to catch slowdowns too small for any one change to fail but
  #   that add up between releases
  # - anything else: a git ref
  # @api private
  class Baseline
    LAST_RELEASE = "last-release"

    def initialize(config, settings)
      @config = config
      @settings = settings
    end

    # The commit, or nil for "last-release" with no release yet.
    def ref
      return @ref if instance_variable_defined?(:@ref)

      @ref = case @settings.base
      when nil then git("merge-base", "HEAD", main_branch)
      when LAST_RELEASE then git("describe", "--tags", "--abbrev=0", "--match", @config.release_tags, "HEAD^", allow_failure: true)
      else @settings.base
      end
    end

    # Whether nothing Config#watch names changed since the baseline (only
    # for a git baseline compared with the working tree).
    def unchanged?
      return false if @settings.base_dir || @settings.candidate_dir

      # (There's a ref: CLI#run checks first.)
      commit = ref #: String
      _, status = Open3.capture2e("git", "-C", @config.root, "diff", "--quiet", commit, "--", *@config.watch)
      status.success?
    end

    # The baseline's tree, checked out and built if it's a commit.
    def root
      base_dir = @settings.base_dir
      return File.expand_path(base_dir) if base_dir

      sha = git("rev-parse", "#{ref}^{commit}")
      dir = File.join(@config.root, "tmp", "duel", "base")
      unless git("-C", dir, "rev-parse", "HEAD", allow_failure: true) == sha
        FileUtils.rm_rf(dir)
        git("worktree", "prune") # (git's record of it)
        git("worktree", "add", dir, sha)
        build(dir, "the baseline")
      end
      dir
    end

    # Removes what Duel keeps in tmp/duel: the baseline's checkout (and
    # git's record of it as a worktree).
    def clean
      FileUtils.rm_rf(File.join(@config.root, "tmp", "duel"))
      git("worktree", "prune", allow_failure: true) # (not a git repository, say)
    end

    # The main branch (see #ref).
    def main_branch
      @config.main_branch ||
        git("symbolic-ref", "--short", "refs/remotes/origin/HEAD", allow_failure: true) ||
        %w[origin/main origin/master].find { |branch| git("rev-parse", branch, allow_failure: true) } ||
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

    def git(*args, allow_failure: false)
      out, err, status = Open3.capture3("git", "-C", @config.root, *args)
      return out.chomp if status.success?
      raise Error, "git #{args.join(" ")} failed: #{err.chomp}" unless allow_failure
    end
  end
end
