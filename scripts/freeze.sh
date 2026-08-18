#!/usr/bin/env bash
# Builds the mirror into one executable that needs no Python.
#
#   scripts/freeze.sh          # dist/summareader-mcp, then proves it runs
#
# One file rather than a directory: it is what a desktop build can hand over,
# and the cost is a few hundred milliseconds of unpacking at start-up. The spec
# beside this script is where the interesting decisions are.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v uv >/dev/null || { echo "uv is not installed." >&2; exit 1; }

# --with rather than a dependency in pyproject.toml: PyInstaller is needed to
# build a package of this, never to run it, and a runtime dependency on it
# would follow the wheel into the container.
uv run --with pyinstaller pyinstaller --clean --noconfirm summareader-mcp.spec

# The checks worth making every time. schema.sql is read through
# importlib.resources and is the first thing a frozen bundle loses — there is
# no source tree beside the executable to look next to — and it is lost at the
# moment somebody opens a library rather than at start-up, which is why this
# opens one.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

./dist/summareader-mcp --help >/dev/null

# Thirty-two zero bytes: this never talks to a server, it only has to get past
# the check that a master key is a key.
cat > "$tmp/config.json" <<JSON
{
  "server": "https://example.invalid",
  "token": "not-used",
  "master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
}
JSON

# Creates the cache library, which means it ran schema.sql.
SUMMAREADER_MCP_CONFIG="$tmp/config.json" SUMMAREADER_MCP_CACHE="$tmp/cache" \
  ./dist/summareader-mcp status
[ -s "$tmp/cache/library.sqlite" ] || { echo "no library was created" >&2; exit 1; }

# And the other way in: somebody else's library file, read-only.
./dist/summareader-mcp --library "$tmp/cache/library.sqlite" status

echo
echo "dist/summareader-mcp — $(du -h dist/summareader-mcp | cut -f1)"
