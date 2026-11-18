# frozen_string_literal: true

require "open3"
require_relative "native"
require_relative "platform"

module Duel
  # Starts a process whose output goes to a log, or whose input and
  # output are pipes, and gives the Child to wait for it and stop it by:
  # with Process.spawn's redirects (Directly), or where spawn can't
  # redirect or wait (JRuby on Windows), through Open3 (ThroughOpen3),
  # the output copied to the log on a thread of its own. STARTER is the
  # one that works here. (JRuby's Open3 there does what it's asked, but
  # with the JVM's own environment, not ENV, and only a program that's an
  # .exe found by name: see .open3.)
  # @api private
  module Spawn
    # Whether Process.spawn redirects a process's input and output: not on
    # JRuby on Windows, whose spawn writes to neither a file nor a pipe
    # it's given (https://github.com/jruby/jruby/issues/3116).
    REDIRECTS = !Platform::JRUBY_ON_WINDOWS

    # Whether Process.wait waits for a process spawned: not on JRuby on
    # Windows, where it returns at once, and so does Process.detach's
    # thread (https://github.com/jruby/jruby/issues/7515).
    WAITS = !Platform::JRUBY_ON_WINDOWS

    # A lone String, as Process.spawn takes one, that a shell runs.
    SHELL = /[\s"'*?<>|&;$`()]/

    # Seconds the copy of a process's output to its log may go on once
    # the process has ended: no longer, where a process it started (a
    # server's daemon, say) keeps the output open.
    COPY_WAIT = 5

    # The most of a process's output copied to its log at a time.
    CHUNK = 65_536

    # The lines of a process's log a failure shows (see .tail).
    LOG_LINES = 10

    # A process started, to wait for and stop.
    class Child
      # What Process.kill raises for a process that's gone: ESRCH, or on
      # JRuby on Windows, EPERM.
      GONE = [Errno::ESRCH, Errno::EPERM].freeze

      attr_reader :pid

      # +pid+'s, waited for by +waiter+, a thread whose value is how it
      # ended (a Process::Status), or for one spawned, by Process.detach's,
      # once it's asked for (see #waiter and #detach). +group+: whether it
      # was started in a group of its own (see Spawn.group), which #kill
      # kills with it. (+windows+: whether it's on Windows, where it can
      # only be killed: see #signal.)
      def initialize(pid, waiter = nil, group: false, windows: Platform::WINDOWS)
        @pid = pid
        @waiter = waiter
        @group = group
        @windows = windows
      end

      # The thread whose value is how it ended (a Process::Status). For one
      # spawned, Process.detach's, made once it's asked for: until then,
      # #wait waits for it itself.
      def waiter = @waiter ||= Process.detach(@pid)

      # Waits for it on a thread from now on (see #waiter), so that it's
      # reaped as it ends: returns itself.
      def detach = tap { waiter }

      def alive? = waiter.alive?

      # Waits for it, and returns how it ended, as Native::Child.wait says:
      # its exit status (or nil), the signal that killed it (or nil), and
      # its peak memory, where it was spawned and nothing else waits for it
      # (see #waiter), and that can be told (or nil).
      def wait
        waiter = @waiter
        waiter ? Native::Child.ended(waiter.value) : Native::Child.wait(@pid)
      end

      # Sends it +signal+. On Windows, which can send another process no
      # signal but KILL, kills it, with what it started (taskkill /T): a
      # process it started would go on otherwise (JRuby's JVM, started by
      # its jruby.exe, say). One that's gone is let be.
      def signal(signal)
        @windows ? Spawn.kill_tree(@pid, windows: true) : Process.kill(signal, @pid)
      rescue *GONE
        nil
      end

      # Kills it, with what it started where that can be told (its group,
      # or on Windows, its tree: see Spawn.kill_tree), and waits for it to
      # end. One that's gone is let be.
      def kill
        (@group || @windows) ? Spawn.kill_tree(@pid, windows: @windows) : Process.kill("KILL", @pid)
        waiter.join
      rescue *GONE
        nil
      end

      # Waits up to +seconds+ for it to end, then kills it (see #kill).
      def stop(seconds) = (kill unless waiter.join(seconds))
    end

    # Starts a process with Process.spawn, given its redirects and pipes.
    module Directly
      # Starts +command+ (as Process.spawn takes it, an environment first),
      # its input nothing and its output and errors in +log+, opened with
      # +mode+ ("a" or "w"), with +options+ (Process.spawn's: chdir:, say).
      # Returns its Child, not yet waited for, so that Child#wait can wait
      # for it as any child, with wait4 (or Child#detach, on a thread).
      def self.logged(env, command, log:, mode:, **options)
        out = Spawn.log(log, mode)
        # (At its end: on Windows, a child given a file opened to append
        # writes from where the file's at, which is its start.)
        out.seek(0, IO::SEEK_END)
        begin
          Child.new(Process.spawn(env, *command, in: File::NULL, out: out, err: out, **options))
        ensure
          out.close
        end
      end

      # Starts +command+ (as Process.spawn takes it, an environment first)
      # with a pipe each way, and +options+, in a group of its own if
      # +group+ (see Spawn.group). Returns its Child, its input and its
      # output.
      def self.piped(env, command, group: false, **options)
        options = options.merge(Spawn.group) if group
        input, requests = IO.pipe
        replies, output = IO.pipe
        pid = begin
          Process.spawn(env, *command, in: input, out: output, **options)
        ensure
          input.close
          output.close
        end
        [Child.new(pid, Process.detach(pid), group: group), requests, replies]
      end

      # Starts +command+ (as Process.spawn takes it, an environment first),
      # its input nothing, and its output and errors this process's, with
      # +options+. Returns its Child.
      def self.started(env, command, **options)
        pid = Process.spawn(env, *command, in: File::NULL, **options)
        Child.new(pid, Process.detach(pid))
      end
    end

    # Starts a process through Open3, as Directly does, where
    # Process.spawn can't redirect or wait: what it says is copied to its
    # log (or to this process's output) on a thread of its own, and its
    # Child's thread (Child#waiter) is Open3's, its value once what it
    # said is copied (see Spawn.ended).
    module ThroughOpen3
      def self.logged(env, command, log:, mode:, **options)
        out = Spawn.log(log, mode)
        input, output, waiter = begin
          Spawn.open3(:popen2e, env, *command, **options)
        rescue SystemCallError
          out.close
          raise
        end
        input.close
        Child.new(waiter.pid, Spawn.ended(waiter, Spawn.copy(output, out), output))
      end

      def self.piped(env, command, group: false, **options)
        options = options.merge(Spawn.group) if group
        input, output, waiter = Spawn.open3(:popen2, env, *command, **options)
        [Child.new(waiter.pid, waiter, group: group), input, output]
      end

      # (Its output and errors copied to this one's, so what it said as it
      # failed is there to see.)
      def self.started(env, command, **options)
        input, output, errors, waiter = Spawn.open3(:popen3, env, *command, **options)
        input.close
        copies = [Spawn.copy(output, $stdout, close: false), Spawn.copy(errors, $stderr, close: false)]
        Child.new(waiter.pid, Spawn.ended(waiter, Thread.new { copies.each(&:join) }, output, errors))
      end
    end

    # How a process starts here: Directly, but where Process.spawn can't
    # redirect or wait, ThroughOpen3.
    # simplecov:disable ThroughOpen3 is JRuby on Windows's (its test run
    # covers it).
    STARTER = (REDIRECTS && WAITS) ? Directly : ThroughOpen3
    # simplecov:enable

    # How a process that failed ended: its exit status +code+, or the
    # +signal+ that killed it (as Child#wait says).
    def self.why(code, signal)
      return "exited with #{code}" if code

      killed = signal #: Integer
      name = begin
        Signal.signame(killed)
      # (JRuby's, for a number it has no name for, where CRuby's is nil,
      # and on Windows for KILL's: https://github.com/jruby/jruby/issues/10080.)
      rescue ArgumentError
        nil
      end
      name ? "was killed by SIG#{name}" : "was killed by signal #{killed}"
    end

    # The end of the log at +path+, for a failure to show: its last
    # LOG_LINES lines, without CRLF's CR (a Windows program's).
    def self.tail(path) = File.readlines(path, chomp: true).last(LOG_LINES).map { |line| "#{line}\n" }.join

    # +message+, then the end of the log at +path+ (see .tail), where
    # there's a log with anything in it.
    def self.with_tail(message, path)
      tail = path ? tail(path) : ""
      tail.empty? ? message : "#{message}\n#{tail}"
    end

    # The log at +path+, opened with +mode+, for a process's output: here,
    # so it's there for a failure to show, and binary, so what's copied to
    # it is as the process wrote it (on Windows, CRuby's text mode would
    # make its CRLF CRCRLF).
    def self.log(path, mode) = File.new(path, mode, binmode: true)

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

      # (Its output read, not shown, through Open3: JRuby's system on
      # Windows ignores out: and err:,
      # https://github.com/jruby/jruby/issues/10081. Where there's no
      # taskkill, the process alone is killed.)
      begin
        open3(:capture2e, "taskkill", "/T", "/F", "/PID", pid.to_s).last.success?
      rescue Errno::ENOENT
        Process.kill("KILL", pid)
      end
    end

    # Open3's +name+d method (capture3, popen2e...), given +args+ (an
    # environment first, or none) and +options+. On JRuby on Windows
    # (+jruby_on_windows+), whose Open3 gives a process the JVM's own
    # environment (https://github.com/jruby/jruby/issues/8680) and ignores
    # unsetenv_others, with ENV under the environment given (or with
    # unsetenv_others, every one of ENV's variables unset but those
    # given), each by ENV's name for it, and the program found, and its
    # arguments quoted, as Windows takes them (see .program).
    def self.open3(name, *args, jruby_on_windows: Platform::JRUBY_ON_WINDOWS, **options, &)
      return Open3.public_send(name, *args, **options, &) unless jruby_on_windows

      none = {} #: Hash[String, String?]
      env, *command = args.first.is_a?(Hash) ? args : [none, *args]
      current = ENV.to_h
      under = options[:unsetenv_others] ? current.keys.product([nil]).to_h : current #: Hash[String, String?]
      # (Each given by ENV's name for it, whatever its case: Windows's
      # names are one, but JRuby's PATH given doesn't replace ENV's Path,
      # https://github.com/jruby/jruby/issues/8951.)
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
    # on as they are, which the program takes out:
    # https://github.com/jruby/jruby/issues/8945.)
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
