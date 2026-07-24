# Changelog

## Unreleased

### Changed
- Color is now consistent and honest across the CLI. Success `✓` marks
  (`scheduled`/`paused`/`resumed`/`removed`), `doctor`'s `✓`/`✗` checks and
  summary, and `run`'s exit line all pick up green/red — matching what `list`
  already did. A new `Every::Color` helper centralizes the ANSI so it's applied
  the same way everywhere, and it **respects [`NO_COLOR`](https://no-color.org)
  and `TERM=dumb`, and never colors non-TTY output** (pipes, files, CI logs stay
  clean). Color is only ever a hint — every message still reads with the codes
  stripped.

## 0.1.2 — 2026-07-24

Dogfooding pass — small fixes from actually using it.

### Fixed
- `list` now reflects the scheduler's real state, not just the run ledger: a
  task whose agent isn't loaded shows **`unscheduled`** (with a hint) instead of
  a stale `ok`/`NEXT`. Closes a gap in the core "know it ran" promise — a task
  that silently stopped firing no longer looks healthy.

### Changed
- After scheduling a task, the confirmation spells out that **output goes to the
  log** (`every log <name>`), since the task runs detached and its output won't
  appear in your terminal — the #1 first-timer confusion.
- A mistyped command (e.g. `every update`) now gets a helpful message listing
  the real commands and the `-- <command>` form, instead of a cryptic
  "expected schedule".

## 0.1.1 — 2026-07-24

Hardening release. Same features as 0.1.0, made dependable after several rounds
of stress testing and code review.

### Added
- **Linux support (beta)** — systemd user timers, same commands; units in
  `~/.config/systemd/user`. Run `loginctl enable-linger $USER` so timers fire
  at boot / after logout.
- **`--timeout 30m`** — kill a run that overruns (and its whole process group)
  so a hung task can't block its own next run.
- **Richer schedules** — `day 9am,6pm` (several times a day), `weekdays 9:30`,
  `weekends 11am`, `monday,thursday 10:00`.
- **Failure notifications** — a failed run pops a desktop notification
  (`--quiet` to opt out).
- **`every run <name>`** is a documented command; prints output on a terminal.
- **Self-identifying** `every version` / `every help` (name, tagline, homepage).

### Fixed
- Output and the run ledger are bounded (no OOM on a chatty task, no unbounded
  disk growth); log/ledger/registry writes are crash-atomic.
- Run duration uses a monotonic clock (immune to NTP/DST jumps); `next run`
  display is DST-safe.
- Scheduled runs use the live installed code, so `brew upgrade` takes effect
  (a `~/Documents` install on macOS still runs from a TCC-safe copy).
- `doctor` no longer false-fails a working `~/path/to/script` task; checks
  systemd linger on Linux; macOS-only hints stay on macOS.
- Re-adding a task with a previously-removed name starts with a clean history.
- One corrupt/forward-incompatible task no longer hides the whole `list`.
- Empty/invalid schedules (`day ,`, `13pm`) are rejected instead of silently
  creating a task that never fires.
- Clean error messages instead of Ruby backtraces; `--timeout 0s`, flag-eating
  `--name`, and over-long names are rejected.

### Changed
- The command is a shell command line (like cron): tokens after `--` run in
  your login shell, so env prefixes, pipes, `&&`, and globs work. Quote args
  with spaces or metacharacters as you would at a prompt.

## 0.1.0 — 2026-07-24

Initial release. Schedule anything on your Mac with one phrase; `list` / `log`
/ `doctor` show whether it actually ran. Pure Ruby stdlib, macOS/launchd.
