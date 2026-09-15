#!/usr/bin/env bash
# Installs the MCP server as a systemd *user* service, on the HTTP transport.
# `--uninstall` reverses it.
#
# A user service and not a system one: this holds the master key and a
# plaintext copy of the library, so it belongs to one person and needs no root
# to install, inspect or remove.
#
# `--docker` runs it as a container instead — no Python on the machine, and
# the same image the compose file describes.
#
#   BIN_DIR=…   where the compiled binary goes  (default ~/.local/bin)
#   CONFIG=…    the secrets file                (default ./summareader-mcp.local.json)
#   CACHE_DIR=… the decrypted library            (default ~/.local/share/summareader-mcp)
#   VENV_DIR=…  a source install's virtualenv    (default ~/.local/lib/summareader-mcp)
#   PORT=…      what it listens on              (default 8100)
#   HOST=…      the address it binds            (default 127.0.0.1)
set -euo pipefail

# Two layouts, one script. In a checkout this file is in scripts/ and the
# repository is its parent; in a released headless bundle everything is flat
# beside it. Told apart by the unit template, which this script cannot work
# without either way.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$here/summareader-mcp.service" ]; then
  repo="$here"
  unit_template="$here/summareader-mcp.service"
else
  repo="$(cd "$here/.." && pwd)"
  unit_template="$repo/scripts/summareader-mcp.service"
fi
cd "$repo"

# mise puts the toolchains on PATH from a login shell only, and this is a
# script somebody may well run from a hook or over ssh.
export PATH="$HOME/.local/share/mise/shims:$PATH"

name="summareader-mcp"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
unit_dir="$HOME/.config/systemd/user"
config="${CONFIG:-$repo/$name.local.json}"
cache_dir="${CACHE_DIR:-$HOME/.local/share/$name}"
port="${PORT:-8100}"
host="${HOST:-127.0.0.1}"

# In a container instead. `restart: unless-stopped` and an enabled
# docker.service are what bring it back after a reboot, so there is no systemd
# unit on this path to keep in step with compose.
if [ "${1:-}" = "--docker" ]; then
  command -v docker >/dev/null || { echo "Docker is not installed." >&2; exit 1; }
  if [ "${2:-}" = "--uninstall" ]; then
    docker compose down
    echo "stopped. ./.cache is kept; it is a cache and safe to delete."
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
  sync_host="$(sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"[a-z]*:\/\/\([^:\/"]*\).*/\1/p' "$config")"
  case "$sync_host" in
    localhost|127.0.0.1)
      echo "note: \"server\" is $sync_host — from inside the container that is the"
      echo "      container itself. Use the sync server's shared network and its"
      echo "      service name, or an address this host publishes." ;;
    ''|http*) ;;
    *)
      docker network ls --format '{{.Name}}' | grep -q "sync" \
        || echo "note: \"server\" names $sync_host; uncomment the sync network block in docker-compose.yml." ;;
  esac
  exit 0
fi

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now "$name.service" 2>/dev/null || true
  rm -f "$unit_dir/$name.service" "$bin_dir/$name"
  rm -rf "${VENV_DIR:-$HOME/.local/lib/$name}"
  systemctl --user daemon-reload
  echo "removed: the service, the binary and its virtualenv."
  # Not "safe to delete" any more, and it never was for a source install: the
  # virtualenv used to be in here. It is also the most complete copy of the
  # library, because a mirror runs no retention.
  echo "kept:    $cache_dir — the decrypted library; and $config, which holds"
  echo "         the master key. Neither is recoverable from the other."
  exit 0
fi

if [ ! -f "$config" ]; then
  echo "No config at $config." >&2
  echo "  cp $name.example.json $name.local.json   # then fill it in" >&2
  exit 1
fi

has_bearer_token() {
  # Either spelling: `http_token` is what older configs call it, and the
  # server still reads them.
  grep -qE '"(bearer|http)_token"[[:space:]]*:[[:space:]]*"[^"]+"' "$config"
}

# Loopback is one machine's business. Anything wider publishes the whole
# library, in plaintext, to whoever can route to this port — so that is a
# refusal rather than the warning further down, which is about a port only
# this host can reach.
case "$host" in
  127.0.0.1|::1|localhost) ;;
  *)
    has_bearer_token || {
      echo "Refusing to bind $host without a bearer_token in $config." >&2
      echo "  That address serves the entire library, in plaintext, to anyone" >&2
      echo "  who can reach it. Set one and install again:" >&2
      echo "    openssl rand -base64 32" >&2
      exit 1
    } ;;
esac

mkdir -p "$bin_dir" "$unit_dir" "$cache_dir"

# Two ways to end up with a binary, and which one is available says which
# layout this is.
#
# From source: its own virtualenv, and the console script out of it. A service
# should not depend on what happens to be installed system-wide, and should not
# have its dependencies changed by something else on the machine.
#
# From a released bundle: the frozen executable beside this script, which
# carries its own interpreter and needs no Python on the machine at all. That
# is the whole point of freezing it, and installing a venv here would ask for
# an interpreter the bundle exists to avoid needing.
if [ -f "$repo/pyproject.toml" ]; then
  # Not inside $cache_dir. It lived there, and the uninstall message below
  # called that same directory "a cache, safe to delete" — so following this
  # installer's own advice removed the virtualenv that $bin_dir/summareader-mcp
  # is a symlink into, and the command stopped existing.
  #
  # Its own directory: it is neither the library nor a cache, it is an
  # installation, and it should go when the program goes rather than when
  # somebody tidies up.
  venv_dir="${VENV_DIR:-$HOME/.local/lib/$name}"
  python3 -m venv "$venv_dir"
  "$venv_dir/bin/pip" install --quiet --upgrade pip
  "$venv_dir/bin/pip" install --quiet .
  ln -sf "$venv_dir/bin/$name" "$bin_dir/$name"
elif [ -x "$repo/$name" ]; then
  echo "Installing the frozen binary beside this script — no Python needed."
  install -m 755 "$repo/$name" "$bin_dir/$name"
else
  echo "Neither source to install from nor a binary beside this script." >&2
  exit 1
fi

sed -e "s|@BIN@|$bin_dir/$name|g" \
    -e "s|@CONFIG@|$config|g" \
    -e "s|@CACHE@|$cache_dir|g" \
    -e "s|@PORT@|$port|g" \
    -e "s|@HOST@|$host|g" \
    "$unit_template" >"$unit_dir/$name.service"

systemctl --user daemon-reload
systemctl --user enable --now "$name.service"

echo "listening on $host:$port, mirror in $cache_dir"
echo
echo "  curl -fsS http://$host:$port/health   # needs no token"
echo "  journalctl --user -u $name -f"
echo

# The port serves the whole library in plaintext to anyone who can reach it.
# The server says so at startup too; saying it here means it is read before
# the thing is running rather than after.
if ! has_bearer_token; then
  echo "WARNING: no bearer_token in $config — anything that can reach the port"
  echo "         can read the entire library. Set one:"
  echo "           openssl rand -base64 32"
  echo
fi
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'yes'; then
  echo "To keep it running when you are not logged in:"
  echo "  sudo loginctl enable-linger $USER"
fi
