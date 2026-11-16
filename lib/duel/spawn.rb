# frozen_string_literal: true

require "open3"
require_relative "platform"

module Duel
  # Starts a process whose output goes to a log, or whose input and
  # output are pipes: with Process.spawn's redirects, or where spawn
  # ignores them (JRuby on Windows, whose spawn writes to neither a file
  # nor a pipe it's given), through Open3, the output copied to the log
  # on a thread of its own. (JRuby's Open3 there does what it's asked,
  # but with the JVM's own environment, not ENV, and only a program
  # that's an .exe found by name: see .open3.)
  # @api private
  module Spawn
    # Whether Process.spawn redirects a process's input and output (and
    # Process.wait waits for it): not on JRuby on Windows.
    REDIRECTS = !Platform::JRUBY_ON_WINDOWS

    # A lone String, as Process.spawn takes one, that a shell runs.
    SHELL = /[\s"'*?<>|&;$`()]/

    # Seconds the copy of a process's output to its log may go on once
    # the process has ended: no longer, where a process it started (a
    # server's daemon, say) keeps the output open.
    COPY_WAIT = 5

    # The most of a process's output copied to its log at a time.
    CHUNK = 65_536

    # Starts +command+ (as Process.spawn takes it, an environment first),
    # its input nothing and its output and errors in +log+, opened with
    # +mode+ ("a" or "w"), with +options+ (Process.spawn's: chdir:, say).
    # Returns its pid, and where it was started through Open3, a thread
    # whose value is how it ended (a Process::Status), once its output is
    # in the log. (Where it was spawned, it's waited for as any child.)
    def self.logged(env, command, log:, mode:, redirects: REDIRECTS, **options)
      # (Here, so it's there for a failure to show. Binary, so what's copied
      # to it is as the process wrote it: on Windows, CRuby's text mode
      # would make its CRLF CRCRLF.)
      out = File.new(log, mode, binmode: true)
      if redirects
        # (At its end: on Windows, a child given a file opened to append
        # writes from where the file's at, which is its start.)
        out.seek(0, IO::SEEK_END)
        pid = begin
          Process.spawn(env, *command, in: File::NULL, out: out, err: out, **options)
        ensure
          out.close
        end
        return [pid, nil]
      end

      input, output, waiter = begin
        open3(:popen2e, env, *command, **options)
      rescue SystemCallError
        out.close
        raise
      end
      input.close
      [waiter.pid, ended(waiter, copy(output, out), output)]
    end

    # Starts +command+ (as Process.spawn takes it, an environment first)
    # with a pipe each way, and +options+. Returns its pid, its input and
    # its output, and a thread whose value is how it ended.
    def self.piped(env, command, redirects: REDIRECTS, **options)
      return open3(:popen2, env, *command, **options).then { |input, output, waiter| [waiter.pid, input, output, waiter] } unless redirects

      input, requests = IO.pipe
      replies, output = IO.pipe
      pid = begin
        Process.spawn(env, *command, in: input, out: output, **options)
      ensure
        input.close
        output.close
      end
      [pid, requests, replies, Process.detach(pid)]
    end

    # Starts +command+ (as Process.spawn takes it, an environment first),
    # its input nothing, and its output and errors this process's, with
    # +options+. Returns its pid and a thread whose value is how it ended:
    # where Process.spawn can't wait (JRuby on Windows), started through
    # Open3, its output and errors copied to this one's, and the thread's
    # value once they're copied (see .ended), so what it said as it failed
    # is there to see.
    def self.started(env, command, redirects: REDIRECTS, **options)
      unless redirects
        input, output, errors, waiter = open3(:popen3, env, *command, **options)
        input.close
        copies = [copy(output, $stdout, close: false), copy(errors, $stderr, close: false)]
        return [waiter.pid, ended(waiter, Thread.new { copies.each(&:join) }, output, errors)]
      end

      pid = Process.spawn(env, *command, in: File::NULL, **options)
      [pid, Process.detach(pid)]
    end

    # Process.spawn's options (and Open3's) that start a process in a
    # group of its own, for .kill_tree to kill it with what it starts: a
    # process group, or on Windows, which has none, a console's (and
    # Ctrl-C at the runner's doesn't reach it, as a process group's
    # doesn't).
    def self.group(windows: Platform::WINDOWS) = windows ? {new_pgroup: true} : {pgroup: true}

    # Kills +pid+ and what it started: its process group (see .group), or
    # on Windows, where no group can be killed, its tree of children
    # (taskkill /T).
    def self.kill_tree(pid, windows: Platform::WINDOWS)
      return Process.kill("KILL", -pid) unless windows

      # (Through Open3: JRuby's system on Windows ignores out: and err:.
      # Where there's no taskkill, the process alone is killed.)
      begin
        Open3.capture2e("taskkill", "/T", "/F", "/PID", pid.to_s).last.success?
      rescue Errno::ENOENT
        Process.kill("KILL", pid)
      end
    end

    # Open3's +name+d method (capture3, popen2e...), given +args+ (an
    # environment first, or none) and +options+. On JRuby on Windows
    # (+java+), whose Open3 gives a process the JVM's own environment and
    # ignores unsetenv_others, with ENV under the environment given (or
    # with unsetenv_others, every one of ENV's variables unset but those
    # given), each by ENV's name for it, and the program found, and its
    # arguments quoted, as Windows takes them (see .program).
    def self.open3(name, *args, java: Platform::JRUBY_ON_WINDOWS, **options, &)
      return Open3.public_send(name, *args, **options, &) unless java

      none = {} #: Hash[String, String?]
      env, *command = args.first.is_a?(Hash) ? args : [none, *args]
      current = ENV.to_h
      under = options[:unsetenv_others] ? current.keys.product([nil]).to_h : current #: Hash[String, String?]
      # (Each given by ENV's name for it, whatever its case: Windows's
      # names are one, but JRuby's PATH given doesn't replace ENV's Path.)
      given = env.transform_keys { |var| current.each_key.find { |name| name.casecmp?(var) } || var }
      Open3.public_send(name, under.merge(given), *program(command), **options, &)
    end

    # +command+ as Windows runs it: a lone String that a shell runs (with
    # a space in it, say) as cmd.exe's, and otherwise with its program
    # found (by name, in +path+'s directories), as the program it is, or
    # with each of +exts+ added where it has no extension (a .cmd file's,
    # say), and its arguments quoted (see .quote). Errno::ENOENT if
    # there's no such program.
    def self.program(command, path: ENV.fetch("PATH", ""), exts: ENV.fetch("PATHEXT", ".EXE").split(";"))
      program = command.fetch(0)
      args = command.drop(1)
      return ["cmd.exe", "/c", program] if args.empty? && program.match?(SHELL)

      places = program.match?(%r{[/\\]}) ? [program] : path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, program) }
      found = places.flat_map { |place| File.extname(place).empty? ? exts.map { |ext| place + ext } : place }.find { |file| File.file?(file) }
      raise Errno::ENOENT, program unless found

      [found, *args.map { |arg| quote(arg) }]
    end

    # +arg+ as a Windows program's command line has it, where it's empty or
    # has a space or a quote in it: in quotes, a quote in it after a
    # backslash, and the backslashes before a quote, or before its end,
    # doubled. (Java quotes one with a space alone, and passes its quotes
    # on as they are, which the program takes out.)
    def self.quote(arg)
      return arg unless arg.empty? || arg.match?(/[\s"]/)

      %("#{arg.gsub(/(\\*)"/) { "#{$1}#{$1}\\\"" }.sub(/(\\+)\z/) { "#{$1}#{$1}" }}")
    end

    # A thread copying +output+ to +out+, until it ends (or is closed),
    # then closing both (but +out+, unless +close+: this process's
    # $stdout, say).
    def self.copy(output, out, close: true)
      Thread.new do
        # (A read at a time, not IO.copy_stream, which on Linux closing
        # the pipe under it doesn't stop, and each in the log at once, for
        # what waits on it to see.)
        loop do
          out.write(output.readpartial(CHUNK))
          out.flush
        end
      # (At its end, EOFError, or closed under it, COPY_WAIT seconds after
      # its process ended: IOError, or EBADF.)
      rescue IOError, Errno::EBADF
        nil
      ensure
        output.close
        out.close if close
      end
    end

    # A thread whose value is +waiter+'s, once +copy+ is done copying
    # +outputs+, or COPY_WAIT seconds later, when they're closed under it.
    def self.ended(waiter, copy, *outputs)
      Thread.new do
        status = waiter.value
        outputs.each(&:close) unless copy.join(COPY_WAIT)
        status
      end
    end
  end
end
