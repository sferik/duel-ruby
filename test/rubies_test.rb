# frozen_string_literal: true

require_relative "test_helper"

# The Ruby each version runs on: the runner's, a path, what a block says,
# or what the version's own version file names, found with the version
# managers (faked here: rbenv, mise and asdf as commands, chruby as its
# directories of Rubies).
class RubiesTest < DuelTest
  cover "Duel::Rubies*"

  def setup
    super
    @path = ENV.fetch("PATH")
    @root = File.join(tmpdir, "managers")
  end

  def teardown
    ENV["PATH"] = @path
    super
  end

  # An executable at +path+ (a Ruby's, or a manager's command, by its
  # shell script).
  def executable(path, script = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, path)
    path
  end

  # rbenv, mise and asdf, each with Rubies of its own (and chruby's,
  # under @root/rubies), on a PATH with nothing else of theirs. None is
  # one the runner could be (Duel needs Ruby 3.4, which JRuby 9.4 isn't),
  # so a version file that asks for one is looked up with the managers.
  def managers
    bin = File.join(@root, "bin")
    executable(File.join(bin, "rbenv"), %([ "$1" = prefix ] && [ -d "#{@root}/rbenv/$2" ] && echo "#{@root}/rbenv/$2" && exit; exit 1))
    executable(File.join(bin, "mise"), %{case "$1 $2" in "where ruby@3.1") echo "#{@root}/mise/3.1.7";; *) exit 1;; esac})
    executable(File.join(bin, "asdf"), %([ "$1 $2" = "where ruby" ] && [ -d "#{@root}/asdf/$3" ] && echo "#{@root}/asdf/$3" && exit; exit 1))
    ENV["PATH"] = [bin, "/bin", "/usr/bin"].join(File::PATH_SEPARATOR)
    {rbenv: executable(File.join(@root, "rbenv", "3.3.6", "bin", "ruby")),
     jruby: executable(File.join(@root, "rbenv", "jruby-9.4.14.0", "bin", "jruby")),
     chruby: executable(File.join(@root, "rubies", "ruby-3.2.10", "bin", "ruby")),
     mise: executable(File.join(@root, "mise", "3.1.7", "bin", "ruby")),
     asdf: executable(File.join(@root, "asdf", "3.0.7", "bin", "ruby"))}
  end

  # The Ruby the version file in a version's tree asks for: +file+, with
  # +contents+.
  def asked(contents, file: ".ruby-version")
    version = File.join(tmpdir, "version-#{contents.hash.abs}")
    FileUtils.mkdir_p(version)
    File.write(File.join(version, file), contents)
    with_constants(Duel::Rubies, CHRUBY: [File.join(@root, "none"), File.join(@root, "rubies")]) do
      Duel::Rubies.find(:version_file, version, "baseline")
    end
  end

  def test_the_runners_by_default
    assert_equal RbConfig.ruby, Duel::Rubies.find(nil, tmpdir, "baseline")
  end

  def test_a_path_or_a_block
    ruby = executable(File.join(tmpdir, "bin", "ruby"))
    roots = []

    assert_equal ruby, Duel::Rubies.find(ruby, tmpdir, "baseline")
    assert_equal ruby, Duel::Rubies.find(->(root) { (roots << root) && ruby }, "/version", "baseline")
    assert_equal ["/version"], roots, "given the version's tree"
    [File.join(tmpdir, "nope"), File.join(tmpdir, "bin"), File.join(tmpdir, "plain").tap { |plain| File.write(plain, "") }].each do |nope|
      error = assert_raises(Duel::Error) { Duel::Rubies.find(nope, tmpdir, "candidate") }

      assert_equal "the candidate's Ruby (#{nope}) isn't there", error.message
    end
  end

  # From the version file, the first manager that has the Ruby it asks for.
  def test_a_version_file
    rubies = managers

    assert_equal rubies.fetch(:rbenv), asked("ruby-3.3.6\n"), "rbenv's, by its name without ruby-"
    assert_equal rubies.fetch(:jruby), asked("jruby-9.4.14.0"), "JRuby's program"
    assert_equal rubies.fetch(:chruby), asked("3.2"), "chruby's"
    assert_equal rubies.fetch(:mise), asked("ruby-3.1"), "mise's"
    assert_equal rubies.fetch(:asdf), asked("ruby-3.0.7"), "asdf's"
    assert_equal rubies.fetch(:rbenv), asked("ruby 3.3.6\n", file: ".tool-versions")
    assert_equal rubies.fetch(:mise), asked(%([tools]\nruby = "3.1"\n), file: "mise.toml")
    error = assert_raises(Duel::Error) { asked("2.9.9") }

    assert_match %r{\Athe baseline's /\S+/\.ruby-version asks for Ruby 2\.9\.9, which isn't installed with rbenv, chruby, mise or asdf: install it, or set c\.ruby in \.duel\.rb\z},
      error.message
  end

  # The runner's own Ruby, where it's the one asked for, before any
  # manager's of that name.
  def test_a_version_file_asking_for_the_runners_own_that_a_manager_has
    runner = (RUBY_ENGINE == "ruby") ? RUBY_ENGINE_VERSION : "#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}"
    managers
    executable(File.join(@root, "rbenv", runner, "bin", "ruby"))

    assert_equal RbConfig.ruby, asked(runner)
  end

  # A manager's Ruby that isn't there (half removed, say) is no Ruby.
  def test_a_manager_without_the_program
    managers
    FileUtils.rm_f(File.join(@root, "rbenv", "3.3.6", "bin", "ruby"))

    assert_raises(Duel::Error) { asked("3.3.6") }
  end

  # The runner's own Ruby, where it's the one asked for, though no
  # manager has it (installed by CI's setup step, say). Another still
  # fails.
  def test_a_version_file_asking_for_the_runners_own
    ENV["PATH"] = ["/bin", "/usr/bin"].join(File::PATH_SEPARATOR)
    prefix = (RUBY_ENGINE == "ruby") ? "" : "#{RUBY_ENGINE}-"
    partial = RUBY_ENGINE_VERSION.split(".").first(2).join(".")

    assert_equal RbConfig.ruby, asked("#{prefix}#{RUBY_ENGINE_VERSION}\n")
    assert_equal RbConfig.ruby, asked("#{prefix}#{partial}"), "by its first parts"
    assert_equal RbConfig.ruby, asked("#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION}\n", file: ".tool-versions") if RUBY_ENGINE == "ruby"
    assert_raises(Duel::Error) { asked("#{prefix}#{RUBY_ENGINE_VERSION}9") }
  end

  # Whether a version file's version is the runner's Ruby, as the
  # managers match one.
  def test_whether_the_runners_own_is_asked_for
    {"3.4.11" => true, "ruby-3.4.11" => true, "3.4" => true, "ruby-3" => true, "3.4.1" => false, "3.5" => false,
     "jruby-3.4.11" => false, "latest" => false, "ruby-3.4.11-preview1" => false, "x3.4.11" => false}.each do |version, runners|
      assert_equal runners, Duel::Rubies.runner_asked?(version, engine: "ruby", engine_version: "3.4.11"), version
    end
    {"jruby-10.1.2.0" => true, "jruby-10.1" => true, "10.1.2.0" => false, "truffleruby-10.1.2.0" => false}.each do |version, runners|
      assert_equal runners, Duel::Rubies.runner_asked?(version, engine: "jruby", engine_version: "10.1.2.0"), version
    end
    assert Duel::Rubies.runner_asked?("truffleruby+graalvm-24.1.0", engine: "truffleruby", engine_version: "24.1.0")
    refute Duel::Rubies.runner_asked?("truffleruby+-24.1.0", engine: "truffleruby", engine_version: "24.1.0"), "a + names more"
    assert_equal Duel::Rubies.runner_asked?(RUBY_ENGINE_VERSION, engine: RUBY_ENGINE, engine_version: RUBY_ENGINE_VERSION),
      Duel::Rubies.runner_asked?(RUBY_ENGINE_VERSION), "the runner's, by default"
  end

  def test_without_a_version_file_the_runners
    assert_equal RbConfig.ruby, Duel::Rubies.find(:version_file, "/", "baseline")
  end

  def test_reading_version_files
    file = ->(name, contents) { File.join(tmpdir, name).tap { |path| File.write(path, contents) } }

    assert_equal "ruby-3.4.1", Duel::Rubies.read(file.call(".ruby-version", "ruby-3.4.1\n"))
    assert_nil Duel::Rubies.read(file.call(".ruby-version", "\n"))
    assert_equal "3.4.1", Duel::Rubies.read(file.call(".tool-versions", "nodejs 20.1\nruby\t3.4.1 3.3.0\n"))
    assert_equal "3.4.2", Duel::Rubies.read(file.call(".tool-versions", "ruby   3.4.2\n"))
    assert_nil Duel::Rubies.read(file.call(".tool-versions", "nodejs 20.1\njruby 1\n"))
    {%([tools]\nruby = "3.4") => "3.4", %([env]\nX = "1"\n\n[tools]\nnode = "20"\n"ruby" = ["3.3.1", "3.2"]\n) => "3.3.1",
     %([tools]\n  ruby = { version = "3.2.2", x = "y" }\n) => "3.2.2", %([tools]\nnode = "20"\n[env]\nruby = "no"\n) => nil,
     %([tools] \nrubyx = "1"\njruby = "2"\n) => nil, %(ruby = "3"\n) => nil, %([tools]\nruby="3.1") => "3.1",
     %(# see [tools] below\n[env]\nruby = "no"\n[tools]\n  ruby  =  [  "3.0.1"]\n) => "3.0.1",
     %([tools]\nruby={version="2.7.8"}\n) => "2.7.8", %([tools]\nruby = {  version  =  "2.6.1" }\n) => "2.6.1"}.each do |toml, version|
      read = [Duel::Rubies.read(file.call("mise.toml", toml)), Duel::Rubies.read(file.call(".mise.toml", toml))]

      assert_equal [version, version], read, toml
    end
  end

  # The nearest that names a Ruby, from the version's tree up, and in a
  # directory, .ruby-version first.
  def test_the_nearest_version_file
    inner = FileUtils.mkdir_p(File.join(tmpdir, "a", "b", "c")).first
    File.write(File.join(tmpdir, "a", ".tool-versions"), "ruby 3.3.0\n")
    File.write(File.join(tmpdir, "a", "b", ".tool-versions"), "nodejs 20\n")

    assert_equal [File.join(tmpdir, "a", ".tool-versions"), "3.3.0"], Duel::Rubies.requested(File.join(inner, "..", "c"))
    File.write(File.join(tmpdir, "a", ".ruby-version"), "3.4.0\n")

    assert_equal [File.join(tmpdir, "a", ".ruby-version"), "3.4.0"], Duel::Rubies.requested(inner)
    assert_nil Duel::Rubies.requested("/")
    assert_equal [File.join(Dir.chdir(tmpdir) { Dir.pwd }, "a", ".ruby-version"), "3.4.0"], Dir.chdir(tmpdir) { Duel::Rubies.requested("a/b") },
      "from a full path"
  end

  # As chruby matches: the Ruby of that name, else the last (by name) of
  # those whose names have it, /opt/rubies' first.
  def test_chruby
    opt = File.join(@root, "opt")
    home = File.join(@root, "home-2.7")
    %w[ruby-3.2.1 ruby-3.2.10].each { |name| FileUtils.mkdir_p(File.join(opt, name)) }
    %w[3.2 ruby-3.2.2].each { |name| FileUtils.mkdir_p(File.join(home, name)) }
    with_constants(Duel::Rubies, CHRUBY: [opt, home]) do
      assert_equal File.join(home, "3.2"), Duel::Rubies.chruby("3.2")
      assert_equal File.join(opt, "ruby-3.2.10"), Duel::Rubies.chruby("3.2.1")
      assert_equal File.join(home, "ruby-3.2.2"), Duel::Rubies.chruby("ruby-3.2")
      assert_nil Duel::Rubies.chruby("2.7")
    end
    assert_equal ["/opt/rubies", File.join(Dir.home, ".rubies")], Duel::Rubies::CHRUBY
  end

  def test_commands
    assert_equal "hi", Duel::Rubies.command("sh", "-c", "echo '  hi  '; echo oops >&2")
    assert_nil Duel::Rubies.command("sh", "-c", "echo hi; exit 1")
    assert_nil Duel::Rubies.command("duel-no-such-program")
  end

  # A version's processes on another Ruby than the runner's get its
  # directory first on PATH, and none of the runner's Ruby's variables.
  def test_environment
    assert_empty Duel::Rubies.environment(RbConfig.ruby)
    link = File.join(tmpdir, "ruby")
    File.symlink(RbConfig.ruby, link)

    assert_empty Duel::Rubies.environment(link), "the runner's, by another path"
    assert Duel::Rubies.runner?(link)
    real = File.realpath(RbConfig.ruby)

    assert stub(RbConfig, :ruby, -> { link }) { Duel::Rubies.runner?(real) }, "its, by another path"
    other = executable(File.join(tmpdir, "other", "bin", "ruby"))
    env = Duel::Rubies.environment(other, path: "/usr/bin:/bin")

    assert_equal "#{File.dirname(other)}:/usr/bin:/bin", env.fetch("PATH")
    assert_equal Duel::Rubies::VARIABLES.to_h { |variable| [variable, nil] }, env.except("PATH")
    assert_includes Duel::Rubies::VARIABLES, "GEM_HOME"
    ENV["PATH"] = "/x"

    assert_equal "#{File.dirname(other)}:/x", Duel::Rubies.environment(other).fetch("PATH"), "this process's, by default"
    ENV.delete("PATH")

    assert_equal File.dirname(other), Duel::Rubies.environment(other).fetch("PATH"), "or none"
    refute Duel::Rubies.runner?(other)
  end
end
