#!/usr/bin/env bash
# Runs the MCP server in the foreground.
#
#   scripts/run.sh              # stdio, which is how a local MCP client starts one
#   scripts/run.sh gui          # the desktop console, which is a Flutter app
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

# The console is a Flutter application in console/, not a subcommand — the
# window that used to be one was Tk inside this package and is gone. `gui` is
# kept as the spelling because it is what somebody types, and because a script
# that answers "no such subcommand" to the obvious word is a script that knows
# the answer and refuses to say it.
#
# The exports above matter here: the console reads the same two variables, so
# `run.sh gui` opens the library `run.sh status` describes rather than the one
# in the home directory. SUMMAREADER_MCP_EXE is how it finds the mirror to
# start — it is a separate program now, and in a checkout the console has no
# way to guess that.
if [ "${1:-}" = "gui" ]; then
  shift
  export SUMMAREADER_MCP_EXE="${SUMMAREADER_MCP_EXE:-$PWD/.venv/bin/summareader-mcp}"

  # A release build if one has been made, because it starts instantly and
  # needs no toolchain. Otherwise the development run, which needs Flutter.
  case "$(uname -s)" in
    Darwin) bundle="console/build/macos/Build/Products/Release/summareader_mcp_console.app/Contents/MacOS/summareader_mcp_console"; device=macos ;;
    *)      bundle="console/build/linux/x64/release/bundle/summareader_mcp_console"; device=linux ;;
  esac

  if [ -x "$bundle" ]; then
    exec "$bundle" "$@"
  fi
  command -v flutter >/dev/null || {
    echo "No Flutter, and no console built yet." >&2
    echo "  cd console && flutter build $device --release" >&2
    echo "…or install Flutter 3.47 and run this again." >&2
    exit 1
  }
  cd console
  exec flutter run -d "$device" --release "$@"
fi

# The virtualenv if there is one, so a checkout runs without being installed.
if [ -x .venv/bin/summareader-mcp ]; then
  exec .venv/bin/summareader-mcp "$@"
fi
command -v python3 >/dev/null || {
  echo "No Python. scripts/run.sh --docker needs only Docker." >&2
  exit 1
}
exec python3 -m summareader_mcp.cli "$@"
