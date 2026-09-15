# Changelog

The version a release is tagged with is the one in `summareader_mcp/__init__.py`,
and the release workflow refuses to publish without a section here that names
it.

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
