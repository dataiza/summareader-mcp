#!/usr/bin/env bash
# Builds every version there is, into dist/.
#
#   scripts/build.sh              # both of them
#   scripts/build.sh --headless   # only the frozen mirror, for this machine
#   scripts/build.sh --console    # only the desktop console, for this machine
#
# There are two programs here and they are not the same thing. The mirror is
# the Python package frozen by PyInstaller: one file that serves, searches and
# paints the terminal interface with no Python on the machine it runs on. The
# console is a Flutter app in front of it — a separate process that starts one
# and asks it what is in the library. Neither of them cross-compiles: a frozen
# bundle is the interpreter of the machine that froze it, and a window needs a
# toolchain per platform. Everything below is for the machine you run it on.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

what="${1:-all}"
out="dist"
mkdir -p "$out"

# PyInstaller and Flutter both narrate at length and neither has anything to
# say when it worked. Kept rather than discarded, because when one of them
# fails its noise is the whole of what there is to read.
quietly() {
  local log
  log="$(mktemp)"
  trap 'rm -f "$log"' RETURN
  "$@" >"$log" 2>&1 || { cat "$log" >&2; exit 1; }
}

if [ "$what" = all ] || [ "$what" = --headless ]; then
  command -v uv >/dev/null || {
    echo "No uv, so nothing can be frozen: https://docs.astral.sh/uv/" >&2
    exit 1
  }

  # freeze.sh rather than a second pyinstaller invocation here: it also proves
  # the bundle by opening a library, which is where a frozen build fails —
  # schema.sql is read through importlib.resources and is the first thing lost.
  echo "The frozen mirror, for this machine:"
  quietly ./scripts/freeze.sh
  printf '  %-38s %s\n' "$out/summareader-mcp" "$(du -h "$out/summareader-mcp" | cut -f1)"
  echo
  echo "  Only this machine's, and no flag changes that. PyInstaller freezes"
  echo "  the interpreter it is run with; macOS and Windows have to be built"
  echo "  on macOS and Windows, and so far nobody has."
fi

if [ "$what" = all ] || [ "$what" = --console ]; then
  [ "$what" = all ] && echo
  if ! command -v flutter >/dev/null; then
    if [ "$what" = --console ]; then
      echo "No Flutter toolchain, so no console: https://flutter.dev/" >&2
      exit 1
    fi
    echo "No Flutter toolchain, so no console. The mirror above is complete"
    echo "on its own — the console is a window in front of it, not part of it."
    exit 0
  fi

  echo "The desktop console, for this machine (linux):"
  (cd console && quietly flutter build linux --release)

  # A bundle, not a file: the launcher wants its lib/ and data/ beside it, so
  # what lands in dist/ is the whole tree under its own name.
  bundle="$out/summareader-mcp-console-linux-x64"
  rm -rf "$bundle"
  cp -r console/build/linux/x64/release/bundle "$bundle"
  printf '  %-38s %s\n' "$bundle/" "$(du -sh "$bundle" | cut -f1)"
  echo
  echo "  Only this machine's. macOS and Windows scaffolding is committed and"
  echo "  neither has ever been built — a window needs that platform's own"
  echo "  toolchain, and there is no runner and no cross setup for either."
fi

echo
echo "In $out/. The mirror is the whole program; the console is a separate one"
echo "that starts, watches and searches a library through it."
