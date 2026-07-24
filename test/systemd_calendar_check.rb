#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Validates every OnCalendar expression `every` generates against the real
# `systemd-analyze calendar` parser. Requires the systemd toolchain (the
# `systemd-analyze` binary) — CI runs this natively on the Linux runner and,
# in a pinned container, from the `docker` workflow.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "every"

# A spread that exercises each shape the parser emits: single/multi time,
# weekday sets, weekend sets, and named-day sets.
SCHEDULES = [
  "day 9am",
  "day 9am,6pm",
  "weekdays 9:30",
  "weekends 11am",
  "monday 10:00",
  "monday,thursday 6pm",
].freeze

count = 0
SCHEDULES.each do |raw|
  schedule = Every::Schedule.parse(raw.split)
  Every::Systemd.calendar_lines(schedule).each do |line|
    ok = system("systemd-analyze", "calendar", line, out: File::NULL)
    abort "invalid OnCalendar for #{raw.inspect}: #{line.inspect}" unless ok
    count += 1
  end
end

puts "all #{count} calendar expressions valid"
