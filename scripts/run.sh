#!/usr/bin/env bash
# Runs the MCP server in the foreground, on stdio — which is how a local MCP
# client starts one. `--transport=http --port=8100` for the other transport.
#
# scripts/install.sh is for leaving it running; docker compose is for running
# it somewhere else entirely.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The config file is found by environment variable, defaulting inside the
# container to /config. Outside one, the copy beside this repo is the one
# somebody just filled in.
export SUMMAREADER_MCP_CONFIG="${SUMMAREADER_MCP_CONFIG:-$PWD/summareader-mcp.local.json}"
export SUMMAREADER_MCP_CACHE="${SUMMAREADER_MCP_CACHE:-$PWD/.cache}"

exec dart run bin/summareader_mcp.dart "$@"
