#!/usr/bin/env bash
# Re-copy the app's look into the console.
#
#   scripts/sync-ui.sh [path-to-summareader-checkout]   # default ../summareader
#
# Why a copy rather than a `git:` dependency in console/pubspec.yaml: reading
# that repository's metadata needs a credential, and the machines that build
# this console do not have one. A dependency that resolves on one laptop and
# fails everywhere else is worse than a directory somebody can see.
#
# console/test/vendored_ui_test.dart fails when the two have drifted and a
# checkout is there to compare against, so running this is the fix rather than
# something to remember.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-$here/../summareader}"

if [ ! -d "$app/packages/summareader_ui" ]; then
  echo "No SummaReader checkout at $app." >&2
  echo "That is where the look lives — clone it beside this repository, or" >&2
  echo "pass its path: scripts/sync-ui.sh /path/to/summareader" >&2
  exit 1
fi

# --delete, because a widget removed there has to disappear here too: a stale
# file that still compiles is the kind of drift nobody notices.
rsync -a --delete \
  --exclude VENDORED.md \
  "$app/packages/summareader_ui/" "$here/console/packages/summareader_ui/"

# The two faces the package asks for. A package cannot carry the assets an
# application has to declare, so they travel separately and arrive together.
mkdir -p "$here/console/assets/fonts"
cp "$app/assets/fonts/Caprasimo-Regular.ttf" \
   "$app/assets/fonts/Figtree-Variable.ttf" \
   "$here/console/assets/fonts/"

echo "summareader_ui and its fonts copied from $app"
