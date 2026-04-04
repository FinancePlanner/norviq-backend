#!/usr/bin/env bash
set -euo pipefail

cd /workspace

mkdir -p .build

build_config="${SWIFT_BUILD_CONFIGURATION:-debug}"
watch_paths=(
  "Sources"
  "Tests"
  "Package.swift"
  "Package.resolved"
)

ignore_regex='(^|/)\.build/|(^|/)\.git/|(^|/)\.swiftpm/|(^|/)DerivedData/|\.swp$|\.tmp$'

run_server() {
  # Run migrations before starting the server
  echo "Running migrations..."
  swift run -c "$build_config" StockPlanBackend migrate --yes
  
  echo "Starting server..."
  swift run -c "$build_config" StockPlanBackend serve --env development --hostname 0.0.0.0 --port 8080
}

stop_server() {
  local pid="${1:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

trap 'stop_server "${server_pid:-}"' EXIT INT TERM

echo "Starting Vapor dev server with auto-restart on file changes..."

while true; do
  run_server &
  server_pid=$!

  inotifywait \
    --recursive \
    --event close_write,move,create,delete \
    --exclude "$ignore_regex" \
    "${watch_paths[@]}" >/dev/null 2>&1

  echo "Source change detected. Restarting Vapor..."
  stop_server "$server_pid"
done
