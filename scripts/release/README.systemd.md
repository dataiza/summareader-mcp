
## Install it as a service

```sh
./install.sh
```

A systemd **user** service on the HTTP transport, with no root involved: this
holds one person's key and one person's library, so it belongs to one person.
It installs the frozen binary beside this README, which carries its own
interpreter — no Python needed on the machine.

`BIN_DIR`, `CONFIG`, `CACHE_DIR`, `PORT` and `HOST` override where things go.
The defaults are `~/.local/bin`, `./summareader-mcp.local.json`,
`~/.local/share/summareader-mcp`, `8100` and `127.0.0.1`.

**`HOST` is refused without a `bearer_token` — or a `tokens` block — in the
config.** That address serves the entire library, in plaintext, to anything
that can route to it.

```sh
openssl rand -base64 32
```

`./install.sh --uninstall` reverses it. It keeps the config, which is not
recoverable, and the cache, which is.

To keep it running when you are not logged in:

```sh
sudo loginctl enable-linger "$USER"
```
