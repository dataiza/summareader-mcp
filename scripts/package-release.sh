#!/usr/bin/env bash
# Everything a release repository is given, built into out/.
#
#   scripts/package-release.sh linux     # both bundles, for this machine
#   scripts/package-release.sh macos
#
# One argument and not two, because neither half cross-compiles. A frozen
# bundle is the interpreter and the libc of the machine that froze it, and a
# window needs a toolchain per platform — so the machine decides, and it
# produces both of that machine's downloads in one pass rather than freezing
# twice.
#
# The two kinds are separate downloads on purpose. A headless bundle is
# everything a server needs and no window; a console bundle is a window that
# carries its own mirror. Somebody installing on a box over ssh and somebody
# double-clicking on a laptop want different files.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

host="${1:-}"
out="out"
mkdir -p "$out"

name=summareader-mcp
version="$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' summareader_mcp/__init__.py)"
[ -n "$version" ] || { echo "summareader_mcp/__init__.py has no __version__" >&2; exit 1; }

case "$host" in
linux) arch=x64 ;;
macos) arch=arm64 ;;
*)
  sed -n '2,6p' "$0" >&2
  exit 1
  ;;
esac

command -v uv >/dev/null || { echo "uv is not installed." >&2; exit 1; }

# The frozen mirror, and the checks freeze.sh makes around it — it opens a
# library with the bundle, which is where a frozen build fails: at the moment
# somebody uses it, not at start-up.
scripts/freeze.sh

# The wheel, for the container. Pure Python, so unlike the frozen bundle it
# does not carry this machine's libc into a Debian image.
#
# Not into out/: everything in there is uploaded by a glob, and a directory in
# the middle of it fails the upload rather than being skipped.
wheels="$(mktemp -d)"
trap 'rm -rf "$wheels"' EXIT
uv build --wheel --out-dir "$wheels"

# ---- headless ---------------------------------------------------------------

dir="$name-headless-$host-$arch"
rm -rf "$dir"
mkdir "$dir"

cp "dist/$name" "$dir/"
cp "$wheels"/*.whl "$dir/"
cp LICENSE CHANGELOG.md "$name.example.json" "$dir/"
cp scripts/release/Dockerfile scripts/release/docker-compose.yml "$dir/"

cat scripts/release/README.head.md >"$dir/README.md"
if [ "$host" = linux ]; then
  # systemd is a Linux answer. Elsewhere the bundle is the binary and the
  # container; shipping an installer that cannot work would be worse than
  # shipping none, and the README must not describe one either.
  cp scripts/install.sh "$dir/"
  cp "scripts/$name.service" "$dir/"
  cat scripts/release/README.systemd.md >>"$dir/README.md"
fi
cat scripts/release/README.tail.md >>"$dir/README.md"

tar -czf "$out/$dir.tar.gz" "$dir"
rm -rf "$dir"
printf '  %-42s %s\n' "$dir" "$(du -h "$out/$dir.tar.gz" | cut -f1)"

# ---- console ----------------------------------------------------------------

if ! command -v flutter >/dev/null; then
  echo "No Flutter toolchain, so no console. The mirror above is complete on"
  echo "its own — the console is a window in front of it, not part of it."
  exit 0
fi

(cd console && flutter pub get && flutter build "$host" --release)

case "$host" in
linux)
  dir="$name-console"
  rm -rf "$dir"
  # Renamed from Flutter's `bundle`, because a tarball that unpacks into a
  # directory called `bundle` says nothing about what it is.
  cp -r console/build/linux/x64/release/bundle "$dir"
  # Beside the console's own executable, which is the first place it looks
  # after the environment. A window that cannot find a mirror has nothing to
  # show.
  cp "dist/$name" "$dir/"
  cp LICENSE CHANGELOG.md "$name.example.json" "$dir/"
  tar -czf "$out/$name-console-linux-x64.tar.gz" "$dir"
  rm -rf "$dir"

  # And the same thing as one file.
  #
  # The AppImage is what a person downloads: chmod +x, run, no repository and
  # no package manager. The tarball stays for anyone packaging this themselves
  # or unpacking it somewhere a fuse mount will not work.
  #
  # Only the AppImage can update itself — it is one file the console owns, so
  # replacing it is a rename. Unpacked into a directory there is nothing to
  # replace, and the console hides that control accordingly.
  scripts/appimage/build.sh \
    console/build/linux/x64/release/bundle \
    "dist/$name" \
    "$version" \
    "$out/SummaReaderMCP-$version-x86_64.AppImage"
  ;;
macos)
  app="$(find console/build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$app" ] || { echo "no .app was built" >&2; exit 1; }
  # Contents/MacOS is what sits beside the console's executable in a bundle.
  cp "dist/$name" "$app/Contents/MacOS/"
  # ditto rather than zip: it preserves the bundle bit and the resource forks
  # that make a .app openable after somebody unzips it.
  rm -f "$out/$name-console-macos.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$name-console-macos.zip"
  ;;
esac
printf '  console for %s\n' "$host"

echo
echo "$version, in $out/."
