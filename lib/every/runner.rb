module Every
  # `every run <name>` — what launchd actually invokes. Executes the task's
  # command through the user's login shell (so PATH matches the terminal),
  # captures all output, and records the run.
  module Runner
    MAX_LOG_BYTES = 5 * 1024 * 1024
    # The run ledger is a rolling window: enough history for status and a
    # staleness watchdog, but bounded so a task firing every minute for years
    # can't grow it without limit (and keep `list` fast). Detailed output lives
    # in the separately-rotated .log.
    MAX_RUN_RECORDS = 500
    RUN_TRIM_BYTES = 256 * 1024
    # Captured output is bounded so a chatty task can't OOM the run: keep the
    # first and last HALF_OUTPUT bytes (errors show up at both ends), drop the
    # middle. The full stream still flows to the command; we just don't hold it.
    HALF_OUTPUT = 32 * 1024

    module_function

    def run(name)
      task = Store.load[name]
      unless task
        warn "every: unknown task #{name.inspect} — orphaned agent? try: every doctor"
        exit 66
      end

      FileUtils.mkdir_p(LOG_DIR)
      FileUtils.mkdir_p(RUNS_DIR)

      started = Time.now
      mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dir, note = workdir(task)
      out, exit_code = capture(task["cmd"], dir, task["timeout"])
      out = note.b + out if note   # note may hold a non-ASCII cwd path
      # Monotonic clock: an NTP/DST wall-clock jump mid-run can't make this
      # negative. The ledger timestamp still uses wall-clock `started`.
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - mono).round(2)

      append_log(name, started, exit_code, duration, out)
      append_run(name, started, exit_code, duration)
      notify_failure(name, exit_code) if exit_code != 0 && !task["quiet"]

      if $stdout.tty?
        print out
        tail = "— exit #{exit_code} in #{duration}s (logged: every log #{name})"
        puts(exit_code.zero? ? Color.green(tail) : Color.red(tail))
      end
      exit exit_code
    end

    # Execute the command, capturing bounded output and enforcing an optional
    # timeout. The child runs in its own process group so a timeout kills the
    # whole tree (the login shell plus anything it spawned), never leaving a
    # hung process to block the next scheduled run.
    def capture(cmd, dir, timeout_sec)
      require "timeout"
      head = "".b           # first HALF_OUTPUT bytes, exactly
      tail = "".b           # last HALF_OUTPUT bytes (rolling)
      dropped = 0
      status = nil
      timed_out = false

      keep = lambda do |chunk|
        if head.bytesize < HALF_OUTPUT
          room = HALF_OUTPUT - head.bytesize
          head << chunk.byteslice(0, room)
          rest = chunk.byteslice(room, chunk.bytesize - room)
          chunk = rest
        end
        return if chunk.nil? || chunk.empty?
        tail << chunk
        return unless tail.bytesize > HALF_OUTPUT
        over = tail.bytesize - HALF_OUTPUT
        dropped += over
        tail = tail.byteslice(over, HALF_OUTPUT)
      end

      Open3.popen2e(*login_shell, cmd, chdir: dir, pgroup: true) do |stdin, out, wait|
        stdin.close
        pid = wait.pid
        drain = lambda do
          while (chunk = out.read(16 * 1024))
            keep.call(chunk)
          end
        end

        begin
          # wait.value lives INSIDE the timeout: a command that closes stdout
          # early but keeps running still gets killed at the deadline.
          if timeout_sec
            Timeout.timeout(timeout_sec) { drain.call; status = wait.value }
          else
            drain.call
            status = wait.value
          end
        rescue Timeout::Error
          timed_out = true
          terminate(pid)
          status = (wait.value rescue nil)
          head << "\n[every: killed after #{timeout_sec}s timeout]\n"
        end
      end

      # Append the tail whenever it exists; only inject the truncation marker
      # when bytes were actually dropped (32-64 KB output keeps head+tail with
      # nothing between). ASCII marker + binary body: no encoding crash.
      body = head
      unless tail.empty?
        body += "\n... [#{dropped} bytes truncated] ...\n".b if dropped.positive?
        body += tail
      end
      [body, exit_code_for(status, timed_out)]
    end

    # timeout -> 124; clean exit -> its code; signal death -> 128+signum.
    def exit_code_for(status, timed_out)
      return 124 if timed_out
      return status.exitstatus if status&.exitstatus
      return 128 + status.termsig if status.respond_to?(:signaled?) && status.signaled?
      1
    end

    # Kill the whole process tree: with pgroup:true the child is its own group
    # leader, so a negative pid signals the group (no getpgid/reap race).
    def terminate(pid)
      Process.kill("TERM", -pid)
      sleep 0.3
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Run through the user's login shell so PATH matches their terminal. Only
    # bash/zsh accept the bundled `-lc`; sh/dash/others reject `-l`, so use -c.
    def login_shell
      return ["/bin/zsh", "-lc"] if RUBY_PLATFORM.include?("darwin")
      sh = ENV["SHELL"] || "/bin/bash"
      [sh, sh =~ /(bash|zsh)\z/ ? "-lc" : "-c"]
    end

    # Desktop notification so failures don't die silently in a log file.
    def notify_failure(name, exit_code)
      msg = "#{name} failed (exit #{exit_code}) — every log #{name}"
      if RUBY_PLATFORM.include?("darwin")
        script = "display notification \"#{osa_esc(msg)}\" with title \"every\""
        system("osascript", "-e", script, out: File::NULL, err: File::NULL)
      else
        system("notify-send", "every", msg, out: File::NULL, err: File::NULL)
      end
    end

    def osa_esc(s)
      s.gsub("\\", "\\\\\\\\").gsub('"', '\"')
    end

    # Probe actual readability: under launchd, TCC-protected dirs (Documents…)
    # pass File.directory? but fail on access — fall back to HOME, loudly.
    def workdir(task)
      dir = task["cwd"]
      return [Dir.home, nil] unless dir && File.directory?(dir)
      Dir.entries(dir)
      [dir, nil]
    rescue SystemCallError
      [Dir.home,
       "note: cwd #{dir} not readable under launchd (TCC) — ran from #{Dir.home}\n"]
    end

    def append_log(name, started, exit_code, duration, out)
      path = File.join(LOG_DIR, "#{name}.log")
      rotate(path)
      File.open(path, "a") do |f|
        f.puts "=== #{started.strftime('%Y-%m-%d %H:%M:%S')} exit=#{exit_code} dur=#{duration}s ==="
        f.write(out)
        f.puts unless out.empty? || out.end_with?("\n")
      end
    end

    def append_run(name, started, exit_code, duration)
      path = File.join(RUNS_DIR, "#{name}.jsonl")
      File.open(path, "a") do |f|
        f.puts JSON.generate("ts" => started.iso8601,
                             "exit" => exit_code,
                             "dur" => duration)
      end
      trim_runs(path)
    end

    # Amortized-cheap bound: only touched once the file crosses the byte cap,
    # then rewritten to the last MAX_RUN_RECORDS lines.
    def trim_runs(path)
      return if File.size(path) <= RUN_TRIM_BYTES
      lines = File.readlines(path)
      return if lines.length <= MAX_RUN_RECORDS
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, lines.last(MAX_RUN_RECORDS).join)
      File.rename(tmp, path)   # atomic: a crash mid-trim can't truncate history
    end

    def rotate(path)
      return unless File.exist?(path) && File.size(path) > MAX_LOG_BYTES
      FileUtils.mv(path, "#{path}.old")
    end
  end
end
