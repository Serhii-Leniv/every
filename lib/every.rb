require "json"
require "fileutils"
require "time"
require "open3"
require "rbconfig"

module Every
  VERSION = "0.1.2".freeze
  HOMEPAGE = "https://github.com/Serhii-Leniv/every".freeze
  TAGLINE = "humane task scheduler for macOS (launchd) and Linux (systemd, beta)".freeze

  ROOT = File.expand_path("..", __dir__)
  BIN  = File.join(ROOT, "bin", "every")

  DATA_DIR   = File.expand_path(ENV["EVERY_HOME"] || "~/.local/share/every")
  LOG_DIR    = File.join(DATA_DIR, "logs")
  RUNS_DIR   = File.join(DATA_DIR, "runs")
  AGENTS_DIR = File.expand_path("~/Library/LaunchAgents")
end

require "every/color"
require "every/tail"
require "every/schedule"
require "every/store"
require "every/runtime"
require "every/launchd"
require "every/systemd"
require "every/backend"
require "every/runner"
require "every/doctor"
require "every/cli"
