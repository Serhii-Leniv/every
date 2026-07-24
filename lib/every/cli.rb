module Every
  class CLI
    # Bounded so the generated unit filename (com.every.<name>.plist /
    # every-<name>.timer) stays under the 255-byte filesystem limit.
    MAX_NAME = 100

    def initialize(argv)
      @argv = argv
    end

    def run
      case @argv.first
      when nil, "help", "-h", "--help"   then help
      when "version", "--version"        then version
      when "list", "ls"                  then list
      when "log"                         then log
      when "rm", "remove"                then rm(@argv[1])
      when "pause"                       then pause(@argv[1])
      when "resume"                      then resume(@argv[1])
      when "doctor"                      then Doctor.run
      when "run"                         then Runner.run(@argv[1] || usage!("run <name>"))
      else                                    add(@argv)
      end
    rescue ArgumentError => e
      warn "every: #{e.message}"
      warn "see: every help"
      exit 64
    rescue => e
      # Any other failure prints a clean line, never a raw backtrace.
      # (SystemExit/Interrupt aren't StandardError, so they pass through.)
      warn "every: #{e.message} (#{e.class})"
      exit 1
    end

    # ---- add: every <schedule> [--name NAME] -- <command> ----

    def add(argv)
      sep = argv.index("--")
      unless sep
        first = argv.first.to_s
        raise ArgumentError,
              "#{first.inspect} isn't a command, and there's no `--` before a task.\n" \
              "  to schedule:  every <when> -- <command>   (e.g. every day 9am -- brew update)\n" \
              "  commands:     list, log, run, pause, resume, rm, doctor, version"
      end

      pre = argv[0...sep]
      cmd_tokens = argv[(sep + 1)..-1] || []
      raise ArgumentError, "missing command after --" if cmd_tokens.empty?

      pre, explicit_name = extract_value_flag(pre, "--name")
      pre, timeout_raw = extract_value_flag(pre, "--timeout")
      quiet = !pre.delete("--quiet").nil?
      timeout = timeout_raw && parse_duration(timeout_raw)

      schedule = Schedule.parse(pre)
      # The command is a shell command line — every runs it through the login
      # shell, so tokens are joined with spaces (like cron), and shell features
      # (env prefixes, pipes, &&, globs) work. Quote args with spaces or
      # metacharacters as you would at a prompt:  -- 'touch "my file.txt"'.
      cmd = cmd_tokens.join(" ")
      store = Store.load

      if explicit_name
        name = sanitize(explicit_name)
        if name.empty?
          raise ArgumentError, "--name #{explicit_name.inspect} is empty after sanitizing " \
                               "(names allow a-z 0-9 . _ -)"
        end
        if name.length > MAX_NAME
          raise ArgumentError, "--name is too long (max #{MAX_NAME} chars)"
        end
        if store[name]
          raise ArgumentError,
                "task #{name.inspect} already exists (every rm #{name}, or pick another --name)"
        end
      else
        name = derive_name(cmd, store)
      end

      attrs = { "cmd" => cmd,
                "schedule" => schedule.to_h,
                "cwd" => Dir.pwd,
                "created_at" => Time.now.iso8601,
                "paused" => false,
                "quiet" => quiet }
      attrs["timeout"] = timeout if timeout

      # A newly-added task starts with a clean slate, even if a task with this
      # name existed before and was rm'd (rm keeps the ledger/log for later
      # inspection, but re-using the name means a fresh task, not the old one).
      reset_history(name)
      store.add(name, attrs)
      Runtime.ensure!
      FileUtils.mkdir_p(LOG_DIR)   # so launchd's _agent.log redirect can open on the first fire
      begin
        backend.write(name, schedule)
        backend.enable(name)
      rescue => e
        store.remove(name)                 # roll back so store & scheduler agree
        backend.delete_units(name) rescue nil
        raise "could not schedule #{name}: #{e.message}"
      end

      puts "#{Color.green('✓')} scheduled #{name}: #{schedule.raw} — #{cmd}"
      nxt = schedule.next_run
      puts "  next run: #{nxt.strftime('%a %d %b %H:%M')}" if nxt
      puts "  runs every #{schedule.human_interval} while the machine is awake" if schedule.interval
      # The task runs detached, so its output won't appear in this terminal —
      # spell that out, it's the #1 first-timer confusion.
      puts "  output:   runs in the background → see it with `every log #{name}`"
    end

    # ---- list ----

    def list
      store = Store.load
      if store.tasks.empty?
        puts "no tasks yet — try: every day 9am -- brew update"
        return
      end

      rows = store.tasks.map do |name, t|
        begin
          sched = Schedule.from_h(t["schedule"])
          last = store.last_run(name)
          lt = last && safe_time(last["ts"])
          last_s = lt ? lt.strftime("%d %b %H:%M") : "—"
          # Trust the scheduler, not just our own ledger: a task whose agent is
          # gone will never fire again, so don't report a stale "ok".
          scheduled = !t["paused"] && backend.loaded?(name)
          status = task_status(t["paused"], scheduled, last)
          nxt = scheduled ? next_str(t, sched, last) : "—"
          [name, sched.raw, last_s, status, nxt]
        rescue StandardError
          # One unreadable/forward-incompatible record must not hide every task.
          [name, (t.dig("schedule", "raw") || "?"), "—", "invalid", "—"]
        end
      end

      headers = %w[NAME SCHEDULE LAST STATUS NEXT]
      widths = headers.each_with_index.map do |h, i|
        [h.length, rows.map { |r| r[i].to_s.length }.max || 0].max
      end
      print_row(headers, widths)
      rows.each { |r| print_row(r, widths, colorize: true) }

      if rows.any? { |r| r[3] == "unscheduled" }
        puts "\n· some tasks aren't loaded in the scheduler — `every resume <name>` to fix, or `every doctor`"
      end
    end

    def next_str(task, sched, last)
      return "—" if task["paused"]
      if sched.interval
        lt = last && safe_time(last["ts"])
        return "soon" unless lt
        (lt + sched.interval).strftime("%d %b %H:%M")
      else
        sched.next_run&.strftime("%d %b %H:%M") || "?"
      end
    end

    def print_row(cells, widths, colorize: false)
      out = cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ")
      if colorize
        out = out.sub(/\bok\b/) { |m| Color.green(m) }
        out = out.sub(/\bFAIL\(\d+\)/) { |m| Color.red(m) }
        out = out.sub(/\bunscheduled\b/) { |m| Color.red(m) }
      end
      puts out
    end

    # ---- log / rm / pause / resume ----

    def log
      args = @argv[1..-1] || []
      n = 40
      if (i = args.index("-n"))
        n = args[i + 1].to_i
        n = 40 if n <= 0
        args = args[0...i] + (args[(i + 2)..-1] || [])
      end
      name = args.first
      usage!("log <name> [-n N]") unless name
      path = File.join(LOG_DIR, "#{name}.log")
      unless File.exist?(path)
        warn "every: no logs yet for #{name.inspect} (has it run? check: every list)"
        exit 1
      end
      puts Tail.lines(path, n).join
    end

    def rm(name)
      usage!("rm <name>") unless name
      store = Store.load
      unless store[name]
        warn "every: no task #{name.inspect}"
        exit 1
      end
      backend.disable(name)
      backend.delete_units(name)
      store.remove(name)
      puts "#{Color.green('✓')} removed #{name} (logs kept in #{LOG_DIR})"
    end

    def pause(name)
      usage!("pause <name>") unless name
      store = Store.load
      unless store[name]
        warn "every: no task #{name.inspect}"
        exit 1
      end
      backend.disable(name)
      store.update(name, "paused" => true)
      puts "#{Color.green('✓')} paused #{name}"
    end

    def resume(name)
      usage!("resume <name>") unless name
      store = Store.load
      task = store[name]
      unless task
        warn "every: no task #{name.inspect}"
        exit 1
      end
      Runtime.ensure!
      backend.write(name, Schedule.from_h(task["schedule"]))
      backend.enable(name)
      store.update(name, "paused" => false)
      puts "#{Color.green('✓')} resumed #{name}"
    end

    # ---- helpers ----

    def derive_name(cmd, store)
      base = sanitize(File.basename(cmd.strip.split(/\s+/).first.to_s))[0, MAX_NAME].to_s
      base = "task" if base.empty?
      name = base
      i = 2
      while store[name]
        suffix = "-#{i}"
        name = base[0, MAX_NAME - suffix.length] + suffix
        i += 1
      end
      name
    end

    def sanitize(s)
      s = s.to_s.downcase.gsub(/[^a-z0-9_.-]/, "-").gsub(/\A-+|-+\z/, "")
      s =~ /\A\.+\z/ ? "" : s   # "." / ".." are not usable filenames
    end

    def parse_duration(raw)
      m = raw.to_s.match(/\A(\d+)(s|m|h)\z/)
      raise ArgumentError, "bad duration #{raw.inspect} (e.g. 90s, 30m, 2h)" unless m
      secs = m[1].to_i * { "s" => 1, "m" => 60, "h" => 3600 }[m[2]]
      raise ArgumentError, "--timeout must be greater than 0" if secs.zero?
      secs
    end

    # Pull `--flag value` or `--flag=value` out of the tokens. Rejects a missing
    # value or a value that is itself a flag (so `--name --quiet` can't silently
    # name the task "quiet" and swallow the flag).
    def extract_value_flag(tokens, flag)
      if (i = tokens.index(flag))
        value = tokens[i + 1]
        if value.nil? || value.start_with?("--")
          raise ArgumentError, "#{flag} needs a value"
        end
        return [tokens[0...i] + (tokens[(i + 2)..-1] || []), value]
      end
      if (i = tokens.index { |t| t.start_with?("#{flag}=") })
        value = tokens[i].split("=", 2)[1].to_s
        raise ArgumentError, "#{flag} needs a value" if value.empty?
        return [tokens[0...i] + (tokens[(i + 1)..-1] || []), value]
      end
      [tokens, nil]
    end

    # The list STATUS reflects the SCHEDULER's reality, not just our ledger:
    # a task that isn't loaded shows "unscheduled" rather than a stale "ok".
    def task_status(paused, scheduled, last)
      if paused                 then "paused"
      elsif !scheduled          then "unscheduled"
      elsif last.nil?           then "·"
      elsif last["exit"] == 0   then "ok"
      else                           "FAIL(#{last['exit']})"
      end
    end

    def safe_time(str)
      Time.parse(str.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Clear any leftover ledger/log from a previously-removed task of this name.
    def reset_history(name)
      FileUtils.rm_f(File.join(RUNS_DIR, "#{name}.jsonl"))
      Dir.glob(File.join(LOG_DIR, "#{name}.log*")).each { |f| File.delete(f) }
    end

    def backend
      Backend.current
    end

    def usage!(msg)
      warn "usage: every #{msg}"
      exit 64
    end

    def version
      puts "every #{VERSION}"
      puts TAGLINE
      puts HOMEPAGE
    end

    def help
      puts <<~TXT
        every #{VERSION} — #{TAGLINE}
        #{HOMEPAGE}

        schedule anything on your Mac, humanely

        add a task:
          every 15m -- ~/bin/sync-notes.sh
          every hourly -- brew update
          every day 9am,6pm -- ruby ~/bin/report.rb
          every weekdays 9:30 -- ~/bin/standup-prep.sh
          every monday,thursday 10:00 --name reports -- ~/bin/weekly.sh

          Flags: --name NAME, --quiet (no failure notification),
                 --timeout 30m (kill a run that overruns, so it can't block
                 the next one).
          The command runs through your login shell (PATH works), in the
          directory where you added it. Missed calendar runs fire on wake.
          Failed runs pop a macOS notification unless --quiet.

        manage:
          every list                what's scheduled, last/next run, ok/FAIL
          every log <name> [-n N]   output of recent runs
          every run <name>          run it right now (prints output, logs too)
          every pause <name>        stop scheduling (keeps the task)
          every resume <name>       start again
          every rm <name>           remove task (logs are kept)
          every doctor              explain why something isn't running

        data:  #{DATA_DIR}
        more:  #{HOMEPAGE}
      TXT
    end
  end
end
