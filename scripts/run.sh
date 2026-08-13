#!/usr/bin/env bash
# Runs the MCP server in the foreground.
#
#   scripts/run.sh              # stdio, which is how a local MCP client starts one
#   scripts/run.sh serve --transport=http --port=8100
#   scripts/run.sh search rust  # or any other subcommand
#   scripts/run.sh --docker     # needs Docker, and nothing else
#
# scripts/install.sh is for leaving it running; docker compose is for running
# it somewhere else entirely.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --docker exists so this can be run on a machine with no Python of the right
# version and no virtualenv. `install.sh --docker` is the other half: this one
# is the foreground, Ctrl-C, try-it version, and that one leaves a container
# behind that restarts with the machine.
if [ "${1:-}" = "--docker" ]; then
  shift
  command -v docker >/dev/null || { echo "Docker is not installed." >&2; exit 1; }

  [ -f summareader-mcp.local.json ] || {
    echo "No config at ./summareader-mcp.local.json." >&2
    echo "  cp summareader-mcp.example.json summareader-mcp.local.json" >&2
    exit 1
  }

  # The container serves HTTP on 8100, not stdio. A container is not a
  # subprocess its client can start, so there is nothing on the other end of
  # its standard input — an MCP client configured with `command:` wants the
  # plain `scripts/run.sh` above instead.
  echo "Serving HTTP on 127.0.0.1:8100 — not stdio. Ctrl-C to stop." >&2

  # No -d: the point of this script is a process you can watch and stop.
  # Same ./.cache the host commands read, so `status` and `search` here
  # describe what the container actually holds.
  MCP_UID="$(id -u)" MCP_GID="$(id -g)"
  export MCP_UID MCP_GID
  exec docker compose up --build --abort-on-container-exit "$@"
fi

# The config file is found by environment variable, defaulting inside the
# container to /config. Outside one, the copy beside this repo is the one
# somebody just filled in.
export SUMMAREADER_MCP_CONFIG="${SUMMAREADER_MCP_CONFIG:-$PWD/summareader-mcp.local.json}"
export SUMMAREADER_MCP_CACHE="${SUMMAREADER_MCP_CACHE:-$PWD/.cache}"

# The virtualenv if there is one, so a checkout runs without being installed.
if [ -x .venv/bin/summareader-mcp ]; then
  exec .venv/bin/summareader-mcp "$@"
fi
command -v python3 >/dev/null || {
  echo "No Python. scripts/run.sh --docker needs only Docker." >&2
  exit 1
}
exec python3 -m summareader_mcp.cli "$@"
