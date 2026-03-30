#!/bin/sh
# nproc on Linux reads the cgroup CPU quota, so it returns the value set by
# --cpus=N rather than the host's total CPU count.  This ensures the Dart
# server spawns exactly as many isolates as the container is allowed to use.
exec /server/bin/server "$(nproc)"
