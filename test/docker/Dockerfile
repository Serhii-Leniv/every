# Ruby plus the systemd toolchain, so `systemd-analyze calendar` can validate
# the OnCalendar expressions `every` generates. `systemd-analyze` is a pure
# validator here — it needs the binary, not PID 1 — so a plain image (no init)
# is enough. The repo is mounted at build/run time; nothing is COPYed in, which
# keeps this image code-agnostic and reusable.
FROM ruby:3.3-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
