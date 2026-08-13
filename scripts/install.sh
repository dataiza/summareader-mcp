#!/usr/bin/env bash
# Installs the MCP server as a systemd *user* service, on the HTTP transport.
# `--uninstall` reverses it.
#
# A user service and not a system one: this holds the master key and a
# plaintext copy of the library, so it belongs to one person and needs no root
# to install, inspect or remove.
#
# `--docker` runs it as a container instead — no Dart SDK on the machine, and
# the same image the compose file describes.
#
#   BIN_DIR=…   where the compiled binary goes  (default ~/.local/bin)
#   CONFIG=…    the secrets file                (default ./summareader-mcp.local.json)
#   CACHE_DIR=… the decrypted mirror            (default ~/.cache/summareader-mcp)
#   PORT=…      what it listens on              (default 8100)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# mise puts the toolchains on PATH from a login shell only, and this is a
# script somebody may well run from a hook or over ssh.
export PATH="$HOME/.local/share/mise/shims:$PATH"

name="summareader-mcp"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
unit_dir="$HOME/.config/systemd/user"
config="${CONFIG:-$repo/$name.local.json}"
cache_dir="${CACHE_DIR:-$HOME/.cache/$name}"
port="${PORT:-8100}"

# In a container instead. `restart: unless-stopped` and an enabled
# docker.service are what bring it back after a reboot, so there is no systemd
# unit on this path to keep in step with compose.
if [ "${1:-}" = "--docker" ]; then
  command -v docker >/dev/null || { echo "Docker is not installed." >&2; exit 1; }
  if [ "${2:-}" = "--uninstall" ]; then
    docker compose down
    echo "stopped. The mirror volume is kept; it is a cache and safe to drop:"
    echo "  docker volume rm ${PWD##*/}_mcp-cache"
    exit 0
  fi
  [ -f "$config" ] || { echo "No config at $config." >&2; exit 1; }

  # The compose file mounts ../summareader-mcp.local.json, so the config has
  # to be the one beside the repo rather than one somewhere else entirely.
  [ "$config" = "$repo/$name.local.json" ] \
    || echo "note: compose mounts $repo/$name.local.json, not $config"

  docker compose up -d --build

  for _ in $(seq 30); do
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 \
    && echo "answering on 127.0.0.1:$port" \
    || { echo "did not answer on 127.0.0.1:$port — docker compose logs" >&2; exit 1; }

  # A container cannot reach a sync server bound to 127.0.0.1 on the host, and
  # a service name only resolves on a shared network. Both are one edit in the
  # compose file, and both look like "the server is down" from in here.
  host="$(sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"[a-z]*:\/\/\([^:\/"]*\).*/\1/p' "$config")"
  case "$host" in
    localhost|127.0.0.1)
      echo "note: \"server\" is $host — from inside the container that is the"
      echo "      container itself. Use the sync server's shared network and its"
      echo "      service name, or an address this host publishes." ;;
    ''|http*) ;;
    *)
      docker network ls --format '{{.Name}}' | grep -q "sync" \
        || echo "note: \"server\" names $host; uncomment the sync network block in docker-compose.yml." ;;
  esac
  exit 0
fi

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now "$name.service" 2>/dev/null || true
  rm -f "$unit_dir/$name.service" "$bin_dir/$name"
  systemctl --user daemon-reload
  echo "removed: the service and the binary."
  echo "kept:    $cache_dir — a cache, safe to delete; and $config, which is not."
  exit 0
fi

if [ ! -f "$config" ]; then
  echo "No config at $config." >&2
  echo "  cp $name.example.json $name.local.json   # then fill it in" >&2
  exit 1
fi

mkdir -p "$bin_dir" "$unit_dir" "$cache_dir"

# Its own virtualenv, and the console script from it: a service should not
# depend on what happens to be installed system-wide, and should not have its
# dependencies changed by something else on the machine.
venv_dir="$cache_dir/venv"
python3 -m venv "$venv_dir"
"$venv_dir/bin/pip" install --quiet --upgrade pip
"$venv_dir/bin/pip" install --quiet .
ln -sf "$venv_dir/bin/$name" "$bin_dir/$name"

sed -e "s|@BIN@|$bin_dir/$name|g" \
    -e "s|@CONFIG@|$config|g" \
    -e "s|@CACHE@|$cache_dir|g" \
    -e "s|@PORT@|$port|g" \
    scripts/$name.service >"$unit_dir/$name.service"

systemctl --user daemon-reload
systemctl --user enable --now "$name.service"

echo "listening on 127.0.0.1:$port, mirror in $cache_dir"
echo
echo "  curl -fsS http://127.0.0.1:$port/health   # needs no token"
echo "  journalctl --user -u $name -f"
echo

# The port serves the whole library in plaintext to anyone who can reach it.
# The server says so at startup too; saying it here means it is read before
# the thing is running rather than after.
if ! grep -q '"http_token"[[:space:]]*:[[:space:]]*"[^"]\+"' "$config"; then
  echo "WARNING: no http_token in $config — anything that can reach the port"
  echo "         can read the entire library. Set one:"
  echo "           openssl rand -base64 32"
  echo
fi
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'yes'; then
  echo "To keep it running when you are not logged in:"
  echo "  sudo loginctl enable-linger $USER"
fi
