# Changelog

The version a release is tagged with is the one in `summareader_mcp/__init__.py`,
and the release workflow refuses to publish without a section here that names
it.

## 0.3.0

### The library moved out of the cache directory

`~/.local/share/summareader-mcp` on Linux, `~/Library/Application Support/
summareader-mcp` on macOS, `%LOCALAPPDATA%` on Windows. `XDG_DATA_HOME` is
honoured when it is absolute and ignored when it is not, as the specification
requires.

It was `~/.cache`, which contradicted what this file already said about the
mirror: it runs no retention, so it is the most complete copy of a library
rather than a subset of one — and `~/.cache` is what a disk cleaner empties.

**The key is still `cache_dir` and the variable is still
`SUMMAREADER_MCP_CACHE`.** Renaming them would touch both Dockerfiles, both
compose files, the unit, `run.sh`, `freeze.sh` and every install that exists,
to change a spelling.

**Nothing is moved and nothing is deleted.** A library left in the old
directory is named on stderr, once, with what happens if it is ignored — the
new one starts empty and rebuilds from the log, which costs every blob
downloaded again. Copy it across by hand to avoid that.

### The window asks where, once

On a first run, and only when nothing else said — a `cache_dir`, the
environment variable or a named library all mean the question is answered.
Accepting writes the key, which is what stops it asking again. A library
already in the chosen directory is kept unless you say otherwise; starting
again costs a re-pull and nothing else.

### Configuration is a button

The settings were behind a menu bar holding one submenu labelled "Console" — a
grey strip that had to be clicked to find out what was in it, and two presses
to reach its only destination. It is a pill in the header now, the way the app
spells the same control.

### Fixed

- `scripts/install.sh` put its virtualenv inside the library directory and the
  uninstall message called that directory "a cache, safe to delete" — so
  following this installer's own advice deleted the virtualenv the installed
  command is a symlink into. It has its own directory now, and the message
  says what is actually kept.
- `cache_dir` is in `summareader-mcp.example.json` at last. It has been read
  since it existed and documented in the README, and was never in the file
  people copy.

## 0.2.0

The first published build. What is in it, rather than what changed.

### The mirror

- Joins a sync library as one more device, pulls the log, and keeps a decrypted
  copy in SQLite. It holds the master key and a plaintext library — the one
  place in the design where the encryption ends, which is what it is for.
- Its own implementation of the sync protocol, checked in the test suite
  against the app's own vectors rather than sharing code with it. That is what
  lets this repository build without the app beside it.
- Runs no retention, so the mirror is the *most complete* copy of a library
  rather than a subset of one. The cache directory deserves the care the
  library does.

### Ways in

- **MCP over stdio**, which is what a client that starts its own subprocess
  wants, and needs no service at all.
- **MCP over HTTP**, for a client somewhere else. Bound to loopback unless a
  `bearer_token` is set — the installer refuses a wider address without one
  rather than serving the library to the network.
- **A command line**: `search`, `recent`, `report`, `pull`, `status`.
- **A terminal interface**, so a machine reached over ssh is not reduced to
  flags.
- **A desktop console**, a window that starts the mirror and asks it what is in
  the library. It carries its own copy of the mirror.

### Running it

- A systemd **user** service, installed by `install.sh` with no root, or a
  container from the compose file.
- Frozen with PyInstaller into one executable that needs no Python on the
  machine it runs on, and proved on every build by opening a library with it —
  which is where a frozen bundle fails, at the moment somebody uses it rather
  than at start-up.
